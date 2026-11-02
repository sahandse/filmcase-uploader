import 'package:flutter_test/flutter_test.dart';
import 'package:filmcase_uploader/boxera_api.dart';

void main() {
  test('sends management ids as the integers the contract declares', () {
    final body = uploadInitBody(
      originalName: 'film.mkv',
      mimeType: 'video/x-matroska',
      sizeBytes: 524288000,
      requestId: 'upload-1730000000-abcdef',
      channelId: 43,
      fileId: '91234',
      partSize: 8 * 1024 * 1024,
    );
    expect(body['space'], 'video');
    expect(body['file_id'], 91234);
    expect(body['channel_id'], 43);
    expect(body['mime_type'], 'video/x-matroska');
    expect(body['size_bytes'], 524288000);

    final video = videoRegisterBody(
      mediaFileId: '91234',
      title: 'فیلم',
      requestId: 'video-1730000000-abcdef',
      channelId: 43,
    );
    expect(video['media_file_id'], 91234);
    expect(video['access_type'], 'free');
    expect(video.containsKey('description'), isFalse);
  });

  test('keeps an id that is not a number instead of turning it to zero', () {
    expect(managementId('file-42'), 'file-42');
    expect(managementId(' 42 '), 42);
    expect(
      uploadInitBody(
        originalName: 'a.mp4',
        mimeType: 'video/mp4',
        sizeBytes: 10,
        requestId: 'k',
        fileId: ' ',
      ).containsKey('file_id'),
      isFalse,
    );
  });

  test('never offers Boxera a non-video mime for space=video', () {
    final body = uploadInitBody(
      originalName: 'series.mkv',
      mimeType: 'application/octet-stream',
      sizeBytes: 100,
      requestId: 'k',
    );
    expect(body['mime_type'], 'video/x-matroska');
    expect(videoMimeTypeFor('clip.mp4', 'video/MP4; codecs=avc1'), 'video/mp4');
    expect(videoMimeTypeFor('clip.bin', ''), 'video/mp4');
  });

  test('clips the fields the contract bounds', () {
    final body = uploadInitBody(
      originalName: 'x' * 300,
      mimeType: 'video/mp4',
      sizeBytes: 100,
      requestId: 'r' * 200,
    );
    expect((body['original_name'] as String).length, 255);
    expect((body['upload_request_id'] as String).length, 120);
  });

  test('asks for a part size inside the window the server enforces', () {
    expect(suggestedPartSize(500 * 1024 * 1024), 8 * 1024 * 1024);
    // A small file still gets the same suggested part; Boxera derives
    // part_count from it, so the upload is one section.
    expect(suggestedPartSize(1024), 8 * 1024 * 1024);
    // 100 GiB needs more than 10000 sections at 8 MiB, so the part grows.
    final huge = suggestedPartSize(100 * 1024 * 1024 * 1024);
    expect(huge, greaterThanOrEqualTo(524288));
    expect(huge, lessThanOrEqualTo(5368709120));
    expect((100 * 1024 * 1024 * 1024) / huge, lessThanOrEqualTo(10000));
  });
}
