import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:filmcase_uploader/import_service.dart';

void main() {
  test('reads the exact JSON shape the import server returns', () {
    final task = ImportTask.fromJson(
      jsonDecode('''
      {
        "id": "0f9c1b2a-0000-4000-8000-000000000001",
        "url": "https://cdn.example/film.mkv",
        "kind": "drive",
        "folder_id": 27577,
        "channel_id": null,
        "title": "",
        "state": "uploading",
        "detail": "بخش ۳ از ۵ • آپلود به Boxera",
        "size": 524288000,
        "uploaded_bytes": 131072000,
        "progress": 0.25,
        "file_id": "file-42",
        "video_id": null,
        "m3u8_url": null,
        "error": null,
        "updated_at": "2026-11-02T08:00:00.000Z"
      }
      ''')
          as Map<String, dynamic>,
    );
    expect(task.kind, 'drive');
    expect(task.folderId, 27577);
    expect(task.channelId, isNull);
    expect(task.stateLabel, 'انتقال بخش‌ها از لینک به Boxera');
    expect(task.progress, 0.25);
    expect(task.isFinished, isFalse);
    expect(task.fileId, 'file-42');
    expect(task.updatedAt, isNotNull);
  });

  test('derives progress from byte counts when the server reports none', () {
    final task = ImportTask.fromJson({
      'id': 'x',
      'url': 'https://cdn.example/a.mp4',
      'state': 'uploading',
      'size': 1000,
      'uploaded_bytes': 400,
      'progress': 0,
    });
    expect(task.progress, 0.4);
  });

  test('keeps known fields when a later answer omits them', () {
    final first = ImportTask.fromJson({
      'id': 'x',
      'url': 'https://cdn.example/a.mp4',
      'state': 'ready',
      'detail': 'آماده پخش',
      'size': 1000,
      'uploaded_bytes': 1000,
      'm3u8_url': 'https://cdn.boxera.ir/hls/a.m3u8',
    });
    final poll = ImportTask.fromJson({
      'id': 'x',
      'url': 'https://cdn.example/a.mp4',
      'state': 'ready',
      'size': 1000,
      'uploaded_bytes': 1000,
    });
    final merged = first.mergedWith(poll);
    expect(merged.m3u8Url, 'https://cdn.boxera.ir/hls/a.m3u8');
    expect(merged.detail, 'آماده پخش');
    expect(merged.isSucceeded, isTrue);
  });

  test('an unlisted state is shown verbatim instead of invented', () {
    expect(
      ImportTask.fromJson({'id': 'x', 'state': 'aborting'}).stateLabel,
      'aborting',
    );
  });

  test('a host typed without a scheme still parses', () {
    expect(
      ImportService(baseUrl: '10.0.0.5:8787/').baseUrl,
      'http://10.0.0.5:8787',
    );
    expect(
      ImportService(baseUrl: 'https://import.example/').baseUrl,
      'https://import.example',
    );
    expect(ImportService(baseUrl: '').isConfigured, isFalse);
  });
}
