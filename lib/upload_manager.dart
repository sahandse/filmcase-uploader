import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'boxera_api.dart';

const _defaultPartSize = 8 * 1024 * 1024;

int? channelIdOf(String? value) {
  final text = value?.trim() ?? '';
  if (text.isEmpty) return null;
  return int.tryParse(text);
}

String videoMimeType(String name) {
  final dot = name.lastIndexOf('.');
  final extension = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  switch (extension) {
    case 'mp4':
    case 'm4v':
      return 'video/mp4';
    case 'mkv':
      return 'video/x-matroska';
    case 'mov':
      return 'video/quicktime';
    case 'avi':
      return 'video/x-msvideo';
    case 'webm':
    case 'vp9':
      return 'video/webm';
    case 'ts':
    case 'm2ts':
      return 'video/mp2t';
    case 'flv':
      return 'video/x-flv';
    case 'wmv':
      return 'video/x-ms-wmv';
    case 'mpg':
    case 'mpeg':
      return 'video/mpeg';
    case '3gp':
      return 'video/3gpp';
    case 'ogv':
      return 'video/ogg';
    default:
      return 'video/mp4';
  }
}

String defaultVideoTitle(String name) {
  final dot = name.lastIndexOf('.');
  final title = dot > 0 ? name.substring(0, dot) : name;
  return title.trim().isEmpty ? name : title.trim();
}

class PickedVideo {
  const PickedVideo({
    required this.path,
    required this.name,
    required this.size,
  });

  final String path;
  final String name;
  final int size;
}

class VideoUploadJob {
  VideoUploadJob({
    required this.id,
    required this.path,
    required this.name,
    required this.size,
    required this.mimeType,
    String? title,
    this.state = stateQueued,
    this.progress = 0,
    this.uploadedBytes = 0,
    this.error,
    this.detail,
    this.requestId,
    this.videoRequestId,
    this.fileId,
    this.sessionId,
    this.videoId,
    this.shareUrl,
    this.previewUrl,
    this.partSize,
    this.protocol,
    this.transcodePercent,
    DateTime? createdAt,
  }) : title = (title == null || title.trim().isEmpty)
           ? defaultVideoTitle(name)
           : title.trim(),
       createdAt = createdAt ?? DateTime.now();

  static const stateQueued = 'queued';
  static const stateUploading = 'uploading';
  static const stateCompleting = 'completing';
  static const stateRegistering = 'registering';
  static const stateProcessing = 'processing';
  static const stateReady = 'ready';
  static const stateFailed = 'failed';
  static const stateCancelled = 'cancelled';

  final String id;
  final String path;
  final String name;
  int size;
  final String mimeType;
  String title;
  String state;
  double progress;
  int uploadedBytes;
  String? error;
  String? detail;
  String? requestId;
  String? videoRequestId;
  String? fileId;
  String? sessionId;
  String? videoId;
  String? shareUrl;
  String? previewUrl;
  int? partSize;
  String? protocol;
  int? transcodePercent;
  final DateTime createdAt;
  int pollFailures = 0;

  bool get isRunning =>
      state == stateUploading ||
      state == stateCompleting ||
      state == stateRegistering;

  bool get isReady => state == stateReady;

  String get stateLabel {
    switch (state) {
      case stateQueued:
        return 'در صف';
      case stateUploading:
        return 'در حال آپلود';
      case stateCompleting:
        return 'نهایی‌سازی';
      case stateRegistering:
        return 'ثبت ویدیو';
      case stateProcessing:
        return 'پردازش ویدیو';
      case stateReady:
        return 'آماده پخش';
      case stateFailed:
        return 'ناموفق';
      case stateCancelled:
        return 'متوقف';
      default:
        return state;
    }
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'path': path,
    'name': name,
    'size': size,
    'mimeType': mimeType,
    'title': title,
    'state': state,
    'progress': progress,
    'uploadedBytes': uploadedBytes,
    'error': error,
    'detail': detail,
    'requestId': requestId,
    'videoRequestId': videoRequestId,
    'fileId': fileId,
    'sessionId': sessionId,
    'videoId': videoId,
    'shareUrl': shareUrl,
    'previewUrl': previewUrl,
    'partSize': partSize,
    'protocol': protocol,
    'transcodePercent': transcodePercent,
    'createdAt': createdAt.toIso8601String(),
  };

  factory VideoUploadJob.fromJson(Map<String, dynamic> json) {
    final name = json['name'] as String? ?? 'video.mp4';
    return VideoUploadJob(
      id:
          json['id'] as String? ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      path: json['path'] as String? ?? '',
      name: name,
      size: (json['size'] as num?)?.round() ?? 0,
      mimeType: json['mimeType'] as String? ?? videoMimeType(name),
      title: json['title'] as String?,
      state: json['state'] as String? ?? stateQueued,
      progress: (json['progress'] as num?)?.toDouble() ?? 0,
      uploadedBytes: (json['uploadedBytes'] as num?)?.round() ?? 0,
      error: json['error'] as String?,
      detail: json['detail'] as String?,
      requestId: json['requestId'] as String?,
      videoRequestId: json['videoRequestId'] as String?,
      fileId: json['fileId'] as String?,
      sessionId: json['sessionId'] as String?,
      videoId: json['videoId'] as String?,
      shareUrl: json['shareUrl'] as String?,
      previewUrl: json['previewUrl'] as String?,
      partSize: (json['partSize'] as num?)?.round(),
      protocol: json['protocol'] as String?,
      transcodePercent: (json['transcodePercent'] as num?)?.round(),
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
    );
  }
}

class _UploadCancelled implements Exception {
  const _UploadCancelled();
}

class VideoUploadManager extends ChangeNotifier {
  final List<VideoUploadJob> jobs = [];
  final Set<String> _active = {};
  final Set<String> _cancelled = {};
  final Map<String, Timer> _timers = {};
  final List<VideoUploadJob> _runQueue = [];

  BoxeraApi Function()? _apiFactory;
  int _concurrency = 2;
  String? _channelId;
  bool _publicVideo = false;
  bool _disposed = false;

  static const _prefsKey = 'video_upload_jobs_v1';

  Future<void> _persistChain = Future<void>.value();

  bool get hasRunning => _active.isNotEmpty || _runQueue.isNotEmpty;
  int get activeCount => _active.length;
  int get readyCount => jobs.where((job) => job.isReady).length;
  int get queuedCount =>
      jobs.where((job) => job.state == VideoUploadJob.stateQueued).length;

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        for (final entry in decoded) {
          if (entry is! Map) continue;
          final job = VideoUploadJob.fromJson(Map<String, dynamic>.from(entry));
          if (job.isRunning) {
            job.state = VideoUploadJob.stateQueued;
            job.detail = 'آپلود نیمه‌کاره؛ با «ادامه» ادامه می‌یابد.';
          }
          jobs.add(job);
        }
      }
    } catch (_) {
      jobs.clear();
    }
    notifyListeners();
  }

  Future<void> persist() {
    _persistChain = _persistChain
        .then((_) async {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(
            _prefsKey,
            jsonEncode([for (final job in jobs) job.toJson()]),
          );
        })
        .catchError((Object _) {});
    return _persistChain;
  }

  int addVideos(Iterable<PickedVideo> picked) {
    var added = 0;
    for (final file in picked) {
      if (file.path.isEmpty || file.size <= 0) continue;
      if (jobs.any((job) => job.path == file.path && job.size == file.size)) {
        continue;
      }
      jobs.insert(
        0,
        VideoUploadJob(
          id: _newId('job'),
          path: file.path,
          name: file.name,
          size: file.size,
          mimeType: videoMimeType(file.name),
        ),
      );
      added += 1;
    }
    if (added > 0) {
      notifyListeners();
      unawaited(persist());
    }
    return added;
  }

  void startAll({
    required BoxeraApi Function() apiFactory,
    required int concurrency,
    String? channelId,
    bool publicVideo = false,
    List<VideoUploadJob>? targets,
  }) {
    _apiFactory = apiFactory;
    _concurrency = concurrency.clamp(1, 5);
    _channelId = (channelId == null || channelId.trim().isEmpty)
        ? null
        : channelId.trim();
    _publicVideo = publicVideo;
    final selection = targets ?? jobs;
    for (final job in selection) {
      if (job.isRunning || job.isReady) continue;
      if (job.videoId != null && job.fileId != null) {
        job.state = VideoUploadJob.stateProcessing;
        job.error = null;
        job.detail = 'بررسی وضعیت پردازش';
        _schedulePoll(job, 2);
        continue;
      }
      _cancelled.remove(job.id);
      job.state = VideoUploadJob.stateQueued;
      job.error = null;
      job.detail = 'در صف آپلود';
      if (!_runQueue.contains(job)) _runQueue.add(job);
    }
    notifyListeners();
    unawaited(persist());
    _pump();
  }

  void retry(VideoUploadJob job) {
    final factory = _apiFactory;
    if (factory == null) return;
    startAll(
      apiFactory: factory,
      concurrency: _concurrency,
      channelId: _channelId,
      publicVideo: _publicVideo,
      targets: [job],
    );
  }

  void cancel(VideoUploadJob job) {
    _cancelled.add(job.id);
    _runQueue.remove(job);
    _timers.remove(job.id)?.cancel();
    if (_active.contains(job.id)) {
      job.detail = 'در حال توقف...';
    } else {
      job.state = VideoUploadJob.stateCancelled;
      job.error = null;
      job.detail = 'متوقف شد';
    }
    notifyListeners();
    unawaited(persist());
  }

  void stopAll() {
    _runQueue.clear();
    for (final job in jobs) {
      if (job.isRunning) _cancelled.add(job.id);
      if (job.state == VideoUploadJob.stateQueued &&
          !_active.contains(job.id)) {
        job.state = VideoUploadJob.stateCancelled;
        job.detail = 'متوقف شد';
      }
    }
    notifyListeners();
    unawaited(persist());
  }

  void remove(VideoUploadJob job) {
    _cancelled.add(job.id);
    _runQueue.remove(job);
    _timers.remove(job.id)?.cancel();
    jobs.remove(job);
    notifyListeners();
    unawaited(persist());
  }

  void rename(VideoUploadJob job, String title) {
    final value = title.trim();
    if (value.isEmpty) return;
    job.title = value;
    notifyListeners();
    unawaited(persist());
  }

  void _pump() {
    final factory = _apiFactory;
    if (factory == null) return;
    var started = false;
    while (_active.length < _concurrency && _runQueue.isNotEmpty) {
      final job = _runQueue.removeAt(0);
      if (job.state != VideoUploadJob.stateQueued || _active.contains(job.id)) {
        continue;
      }
      _active.add(job.id);
      started = true;
      unawaited(_run(job, factory(), _channelId, _publicVideo));
    }
    if (started) notifyListeners();
  }

  Future<void> _run(
    VideoUploadJob job,
    BoxeraApi api,
    String? channelId,
    bool publicVideo,
  ) async {
    job.state = VideoUploadJob.stateUploading;
    job.error = null;
    job.detail = 'آماده‌سازی آپلود';
    job.pollFailures = 0;
    notifyListeners();
    await persist();
    try {
      await _pipeline(job, api, channelId, publicVideo);
    } on _UploadCancelled {
      job.state = VideoUploadJob.stateCancelled;
      job.error = null;
      job.detail = 'متوقف شد؛ با «ادامه» ادامه می‌یابد.';
    } catch (error) {
      if (_cancelled.contains(job.id)) {
        job.state = VideoUploadJob.stateCancelled;
        job.error = null;
        job.detail = 'متوقف شد؛ با «ادامه» ادامه می‌یابد.';
      } else {
        job.state = VideoUploadJob.stateFailed;
        job.error = describeError(error);
        job.detail = 'آپلود متوقف شد';
      }
    } finally {
      _active.remove(job.id);
      notifyListeners();
      await persist();
      _pump();
    }
  }

  Future<void> _pipeline(
    VideoUploadJob job,
    BoxeraApi api,
    String? channelId,
    bool publicVideo,
  ) async {
    final file = File(job.path);
    if (!await file.exists()) {
      throw BoxeraException(
        'فایل انتخاب‌شده در حافظه موقت برنامه نیست؛ آن را دوباره از گوشی انتخاب کن.',
      );
    }
    final length = await file.length();
    if (length <= 0) throw BoxeraException('فایل انتخاب‌شده خالی است.');
    if (length != job.size) {
      job.size = length;
      job.fileId = null;
      job.sessionId = null;
      job.requestId = null;
      job.uploadedBytes = 0;
      job.progress = 0;
    }
    _checkCancelled(job);
    final requestId = job.requestId ?? _newId('upload');
    job.requestId = requestId;
    await persist();
    final session = await api.initUpload(
      originalName: job.name,
      mimeType: job.mimeType,
      sizeBytes: job.size,
      requestId: requestId,
      channelId: channelIdOf(channelId),
      fileId: job.fileId,
      partSize: job.partSize ?? _defaultPartSize,
    );
    _checkCancelled(job);
    job.sessionId = session.id;
    job.protocol = session.protocol;
    job.fileId = session.fileId ?? job.fileId;
    if (session.partSize > 0) job.partSize = session.partSize;
    job.requestId = null;
    job.detail = 'اتصال به Boxera برقرار شد';
    await persist();
    if (session.uploadStatus == 'completed') {
      job.uploadedBytes = job.size;
      job.progress = 1;
      notifyListeners();
      await _registerAndPoll(job, api, channelId, publicVideo);
      return;
    }
    if (session.protocol == 'tus-edge') {
      await _uploadTus(job, api, session, file);
      job.state = VideoUploadJob.stateCompleting;
      job.detail = 'نهایی‌سازی آپلود';
      notifyListeners();
      await _complete(job, api, const []);
    } else {
      final parts = await _uploadMultipart(job, api, session, file);
      await _complete(job, api, parts);
    }
    await _registerAndPoll(job, api, channelId, publicVideo);
  }

  Future<void> _complete(
    VideoUploadJob job,
    BoxeraApi api,
    List<PartReference> parts,
  ) async {
    job.state = VideoUploadJob.stateCompleting;
    job.detail = 'ثبت پایان آپلود در Boxera';
    notifyListeners();
    await persist();
    final fileId =
        await api.completeUpload(job.sessionId!, parts) ?? job.fileId;
    if (fileId == null || fileId.isEmpty) {
      throw BoxeraException(
        'Boxera شناسه فایل را برنگرداند؛ آپلود را دوباره بررسی کن.',
      );
    }
    job.fileId = fileId;
    job.progress = 1;
    job.uploadedBytes = job.size;
    notifyListeners();
    await persist();
  }

  Future<List<PartReference>> _uploadMultipart(
    VideoUploadJob job,
    BoxeraApi api,
    UploadSession session,
    File file,
  ) async {
    final partSize = session.partSize > 0
        ? session.partSize
        : (job.partSize ?? _defaultPartSize);
    final partCount = session.partCount > 0
        ? session.partCount
        : (job.size / partSize).ceil();
    final collected = <int, String>{};
    var startPart = 1;
    for (var pageIndex = 0; pageIndex < 1000; pageIndex++) {
      _checkCancelled(job);
      final page = await api.partUrls(session.id, startPart: startPart);
      if (page.parts.isEmpty && page.uploadedParts.isEmpty && partCount > 0) {
        throw BoxeraException('Boxera فهرست بخش‌های آپلود را برنگرداند.');
      }
      final uploadedByNumber = <int, UploadedPart>{
        for (final part in page.uploadedParts) part.number: part,
      };
      for (final part in page.parts) {
        _checkCancelled(job);
        if (collected.containsKey(part.number)) continue;
        final knownEtag = uploadedByNumber[part.number]?.etag;
        if (knownEtag != null && knownEtag.isNotEmpty) {
          collected[part.number] = knownEtag;
          _refreshUploaded(job, collected, partSize);
          notifyListeners();
          continue;
        }
        final offset = (part.number - 1) * partSize;
        final length = _partLength(part.number, job.size, partSize);
        if (length <= 0) continue;
        final bytes = await _readChunk(file, offset, length);
        job.detail = 'آپلود بخش ${part.number} از $partCount';
        notifyListeners();
        final etag = await _putPart(job, api, session.id, part, bytes);
        collected[part.number] = etag;
        _refreshUploaded(job, collected, partSize);
        notifyListeners();
        await persist();
      }
      if (!page.hasMore) break;
      final next = page.nextStartPart;
      if (next == null || next <= startPart) break;
      startPart = next;
    }
    if (collected.length < partCount) {
      throw BoxeraException(
        'آپلود ناقص ماند (${collected.length} از $partCount بخش)؛ دوباره روی «ادامه» بزن.',
      );
    }
    final numbers = collected.keys.toList()..sort();
    return [
      for (final number in numbers) PartReference(number, collected[number]!),
    ];
  }

  Future<String> _putPart(
    VideoUploadJob job,
    BoxeraApi api,
    String sessionId,
    UploadPart part,
    List<int> bytes,
  ) async {
    Object? lastError;
    for (var attempt = 1; attempt <= 3; attempt++) {
      _checkCancelled(job);
      try {
        final headers = <String, String>{};
        part.headers.forEach((key, value) {
          final lower = key.toLowerCase();
          if (lower == 'host' || lower == 'content-length') return;
          headers[key] = value;
        });
        final uri = Uri.parse(part.url);
        final response = part.method == 'POST'
            ? await http
                  .post(uri, headers: headers, body: bytes)
                  .timeout(const Duration(minutes: 10))
            : await http
                  .put(uri, headers: headers, body: bytes)
                  .timeout(const Duration(minutes: 10));
        if (response.statusCode >= 200 && response.statusCode < 300) {
          final etag = response.headers['etag']?.trim() ?? '';
          if (etag.isEmpty) {
            throw BoxeraException(
              'پاسخ سرور آپلود بخش ${part.number} بدون ETag بود.',
            );
          }
          await _safeReport(
            api,
            sessionId,
            part.number,
            attempt,
            'success',
            etag: etag,
            size: bytes.length,
          );
          return etag;
        }
        lastError = BoxeraException(
          'آپلود بخش ${part.number} ناموفق بود.',
          statusCode: response.statusCode,
        );
      } catch (error) {
        lastError = error;
      }
      if (attempt >= 3) break;
      await _safeReport(
        api,
        sessionId,
        part.number,
        attempt,
        'retry',
        message: describeError(lastError),
      );
      job.detail = 'تلاش دوباره برای بخش ${part.number} (${attempt + 1} از 3)';
      notifyListeners();
      await Future<void>.delayed(Duration(seconds: attempt * 2));
    }
    await _safeReport(
      api,
      sessionId,
      part.number,
      3,
      'failed',
      message: describeError(
        lastError ?? 'آپلود بخش ${part.number} ناموفق بود.',
      ),
    );
    throw lastError is BoxeraException
        ? lastError
        : BoxeraException('آپلود بخش ${part.number} ناموفق بود.');
  }

  Future<void> _uploadTus(
    VideoUploadJob job,
    BoxeraApi api,
    UploadSession session,
    File file,
  ) async {
    final url = session.uploadUrl;
    if (url == null || url.isEmpty) {
      throw BoxeraException('Boxera آدرس آپلود TUS را برنگرداند.');
    }
    final baseHeaders = <String, String>{};
    session.uploadHeaders.forEach((key, value) {
      final lower = key.toLowerCase();
      if (lower == 'host' || lower == 'content-length') return;
      baseHeaders[key] = value;
    });
    final headers = <String, String>{'Tus-Resumable': '1.0.0', ...baseHeaders};
    var offset = session.offset;
    try {
      final head = await http
          .head(Uri.parse(url), headers: headers)
          .timeout(const Duration(seconds: 30));
      final remote = int.tryParse(head.headers['upload-offset'] ?? '');
      if (remote != null && remote >= 0) offset = remote;
    } catch (_) {
      // Keep the offset reported by init when the HEAD request is unavailable.
    }
    final partSize = session.partSize > 0
        ? session.partSize
        : (job.partSize ?? _defaultPartSize);
    final totalParts = (job.size / partSize).ceil();
    while (offset < job.size) {
      _checkCancelled(job);
      final length = min(partSize, job.size - offset);
      final bytes = await _readChunk(file, offset, length);
      job.detail = 'آپلود بخش ${offset ~/ partSize + 1} از $totalParts';
      notifyListeners();
      http.Response response;
      try {
        response = await http
            .patch(
              Uri.parse(url),
              headers: {
                ...headers,
                'Upload-Offset': '$offset',
                'Content-Type': 'application/offset+octet-stream',
              },
              body: bytes,
            )
            .timeout(const Duration(minutes: 10));
      } catch (error) {
        throw BoxeraException('آپلود TUS قطع شد: ${describeError(error)}');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw BoxeraException(
          'سرور TUS این بخش را نپذیرفت.',
          statusCode: response.statusCode,
        );
      }
      final next = int.tryParse(response.headers['upload-offset'] ?? '');
      offset = next ?? (offset + bytes.length);
      job.uploadedBytes = offset;
      job.progress = job.size <= 0 ? 0 : (offset / job.size).clamp(0.0, 1.0);
      notifyListeners();
      await persist();
    }
    job.uploadedBytes = job.size;
    job.progress = 1;
  }

  Future<void> _registerAndPoll(
    VideoUploadJob job,
    BoxeraApi api,
    String? channelId,
    bool publicVideo,
  ) async {
    final fileId = job.fileId;
    if (fileId == null || fileId.isEmpty) {
      throw BoxeraException(
        'شناسه فایل Boxera موجود نیست؛ آپلود را دوباره شروع کن.',
      );
    }
    job.state = VideoUploadJob.stateRegistering;
    job.detail = 'ثبت ویدیو در Boxera';
    notifyListeners();
    if (job.videoRequestId == null) {
      job.videoRequestId = _newId('video');
      await persist();
    }
    final videoId = await api.registerVideo(
      mediaFileId: fileId,
      title: job.title,
      requestId: job.videoRequestId!,
      channelId: channelIdOf(channelId),
      visibility: publicVideo ? 'public' : 'unlisted',
    );
    if (videoId == null || videoId.isEmpty) {
      throw BoxeraException('Boxera شناسه ویدیو را برنگرداند.');
    }
    job.videoId = videoId;
    job.state = VideoUploadJob.stateProcessing;
    job.detail = 'ویدیو ثبت شد؛ در انتظار پردازش';
    job.progress = 1;
    job.transcodePercent = null;
    notifyListeners();
    await persist();
    _schedulePoll(job, 3);
  }

  void _schedulePoll(VideoUploadJob job, int seconds) {
    if (_disposed) return;
    _timers[job.id]?.cancel();
    final factory = _apiFactory;
    final videoId = job.videoId;
    if (factory == null || videoId == null) return;
    _timers[job.id] = Timer(Duration(seconds: max(2, seconds)), () async {
      _timers.remove(job.id);
      if (_disposed ||
          job.state != VideoUploadJob.stateProcessing ||
          job.videoId == null) {
        return;
      }
      try {
        final info = await factory().videoProcessing(videoId);
        job.pollFailures = 0;
        if (info.progressPercent != null) {
          job.transcodePercent = info.progressPercent;
        }
        if (info.state == 'ready') {
          job.shareUrl = info.shareUrl;
          job.previewUrl = info.previewUrl;
          job.transcodePercent = 100;
          job.state = VideoUploadJob.stateReady;
          job.error = null;
          job.detail = (info.shareUrl ?? '').isEmpty
              ? 'پردازش تمام شد؛ لینک عمومی M3U8 در دسترس نیست.'
              : 'آماده پخش';
          job.progress = 1;
          notifyListeners();
          await persist();
          return;
        }
        if (info.state == 'failed' || info.state == 'unavailable') {
          job.state = VideoUploadJob.stateFailed;
          job.error = info.transcodeError ?? 'پردازش ویدیو ناموفق بود.';
          if (info.reuploadRequired) {
            job.error = '${job.error} فایل باید دوباره آپلود شود.';
          }
          job.detail = info.state == 'unavailable'
              ? 'ویدیو در دسترس نیست'
              : 'پردازش ناموفق';
          notifyListeners();
          await persist();
          return;
        }
        final message = info.message;
        job.detail = message != null && message.isNotEmpty
            ? message
            : (info.stage == null
                  ? 'در حال پردازش ویدیو'
                  : 'در حال پردازش • ${info.stage}');
        notifyListeners();
        await persist();
        _schedulePoll(job, info.pollAfterSeconds);
      } catch (error) {
        job.pollFailures += 1;
        if (job.pollFailures >= 20) {
          job.state = VideoUploadJob.stateFailed;
          job.error = 'بررسی وضعیت پردازش ممکن نشد: ${describeError(error)}';
          job.detail = 'برای ادامه، روی «ادامه» بزن.';
          notifyListeners();
          await persist();
          return;
        }
        job.detail = 'خطا در بررسی وضعیت؛ تلاش دوباره...';
        notifyListeners();
        _schedulePoll(job, 15);
      }
    });
  }

  Future<void> _safeReport(
    BoxeraApi api,
    String sessionId,
    int partNumber,
    int attempt,
    String status, {
    String? message,
    String? etag,
    int? size,
  }) async {
    try {
      await api.reportPart(
        sessionId,
        partNumber: partNumber,
        attempt: attempt,
        status: status,
        message: message,
        etag: etag,
        size: size,
      );
    } catch (_) {
      // Reporting is advisory; a failed report must not abort the upload.
    }
  }

  Future<List<int>> _readChunk(File file, int offset, int length) async {
    final handle = await file.open();
    try {
      await handle.setPosition(offset);
      return await handle.read(length);
    } finally {
      await handle.close();
    }
  }

  int _partLength(int number, int size, int partSize) {
    final remaining = size - (number - 1) * partSize;
    if (remaining <= 0) return 0;
    return remaining > partSize ? partSize : remaining;
  }

  void _refreshUploaded(
    VideoUploadJob job,
    Map<int, String> etags,
    int partSize,
  ) {
    var bytes = 0;
    for (final number in etags.keys) {
      bytes += _partLength(number, job.size, partSize);
    }
    job.uploadedBytes = bytes;
    job.progress = job.size <= 0 ? 0 : (bytes / job.size).clamp(0.0, 1.0);
  }

  void _checkCancelled(VideoUploadJob job) {
    if (_cancelled.contains(job.id)) throw const _UploadCancelled();
  }

  String _newId(String prefix) {
    final random = Random.secure();
    final suffix = List<int>.generate(
      6,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return '$prefix-${DateTime.now().millisecondsSinceEpoch}-$suffix';
  }

  @override
  void dispose() {
    _disposed = true;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    super.dispose();
  }
}
