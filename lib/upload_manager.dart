import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'boxera_api.dart';

const _defaultPartSize = 8 * 1024 * 1024;

bool isHttpLink(String value) {
  final uri = Uri.tryParse(value.trim());
  return uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty;
}

String linkVideoName(String url) {
  final uri = Uri.tryParse(url.trim());
  var segment = '';
  if (uri != null) {
    for (final part in uri.pathSegments) {
      if (part.trim().isNotEmpty) segment = part;
    }
  }
  segment = Uri.decodeComponent(segment).trim();
  segment = segment.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_');
  if (segment.isEmpty) segment = 'video.mp4';
  if (!segment.contains('.')) segment = '$segment.mp4';
  if (segment.length > 150) {
    final dot = segment.lastIndexOf('.');
    final extension = dot >= 0 ? segment.substring(dot) : '';
    segment = '${segment.substring(0, 150 - extension.length)}$extension';
  }
  return segment;
}

String formatByteCount(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
}

/// Total size declared by a `Content-Range: bytes 0-0/12345` header.
int? totalFromContentRange(String? header) {
  final text = (header ?? '').trim();
  final slash = text.lastIndexOf('/');
  if (slash < 0 || slash == text.length - 1) return null;
  final total = int.tryParse(text.substring(slash + 1).trim());
  return total == null || total <= 0 ? null : total;
}

/// Sliding-window average of a byte counter; reports only measured values.
class TransferMeter {
  TransferMeter({
    Duration window = const Duration(seconds: 15),
    Duration minInterval = const Duration(milliseconds: 250),
  }) : _window = window,
       _minInterval = minInterval;

  final Duration _window;
  final Duration _minInterval;
  final List<_TransferSample> _samples = [];

  double? _bytesPerSecond;
  int? _remainingSeconds;

  double? get bytesPerSecond => _bytesPerSecond;
  int? get remainingSeconds => _remainingSeconds;

  void reset() {
    _samples.clear();
    _bytesPerSecond = null;
    _remainingSeconds = null;
  }

  void sample(int bytes, int totalBytes, [DateTime? at]) {
    final now = at ?? DateTime.now();
    if (_samples.isNotEmpty && bytes < _samples.last.bytes) _samples.clear();
    if (_samples.isNotEmpty &&
        now.difference(_samples.last.at) < _minInterval) {
      return;
    }
    _samples.add(_TransferSample(now, bytes));
    while (_samples.length > 2 && now.difference(_samples.first.at) > _window) {
      _samples.removeAt(0);
    }
    final first = _samples.first;
    final last = _samples.last;
    final elapsed = last.at.difference(first.at).inMilliseconds / 1000.0;
    if (elapsed < 1 || last.bytes <= first.bytes) {
      _bytesPerSecond = null;
      _remainingSeconds = null;
      return;
    }
    final speed = (last.bytes - first.bytes) / elapsed;
    _bytesPerSecond = speed;
    if (totalBytes > last.bytes) {
      _remainingSeconds = ((totalBytes - last.bytes) / speed).round();
    } else {
      _remainingSeconds = totalBytes > 0 ? 0 : null;
    }
  }
}

class _TransferSample {
  const _TransferSample(this.at, this.bytes);
  final DateTime at;
  final int bytes;
}

String speedText(double? bytesPerSecond) => bytesPerSecond == null
    ? ''
    : '${formatByteCount(bytesPerSecond.round())}/ث';

String etaText(int? seconds) {
  if (seconds == null) return '';
  if (seconds <= 0) return 'چند لحظه';
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final secs = seconds % 60;
  final parts = <String>[
    if (hours > 0) '$hours ساعت',
    if (minutes > 0) '$minutes دقیقه',
    if (hours == 0 && secs > 0) '$secs ثانیه',
  ];
  return parts.isEmpty ? 'کمتر از ۱ ثانیه' : parts.join(' و ');
}

/// Where the bytes of a job come from, read one upload part at a time.
abstract class VideoByteSource {
  int get size;

  Future<Uint8List> read(int offset, int length);

  Future<void> close() async {}
}

class FileByteSource implements VideoByteSource {
  FileByteSource(this.file, this.size);

  final File file;
  @override
  final int size;

  @override
  Future<Uint8List> read(int offset, int length) async {
    final bytes = Uint8List(length);
    final handle = await file.open();
    var filled = 0;
    try {
      await handle.setPosition(offset);
      while (filled < length) {
        final chunk = await handle.read(length - filled);
        if (chunk.isEmpty) break;
        bytes.setRange(filled, filled + chunk.length, chunk);
        filled += chunk.length;
      }
    } finally {
      await handle.close();
    }
    if (filled == 0) {
      throw BoxeraException('خواندن بخش فایل از حافظهٔ گوشی ممکن نشد.');
    }
    return filled == length ? bytes : bytes.sublist(0, filled);
  }

  @override
  Future<void> close() async {}
}

/// Relays a remote file to Boxera one HTTP range at a time, so no copy of the
/// video is ever written to the phone.
class RangeHttpByteSource implements VideoByteSource {
  RangeHttpByteSource(this.uri, this.size, this._client, this._isCancelled);

  final Uri uri;
  @override
  final int size;
  final http.Client _client;
  final bool Function() _isCancelled;

  @override
  Future<Uint8List> read(int offset, int length) async {
    Object? lastError;
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        return await _readOnce(offset, length);
      } on _UploadCancelled {
        rethrow;
      } catch (error) {
        lastError = error;
        if (attempt < 3) {
          await Future<void>.delayed(Duration(seconds: attempt * 2));
        }
      }
    }
    throw lastError is BoxeraException
        ? lastError
        : BoxeraException(
            'خواندن بخش لینک ناموفق بود: ${describeError(lastError!)}',
          );
  }

  Future<Uint8List> _readOnce(int offset, int length) async {
    if (_isCancelled()) throw const _UploadCancelled();
    final request = http.Request('GET', uri)
      ..followRedirects = true
      ..maxRedirects = 5
      ..headers['Range'] = 'bytes=$offset-${offset + length - 1}'
      ..headers['Accept'] = '*/*'
      ..headers['User-Agent'] = 'FilmcaseUploader';
    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 60));
    if (response.statusCode != 206) {
      await response.stream.drain<void>();
      throw BoxeraException(
        'سرور لینک تکه‌ای از فایل را با Range نداد (پاسخ ${response.statusCode})؛ '
        'این لینک باید پشتیبانی Range داشته باشد.',
      );
    }
    final bytes = Uint8List(length);
    var filled = 0;
    await for (final chunk in response.stream.timeout(
      const Duration(minutes: 5),
    )) {
      if (_isCancelled()) throw const _UploadCancelled();
      if (filled + chunk.length > length) {
        throw BoxeraException('سرور لینک بیش از اندازهٔ درخواستی داده فرستاد.');
      }
      bytes.setRange(filled, filled + chunk.length, chunk);
      filled += chunk.length;
    }
    if (filled != length) {
      throw BoxeraException(
        'سرور لینک $length بایت بده بود ولی $filled بایت داد.',
      );
    }
    return bytes;
  }

  @override
  Future<void> close() async => _client.close();
}

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
    this.sourceUrl,
    this.downloaded = false,
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
  static const stateDownloading = 'downloading';
  static const stateUploading = 'uploading';
  static const stateCompleting = 'completing';
  static const stateRegistering = 'registering';
  static const stateProcessing = 'processing';
  static const stateReady = 'ready';
  static const stateFailed = 'failed';
  static const stateCancelled = 'cancelled';

  final String id;
  String path;
  String name;
  int size;
  String mimeType;
  final String? sourceUrl;
  bool downloaded;
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

  /// Live rate of the phase currently moving bytes; never persisted.
  final TransferMeter meter = TransferMeter();

  double? get bytesPerSecond => meter.bytesPerSecond;
  int? get remainingSeconds => meter.remainingSeconds;

  bool get isRunning =>
      state == stateDownloading ||
      state == stateUploading ||
      state == stateCompleting ||
      state == stateRegistering;

  bool get isReady => state == stateReady;

  /// States where bytes are currently crossing the network.
  bool get isMovingBytes =>
      state == stateDownloading || state == stateUploading;

  bool get isLink => (sourceUrl ?? '').isNotEmpty;

  String get stateLabel {
    switch (state) {
      case stateQueued:
        return 'در صف';
      case stateDownloading:
        return 'در حال خواندن از لینک';
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
    'sourceUrl': sourceUrl,
    'downloaded': downloaded,
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
      sourceUrl: json['sourceUrl'] as String?,
      downloaded: json['downloaded'] as bool? ?? false,
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

  /// Bytes this device has actually moved into Boxera for the listed jobs.
  int get movedBytes =>
      jobs.fold<int>(0, (sum, job) => sum + job.uploadedBytes);

  /// Sum of the live rates of the jobs currently moving bytes, or null.
  double? get queueSpeed {
    double? total;
    for (final job in jobs) {
      if (!job.isMovingBytes) continue;
      final speed = job.bytesPerSecond;
      if (speed != null) total = (total ?? 0) + speed;
    }
    return total;
  }

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

  int addLinks(Iterable<String> links) {
    var added = 0;
    for (final raw in links) {
      final url = raw.trim();
      if (!isHttpLink(url)) continue;
      if (jobs.any((job) => job.sourceUrl == url && !job.isReady)) continue;
      final name = linkVideoName(url);
      jobs.insert(
        0,
        VideoUploadJob(
          id: _newId('job'),
          path: '',
          name: name,
          size: 0,
          mimeType: videoMimeType(name),
          sourceUrl: url,
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
      job.detail = job.isLink ? 'در صف انتقال از لینک' : 'در صف آپلود';
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
    final wasActive = _active.contains(job.id);
    _cancelled.add(job.id);
    _runQueue.remove(job);
    _timers.remove(job.id)?.cancel();
    jobs.remove(job);
    if (!wasActive) unawaited(_cleanupTemp(job));
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
    job.detail = job.isLink ? 'باز کردن منبع لینک' : 'باز کردن فایل انتخاب‌شده';
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
    final source = await _openSource(job);
    try {
      final length = source.size;
      if (length <= 0) throw BoxeraException('منبع ویدیو خالی است.');
      job.state = VideoUploadJob.stateUploading;
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
      job.meter.reset();
      job.detail = 'اتصال به Boxera برقرار شد';
      notifyListeners();
      await persist();
      if (session.uploadStatus == 'completed') {
        job.uploadedBytes = job.size;
        job.progress = 1;
        notifyListeners();
        await _registerAndPoll(job, api, channelId, publicVideo);
        return;
      }
      if (session.protocol == 'tus-edge') {
        await _uploadTus(job, api, session, source);
        job.state = VideoUploadJob.stateCompleting;
        job.detail = 'نهایی‌سازی آپلود';
        notifyListeners();
        await _complete(job, api, const []);
      } else {
        final parts = await _uploadMultipart(job, api, session, source);
        await _complete(job, api, parts);
      }
      await _registerAndPoll(job, api, channelId, publicVideo);
    } finally {
      await source.close();
    }
  }

  Future<VideoByteSource> _openSource(VideoUploadJob job) async {
    if (!job.isLink) {
      final file = File(job.path);
      if (!await file.exists()) {
        throw BoxeraException(
          'فایل انتخاب‌شده در حافظه موقت برنامه نیست؛ آن را دوباره از گوشی انتخاب کن.',
        );
      }
      final size = await file.length();
      if (size <= 0) throw BoxeraException('فایل انتخاب‌شده خالی است.');
      return FileByteSource(file, size);
    }
    if (job.downloaded && job.path.isNotEmpty) {
      final existing = File(job.path);
      final length = await existing.exists() ? await existing.length() : 0;
      if (length > 0) return FileByteSource(existing, length);
    }
    final streamed = await _probeLink(job);
    if (streamed != null) return streamed;
    final file = await _downloadLinkToTempFile(job);
    return FileByteSource(file, await file.length());
  }

  /// Asks the link for one byte with a Range header: a 206 answer means the
  /// file can be relayed to Boxera in pieces without storing it on the phone.
  Future<RangeHttpByteSource?> _probeLink(VideoUploadJob job) async {
    final url = job.sourceUrl ?? '';
    final uri = Uri.tryParse(url);
    if (uri == null || !isHttpLink(url)) {
      throw BoxeraException(
        'لینک معتبر نیست؛ فقط آدرس http یا https پذیرفته می‌شود.',
      );
    }
    final initialTitle = defaultVideoTitle(linkVideoName(url));
    job.state = VideoUploadJob.stateDownloading;
    job.progress = 0;
    job.uploadedBytes = 0;
    job.meter.reset();
    job.detail = 'بررسی لینک برای انتقال تکه‌ای...';
    notifyListeners();

    final client = http.Client();
    var handedOver = false;
    try {
      final request = http.Request('GET', uri)
        ..followRedirects = true
        ..maxRedirects = 5
        ..headers['Accept'] = '*/*'
        ..headers['User-Agent'] = 'FilmcaseUploader'
        ..headers['Range'] = 'bytes=0-0';
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 45));
      _checkCancelled(job);
      final total = totalFromContentRange(response.headers['content-range']);
      if (response.statusCode != 206 || total == null) {
        await response.stream.listen((_) {}).cancel();
        return null;
      }
      await response.stream.drain<void>();
      _applyLinkMetadata(job, response.headers, uri, initialTitle);
      job.size = total;
      job.downloaded = false;
      job.detail = 'انتقال تکه‌ای از لینک؛ بدون ذخیره در گوشی';
      notifyListeners();
      await persist();
      handedOver = true;
      return RangeHttpByteSource(
        uri,
        total,
        client,
        () => _cancelled.contains(job.id),
      );
    } on _UploadCancelled {
      rethrow;
    } catch (_) {
      // Any failed probe falls back to the temporary-file path, which reports
      // the real error if the link cannot be fetched at all.
      return null;
    } finally {
      if (!handedOver) client.close();
    }
  }

  void _applyLinkMetadata(
    VideoUploadJob job,
    Map<String, String> headers,
    Uri uri,
    String initialTitle,
  ) {
    final contentType = (headers['content-type'] ?? '')
        .split(';')
        .first
        .trim()
        .toLowerCase();
    var name = _filenameFromDisposition(headers['content-disposition']);
    if (name == null || name.isEmpty) {
      final segments = uri.pathSegments;
      name = _safeFileName(
        segments.isEmpty ? '' : Uri.decodeComponent(segments.last),
      );
    }
    if (name.isEmpty) name = 'video.mp4';
    if (!name.contains('.')) {
      name = '$name${_extensionForMime(contentType) ?? '.mp4'}';
    }
    job.name = name;
    job.mimeType = contentType.startsWith('video/')
        ? contentType
        : videoMimeType(name);
    if (job.title == initialTitle) {
      job.title = defaultVideoTitle(name);
    }
  }

  Future<File> _downloadLinkToTempFile(VideoUploadJob job) async {
    final url = job.sourceUrl ?? '';
    final uri = Uri.tryParse(url);
    if (uri == null || !isHttpLink(url)) {
      throw BoxeraException(
        'لینک معتبر نیست؛ فقط آدرس http یا https پذیرفته می‌شود.',
      );
    }
    final initialTitle = defaultVideoTitle(linkVideoName(url));
    job.state = VideoUploadJob.stateDownloading;
    job.progress = 0;
    job.uploadedBytes = 0;
    job.meter.reset();
    job.detail = 'انتقال تکه‌ای ممکن نشد؛ دانلود موقت در حافظهٔ گوشی';
    notifyListeners();

    final dir = await getTemporaryDirectory();
    final partial = File('${dir.path}/filmcase_${job.id}.part');
    final request = http.Request('GET', uri)
      ..followRedirects = true
      ..maxRedirects = 5
      ..headers['Accept'] = '*/*'
      ..headers['User-Agent'] = 'FilmcaseUploader';
    final client = http.Client();
    RandomAccessFile? handle;
    var received = 0;
    try {
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 60));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw BoxeraException(
          'لینک پاسخ ${response.statusCode} داد؛ فایل باید مستقیم و عمومی باشد.',
        );
      }
      _applyLinkMetadata(job, response.headers, uri, initialTitle);
      final total = response.contentLength ?? 0;
      job.size = total;
      job.detail = total > 0
          ? 'دانلود 0 از ${_formatBytes(total)}'
          : 'دانلود از لینک...';
      notifyListeners();

      if (await partial.exists()) await partial.delete();
      handle = await partial.open(mode: FileMode.writeOnly);
      var lastTick = DateTime.now();
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 90),
      )) {
        _checkCancelled(job);
        await handle.writeFrom(chunk);
        received += chunk.length;
        job.meter.sample(received, total);
        job.size = total > 0 ? total : received;
        job.progress = total > 0 ? (received / total).clamp(0.0, 1.0) : 0.0;
        final now = DateTime.now();
        if (now.difference(lastTick) >= const Duration(milliseconds: 400)) {
          lastTick = now;
          job.detail = total > 0
              ? 'دانلود ${_formatBytes(received)} از ${_formatBytes(total)}'
              : 'دانلود ${_formatBytes(received)}';
          notifyListeners();
        }
      }
      await handle.flush();
      await handle.close();
      handle = null;
      if (received == 0) {
        throw BoxeraException('فایلی از این لینک دریافت نشد.');
      }
      final dot = job.name.lastIndexOf('.');
      final extension = dot >= 0
          ? job.name
                .substring(dot)
                .toLowerCase()
                .replaceAll(RegExp(r'[^a-z0-9.]'), '')
          : (_extensionForMime(job.mimeType) ?? '.mp4');
      final target = File('${dir.path}/filmcase_${job.id}$extension');
      if (await target.exists()) await target.delete();
      await partial.rename(target.path);
      job.path = target.path;
      job.size = received;
      job.downloaded = true;
      job.progress = 0;
      job.detail = 'دانلود کامل شد؛ شروع آپلود به Boxera';
      notifyListeners();
      await persist();
      return target;
    } on _UploadCancelled {
      await _discardPartial(handle, partial);
      rethrow;
    } catch (error) {
      await _discardPartial(handle, partial);
      if (_cancelled.contains(job.id)) throw const _UploadCancelled();
      if (error is BoxeraException) rethrow;
      throw BoxeraException(
        'دانلود از لینک ناموفق بود: ${describeError(error)}',
      );
    } finally {
      client.close();
    }
  }

  Future<void> _discardPartial(RandomAccessFile? handle, File partial) async {
    try {
      if (handle != null) await handle.close();
    } catch (_) {}
    try {
      if (await partial.exists()) await partial.delete();
    } catch (_) {}
  }

  Future<void> _cleanupTemp(VideoUploadJob job) async {
    if (!job.isLink) return;
    try {
      if (job.path.isNotEmpty) {
        final file = File(job.path);
        if (await file.exists()) await file.delete();
      }
      final dir = await getTemporaryDirectory();
      final partial = File('${dir.path}/filmcase_${job.id}.part');
      if (await partial.exists()) await partial.delete();
    } catch (_) {}
  }

  String _safeFileName(String raw) {
    var name = raw.split('/').last.split('\\').last.trim();
    name = name.replaceAll(RegExp(r'[<>:"|?*\x00-\x1F]'), '_');
    if (name.length > 150) {
      final dot = name.lastIndexOf('.');
      final extension = dot >= 0 ? name.substring(dot) : '';
      name = '${name.substring(0, 150 - extension.length)}$extension';
    }
    return name;
  }

  String? _filenameFromDisposition(String? header) {
    if (header == null || header.trim().isEmpty) return null;
    final encoded = RegExp(
      r"filename\*\s*=\s*(?:UTF-8'')?([^;]+)",
      caseSensitive: false,
    ).firstMatch(header);
    final plain = RegExp(
      r'filename\s*=\s*"?([^";]+)"?',
      caseSensitive: false,
    ).firstMatch(header);
    final raw = (encoded?.group(1) ?? plain?.group(1))?.trim();
    if (raw == null || raw.isEmpty) return null;
    try {
      return _safeFileName(Uri.decodeComponent(raw));
    } catch (_) {
      return _safeFileName(raw);
    }
  }

  String? _extensionForMime(String mimeType) {
    switch (mimeType.split(';').first.trim().toLowerCase()) {
      case 'video/mp4':
        return '.mp4';
      case 'video/quicktime':
        return '.mov';
      case 'video/x-matroska':
        return '.mkv';
      case 'video/webm':
        return '.webm';
      case 'video/x-msvideo':
        return '.avi';
      case 'video/mp2t':
        return '.ts';
      case 'video/x-flv':
        return '.flv';
      case 'video/mpeg':
        return '.mpg';
      case 'video/3gpp':
        return '.3gp';
      case 'video/ogg':
        return '.ogv';
      default:
        return null;
    }
  }

  String _formatBytes(int bytes) => formatByteCount(bytes);

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
    VideoByteSource source,
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
        job.detail = _partDetail(job, part.number, partCount, 'خواندن از لینک');
        notifyListeners();
        final bytes = await source.read(offset, length);
        job.detail = _partDetail(
          job,
          part.number,
          partCount,
          'آپلود به Boxera',
        );
        notifyListeners();
        final etag = await _putPart(job, api, session.id, part, bytes);
        collected[part.number] = etag;
        _refreshUploaded(job, collected, partSize, measured: true);
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
    VideoByteSource source,
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
      final number = offset ~/ partSize + 1;
      job.detail = _partDetail(job, number, totalParts, 'خواندن از لینک');
      notifyListeners();
      final bytes = await source.read(offset, length);
      job.detail = _partDetail(job, number, totalParts, 'آپلود به Boxera');
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
      job.meter.sample(offset, job.size);
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
          unawaited(_cleanupTemp(job));
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

  /// Progress line for one part. For links the step is named, because reading
  /// from the link and pushing to Boxera are two separate network trips.
  String _partDetail(
    VideoUploadJob job,
    int number,
    int partCount,
    String step,
  ) {
    final count = partCount > 0 ? 'بخش $number از $partCount' : 'بخش $number';
    return job.isLink ? '$count • $step' : 'آپلود $count';
  }

  int _partLength(int number, int size, int partSize) {
    final remaining = size - (number - 1) * partSize;
    if (remaining <= 0) return 0;
    return remaining > partSize ? partSize : remaining;
  }

  void _refreshUploaded(
    VideoUploadJob job,
    Map<int, String> etags,
    int partSize, {
    bool measured = false,
  }) {
    var bytes = 0;
    for (final number in etags.keys) {
      bytes += _partLength(number, job.size, partSize);
    }
    job.uploadedBytes = bytes;
    job.progress = job.size <= 0 ? 0 : (bytes / job.size).clamp(0.0, 1.0);
    // Only bytes this run actually pushed are timed; adopted server parts are
    // not a transfer and would invent a rate.
    if (measured) job.meter.sample(bytes, job.size);
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
