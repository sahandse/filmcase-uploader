import 'package:filmcase_uploader/upload_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('accepts only http(s) links with a host', () {
    expect(isHttpLink('https://example.com/a.mp4'), isTrue);
    expect(isHttpLink(' http://example.com/a '), isTrue);
    expect(isHttpLink('ftp://example.com/a.mp4'), isFalse);
    expect(isHttpLink('example.com/a.mp4'), isFalse);
    expect(isHttpLink(''), isFalse);
  });

  test('derives a usable video name from the link', () {
    expect(
      linkVideoName('https://cdn.example.com/films/My%20Film.mkv?token=1'),
      'My Film.mkv',
    );
    expect(linkVideoName('https://example.com/episode'), 'episode.mp4');
    expect(linkVideoName('https://example.com/'), 'video.mp4');
    expect(linkVideoName('https://example.com/../evil'), 'evil.mp4');
  });
}
