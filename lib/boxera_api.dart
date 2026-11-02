import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class BoxeraException implements Exception {
  BoxeraException(this.message, {this.statusCode, this.code});

  final String message;
  final int? statusCode;
  final String? code;

  @override
  String toString() =>
      statusCode == null ? message : '$message (HTTP $statusCode)';
}

String describeError(Object error) {
  if (error is BoxeraException) return error.message;
  final text = error
      .toString()
      .replaceFirst(RegExp(r'^[A-Za-z]+Exception:?\s*'), '')
      .trim();
  if (text.length > 160) return '${text.substring(0, 160)}…';
  return text.isEmpty ? 'خطای نامشخص' : text;
}

class AccountInfo {
  const AccountInfo({this.userId, this.canUpload, this.idempotentInit});

  final String? userId;
  final bool? canUpload;
  final bool? idempotentInit;
}

class UploadSession {
  const UploadSession({
    required this.id,
    required this.partSize,
    required this.partCount,
    required this.protocol,
    this.fileId,
    this.uploadUrl,
    this.uploadHeaders = const {},
    this.offset = 0,
    this.length = 0,
    this.uploadStatus,
    this.isResume = false,
  });

  final String id;
  final int partSize;
  final int partCount;
  final String protocol;
  final String? fileId;
  final String? uploadUrl;
  final Map<String, String> uploadHeaders;
  final int offset;
  final int length;
  final String? uploadStatus;
  final bool isResume;

  factory UploadSession.fromJson(Map<String, dynamic> json) {
    final protocol = textOf(json['upload_protocol']);
    return UploadSession(
      id: textOf(json['upload_session_id']),
      partSize: intOf(json['part_size']) ?? 0,
      partCount: intOf(json['part_count']) ?? 0,
      protocol: protocol.isEmpty ? 's3-multipart' : protocol,
      fileId: nullableTextOf(json['file_id']),
      uploadUrl: nullableTextOf(json['upload_url']),
      uploadHeaders: parseUploadHeaders(json['upload_headers']),
      offset: intOf(json['upload_offset']) ?? 0,
      length: intOf(json['upload_length']) ?? 0,
      uploadStatus: nullableTextOf(json['upload_status']),
      isResume: json['is_resume'] == true,
    );
  }
}

class UploadPart {
  const UploadPart({
    required this.number,
    required this.url,
    required this.method,
    this.headers = const {},
  });

  final int number;
  final String url;
  final String method;
  final Map<String, String> headers;
}

class UploadedPart {
  const UploadedPart({required this.number, this.etag, this.size});

  final int number;
  final String? etag;
  final int? size;
}

class PartUrlsPage {
  const PartUrlsPage({
    required this.parts,
    required this.uploadedParts,
    required this.hasMore,
    this.nextStartPart,
  });

  final List<UploadPart> parts;
  final List<UploadedPart> uploadedParts;
  final bool hasMore;
  final int? nextStartPart;

  factory PartUrlsPage.fromJson(Map<String, dynamic> json) {
    final parts = <UploadPart>[];
    final rawParts = json['parts'];
    if (rawParts is List) {
      for (final item in rawParts) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        final url = textOf(map['upload_url']);
        final number = intOf(map['part_number']) ?? 0;
        if (url.isEmpty || number <= 0) continue;
        final method = textOf(map['method']);
        parts.add(
          UploadPart(
            number: number,
            url: url,
            method: method.isEmpty ? 'PUT' : method.toUpperCase(),
            headers: parseUploadHeaders(map['headers']),
          ),
        );
      }
    }
    final uploaded = <UploadedPart>[];
    final rawUploaded = json['uploaded_parts'];
    if (rawUploaded is List) {
      for (final item in rawUploaded) {
        if (item is! Map) continue;
        final map = Map<String, dynamic>.from(item);
        final number = intOf(map['part_number']) ?? 0;
        if (number <= 0) continue;
        uploaded.add(
          UploadedPart(
            number: number,
            etag: nullableTextOf(map['etag']),
            size: intOf(map['size']),
          ),
        );
      }
    }
    return PartUrlsPage(
      parts: parts,
      uploadedParts: uploaded,
      hasMore: json['has_more_parts'] == true,
      nextStartPart: intOf(json['next_start_part']),
    );
  }
}

class PartReference {
  const PartReference(this.number, this.etag);

  final int number;
  final String etag;
}

class ProcessingInfo {
  const ProcessingInfo({
    required this.state,
    required this.pollAfterSeconds,
    this.shareUrl,
    this.previewUrl,
    this.playbackReady = false,
    this.progressPercent,
    this.stage,
    this.message,
    this.transcodeError,
    this.reuploadRequired = false,
  });

  final String state;
  final int pollAfterSeconds;
  final String? shareUrl;
  final String? previewUrl;
  final bool playbackReady;
  final int? progressPercent;
  final String? stage;
  final String? message;
  final String? transcodeError;
  final bool reuploadRequired;

  factory ProcessingInfo.fromJson(Map<String, dynamic> json) {
    final playback = mapOf(json['playback']);
    final transcode = mapOf(json['transcode']);
    final progress = mapOf(transcode['progress']);
    final file = mapOf(json['file']);
    return ProcessingInfo(
      state: textOf(json['state']),
      pollAfterSeconds: intOf(json['poll_after_seconds']) ?? 5,
      shareUrl: firstText([
        playback['share_url'],
        playback['m3u8_url'],
        json['m3u8_url'],
        json['share_url'],
      ]),
      previewUrl: firstText([
        playback['url'],
        playback['preview_url'],
        json['preview_url'],
      ]),
      playbackReady: playback['ready'] == true,
      progressPercent: intOf(progress['percent']),
      stage: nullableTextOf(progress['stage']),
      message:
          nullableTextOf(progress['message']) ??
          nullableTextOf(json['message']),
      transcodeError:
          nullableTextOf(transcode['error']) ?? nullableTextOf(json['error']),
      reuploadRequired: file['reupload_required'] == true,
    );
  }
}

/// Boxera keeps every management id as an integer, but the app carries them as
/// strings (that is how they arrive and how they persist), so they are sent
/// back in the type the endpoint declares.
Object managementId(String value) {
  final text = value.trim();
  return int.tryParse(text) ?? text;
}

/// Container of a file name, limited to the mimes Boxera transcodes.
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

/// `space=video` rejects a mime that does not start with `video/`, so a server
/// answering `application/octet-stream` for a clip still uploads it.
String videoMimeTypeFor(String name, String declared) {
  final type = declared.split(';').first.trim().toLowerCase();
  if (type.startsWith('video/') && type.length > 'video/'.length) return type;
  return videoMimeType(name);
}

String clipText(String value, int maxLength) =>
    value.length <= maxLength ? value : value.substring(0, maxLength);

const _minPartSize = 524288;
const _maxPartSize = 5368709120;
const _maxParts = 10000;

/// Part size Boxera accepts for one file: inside its byte window and never
/// more than 10000 sections, which needs a bigger part for a huge file.
int suggestedPartSize(int sizeBytes) {
  const defaultPartSize = 8 * 1024 * 1024;
  if (sizeBytes <= defaultPartSize * _maxParts) return defaultPartSize;
  final needed = (sizeBytes / _maxParts).ceil();
  final rounded = (needed / _minPartSize).ceil() * _minPartSize;
  return rounded.clamp(_minPartSize, _maxPartSize);
}

Map<String, dynamic> uploadInitBody({
  required String originalName,
  required String mimeType,
  required int sizeBytes,
  required String requestId,
  int? channelId,
  String? fileId,
  int? partSize,
}) => {
  'space': 'video',
  'original_name': clipText(originalName, 255),
  'mime_type': videoMimeTypeFor(originalName, mimeType),
  'size_bytes': sizeBytes,
  'upload_request_id': clipText(requestId, 120),
  if (partSize != null) 'part_size': partSize,
  if (channelId != null) 'channel_id': channelId,
  if (fileId != null && fileId.trim().isNotEmpty)
    'file_id': managementId(fileId),
};

Map<String, dynamic> videoRegisterBody({
  required String mediaFileId,
  required String title,
  required String requestId,
  int? channelId,
  String? description,
  String visibility = 'unlisted',
}) => {
  'media_file_id': managementId(mediaFileId),
  'title': clipText(title, 255),
  'upload_request_id': clipText(requestId, 120),
  'visibility': visibility,
  'access_type': 'free',
  if (channelId != null) 'channel_id': channelId,
  if (description != null && description.trim().isNotEmpty)
    'description': description.trim(),
};

class BoxeraApi {
  BoxeraApi({required String baseUrl, required String token})
    : baseUrl = baseUrl.trim().replaceAll(RegExp(r'/+$'), ''),
      token = token.trim();

  final String baseUrl;
  final String token;

  static const _timeout = Duration(seconds: 45);

  Map<String, String> get _headers => {
    'Accept': 'application/json',
    if (token.isNotEmpty) 'Authorization': 'Bearer $token',
  };

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    http.Response response;
    try {
      final uri = Uri.parse('$baseUrl$path');
      if (method == 'GET') {
        response = await http.get(uri, headers: _headers).timeout(_timeout);
      } else {
        response = await http
            .post(
              uri,
              headers: {..._headers, 'Content-Type': 'application/json'},
              body: jsonEncode(body ?? const <String, dynamic>{}),
            )
            .timeout(_timeout);
      }
    } on TimeoutException {
      throw BoxeraException(
        'پاسخ Boxera در زمان مقرر دریافت نشد؛ اتصال اینترنت را بررسی کن.',
      );
    } catch (error) {
      throw BoxeraException(
        'ارتباط با Boxera برقرار نشد: ${describeError(error)}',
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
      throw _exceptionFor(response.statusCode, decoded);
    }
    return _payload(decoded);
  }

  Future<AccountInfo> authMe() async {
    final data = await _send('GET', '/auth/me');
    final user = mapOf(data['user']);
    final features = mapOf(data['upload_api_features']);
    return AccountInfo(
      userId: nullableTextOf(user['id']) ?? nullableTextOf(data['id']),
      canUpload: data.containsKey('can_upload')
          ? boolOf(data['can_upload'])
          : null,
      idempotentInit: features.containsKey('idempotent_init')
          ? boolOf(features['idempotent_init'])
          : null,
    );
  }

  Future<UploadSession> initUpload({
    required String originalName,
    required String mimeType,
    required int sizeBytes,
    required String requestId,
    int? channelId,
    String? fileId,
    int? partSize,
  }) async {
    final data = await _send(
      'POST',
      '/uploads/init',
      body: uploadInitBody(
        originalName: originalName,
        mimeType: mimeType,
        sizeBytes: sizeBytes,
        requestId: requestId,
        channelId: channelId,
        fileId: fileId,
        partSize: partSize,
      ),
    );
    final session = UploadSession.fromJson(data);
    if (session.id.isEmpty) {
      throw BoxeraException('Boxera نشست آپلود را برنگرداند.');
    }
    return session;
  }

  Future<PartUrlsPage> partUrls(
    String sessionId, {
    int startPart = 1,
    int limit = 200,
  }) async {
    final data = await _send(
      'POST',
      '/uploads/${Uri.encodeComponent(sessionId)}/part-urls',
      body: {'start_part': startPart, 'limit': limit},
    );
    return PartUrlsPage.fromJson(data);
  }

  Future<void> reportPart(
    String sessionId, {
    required int partNumber,
    required int attempt,
    required String status,
    String? message,
    String? etag,
    int? size,
  }) async {
    await _send(
      'POST',
      '/uploads/${Uri.encodeComponent(sessionId)}/part-retry',
      body: {
        'part_number': partNumber,
        'attempt': attempt,
        'status': status,
        if (message != null && message.isNotEmpty)
          'message': clipText(message, 255),
        if (etag != null) 'etag': etag,
        if (size != null) 'size': size,
      },
    );
  }

  Future<String?> completeUpload(
    String sessionId,
    List<PartReference> parts,
  ) async {
    final data = await _send(
      'POST',
      '/uploads/${Uri.encodeComponent(sessionId)}/complete',
      body: {
        'parts': [
          for (final part in parts)
            {'part_number': part.number, 'etag': part.etag},
        ],
      },
    );
    return nullableTextOf(data['id']);
  }

  Future<String?> registerVideo({
    required String mediaFileId,
    required String title,
    required String requestId,
    int? channelId,
    String? description,
    String visibility = 'unlisted',
  }) async {
    final data = await _send(
      'POST',
      '/video/videos',
      body: videoRegisterBody(
        mediaFileId: mediaFileId,
        title: title,
        requestId: requestId,
        channelId: channelId,
        description: description,
        visibility: visibility,
      ),
    );
    final video = mapOf(data['video']);
    return nullableTextOf(video['id']) ??
        nullableTextOf(data['video_id']) ??
        nullableTextOf(data['id']);
  }

  Future<ProcessingInfo> videoProcessing(String videoId) async {
    final data = await _send(
      'GET',
      '/video/videos/${Uri.encodeComponent(videoId)}/processing',
    );
    return ProcessingInfo.fromJson(data);
  }
}

Map<String, dynamic> mapOf(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  return const <String, dynamic>{};
}

String textOf(dynamic value) => value?.toString().trim() ?? '';

String? nullableTextOf(dynamic value) {
  final text = textOf(value);
  return text.isEmpty ? null : text;
}

int? intOf(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.round();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

bool boolOf(dynamic value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  final text = textOf(value).toLowerCase();
  return text == 'true' || text == '1' || text == 'yes';
}

String? firstText(List<dynamic> values) {
  for (final value in values) {
    final text = nullableTextOf(value);
    if (text != null) return text;
  }
  return null;
}

Map<String, String> parseUploadHeaders(dynamic raw) {
  final result = <String, String>{};
  if (raw is Map) {
    raw.forEach((key, value) {
      if (key == null || value == null) return;
      result[key.toString()] = value.toString();
    });
  } else if (raw is List) {
    for (final item in raw) {
      if (item is Map) {
        final name = item['name'] ?? item['key'] ?? item['header'];
        final value = item['value'];
        if (name != null && value != null) {
          result[name.toString()] = value.toString();
        }
      } else if (item is List && item.length >= 2) {
        result[item[0].toString()] = item[1].toString();
      }
    }
  }
  return result;
}

Map<String, dynamic> _payload(dynamic decoded) {
  if (decoded is Map<String, dynamic>) {
    for (final key in const ['data', 'response']) {
      final inner = decoded[key];
      if (inner is Map) return Map<String, dynamic>.from(inner);
    }
    return decoded;
  }
  if (decoded is Map) return Map<String, dynamic>.from(decoded);
  if (decoded is List) return <String, dynamic>{'items': decoded};
  return <String, dynamic>{};
}

BoxeraException _exceptionFor(int status, dynamic decoded) {
  final root = mapOf(decoded);
  final inner = mapOf(root['data']);
  var message = textOf(root['message']);
  if (message.isEmpty) message = textOf(inner['message']);
  if (message.isEmpty) {
    message = _firstError(root['errors'] ?? inner['errors']);
  }
  if (message.isEmpty) message = _statusMessage(status);
  final code = nullableTextOf(root['code']) ?? nullableTextOf(inner['code']);
  return BoxeraException(message, statusCode: status, code: code);
}

String _firstError(dynamic errors) {
  if (errors is List) {
    for (final item in errors) {
      final text = textOf(item);
      if (text.isNotEmpty) return text;
    }
  }
  if (errors is Map) {
    for (final value in errors.values) {
      if (value is List) {
        for (final item in value) {
          final text = textOf(item);
          if (text.isNotEmpty) return text;
        }
      }
      final text = textOf(value);
      if (text.isNotEmpty) return text;
    }
  }
  return '';
}

String _statusMessage(int status) {
  switch (status) {
    case 400:
      return 'درخواست نامعتبر است.';
    case 401:
      return 'توکن آپلود نامعتبر یا منقضی شده است.';
    case 403:
      return 'این توکن اجازه انجام این کار را ندارد.';
    case 404:
      return 'مورد درخواستی در Boxera پیدا نشد.';
    case 409:
      return 'وضعیت آپلود با درخواست هم‌خوانی ندارد.';
    case 413:
      return 'حجم فایل بیش از حد مجاز است.';
    case 422:
      return 'اطلاعات آپلود پذیرفته نشد؛ سهمیه یا محدودیت پلن را بررسی کن.';
    case 429:
      return 'تعداد درخواست‌ها زیاد است؛ کمی بعد دوباره تلاش کن.';
    case 500:
    case 502:
    case 503:
    case 504:
      return 'Boxera موقتاً در دسترس نیست.';
    default:
      return 'درخواست Boxera ناموفق بود.';
  }
}
