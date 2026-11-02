#!/usr/bin/env node
// End-to-end self-test for tools/boxera-link-importer.mjs.
//
// It boots one mock server that plays three roles — a Range-capable link
// source, a Boxera-style upload API, and the storage endpoints behind
// part-urls — then runs the importer as a child process. The mock reassembles
// what it received and compares it byte for byte with the original file, so a
// passing run proves the link relay neither loses nor reorders data.
//
//   node tools/import_server_selftest.mjs
//
// No dependencies, no network access outside 127.0.0.1.

import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const IMPORTER = path.join(path.dirname(fileURLToPath(import.meta.url)), 'boxera-link-importer.mjs');
// The smallest part size Boxera accepts; fixtures are sized in multiples of it
// so a transfer still spans several parts.
const PART_SIZE = 524288;
const TOKEN = 'mock-upload-token';

function content(key, length) {
  const chunks = [];
  let filled = 0;
  let index = 0;
  while (filled < length) {
    const block = crypto.createHash('sha256').update(`${key}:${index}`).digest();
    chunks.push(block);
    filled += block.length;
    index += 1;
  }
  return Buffer.concat(chunks).subarray(0, length);
}

const files = new Map(
  [
    ['m1', { name: 'relay-movie.mp4', mime: 'video/mp4', size: 1_200_000 }],
    ['m2', { name: 'drive-file.mkv', mime: 'video/x-matroska', size: 700_000 }],
    ['m3', { name: 'tus-movie.mp4', mime: 'video/mp4', size: 600_000 }],
    // Names steer the mock: already-done answers with a completed session and
    // stale-session dies with 409 after its first part.
    ['m4', { name: 'already-done-movie.mp4', mime: 'video/mp4', size: 600_000 }],
    ['m5', { name: 'stale-session-movie.mp4', mime: 'video/mp4', size: 1_200_000 }],
  ].map(([key, meta]) => [key, { key, ...meta, body: content(key, meta.size) }]),
);

const sessions = new Map();
const processingCounts = new Map();
let sessionSequence = 0;

function sendJson(response, status, payload, extra = {}) {
  const body = JSON.stringify(payload);
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    ...extra,
  });
  response.end(body);
}

async function rawBody(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  return Buffer.concat(chunks);
}

function findFileByName(name) {
  for (const file of files.values()) if (file.name === name) return file;
  return null;
}

function createMockServer() {
  return createServer(async (request, response) => {
    const url = new URL(request.url, 'http://127.0.0.1');
    const parts = url.pathname.split('/').filter(Boolean);
    const method = request.method.toUpperCase();
    try {
      // ---------- the link being imported ----------
      // /never-ranges ignores Range and answers with the whole body, exactly
      // like the links the importer must refuse instead of bulk-downloading.
      if (method === 'GET' && parts[0] === 'never-ranges') {
        const file = files.get(parts[1]);
        response.writeHead(200, { 'Content-Type': file.mime, 'Content-Length': file.body.length });
        response.end(file.body);
        return;
      }
      if (method === 'GET' && (parts[0] === 'files' || parts[0] === 'redirect')) {
        const file = files.get(parts[1]);
        if (!file) return sendJson(response, 404, { message: 'No such file.' });
        if (parts[0] === 'redirect') {
          response.writeHead(302, { Location: `/files/${file.key}` });
          response.end();
          return;
        }
        const range = /bytes=(\d+)-(\d+)/.exec(request.headers.range || '');
        const start = range ? Number(range[1]) : 0;
        const end = range ? Math.min(Number(range[2]), file.size - 1) : file.size - 1;
        if (start >= file.size || start > end) {
          return sendJson(response, 416, { message: 'Range outside the file.' });
        }
        const slice = file.body.subarray(start, end + 1);
        if (slice.length > 1) {
          // A real part read; the 0-0 probe is metadata and costs nothing.
          file.partReads = (file.partReads || 0) + 1;
        }
        response.writeHead(range ? 206 : 200, {
          'Content-Type': file.mime,
          'Content-Length': slice.length,
          'Accept-Ranges': 'bytes',
          'Content-Range': `bytes ${start}-${end}/${file.size}`,
          'Content-Disposition': `attachment; filename*=UTF-8''${encodeURIComponent(file.name)}`,
        });
        response.end(slice);
        return;
      }

      // ---------- Boxera-compatible upload API ----------
      if (parts[0] === 'api') {
        const route = parts.slice(1).join('/');
        const body = ['GET', 'HEAD'].includes(method)
          ? null
          : JSON.parse((await rawBody(request).then((b) => b.toString('utf8'))) || '{}');

        if (method === 'POST' && route === 'uploads/init') {
          const partSize = Number(body.part_size) || PART_SIZE;
          // Boxera only accepts a suggested part size inside this window.
          if (partSize < 524288 || partSize > 5368709120) {
            return sendJson(response, 422, {
              message: `part_size ${partSize} is outside the allowed range.`,
            });
          }
          if (!/^[a-zA-Z0-9._:-]{1,120}$/.test(String(body.upload_request_id || ''))) {
            return sendJson(response, 422, { message: 'upload_request_id is not a valid key.' });
          }
          if (typeof body.original_name !== 'string' || !body.original_name.length ||
              body.original_name.length > 255) {
            return sendJson(response, 422, { message: 'original_name must be 1..255 characters.' });
          }
          if (!Number.isInteger(body.size_bytes) || body.size_bytes < 1) {
            return sendJson(response, 422, { message: 'size_bytes must be a positive integer.' });
          }
          if (body.space === 'video' && !String(body.mime_type || '').startsWith('video/')) {
            return sendJson(response, 422, { message: 'mime_type must start with video/ for a video.' });
          }
          if (body.file_id !== undefined && !Number.isInteger(body.file_id)) {
            return sendJson(response, 422, { message: 'file_id must be an integer.' });
          }
          const file = findFileByName(body.original_name);
          if (!file) return sendJson(response, 422, { message: 'Unknown file name.' });
          if (body.space === 'video' && body.folder_id !== undefined) {
            return sendJson(response, 409, { message: 'folder_id is not allowed for video.' });
          }
          sessionSequence += 1;
          const protocol = file.name.startsWith('tus') ? 'tus-edge' : 's3-multipart';
          // Every management id in this API is a number.
          const id = 5000 + sessionSequence;
          const session = {
            id,
            file,
            protocol,
            partSize,
            partCount: Math.ceil(file.size / partSize),
            init: body,
            received: new Map(),
            tus: Buffer.alloc(0),
            completed: null,
            registered: null,
            sizeMismatch: false,
            storagePuts: 0,
            partUrlCalls: 0,
            dead: false,
            // Only the first session of that file dies mid-transfer; the
            // replacement Boxera hands out after a 409 must work.
            expireAfter:
              file.name.startsWith('stale-session') &&
              ![...sessions.values()].some((item) => item.file === file)
                ? 1
                : 0,
            precompleted: file.name.startsWith('already-done'),
            fileId: 7000 + sessionSequence,
          };
          // Parts already accepted stay on the file across sessions.
          const prior = [...sessions.values()].find(
            (item) => item.fileId === body.file_id && item.file === file,
          );
          if (prior) {
            for (const [number, info] of prior.received) session.received.set(number, info);
            session.carriedFrom = prior.id;
          }
          sessions.set(id, session);
          if (session.precompleted) {
            session.completed = {
              at: new Date().toISOString(),
              integrity: true,
              declaredParts: 0,
            };
          }
          return sendJson(response, 201, {
            data: {
              upload_session_id: id,
              part_size: session.partSize,
              part_count: session.partCount,
              upload_protocol: protocol,
              file_id: session.fileId,
              upload_status: session.precompleted ? 'completed' : 'active',
              expires_at: new Date(Date.now() + 3600_000).toISOString(),
              ...(protocol === 'tus-edge'
                ? {
                    upload_url: `http://127.0.0.1:${portOf(server)}/tus/${id}`,
                    upload_headers: { 'x-mock-tus': '1' },
                    upload_offset: 0,
                  }
                : {}),
            },
          });
        }

        if (method === 'POST' && /^uploads\/[^/]+\/part-urls$/.test(route)) {
          const session = sessions.get(Number(parts[2]));
          if (!session) return sendJson(response, 404, { message: 'Unknown session.' });
          if (session.dead) {
            return sendJson(response, 409, { message: 'Upload session expired.' });
          }
          session.partUrlCalls += 1;
          const start = Math.max(1, Number(body.start_part) || 1);
          const limit = Math.max(1, Math.min(Number(body.limit) || 200, 200));
          const last = Math.min(session.partCount, start + limit - 1);
          const list = [];
          const base = `http://127.0.0.1:${portOf(server)}/storage/${session.id}/`;
          for (let number = start; number <= last; number++) {
            list.push({
              part_number: number,
              method: 'PUT',
              upload_url: `${base}${number}`,
              headers: {
                // A host/content-length here must be dropped by the importer.
                host: 'storage.invalid',
                'content-length': '1',
                'x-mock-part': String(number),
                'Content-Type': session.file.mime,
              },
            });
          }
          return sendJson(response, 200, {
            data: {
              parts: list,
              uploaded_parts: [...session.received.entries()].map(([number, info]) => ({
                part_number: number,
                etag: info.etag,
                size: info.bytes.length,
              })),
              has_more_parts: last < session.partCount,
              next_start_part: last + 1,
            },
          });
        }

        if (method === 'POST' && /^uploads\/[^/]+\/part-retry$/.test(route)) {
          return sendJson(response, 200, { data: { ok: true, echoed: body } });
        }

        if (method === 'POST' && /^uploads\/[^/]+\/complete$/.test(route)) {
          const session = sessions.get(Number(parts[2]));
          if (!session) return sendJson(response, 404, { message: 'Unknown session.' });
          if (session.dead) {
            return sendJson(response, 409, { message: 'Upload session expired.' });
          }
          if (session.precompleted) {
            session.completeRepeats = (session.completeRepeats || 0) + 1;
            return sendJson(response, 200, { data: { id: session.fileId } });
          }
          const merged = Buffer.alloc(session.file.size);
          if (session.protocol === 'tus-edge') {
            session.tus.copy(merged, 0, 0, Math.min(session.tus.length, merged.length));
          } else {
            for (const part of body.parts || []) {
              const info = session.received.get(Number(part.part_number));
              if (!info) {
                return sendJson(response, 422, { message: `Missing part ${part.part_number}.` });
              }
              if (info.etag !== part.etag) {
                return sendJson(response, 422, { message: `ETag mismatch for part ${part.part_number}.` });
              }
              info.bytes.copy(merged, (Number(part.part_number) - 1) * session.partSize);
            }
          }
          session.completed = {
            at: new Date().toISOString(),
            integrity: Buffer.compare(merged, session.file.body) === 0,
            declaredParts: (body.parts || []).length,
          };
          return sendJson(response, 200, { data: { id: session.fileId } });
        }

        if (method === 'POST' && route === 'video/videos') {
          const session = [...sessions.values()].find((item) => item.fileId === body.media_file_id);
          if (session) session.registered = body;
          return sendJson(response, 201, { data: { video: { id: 'vid-1', title: body.title } } });
        }

        if (method === 'GET' && /^video\/videos\/[^/]+\/processing$/.test(route)) {
          const seen = (processingCounts.get(route) || 0) + 1;
          processingCounts.set(route, seen);
          if (seen < 2) {
            return sendJson(response, 200, {
              data: {
                state: 'in_progress',
                poll_after_seconds: 0,
                transcode: { progress: { percent: 45, stage: 'muxing' } },
              },
            });
          }
          return sendJson(response, 200, {
            data: {
              state: 'ready',
              poll_after_seconds: 0,
              playback: {
                ready: true,
                share_url: 'https://cdn.boxera.invalid/hls/vid-1.m3u8',
                url: 'https://cdn.boxera.invalid/preview/vid-1?sig=expired',
              },
            },
          });
        }

        return sendJson(response, 404, { message: `Mock API has no ${method} /${route}.` });
      }

      // ---------- storage behind part-urls ----------
      if (parts[0] === 'storage' && method === 'PUT') {
        const session = sessions.get(Number(parts[1]));
        const number = Number(parts[2]);
        if (!session || !number) return sendJson(response, 404, { message: 'Unknown part.' });
        const bytes = await rawBody(request);
        if (session.expireAfter && number > session.expireAfter) {
          // The session dies mid-transfer, exactly like an expired Boxera one:
          // everything already accepted stays on the file.
          session.dead = true;
          return sendJson(response, 409, { message: 'Upload session expired.' });
        }
        const want = Math.min(
          session.partSize,
          Math.max(0, session.file.size - (number - 1) * session.partSize),
        );
        if (bytes.length !== want) {
          session.sizeMismatch = true;
          return sendJson(response, 400, { message: `Part ${number} was ${bytes.length}, expected ${want}.` });
        }
        if (request.headers['x-mock-part'] !== String(number)) {
          return sendJson(response, 400, { message: 'Per-part header did not survive the relay.' });
        }
        const etag = `"${crypto.createHash('md5').update(bytes).digest('hex')}"`;
        session.received.set(number, { etag, bytes });
        session.storagePuts += 1;
        response.writeHead(200, { ETag: etag, 'Content-Length': '0' });
        response.end();
        return;
      }

      // ---------- TUS edge ----------
      if (parts[0] === 'tus') {
        const session = sessions.get(Number(parts[1]));
        if (!session) return sendJson(response, 404, { message: 'Unknown TUS upload.' });
        if (method === 'HEAD') {
          response.writeHead(200, {
            'Upload-Offset': String(session.tus.length),
            'Tus-Resumable': '1.0.0',
            'Content-Length': '0',
          });
          response.end();
          return;
        }
        if (method === 'PATCH') {
          const bytes = await rawBody(request);
          const offset = Number(request.headers['upload-offset']);
          if (offset !== session.tus.length) {
            return sendJson(response, 409, { message: `Offset ${offset} is behind ${session.tus.length}.` });
          }
          session.tus = Buffer.concat([session.tus, bytes]);
          response.writeHead(204, {
            'Upload-Offset': String(session.tus.length),
            'Tus-Resumable': '1.0.0',
            'Content-Length': '0',
          });
          response.end();
          return;
        }
        return sendJson(response, 405, { message: 'Unsupported TUS method.' });
      }

      sendJson(response, 404, { message: 'No mock route.' });
    } catch (error) {
      sendJson(response, 500, { message: String(error?.message || error) });
    }
  });
}

let server = null;
function portOf(instance) {
  return instance.address().port;
}

// ---------- assertions ----------

const results = [];
function check(name, condition, detail = '') {
  results.push({ name, ok: Boolean(condition), detail });
  console.log(`${condition ? 'PASS' : 'FAIL'}  ${name}${detail && !condition ? ` — ${detail}` : ''}`);
}

function readState(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return null;
  }
}

function importerEnv(extra = {}) {
  return {
    ...process.env,
    BOXERA_API_BASE: `http://127.0.0.1:${portOf(server)}/api`,
    BOXERA_API_TOKEN: TOKEN,
    BOXERA_PART_SIZE: String(PART_SIZE),
    IMPORT_ALLOW_PRIVATE: '1',
    IMPORT_STATE_DIR: stateDir,
    ...extra,
  };
}

let stateDir = '';

function runChild(argv, env) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [IMPORTER, ...argv], {
      env,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk) => (stdout += chunk));
    child.stderr.on('data', (chunk) => (stderr += chunk));
    const timer = setTimeout(() => child.kill('SIGKILL'), 45_000);
    child.on('close', (code) => {
      clearTimeout(timer);
      resolve({ code, stdout, stderr });
    });
  });
}

async function waitForHealth(base, headers) {
  for (let attempt = 0; attempt < 40; attempt++) {
    try {
      const response = await fetch(`${base}/health`, { headers });
      if (response.ok) return await response.json();
    } catch {}
    await new Promise((done) => setTimeout(done, 250));
  }
  return null;
}

// ---------- scenarios ----------

async function testMultipartViaRedirect() {
  const file = files.get('m1');
  const stateFile = path.join(stateDir, 'm1.json');
  const run = await runChild(
    [
      'once',
      `http://127.0.0.1:${portOf(server)}/redirect/m1`,
      '--kind=video',
      '--channel-id=43',
      `--state=${stateFile}`,
      '--wait-seconds=20',
    ],
    importerEnv(),
  );
  const state = readState(stateFile);
  check('multipart: importer exited cleanly', run.code === 0, `code ${run.code} :: ${run.stderr.slice(-400)}`);
  check('multipart: state is ready', state?.state === 'ready', `state=${state?.state} error=${state?.error}`);
  check(
    'multipart: all parts relayed',
    state && Object.keys(state.parts || {}).length === Math.ceil(file.size / PART_SIZE),
    `parts=${state ? Object.keys(state.parts || {}).length : 'none'}`,
  );
  const session = [...sessions.values()].find((item) => item.file === file);
  check('multipart: Range probe followed the redirect', Boolean(session));
  check('multipart: Boxera reassembled identical bytes', session?.completed?.integrity === true);
  check('multipart: no part size mismatch', session && !session.sizeMismatch);
  check('multipart: init used space=video', session?.init?.space === 'video');
  check('multipart: init carried channel_id 43', Number(session?.init?.channel_id) === 43);
  check('multipart: init carried upload_request_id', Boolean(session?.init?.upload_request_id));
  check('multipart: decoded RFC 5987 file name', session?.init?.original_name === file.name);
  check('multipart: registered as free + unlisted', session?.registered?.visibility === 'unlisted' && session?.registered?.access_type === 'free');
  check('multipart: media_file_id from complete', session?.registered?.media_file_id === session?.fileId);
  check(
    'multipart: m3u8 published, preview kept separate',
    state?.m3u8_url === 'https://cdn.boxera.invalid/hls/vid-1.m3u8' && Boolean(state?.preview_url),
    `m3u8=${state?.m3u8_url}`,
  );
}

async function testDriveFolder() {
  const file = files.get('m2');
  const stateFile = path.join(stateDir, 'm2.json');
  const run = await runChild(
    [
      'once',
      `http://127.0.0.1:${portOf(server)}/files/m2`,
      '--kind=drive',
      '--folder-id=27576',
      '--title=نمونه',
      `--state=${stateFile}`,
    ],
    importerEnv(),
  );
  const state = readState(stateFile);
  check('drive: importer exited cleanly', run.code === 0, `code ${run.code} :: ${run.stderr.slice(-400)}`);
  check('drive: state is ready', state?.state === 'ready', `state=${state?.state} error=${state?.error}`);
  const session = [...sessions.values()].find((item) => item.file === file);
  check('drive: init used space=drive', session?.init?.space === 'drive');
  check('drive: init carried folder_id 27576', Number(session?.init?.folder_id) === 27576);
  check('drive: no channel_id leaked into a drive init', session?.init?.channel_id === undefined);
  check('drive: video registration skipped', session?.registered == null);
  check('drive: Boxera reassembled identical bytes', session?.completed?.integrity === true);
  check('drive: no m3u8 for a drive file', state?.m3u8_url == null);
}

async function testTusProtocol() {
  const file = files.get('m3');
  const stateFile = path.join(stateDir, 'm3.json');
  const run = await runChild(
    ['once', `http://127.0.0.1:${portOf(server)}/files/m3`, '--kind=video', `--state=${stateFile}`],
    importerEnv(),
  );
  const state = readState(stateFile);
  check('tus: importer exited cleanly', run.code === 0, `code ${run.code} :: ${run.stderr.slice(-400)}`);
  const session = [...sessions.values()].find((item) => item.file === file);
  check('tus: session used tus-edge', session?.protocol === 'tus-edge');
  check('tus: whole file streamed in patches', session?.tus.length === file.size, `got ${session?.tus.length}`);
  check('tus: Boxera reassembled identical bytes', session?.completed?.integrity === true);
  check('tus: finished with an m3u8 link', (state?.m3u8_url || '').includes('.m3u8'));
}

async function testRejectsNonRangeLink() {
  const run = await runChild(
    ['once', `http://127.0.0.1:${portOf(server)}/never-ranges/m1`, '--kind=video'],
    importerEnv(),
  );
  check('guard: non-Range link fails instead of bulk download', run.code === 1, `code ${run.code}`);
  check('guard: failure message names the Range problem', /byte ranges/i.test(run.stderr + run.stdout));
}

async function testLoopbackGuard() {
  const run = await runChild(
    ['once', 'http://localhost:9/whatever.mp4', '--kind=video'],
    importerEnv({ IMPORT_ALLOW_PRIVATE: '0' }),
  );
  check('ssrf: loopback host refused', run.code === 1, `code ${run.code}`);
}

async function testCompletedSessionSendsNoBytes() {
  const file = files.get('m4');
  const stateFile = path.join(stateDir, 'm4.json');
  const run = await runChild(
    [
      'once',
      `http://127.0.0.1:${portOf(server)}/files/m4`,
      '--kind=video',
      `--state=${stateFile}`,
      '--wait-seconds=20',
    ],
    importerEnv(),
  );
  const state = readState(stateFile);
  const session = [...sessions.values()].find((item) => item.file === file);
  check('completed: importer exited cleanly', run.code === 0, `code ${run.code} :: ${run.stderr.slice(-400)}`);
  check('completed: state reaches ready', state?.state === 'ready', `state=${state?.state} error=${state?.error}`);
  check(
    'completed: no part url was requested',
    session?.partUrlCalls === 0,
    `calls=${session?.partUrlCalls}`,
  );
  check('completed: no part byte was read from the link', !file.partReads, `reads=${file.partReads}`);
  check(
    'completed: complete was repeated for the file id',
    session?.completeRepeats === 1,
    `repeats=${session?.completeRepeats}`,
  );
  check(
    'completed: video registered from that file',
    session?.registered?.media_file_id === session?.fileId,
  );
}

async function testExpiredSessionOpensAFreshOne() {
  const file = files.get('m5');
  const stateFile = path.join(stateDir, 'm5.json');
  const run = await runChild(
    [
      'once',
      `http://127.0.0.1:${portOf(server)}/files/m5`,
      '--kind=video',
      `--state=${stateFile}`,
      '--wait-seconds=20',
    ],
    importerEnv(),
  );
  const state = readState(stateFile);
  const used = [...sessions.values()].filter((item) => item.file === file);
  const [first, second] = used;
  check('expiry: a second session was opened', Boolean(second), `sessions=${used.length}`);
  check('expiry: the first session died after one part', first?.storagePuts === 1, `puts=${first?.storagePuts}`);
  check('expiry: the fresh init carried the previous file id', second?.init?.file_id === first?.fileId);
  check(
    'expiry: the fresh init used a new request key',
    Boolean(second?.init?.upload_request_id) &&
      second?.init?.upload_request_id !== first?.init?.upload_request_id,
  );
  check('expiry: an accepted part was not sent again', second?.storagePuts === 2, `puts=${second?.storagePuts}`);
  check(
    'expiry: every part reached the file',
    second?.received?.size === Math.ceil(file.size / PART_SIZE),
    `parts=${second?.received?.size}`,
  );
  check('expiry: Boxera reassembled identical bytes', second?.completed?.integrity === true);
  check('expiry: video registered from the new file', second?.registered?.media_file_id === second?.fileId);
  check('expiry: importer exited cleanly', run.code === 0, `code ${run.code} :: ${run.stderr.slice(-400)}`);
  check('expiry: state reaches ready', state?.state === 'ready', `state=${state?.state} error=${state?.error}`);
}

async function testChangedInputRotatesTheKey() {
  const file = files.get('m2');
  const stateFile = path.join(stateDir, 'rotate.json');
  fs.writeFileSync(
    stateFile,
    JSON.stringify({
      id: 'rotate',
      url: `http://127.0.0.1:${portOf(server)}/files/m2`,
      kind: 'drive',
      folder_id: 27576,
      channel_id: null,
      title: '',
      created_at: new Date().toISOString(),
      state: 'failed',
      detail: '',
      size: 111,
      uploaded_bytes: 0,
      progress: 0,
      request_id: 'import-stale-key',
      session_id: 'sess-old',
      file_id: 424242,
      video_id: null,
      name: 'old-name.mp4',
      mime_type: 'video/mp4',
      parts: {},
      m3u8_url: null,
      preview_url: null,
      error: 'previous attempt',
    }),
  );
  const run = await runChild(
    [
      'once',
      `http://127.0.0.1:${portOf(server)}/files/m2`,
      '--kind=drive',
      '--folder-id=27576',
      `--state=${stateFile}`,
    ],
    importerEnv(),
  );
  const state = readState(stateFile);
  const session = [...sessions.values()].find((item) => item.init?.file_id === 424242);
  check('rotate: a previous attempt was resumed', Boolean(session));
  check(
    'rotate: the stale key was not replayed',
    session && session.init.upload_request_id !== 'import-stale-key',
  );
  check(
    'rotate: the new key matches the Boxera pattern',
    /^[a-zA-Z0-9._:-]{1,120}$/.test(String(session?.init?.upload_request_id || '')),
    `key=${session?.init?.upload_request_id}`,
  );
  check('rotate: the file was completed', session?.completed?.integrity === true);
  check('rotate: importer exited cleanly', run.code === 0, `code ${run.code} :: ${run.stderr.slice(-400)}`);
  check('rotate: state reaches ready', state?.state === 'ready', `state=${state?.state} error=${state?.error}`);
}

async function testPartSizePolicy() {
  const tiny = await runChild(
    ['once', 'http://example.invalid/a.mp4'],
    importerEnv({ BOXERA_PART_SIZE: '65536' }),
  );
  check(
    'policy: a part size below the Boxera minimum is refused at startup',
    tiny.code === 2 && /BOXERA_PART_SIZE/.test(tiny.stderr),
    `code ${tiny.code} :: ${tiny.stderr.slice(-200)}`,
  );
  const { suggestPartSize } = await import(pathToFileURL(IMPORTER).href);
  const size = 10_001 * 8 * 1024 * 1024;
  const suggested = suggestPartSize(size);
  check(
    'policy: the suggestion stays inside the part size window',
    suggested >= 524288 && suggested <= 5368709120,
    `suggested=${suggested}`,
  );
  check(
    'policy: the 10000 part ceiling is respected',
    Math.ceil(size / suggested) <= 10000 && Math.ceil(size / 8388608) > 10000,
    `parts=${Math.ceil(size / suggested)}`,
  );
}

async function testHttpApi() {
  const apiPort = 41_777;
  const base = `http://127.0.0.1:${apiPort}`;
  const child = spawn(
    process.execPath,
    [IMPORTER, 'serve', `--port=${apiPort}`, '--bind=127.0.0.1'],
    { env: importerEnv({ IMPORT_TOKEN: 'selftest-secret' }), stdio: ['ignore', 'pipe', 'pipe'] },
  );
  let stderr = '';
  child.stderr.on('data', (chunk) => (stderr += chunk));
  const health = await waitForHealth(base, {});
  check('api: /health is open and reports the token', health?.ok === true && health?.has_boxera_token === true, JSON.stringify(health));

  const denied = await fetch(`${base}/import`, { method: 'POST', body: '{}' });
  check('api: unauthenticated import rejected', denied.status === 401, `status ${denied.status}`);

  const auth = { Authorization: 'Bearer selftest-secret', 'Content-Type': 'application/json' };
  const missingFolder = await fetch(`${base}/import`, {
    method: 'POST',
    headers: auth,
    body: JSON.stringify({ url: `http://127.0.0.1:${portOf(server)}/files/m1`, kind: 'drive' }),
  });
  check('api: drive import needs folder_id', missingFolder.status === 422, `status ${missingFolder.status}`);

  const badUrl = await fetch(`${base}/import`, {
    method: 'POST',
    headers: auth,
    body: JSON.stringify({ url: 'ftp://example.invalid/x.mp4' }),
  });
  check('api: non-http url rejected', badUrl.status === 422, `status ${badUrl.status}`);

  const accepted = await fetch(`${base}/import`, {
    method: 'POST',
    headers: auth,
    body: JSON.stringify({
      url: `http://127.0.0.1:${portOf(server)}/files/m1`,
      kind: 'video',
      channel_id: 43,
      title: 'تست سرور',
      wait_seconds: 20,
    }),
  });
  const created = await accepted.json();
  check('api: import accepted as a task', accepted.status === 202 && Boolean(created.id), `status ${accepted.status}`);

  let view = created;
  for (let attempt = 0; attempt < 120 && !['ready', 'done', 'failed'].includes(view.state); attempt++) {
    await new Promise((done) => setTimeout(done, 250));
    view = await (await fetch(`${base}/status/${created.id}`, { headers: auth })).json();
  }
  check('api: status reaches ready with an m3u8', ['ready', 'done'].includes(view.state) && Boolean(view.m3u8_url), `state=${view.state} error=${view.error}`);
  check('api: progress reached the full size', view.size === view.uploaded_bytes, `${view.uploaded_bytes}/${view.size}`);
  const list = await (await fetch(`${base}/imports`, { headers: auth })).json();
  check('api: /imports lists the task', Array.isArray(list) && list.some((item) => item.id === created.id));
  const unknown = await fetch(`${base}/status/${'0'.repeat(36)}`, { headers: auth });
  check('api: unknown id is 404', unknown.status === 404, `status ${unknown.status}`);

  child.kill('SIGKILL');
  await new Promise((done) => child.once('close', done));
}

// ---------- main ----------

async function main() {
  stateDir = fs.mkdtempSync(path.join(os.tmpdir(), 'importer-selftest-'));
  server = createMockServer();
  await new Promise((done) => server.listen(0, '127.0.0.1', done));
  console.log(`mock Boxera + link server on port ${portOf(server)}`);
  console.log(`importer under test: ${IMPORTER}\n`);

  await testMultipartViaRedirect();
  await testDriveFolder();
  await testTusProtocol();
  await testCompletedSessionSendsNoBytes();
  await testExpiredSessionOpensAFreshOne();
  await testChangedInputRotatesTheKey();
  await testPartSizePolicy();
  await testRejectsNonRangeLink();
  await testLoopbackGuard();
  await testHttpApi();

  const failed = results.filter((item) => !item.ok);
  console.log(`\n${results.length - failed.length}/${results.length} checks passed`);
  if (failed.length) {
    console.log('failed:');
    for (const item of failed) console.log(` - ${item.name}: ${item.detail}`);
  }
  server.close();
  fs.rmSync(stateDir, { recursive: true, force: true });
  process.exitCode = failed.length ? 1 : 0;
}

await main();
