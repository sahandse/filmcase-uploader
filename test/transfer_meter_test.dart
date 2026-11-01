import 'package:filmcase_uploader/upload_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final start = DateTime(2026, 11, 1, 12);
  Duration later(int seconds) => Duration(seconds: seconds);

  test('reports nothing before one second of measured transfer', () {
    final meter = TransferMeter();
    meter.sample(0, 10000, start);
    meter.sample(500, 10000, start.add(later(1)));
    expect(meter.bytesPerSecond, isNotNull);
    meter.reset();
    meter.sample(0, 10000, start);
    meter.sample(500, 10000, start.add(const Duration(milliseconds: 400)));
    expect(meter.bytesPerSecond, isNull);
    expect(meter.remainingSeconds, isNull);
  });

  test('measures speed and the remaining time from the byte samples', () {
    final meter = TransferMeter();
    meter.sample(0, 10000, start);
    meter.sample(2000, 10000, start.add(later(1)));
    expect(meter.bytesPerSecond, closeTo(2000, 1));
    expect(meter.remainingSeconds, 4);
    meter.sample(4000, 10000, start.add(later(2)));
    expect(meter.bytesPerSecond, closeTo(2000, 1));
    expect(meter.remainingSeconds, 3);
  });

  test('starts a new window when the counter falls back to a new phase', () {
    final meter = TransferMeter();
    meter.sample(5000, 10000, start);
    meter.sample(6000, 10000, start.add(later(1)));
    expect(meter.bytesPerSecond, isNotNull);
    meter.sample(0, 8000, start.add(later(2)));
    expect(meter.bytesPerSecond, isNull);
  });

  test('keeps the rate but drops the estimate when the size is unknown', () {
    final meter = TransferMeter();
    meter.sample(0, 0, start);
    meter.sample(3000, 0, start.add(later(1)));
    expect(meter.bytesPerSecond, closeTo(3000, 1));
    expect(meter.remainingSeconds, isNull);
  });

  test('formats only measured values', () {
    expect(formatByteCount(1536), '1.5 KB');
    expect(speedText(1536), '1.5 KB/ث');
    expect(speedText(null), '');
    expect(etaText(null), '');
    expect(etaText(75), '1 دقیقه و 15 ثانیه');
    expect(etaText(3700), '1 ساعت و 1 دقیقه');
  });
}
