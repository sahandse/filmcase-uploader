import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:filmcase_uploader/main.dart';

void main() {
  test('root application widget can be constructed', () {
    expect(const FilmcaseUploaderApp(), isA<Widget>());
  });
}
