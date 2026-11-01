import 'dart:io';

import 'package:filmcase_uploader/boxera_api.dart';
import 'package:filmcase_uploader/upload_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reads the total out of a Content-Range header', () {
    expect(totalFromContentRange('bytes 0-0/12345678'), 12345678);
    expect(totalFromContentRange(' bytes 512-1023 / 4096 '), 4096);
    expect(totalFromContentRange('bytes */99'), 99);
    expect(totalFromContentRange('bytes 0-0/*'), isNull);
    expect(totalFromContentRange('bytes 0-0/0'), isNull);
    expect(totalFromContentRange('bytes 0-0'), isNull);
    expect(totalFromContentRange(null), isNull);
  });

  test('file source returns exactly the requested window', () async {
    final file = _tempFile('window');
    await file.writeAsBytes(List<int>.generate(10, (index) => index));
    final source = FileByteSource(file, await file.length());
    try {
      expect(source.size, 10);
      expect(await source.read(0, 1), [0]);
      expect(await source.read(3, 4), [3, 4, 5, 6]);
      expect(await source.read(8, 5), [8, 9]);
    } finally {
      await source.close();
      await file.delete();
    }
  });

  test('file source fails loudly when the window is past the end', () async {
    final file = _tempFile('eof');
    await file.writeAsBytes([1, 2, 3]);
    final source = FileByteSource(file, 3);
    try {
      await expectLater(source.read(9, 2), throwsA(isA<BoxeraException>()));
    } finally {
      await source.close();
      await file.delete();
    }
  });
}

File _tempFile(String label) => File(
  '${Directory.systemTemp.path}/filmcase_$label'
  '_${DateTime.now().microsecondsSinceEpoch}.bin',
);
