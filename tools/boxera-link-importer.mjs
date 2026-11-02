#!/usr/bin/env node
// Server-side link importer for Boxera.
//
// Boxera's upload API has no "fetch this URL" endpoint, so somebody has to
// read the link. Running that somebody on a server keeps the video off the
// phone entirely: no storage, no mobile data.
//
//   node boxera-link-importer.mjs once <url> [--kind=video|drive] [--folder-id=N]
//       [--channel-id=N] [--title=T] [--state=PATH] [--wait-seconds=N]
//   node boxera-link-importer.mjs serve [--port=8787] [--bind=127.0.0.1]
//
// Env: BOXERA_API_BASE, BOXERA_API_TOKEN, BOXERA_PART_SIZE, IMPORT_TOKEN,
//      IMPORT_BIND, IMPORT_PORT, IMPORT_CONCURRENCY, IMPORT_ALLOW_PRIVATE,
//      IMPORT_STATE_DIR
//
// Requires Node 22 or newer. No dependencies.

import { createHash, randomUUID } from 'node:crypto';
import { createServer } from 'node:http';
import dns from 'node:dns/promises';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const API_BASE = (process.env.BOXERA_API_BASE || 'https://boxera.ir/api')
  .replace(/\/+$/, '');
const TOKEN = (process.env.BOXERA_API_TOKEN || '').trim();
const PART_SIZE = Number(process.env.BOXERA_PART_SIZE || 8 * 1024 * 1024);
const STATE_DIR =
  process.env.IMPORT_STATE_DIR || path.join(os.tmpdir(), 'boxera-link-importer');
const ALLOW_PRIVATE = process.env.IMPORT_ALLOW_PRIVATE === '1';
const USER_AGENT = 'FilmcaseLinkImporter/1.0';

const tasks = new Map();
let running = 0;
const pending = [];
// --state only exists for the one-shot mode; the queue always uses STATE_DIR.
let singleStatePath = null;

// ---------- helpers ----------

function log(...args) {
  console.log(new Date().toISOString(), ...args);
}

class ImportError extends Error {}

function parseArgs(argv) {
  const out = { _: [] };
  for (const item of argv) {
    if (!item.startsWith('--')) {
      out._.push(item);
      continue;
    }
    const eq = item.indexOf('=');
    if (eq < 0) out[item.slice(2)] = true;
    else out[item.slice(2, eq)] = item.slice(eq + 1);
  }
  return out;
}

function isPrivateAddress(address) {
  return (
    /^(127\.|10\.|192\.168\.|169\.254\.|0\.)/.test(address) ||
    /^172\.(1[6-9]|2\d|3[01])\./.test(address) ||
    address === '::1' ||
    /^f[cd][0-9a-f]{2}:/i.test(address) ||
    /^fe80:/i.test(address)
  );
}

async function assertPublicUrl(url) {
  if (!/^https?:\/\//i.test(url)) {
    throw new ImportError('Only absolute http(s) URLs can be imported.');
  }
  const host = new URL(url).hostname;
  if (host === 'localhost' || host.endsWith('.localhost')) {
    throw new ImportError('Refusing to fetch a loopback host.');
  }
  if (ALLOW_PRIVATE) return;
  if (/^[0-9.]+$/.test(host) || host.includes(':')) {
    if (isPrivateAddress(host)) {
      throw new ImportError(`Refusing to fetch the private address ${host}.`);
    }
    return;
  }
  const records = await dns.lookup(host, { all: true }).catch(() => []);
  if (records.some((entry) => isPrivateAddress(entry.address))) {
    throw new ImportError(`${host} resolves to a private address.`);
  }
}

async function openStream(url, range) {
  await assertPublicUrl(url);
  const headers = { Accept: '*/*', 'User-Agent': USER_AGENT };
  if (range) headers.Range = range;
  const response = await fetch(url, { method: 'GET', headers, redirect: 'manual' });
  if (response.status >= 300 && response.status < 400) {
    const next = response.headers.get('location');
    await response.body?.cancel().catch(() => {});
    if (!next) throw new ImportError(`Redirect ${response.status} had no target.`);
    return openStream(new URL(next, url).href, range);
  }
  return response;
}

async function drainBody(response) {
  if (!response?.body) return;
  try {
    await response.body.cancel();
  } catch {}
}

async function readRange(url, offset, length) {
  let lastError;
  for (let attempt = 1; attempt <= 3; attempt++) {
    let response;
    try {
      response = await openStream(url, `bytes=${offset}-${offset + length - 1}`);
      if (response.status !== 206) {
        throw new ImportError(
          `Link answered ${response.status} to a Range request; it must support byte ranges.`,
        );
      }
      const chunks = [];
      let seen = 0;
      for await (const chunk of response.body) {
        const piece = Buffer.from(chunk);
        seen += piece.length;
        if (seen > length) {
          throw new ImportError('Link sent more bytes than were requested.');
        }
        chunks.push(piece);
      }
      if (seen !== length) {
        throw new ImportError(`Link gave ${seen} bytes where ${length} were needed.`);
      }
      return Buffer.concat(chunks, length);
    } catch (error) {
      lastError = error;
      await drainBody(response);
      if (attempt < 3) await new Promise((done) => setTimeout(done, attempt * 2000));
    }
  }
  throw lastError;
}

function nameFromDisposition(header, url) {
  const encoded = /filename\*\s*=\s*(?:UTF-8'')?([^;]+)/i.exec(header || '');
  const plain = /filename\s*=\s*"?([^";]+)"?/i.exec(header || '');
  const raw = (encoded?.[1] || plain?.[1] || '').trim().replace(/^["']|["']$/g, '');
  if (raw) {
    try {
      return decodeURIComponent(raw);
    } catch {
      return raw;
    }
  }
  const segments = new URL(url).pathname.split('/').filter(Boolean);
  return decodeURIComponent(segments.at(-1) || 'video.mp4');
}

async function probeLink(url) {
  const response = await openStream(url, 'bytes=0-0');
  if (response.status !== 206) {
    await drainBody(response);
    throw new ImportError(
      `Link does not support byte ranges (answered ${response.status}).`,
    );
  }
  const total = Number((response.headers.get('content-range') || '').split('/').at(-1));
  await drainBody(response);
  if (!Number.isFinite(total) || total <= 0) {
    throw new ImportError('Link did not declare its total size in Content-Range.');
  }
  const contentType = (response.headers.get('content-type') || '')
    .split(';')[0]
    .trim()
    .toLowerCase();
  let name = nameFromDisposition(response.headers.get('content-disposition'), url);
  if (!/\.[a-z0-9]{1,5}$/i.test(name)) {
    const extension = contentType.includes('matroska')
      ? '.mkv'
      : contentType.includes('quicktime')
        ? '.mov'
        : contentType.includes('webm')
          ? '.webm'
          : contentType.includes('ogg')
            ? '.ogv'
            : '.mp4';
    name = `${name}${extension}`;
  }
  return { name, size: total, mimeType: contentType || 'video/mp4' };
}

// ---------- Boxera API ----------

function unwrap(json) {
  if (json && typeof json === 'object') {
    if (json.data && typeof json.data === 'object' && !Array.isArray(json.data)) {
      return json.data;
    }
    return json;
  }
  return {};
}

async function callBoxera(method, apiPath, body) {
  if (!TOKEN) throw new ImportError('BOXERA_API_TOKEN is not set.');
  const response = await fetch(`${API_BASE}${apiPath}`, {
    method,
    headers: {
      Accept: 'application/json',
      Authorization: `Bearer ${TOKEN}`,
      ...(body ? { 'Content-Type': 'application/json' } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await response.text();
  let json;
  try {
    json = text ? JSON.parse(text) : {};
  } catch {
    json = {};
  }
  if (!response.ok) {
    const message =
      json?.message || json?.data?.message || `Boxera answered ${response.status}.`;
    throw new ImportError(`${message} (${method} ${apiPath} -> ${response.status})`);
  }
  return unwrap(json);
}

function parseHeaders(raw) {
  const out = {};
  if (Array.isArray(raw)) {
    for (const item of raw) {
      if (!item || typeof item !== 'object') continue;
      const key = item.name || item.key || item.header;
      if (key != null && item.value != null) out[String(key)] = String(item.value);
    }
  } else if (raw && typeof raw === 'object') {
    for (const [key, value] of Object.entries(raw)) out[key] = String(value);
  }
  for (const key of ['host', 'content-length']) delete out[key];
  return out;
}

async function reportPart(sessionId, payload) {
  await callBoxera(
    'POST',
    `/uploads/${encodeURIComponent(sessionId)}/part-retry`,
    payload,
  ).catch(() => {});
}

async function storageSend(sessionId, part, bytes) {
  let lastError;
  for (let attempt = 1; attempt <= 3; attempt++) {
    try {
      const response = await fetch(part.upload_url, {
        method: (part.method || 'PUT').toUpperCase(),
        headers: part.headers,
        body: bytes,
      });
      if (response.ok) {
        const etag = (response.headers.get('etag') || '').trim();
        if (!etag) {
          throw new ImportError(`Storage gave no ETag for part ${part.part_number}.`);
        }
        return etag;
      }
      lastError = new ImportError(
        `Storage rejected part ${part.part_number} (${response.status}).`,
      );
    } catch (error) {
      lastError = error;
    }
    await reportPart(sessionId, {
      part_number: part.part_number,
      attempt,
      status: 'retry',
      message: String(lastError?.message || lastError).slice(0, 255),
    });
    await new Promise((done) => setTimeout(done, attempt * 2000));
  }
  throw lastError;
}

function statePathFor(id) {
  return singleStatePath || path.join(STATE_DIR, `${id}.json`);
}

function taskToState(task) {
  return {
    id: task.id,
    url: task.url,
    kind: task.kind,
    folder_id: task.folderId ?? null,
    channel_id: task.channelId ?? null,
    title: task.title,
    created_at: task.createdAt,
    updated_at: new Date().toISOString(),
    state: task.state,
    detail: task.detail,
    size: task.size,
    uploaded_bytes: task.uploadedBytes,
    progress: task.progress,
    request_id: task.requestId,
    session_id: task.sessionId,
    file_id: task.fileId,
    video_id: task.videoId,
    name: task.name,
    mime_type: task.mimeType,
    parts: Object.fromEntries(task.parts),
    m3u8_url: task.m3u8Url,
    preview_url: task.previewUrl,
    error: task.error,
  };
}

function saveState(task) {
  const target = statePathFor(task.id);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  const temporary = `${target}.tmp`;
  fs.writeFileSync(temporary, JSON.stringify(taskToState(task), null, 2));
  fs.renameSync(temporary, target);
}

function newTask({ url, kind, folderId, channelId, title, id }) {
  return {
    id: id || randomUUID(),
    url,
    kind,
    folderId,
    channelId,
    title,
    createdAt: new Date().toISOString(),
    state: 'queued',
    detail: 'در صف',
    size: 0,
    uploadedBytes: 0,
    progress: 0,
    requestId: null,
    sessionId: null,
    fileId: null,
    videoId: null,
    name: '',
    mimeType: '',
    parts: new Map(),
    m3u8Url: null,
    previewUrl: null,
    error: null,
    waitSeconds: 1800,
  };
}

function loadFromDisk(id) {
  try {
    const saved = JSON.parse(fs.readFileSync(statePathFor(id), 'utf8'));
    const task = newTask({
      url: saved.url,
      kind: saved.kind === 'drive' ? 'drive' : 'video',
      folderId: saved.folder_id,
      channelId: saved.channel_id,
      title: saved.title,
      id: saved.id,
    });
    Object.assign(task, {
      createdAt: saved.created_at || task.createdAt,
      state: saved.state,
      detail: saved.detail,
      size: saved.size || 0,
      uploadedBytes: saved.uploaded_bytes || 0,
      progress: saved.progress || 0,
      requestId: saved.request_id,
      sessionId: saved.session_id,
      fileId: saved.file_id,
      videoId: saved.video_id,
      name: saved.name,
      mimeType: saved.mime_type,
      m3u8Url: saved.m3u8_url,
      previewUrl: saved.preview_url,
      error: saved.error,
      parts: new Map(
        Object.entries(saved.parts || {}).map(([key, value]) => [Number(key), value]),
      ),
    });
    return task;
  } catch {
    return null;
  }
}

function makeReporter(task) {
  return (patch) => {
    Object.assign(task, patch);
    saveState(task);
    log(task.id, task.state, task.detail || task.error || '');
  };
}

// ---------- import ----------

async function runImport(task, report) {
  report({ state: 'probing', detail: 'خواندن اطلاعات لینک' });
  const meta = await probeLink(task.url);
  task.requestId = task.requestId || `import-${task.id}`;
  report({
    state: 'init',
    detail: 'ساخت نشست آپلود در Boxera',
    name: meta.name,
    mimeType: meta.mimeType,
    size: meta.size,
    requestId: task.requestId,
  });

  const initBody = {
    space: task.kind === 'drive' ? 'drive' : 'video',
    original_name: meta.name,
    mime_type: meta.mimeType,
    size_bytes: meta.size,
    upload_request_id: task.requestId,
    part_size: PART_SIZE,
  };
  if (task.kind === 'drive' && task.folderId) initBody.folder_id = Number(task.folderId);
  if (task.kind === 'video' && task.channelId) initBody.channel_id = Number(task.channelId);
  if (task.fileId) initBody.file_id = task.fileId;

  const session = await callBoxera('POST', '/uploads/init', initBody);
  const sessionId = String(session.upload_session_id || '');
  if (!sessionId) throw new ImportError('Boxera gave no upload_session_id.');
  const partSize = Number(session.part_size || PART_SIZE);
  const totalParts =
    Number(session.part_count || 0) > 0
      ? Number(session.part_count)
      : Math.ceil(meta.size / partSize);
  report({
    state: 'uploading',
    sessionId,
    fileId: session.file_id || task.fileId,
    detail: 'انتقال بخش‌ها از لینک به Boxera',
  });

  if (String(session.upload_status || '') === 'completed') {
    task.fileId = session.file_id || task.fileId;
    task.parts = new Map();
  } else if (String(session.upload_protocol || 's3-multipart') === 'tus-edge') {
    await runTus(task, session, partSize, report);
    report({ state: 'completing', detail: 'نهایی‌سازی آپلود' });
    const done = await callBoxera('POST', `/uploads/${encodeURIComponent(sessionId)}/complete`, {
      parts: [],
    });
    task.fileId = done.id || done.file_id || task.fileId;
  } else {
    let startPart = 1;
    for (let page = 0; page < 1000; page++) {
      const list = await callBoxera(
        'POST',
        `/uploads/${encodeURIComponent(sessionId)}/part-urls`,
        { start_part: startPart, limit: 200 },
      );
      for (const item of list.uploaded_parts || []) {
        const number = Number(item?.part_number);
        if (number && item.etag) task.parts.set(number, String(item.etag));
      }
      for (const part of list.parts || []) {
        const number = Number(part.part_number);
        if (!number || task.parts.has(number)) continue;
        const length = Math.min(partSize, Math.max(0, task.size - (number - 1) * partSize));
        if (length <= 0) continue;
        report({ detail: `بخش ${number} از ${totalParts} • خواندن از لینک` });
        const bytes = await readRange(task.url, (number - 1) * partSize, length);
        report({ detail: `بخش ${number} از ${totalParts} • آپلود به Boxera` });
        const etag = await storageSend(
          sessionId,
          { ...part, headers: parseHeaders(part.headers) },
          bytes,
        );
        task.parts.set(number, etag);
        await reportPart(sessionId, {
          part_number: number,
          attempt: 1,
          status: 'success',
          etag,
          size: length,
        });
        report({
          uploadedBytes: uploadedBytesOf(task, partSize),
          progress: task.size ? uploadedBytesOf(task, partSize) / task.size : 0,
        });
      }
      if (!list.has_more_parts) break;
      const next = Number(list.next_start_part || 0);
      if (!next || next <= startPart) break;
      startPart = next;
    }
    if (task.parts.size < totalParts) {
      throw new ImportError(
        `آپلود ناقص ماند (${task.parts.size} از ${totalParts} بخش)؛ همان دستور را دوباره اجرا کن.`,
      );
    }
    report({ state: 'completing', detail: 'ثبت پایان آپلود در Boxera' });
    const parts = [...task.parts.entries()]
      .sort((a, b) => a[0] - b[0])
      .map(([number, etag]) => ({ part_number: number, etag }));
    const done = await callBoxera('POST', `/uploads/${encodeURIComponent(sessionId)}/complete`, {
      parts,
    });
    task.fileId = done.id || done.file_id || task.fileId;
  }

  if (!task.fileId) throw new ImportError('Boxera did not return a file id.');

  if (task.kind === 'drive') {
    report({
      state: 'ready',
      fileId: task.fileId,
      uploadedBytes: task.size,
      progress: 1,
      detail: 'فایل در فولدر Drive آماده شد',
    });
    return { state: 'ready', m3u8Url: null };
  }

  report({
    state: 'registering',
    uploadedBytes: task.size,
    progress: 1,
    detail: 'ثبت ویدیو در Boxera',
  });
  const video = await callBoxera('POST', '/video/videos', {
    media_file_id: task.fileId,
    title: task.title || task.name,
    upload_request_id: `video-${task.id}`,
    visibility: 'unlisted',
    access_type: 'free',
    ...(task.channelId ? { channel_id: Number(task.channelId) } : {}),
  });
  const videoId = video.video?.id || video.video_id || video.id;
  if (!videoId) throw new ImportError('Boxera did not return a video id.');
  report({
    state: 'processing',
    videoId: String(videoId),
    detail: 'در انتظار تبدیل ویدیو',
  });

  const deadline = Date.now() + Math.max(0, Number(task.waitSeconds || 0)) * 1000;
  for (;;) {
    const info = await callBoxera(
      'GET',
      `/video/videos/${encodeURIComponent(String(videoId))}/processing`,
    );
    const playback = info.playback || {};
    const shareUrl = playback.share_url || playback.m3u8_url || info.m3u8_url || null;
    const percent = info.transcode?.progress?.percent ?? null;
    report({
      state: info.state || 'processing',
      m3u8Url: shareUrl,
      previewUrl: playback.url || playback.preview_url || info.preview_url || null,
      detail:
        info.state === 'ready'
          ? 'آماده پخش'
          : `در حال پردازش${percent == null ? '' : ` ${percent}%`}`,
    });
    if (
      info.state === 'ready' ||
      info.state === 'failed' ||
      info.state === 'unavailable'
    ) {
      return { state: info.state, m3u8Url: shareUrl };
    }
    if (Date.now() > deadline) return { state: 'pending', m3u8Url: shareUrl };
    const rawPoll = Number(info.poll_after_seconds);
    const waitSeconds = Number.isFinite(rawPoll) && rawPoll >= 0 ? rawPoll : 5;
    await new Promise((done) => setTimeout(done, waitSeconds * 1000));
  }
}

function uploadedBytesOf(task, partSize) {
  let bytes = 0;
  for (const number of task.parts.keys()) {
    bytes += Math.min(partSize, Math.max(0, task.size - (number - 1) * partSize));
  }
  return bytes;
}

async function runTus(task, session, partSize, report) {
  const url = session.upload_url;
  if (!url) throw new ImportError('Boxera gave no TUS upload_url.');
  const headers = { 'Tus-Resumable': '1.0.0', ...parseHeaders(session.upload_headers) };
  let offset = Number(session.upload_offset || 0);
  try {
    const head = await fetch(url, { method: 'HEAD', headers });
    await drainBody(head);
    const remote = Number(head.headers.get('upload-offset'));
    if (Number.isFinite(remote) && remote >= 0) offset = remote;
  } catch {
    // The offset from init is still a valid starting point.
  }
  const totalParts = Math.ceil(task.size / partSize);
  while (offset < task.size) {
    const length = Math.min(partSize, task.size - offset);
    const number = Math.floor(offset / partSize) + 1;
    report({ detail: `بخش ${number} از ${totalParts} • خواندن از لینک` });
    const bytes = await readRange(task.url, offset, length);
    report({ detail: `بخش ${number} از ${totalParts} • آپلود به Boxera` });
    const response = await fetch(url, {
      method: 'PATCH',
      headers: {
        ...headers,
        'Upload-Offset': String(offset),
        'Content-Type': 'application/offset+octet-stream',
      },
      body: bytes,
    });
    await response.text().catch(() => '');
    if (!response.ok) {
      throw new ImportError(`TUS rejected the chunk (${response.status}).`);
    }
    offset = Number(response.headers.get('upload-offset')) || offset + length;
    report({
      uploadedBytes: offset,
      progress: task.size ? offset / task.size : 0,
    });
  }
}

// ---------- queue ----------

function enqueue(task) {
  tasks.set(task.id, task);
  saveState(task);
  pending.push(task);
  drain();
  return task;
}

function drain() {
  const limit = Number(process.env.IMPORT_CONCURRENCY || 1);
  while (running < limit && pending.length) {
    const task = pending.shift();
    running += 1;
    const report = makeReporter(task);
    runImport(task, report)
      .then((result) => {
        if (result.state === 'failed' || result.state === 'unavailable') {
          report({ state: 'failed', error: 'Boxera پردازش ویدیو را ناموفق اعلام کرد.' });
        } else if (!['ready', 'failed'].includes(task.state)) {
          report({ state: 'done', detail: 'انتقال تمام شد' });
        }
      })
      .catch((error) => {
        report({
          state: 'failed',
          error: String(error?.message || error),
          detail: 'انتقال ناموفق بود',
        });
      })
      .finally(() => {
        running -= 1;
        drain();
      });
  }
}

// ---------- http server ----------

function json(response, status, payload) {
  const body = JSON.stringify(payload, null, 2);
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
  });
  response.end(body);
}

function publicView(task) {
  return {
    id: task.id,
    url: task.url,
    kind: task.kind,
    folder_id: task.folderId ?? null,
    channel_id: task.channelId ?? null,
    title: task.title,
    state: task.state,
    detail: task.detail,
    size: task.size,
    uploaded_bytes: task.uploadedBytes,
    progress: Number((task.progress || 0).toFixed(4)),
    file_id: task.fileId,
    video_id: task.videoId,
    m3u8_url: task.m3u8Url,
    error: task.error,
    updated_at: new Date().toISOString(),
  };
}

function readBody(request) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    request.on('data', (chunk) => {
      size += chunk.length;
      if (size > 64 * 1024) {
        reject(new ImportError('Request body is too large.'));
        request.destroy();
        return;
      }
      chunks.push(chunk);
    });
    request.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    request.on('error', reject);
  });
}

function resolveKnown(id) {
  return tasks.get(id) || loadFromDisk(id);
}

function startServer() {
  const bind = process.env.IMPORT_BIND || '127.0.0.1';
  const port = Number(process.env.IMPORT_PORT || 8787);
  const secret = (process.env.IMPORT_TOKEN || '').trim();
  if (!secret && bind !== '127.0.0.1' && bind !== 'localhost') {
    console.error('Refusing to listen on a public address without IMPORT_TOKEN set.');
    process.exit(1);
  }
  const server = createServer(async (request, response) => {
    const requestUrl = new URL(request.url, `http://${request.headers.host || 'localhost'}`);
    try {
      if (request.method === 'GET' && requestUrl.pathname === '/health') {
        json(response, 200, {
          ok: true,
          api_base: API_BASE,
          has_boxera_token: Boolean(TOKEN),
          queue: { running, pending: pending.length },
        });
        return;
      }
      if (secret && request.headers.authorization !== `Bearer ${secret}`) {
        json(response, 401, { message: 'Invalid import token.' });
        return;
      }
      if (request.method === 'POST' && requestUrl.pathname === '/import') {
        const body = JSON.parse((await readBody(request)) || '{}');
        const link = String(body.url || '').trim();
        if (!/^https?:\/\//i.test(link)) {
          json(response, 422, { message: 'A full http(s) url is required.' });
          return;
        }
        await assertPublicUrl(link);
        const kind = body.kind === 'drive' ? 'drive' : 'video';
        if (kind === 'drive' && !body.folder_id && !body.at_root) {
          json(response, 422, { message: 'folder_id is required for a drive import.' });
          return;
        }
        const task = newTask({
          url: link,
          kind,
          folderId: body.folder_id ?? null,
          channelId: body.channel_id ?? null,
          title: String(body.title || '').trim(),
        });
        task.waitSeconds = Number(body.wait_seconds ?? 1800);
        enqueue(task);
        json(response, 202, publicView(task));
        return;
      }
      const status = /^\/status\/([0-9a-f-]{36})$/.exec(requestUrl.pathname);
      if (request.method === 'GET' && status) {
        const known = resolveKnown(status[1]);
        if (!known) {
          json(response, 404, { message: 'Unknown import id.' });
          return;
        }
        json(response, 200, publicView(known));
        return;
      }
      if (request.method === 'GET' && requestUrl.pathname === '/imports') {
        json(response, 200, [...tasks.values()].map(publicView));
        return;
      }
      json(response, 404, { message: 'No such endpoint.' });
    } catch (error) {
      json(response, 500, { message: String(error?.message || error) });
    }
  });
  server.listen(port, bind, () => {
    log(`link importer listening on http://${bind}:${port}`);
    if (!TOKEN) log('BOXERA_API_TOKEN is not set; imports will fail.');
  });
}

// ---------- entry ----------

async function main() {
  const [mode, ...rest] = process.argv.slice(2);
  const args = parseArgs(rest);
  if (mode === 'serve') {
    if (args.port) process.env.IMPORT_PORT = String(args.port);
    if (args.bind) process.env.IMPORT_BIND = String(args.bind);
    startServer();
    return;
  }
  const link = args._[0];
  if (!link || !/^https?:\/\//i.test(link)) {
    console.error(
      'usage: node boxera-link-importer.mjs once <url> [--kind=video|drive] ' +
        '[--folder-id=N] [--channel-id=N] [--title=T] [--state=PATH] [--wait-seconds=N]',
    );
    process.exit(2);
  }
  if (args.state) singleStatePath = path.resolve(String(args.state));
  const kind = args.kind === 'drive' ? 'drive' : 'video';
  const stableId = createHash('sha256').update(link).digest('hex').slice(0, 36);
  const resumed = args.state ? loadFromDisk(stableId) : null;
  const task =
    resumed ||
    newTask({
      url: link,
      kind,
      folderId: args['folder-id'] ?? null,
      channelId: args['channel-id'] ?? null,
      title: String(args.title || '').trim(),
      id: args.state ? stableId : undefined,
    });
  task.waitSeconds = Number(args['wait-seconds'] ?? 1800);
  const report = makeReporter(task);
  try {
    await runImport(task, report);
    console.log(
      JSON.stringify(
        {
          file_id: task.fileId,
          video_id: task.videoId,
          m3u8_url: task.m3u8Url,
          state: task.state,
          size: task.size,
        },
        null,
        2,
      ),
    );
  } catch (error) {
    const message = String(error?.message || error);
    report({ state: 'failed', error: message });
    console.error(message);
    process.exitCode = 1;
  }
}

await main();
