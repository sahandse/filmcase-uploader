import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

class ConnectionDiagnosticsPage extends StatefulWidget {
  const ConnectionDiagnosticsPage({
    super.key,
    required this.apiBase,
    required this.token,
  });
  final String apiBase;
  final String token;
  @override
  State<ConnectionDiagnosticsPage> createState() =>
      _ConnectionDiagnosticsPageState();
}

class _ConnectionDiagnosticsPageState extends State<ConnectionDiagnosticsPage> {
  bool running = false;
  final results = <Map<String, String>>[];

  void add(String title, String status, String detail) {
    if (mounted)
      setState(
        () => results.add({'title': title, 'status': status, 'detail': detail}),
      );
  }

  Future<void> runDiagnostics() async {
    if (running) return;
    setState(() {
      running = true;
      results.clear();
    });
    Uri base;
    try {
      base = Uri.parse(widget.apiBase.trim());
      if (!base.hasScheme ||
          base.host.isEmpty ||
          (base.scheme != 'https' && base.scheme != 'http')) {
        throw const FormatException(
          'آدرس باید با https:// یا http:// و دامنه معتبر وارد شود.',
        );
      }
      add('ساختار آدرس API', 'موفق', base.toString());
    } catch (e) {
      add('ساختار آدرس API', 'ناموفق', e.toString());
      if (mounted) setState(() => running = false);
      return;
    }
    try {
      final addresses = await InternetAddress.lookup(
        base.host,
      ).timeout(const Duration(seconds: 12));
      if (addresses.isEmpty)
        throw const SocketException('برای دامنه IP پیدا نشد.');
      add('DNS', 'موفق', addresses.map((e) => e.address).toSet().join('، '));
    } catch (e) {
      add('DNS', 'ناموفق', e.toString());
      if (mounted) setState(() => running = false);
      return;
    }
    try {
      final path = '${base.path.replaceAll(RegExp(r'/+$'), '')}/auth/me';
      final response = await http
          .get(
            base.replace(path: path),
            headers: {
              'Accept': 'application/json',
              if (widget.token.trim().isNotEmpty)
                'Authorization': 'Bearer ${widget.token.trim()}',
            },
          )
          .timeout(const Duration(seconds: 20));
      add(
        'ارتباط HTTPS و پاسخ API',
        'موفق',
        'سرور پاسخ داد: HTTP ${response.statusCode}',
      );
      if (response.statusCode >= 200 && response.statusCode < 300) {
        add('اعتبار توکن', 'موفق', 'توکن توسط endpoint احراز هویت پذیرفته شد.');
      } else if (response.statusCode == 401) {
        add(
          'اعتبار توکن',
          'ناموفق',
          widget.token.trim().isEmpty
              ? 'توکن وارد نشده است.'
              : 'سرور توکن را نپذیرفت؛ اعتبار و انقضای آن را بررسی کن.',
        );
      } else if (response.statusCode == 403) {
        add(
          'مجوز توکن',
          'محدود',
          'درخواست به سرور رسید اما این توکن مجوز دسترسی ندارد.',
        );
      } else if (response.statusCode == 404) {
        add(
          'مسیر API',
          'ناموفق',
          'مسیر /auth/me پیدا نشد؛ آدرس پایه را بررسی کن.',
        );
      } else if (response.statusCode >= 500) {
        add(
          'وضعیت سرور',
          'ناموفق',
          'خطای سمت Boxera: HTTP ${response.statusCode}',
        );
      } else {
        add('پاسخ احراز هویت', 'نیازمند بررسی', 'HTTP ${response.statusCode}');
      }
    } on HandshakeException catch (e) {
      add('گواهی SSL', 'ناموفق', e.message);
    } on SocketException catch (e) {
      add('ارتباط با API', 'ناموفق', e.message);
    } catch (e) {
      add('ارتباط با API', 'ناموفق', e.toString());
    } finally {
      if (mounted) setState(() => running = false);
    }
  }

  Future<void> copyReport() async {
    final report = results
        .map((e) => '${e['title']}: ${e['status']} — ${e['detail']}')
        .join('\n');
    await Clipboard.setData(ClipboardData(text: report));
    if (mounted)
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('گزارش کپی شد؛ توکن در گزارش قرار نمی‌گیرد.'),
        ),
      );
  }

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      const Text(
        'عیب‌یابی اتصال Boxera',
        style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 8),
      const Text(
        'ساختار آدرس، DNS، ارتباط امن و پاسخ واقعی endpoint احراز هویت بررسی می‌شوند. مقدار توکن نمایش داده نمی‌شود.',
        style: TextStyle(color: Colors.white60),
      ),
      const SizedBox(height: 14),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'آدرس API',
                style: TextStyle(color: Colors.white60, fontSize: 12),
              ),
              const SizedBox(height: 5),
              SelectableText(widget.apiBase, textDirection: TextDirection.ltr),
              const SizedBox(height: 10),
              Row(
                children: [
                  const Icon(
                    Icons.vpn_key_outlined,
                    color: Color(0xFFFF8A24),
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    widget.token.isEmpty ? 'توکن ثبت نشده' : 'توکن ذخیره شده',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      FilledButton.icon(
        onPressed: running ? null : runDiagnostics,
        icon: running
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.play_arrow),
        label: Text(running ? 'در حال آزمایش...' : 'شروع عیب‌یابی'),
      ),
      if (results.isNotEmpty) ...[
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'نتایج آزمایش',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
            ),
            TextButton.icon(
              onPressed: copyReport,
              icon: const Icon(Icons.copy, size: 17),
              label: const Text('کپی گزارش'),
            ),
          ],
        ),
        ...results.map((r) {
          final status = r['status']!;
          final color = status == 'موفق'
              ? Colors.greenAccent
              : (status == 'محدود' || status == 'نیازمند بررسی'
                    ? Colors.amber
                    : Colors.redAccent);
          return Card(
            child: ListTile(
              leading: Icon(
                status == 'موفق' ? Icons.check_circle : Icons.error_outline,
                color: color,
              ),
              title: Text(r['title']!),
              subtitle: SelectableText(r['detail']!),
              trailing: Text(
                status,
                style: TextStyle(color: color, fontSize: 12),
              ),
            ),
          );
        }),
      ],
      const SizedBox(height: 12),
      const Text(
        'گزارش شامل مقدار توکن نیست. پیش از اشتراک‌گذاری، اطلاعات شخصی احتمالی در متن خطا را بررسی کن.',
        style: TextStyle(color: Colors.white54, fontSize: 12),
      ),
    ],
  );
}
