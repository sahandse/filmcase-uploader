import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'boxera_api.dart';

/// Talks to `tools/boxera-link-importer.mjs`, the small server that reads a
/// video link itself and hands the bytes to Boxera. Delegating to it is the
/// only way an import can cost the phone neither storage nor mobile data.
class ImportTask {
  const ImportTask({
    required this.id,
    required this.url,
    required this.kind,
    required this.state,
    this.detail = '',
    this.size = 0,
    this.uploadedBytes = 0,
    this.progress = 0,
    this.folderId,
    this.channelId,
    this.title = '',
    this.fileId,
    this.videoId,
    this.m3u8Url,
    this.error,
    this.updatedAt,
  });

  final String id;
  final String url;
  final String kind;
  final String state;
  final String detail;
  final int size;
  final int uploadedBytes;
  final double progress;
  final int? folderId;
  final int? channelId;
  final String title;
  final String? fileId;
  final String? videoId;
  final String? m3u8Url;
  final String? error;
  final DateTime? updatedAt;

  static const finishedStates = {'ready', 'done', 'failed'};

  bool get isFinished => finishedStates.contains(state);
  bool get isSucceeded => state == 'ready' || state == 'done';

  factory ImportTask.fromJson(Map<String, dynamic> json) {
    final size = intOf(json['size']) ?? 0;
    final uploaded = intOf(json['uploaded_bytes']) ?? 0;
    final reported = double.tryParse(json['progress']?.toString() ?? '') ?? 0;
    return ImportTask(
      id: textOf(json['id']),
      url: textOf(json['url']),
      kind: textOf(json['kind']) == 'drive' ? 'drive' : 'video',
      state: textOf(json['state']) == '' ? 'queued' : textOf(json['state']),
      detail: textOf(json['detail']),
      size: size,
      uploadedBytes: uploaded,
      progress: reported > 0 ? reported : (size > 0 ? uploaded / size : 0),
      folderId: intOf(json['folder_id']),
      channelId: intOf(json['channel_id']),
      title: textOf(json['title']),
      fileId: nullableTextOf(json['file_id']),
      videoId: nullableTextOf(json['video_id']),
      m3u8Url: nullableTextOf(json['m3u8_url']),
      error: nullableTextOf(json['error']),
      updatedAt: DateTime.tryParse(textOf(json['updated_at'])),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'url': url,
    'kind': kind,
    'state': state,
    'detail': detail,
    'size': size,
    'uploaded_bytes': uploadedBytes,
    'progress': progress,
    'folder_id': folderId,
    'channel_id': channelId,
    'title': title,
    'file_id': fileId,
    'video_id': videoId,
    'm3u8_url': m3u8Url,
    'error': error,
    'updated_at': updatedAt?.toIso8601String(),
  };

  /// Merges a server answer into the locally known task; the server does not
  /// repeat every field, so unknown parts of the previous view are kept.
  ImportTask mergedWith(ImportTask next) => ImportTask(
    id: id,
    url: next.url.isEmpty ? url : next.url,
    kind: next.kind,
    state: next.state,
    detail: next.detail.isEmpty ? detail : next.detail,
    size: next.size == 0 ? size : next.size,
    uploadedBytes: next.uploadedBytes == 0 ? uploadedBytes : next.uploadedBytes,
    progress: next.progress == 0 ? progress : next.progress,
    folderId: next.folderId ?? folderId,
    channelId: next.channelId ?? channelId,
    title: next.title.isEmpty ? title : next.title,
    fileId: next.fileId ?? fileId,
    videoId: next.videoId ?? videoId,
    m3u8Url: next.m3u8Url ?? m3u8Url,
    error: next.error ?? error,
    updatedAt: next.updatedAt ?? DateTime.now(),
  );

  static const stateLabels = {
    'queued': 'در صف سرور',
    'probing': 'خواندن اطلاعات لینک توسط سرور',
    'init': 'ساخت نشست آپلود در Boxera',
    'uploading': 'انتقال بخش‌ها از لینک به Boxera',
    'completing': 'نهایی‌سازی آپلود',
    'registering': 'ثبت ویدیو در Boxera',
    'processing': 'در انتظار تبدیل ویدیو',
    'pending': 'پردازش سرور هنوز تمام نشده',
    'ready': 'آماده پخش',
    'done': 'انتقال تمام شد',
    'failed': 'ناموفق',
  };

  String get stateLabel => stateLabels[state] ?? state;
}

class ImportHealth {
  const ImportHealth({
    required this.ok,
    required this.apiBase,
    required this.hasBoxeraToken,
    required this.running,
    required this.pending,
  });

  final bool ok;
  final String apiBase;
  final bool hasBoxeraToken;
  final int running;
  final int pending;
}

class ImportService {
  ImportService({required String baseUrl, String token = ''})
    : baseUrl = baseUrl.trim().replaceAll(RegExp(r'/+$'), ''),
      token = token.trim();

  final String baseUrl;
  final String token;

  bool get isConfigured => baseUrl.isNotEmpty;

  Map<String, String> get _headers => {
    'Accept': 'application/json',
    if (token.isNotEmpty) 'Authorization': 'Bearer $token',
  };

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    if (!isConfigured) {
      throw BoxeraException(
        'آدرس سرور import در تنظیمات وارد نشده است؛ بدون سرور، لینک را نمی‌توان بدون مصرف اینترنت گوشی منتقل کرد.',
      );
    }
    final uri = Uri.parse('$baseUrl$path');
    http.Response response;
    try {
      response = method == 'GET'
          ? await http.get(uri, headers: _headers).timeout(timeout)
          : await http
                .post(
                  uri,
                  headers: {..._headers, 'Content-Type': 'application/json'},
                  body: jsonEncode(body ?? const <String, dynamic>{}),
                )
                .timeout(timeout);
    } on TimeoutException {
      throw BoxeraException('سرور import در زمان مقرر پاسخ نداد.');
    } catch (error) {
      throw BoxeraException(
        'ارتباط با سرور import برقرار نشد: ${describeError(error)}',
      );
    }
    dynamic decoded;
    if (response.body.trim().isNotEmpty) {
      try {
        decoded = jsonDecode(response.body);
      } catch (_) {
        decoded = null;
      }
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final map = decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : const <String, dynamic>{};
      throw BoxeraException(
        nullableTextOf(map['message']) ??
            'سرور import پاسخ داد: ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    throw BoxeraException('پاسخ سرور import ساختار JSON نداشت.');
  }

  Future<ImportHealth> health() async {
    final data = await _send(
      'GET',
      '/health',
      timeout: const Duration(seconds: 12),
    );
    final queue = data['queue'] is Map
        ? Map<String, dynamic>.from(data['queue'] as Map)
        : const <String, dynamic>{};
    return ImportHealth(
      ok: data['ok'] == true,
      apiBase: textOf(data['api_base']),
      hasBoxeraToken: data['has_boxera_token'] == true,
      running: intOf(queue['running']) ?? 0,
      pending: intOf(queue['pending']) ?? 0,
    );
  }

  Future<ImportTask> importLink({
    required String url,
    required String kind,
    int? folderId,
    int? channelId,
    String title = '',
  }) async {
    final data = await _send(
      'POST',
      '/import',
      body: {
        'url': url,
        'kind': kind,
        if (folderId != null) 'folder_id': folderId,
        if (channelId != null) 'channel_id': channelId,
        if (title.trim().isNotEmpty) 'title': title.trim(),
      },
    );
    return ImportTask.fromJson(data);
  }

  Future<ImportTask> status(String id) async {
    final data = await _send('GET', '/status/${Uri.encodeComponent(id)}');
    return ImportTask.fromJson(data);
  }
}

/// Keeps the delegated tasks on the phone so the list survives a restart and
/// keeps polling the server without the user pressing refresh.
class ImportDelegate extends ChangeNotifier {
  ImportDelegate();

  static const _key = 'import_tasks_v1';
  final List<ImportTask> tasks = [];
  Timer? _timer;
  bool refreshing = false;

  /// Set by the screen whenever the saved server settings change; the poll
  /// timer needs it because it fires outside of a user action.
  ImportService? currentService;

  List<ImportTask> get active =>
      tasks.where((task) => !task.isFinished).toList();

  ImportTask? forUrl(String url) {
    for (final task in tasks) {
      if (task.url == url) return task;
    }
    return null;
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_key) ?? const <String>[];
    tasks
      ..clear()
      ..addAll(
        saved.map((line) {
          try {
            return ImportTask.fromJson(
              jsonDecode(line) as Map<String, dynamic>,
            );
          } catch (_) {
            return null;
          }
        }).nonNulls,
      );
    _schedule();
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _key,
      tasks.map((task) => jsonEncode(task.toJson())).toList(),
    );
  }

  Future<void> delegate({
    required ImportService service,
    required List<String> urls,
    required String kind,
    int? folderId,
    int? channelId,
    String title = '',
  }) async {
    for (final url in urls) {
      if (forUrl(url)?.isSucceeded ?? false) continue;
      try {
        final created = await service.importLink(
          url: url,
          kind: kind,
          folderId: folderId,
          channelId: channelId,
          title: title,
        );
        _replace(created);
      } catch (error) {
        _replace(
          ImportTask(
            id: 'local-${DateTime.now().microsecondsSinceEpoch}',
            url: url,
            kind: kind,
            state: 'failed',
            detail: 'سرور این لینک را نپذیرفت',
            error: describeError(error),
            folderId: folderId,
            channelId: channelId,
            title: title,
            updatedAt: DateTime.now(),
          ),
        );
      }
      await _persist();
      notifyListeners();
    }
    _schedule();
  }

  void _replace(ImportTask next) {
    final index = tasks.indexWhere((task) => task.url == next.url);
    if (index < 0) {
      tasks.insert(0, next);
      return;
    }
    tasks[index] = tasks[index].mergedWith(next);
  }

  Future<void> refresh(ImportService service) async {
    if (refreshing || !service.isConfigured) return;
    refreshing = true;
    notifyListeners();
    try {
      for (final task in [...tasks]) {
        if (task.isFinished || task.id.startsWith('local-')) continue;
        try {
          _replace(await service.status(task.id));
        } catch (error) {
          _replace(
            task.mergedWith(
              ImportTask(
                id: task.id,
                url: task.url,
                kind: task.kind,
                state: task.state,
                error: describeError(error),
              ),
            ),
          );
        }
      }
      await _persist();
    } finally {
      refreshing = false;
      notifyListeners();
      _schedule();
    }
  }

  void _schedule() {
    final shouldPoll = active.isNotEmpty;
    if (shouldPoll && _timer == null) {
      _timer = Timer.periodic(const Duration(seconds: 5), (_) {
        final service = currentService;
        if (service == null) {
          stop();
          return;
        }
        unawaited(refresh(service));
      });
    } else if (!shouldPoll) {
      stop();
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> forget(ImportTask task) async {
    tasks.remove(task);
    await _persist();
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
