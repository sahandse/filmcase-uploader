import 'dart:convert';
import 'connection_diagnostics_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const FilmcaseUploaderApp());

const orange = Color(0xFFFF8A24);
const bg = Color(0xFF101114);
const panel = Color(0xFF1B1E23);

String bytesText(int? value) {
  if (value == null) return 'نامشخص';
  if (value < 1024) return '$value B';
  if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
  if (value < 1024 * 1024 * 1024) return '${(value / (1024 * 1024)).toStringAsFixed(1)} MB';
  return '${(value / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

class UploadItem {
  UploadItem(this.url, {this.folder = 'ریشه'});
  final String url;
  String folder;
  String status = 'در انتظار بررسی';
  int? sizeBytes;
  String? contentType;
  String? error;
  bool checking = false;

  Map<String, dynamic> toJson() => {
    'url': url, 'folder': folder, 'status': status,
    'sizeBytes': sizeBytes, 'contentType': contentType, 'error': error,
  };

  factory UploadItem.fromJson(Map<String, dynamic> json) {
    final item = UploadItem(json['url'] as String? ?? '', folder: json['folder'] as String? ?? 'ریشه');
    item.status = json['status'] as String? ?? 'در انتظار بررسی';
    item.sizeBytes = json['sizeBytes'] as int?;
    item.contentType = json['contentType'] as String?;
    item.error = json['error'] as String?;
    return item;
  }
}

class FilmcaseUploaderApp extends StatelessWidget {
  const FilmcaseUploaderApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Filmcase Uploader',
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bg,
      colorScheme: const ColorScheme.dark(primary: orange, surface: panel),
      useMaterial3: true,
      inputDecorationTheme: InputDecorationTheme(
        filled: true, fillColor: panel,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      ),
    ),
    home: const HomePage(),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _secure = FlutterSecureStorage();
  String mode = 'اتصال شخصی Boxera';
  String apiBase = 'https://boxera.ir/api';
  String token = '';
  String folder = 'ریشه';
  final folders = <String>['ریشه', 'فیلم‌ها', 'سریال‌ها', 'دوبله', 'زیرنویس'];
  final items = <UploadItem>[];
  final linkController = TextEditingController();
  final folderController = TextEditingController();
  bool obscure = true;
  bool checkingAll = false;
  String connectionState = 'تنظیم نشده';
  int selectedNav = 0;
  int maxConcurrent = 2;
  int maxConcurrentUploads = 2;
  int maxBatch = 50;
  int? accountQuotaBytes;
  int? accountUsedBytes;
  bool autoCheckLinks = true;

  int get knownTotalBytes => items.fold<int>(0, (sum, item) => sum + (item.sizeBytes ?? 0));
  int get knownCount => items.where((item) => item.sizeBytes != null).length;
  int get unknownCount => items.length - knownCount;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final savedToken = await _secure.read(key: 'boxera_upload_token') ?? '';
    if (!mounted) return;
    setState(() {
      apiBase = p.getString('apiBase') ?? apiBase;
      token = savedToken;
      maxConcurrent = p.getInt('maxConcurrent') ?? 2;
      maxConcurrentUploads = p.getInt('maxConcurrentUploads') ?? 2;
      maxBatch = p.getInt('maxBatch') ?? 50;
      autoCheckLinks = p.getBool('autoCheckLinks') ?? true;
      folders
        ..clear()
        ..addAll(p.getStringList('folders') ?? ['ریشه', 'فیلم‌ها', 'سریال‌ها', 'دوبله', 'زیرنویس']);
      for (final line in p.getStringList('history') ?? <String>[]) {
        try { items.add(UploadItem.fromJson(jsonDecode(line) as Map<String, dynamic>)); } catch (_) {}
      }
    });
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('apiBase', apiBase);
    if (token.isEmpty) {
      await _secure.delete(key: 'boxera_upload_token');
    } else {
      await _secure.write(key: 'boxera_upload_token', value: token);
    }
    await p.setInt('maxConcurrent', maxConcurrent);
    await p.setInt('maxConcurrentUploads', maxConcurrentUploads);
    await p.setInt('maxBatch', maxBatch);
    await p.setBool('autoCheckLinks', autoCheckLinks);
    await p.setStringList('folders', folders);
    await p.setStringList('history', items.map((e) => jsonEncode(e.toJson())).toList());
  }

  List<String> _parseLinks(String text) => text
    .split(RegExp(r'[\r\n]+'))
    .map((e) => e.trim())
    .where((e) => e.isNotEmpty)
    .toSet()
    .toList();

  bool _validUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null && (uri.scheme == 'https' || uri.scheme == 'http') && uri.host.isNotEmpty;
  }

  Future<void> _addLinks() async {
    final links = _parseLinks(linkController.text);
    final valid = links.where(_validUrl).toList();
    final invalid = links.length - valid.length;
    final existing = items.map((e) => e.url).toSet();
    final fresh = valid.where((e) => !existing.contains(e)).take(maxBatch).toList();
    setState(() {
      for (final url in fresh) { items.insert(0, UploadItem(url, folder: folder)); }
    });
    await _save();
    linkController.clear();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${fresh.length} لینک اضافه شد؛ ${invalid} نامعتبر و ${valid.length - fresh.length} تکراری/بیش از سقف دسته حذف شد.')));
    if (autoCheckLinks && fresh.isNotEmpty) _checkItems(fresh.map((url) => items.firstWhere((e) => e.url == url)).toList());
  }

  Future<void> _checkItems(List<UploadItem> selected) async {
    for (final item in selected) {
      if (!mounted) return;
      setState(() { item.checking = true; item.error = null; item.status = 'در حال بررسی لینک'; });
      try {
        final response = await http.head(Uri.parse(item.url), headers: {'User-Agent': 'FilmcaseUploader/1.0'}).timeout(const Duration(seconds: 20));
        final rawLength = response.headers['content-length'];
        final length = rawLength == null ? null : int.tryParse(rawLength);
        if (response.statusCode >= 200 && response.statusCode < 400) {
          setState(() {
            item.sizeBytes = length;
            item.contentType = response.headers['content-type'];
            item.status = length == null ? 'لینک بررسی شد؛ حجم نامشخص' : 'لینک بررسی شد';
          });
        } else {
          setState(() { item.status = 'بررسی ناموفق'; item.error = 'HTTP ${response.statusCode}'; });
        }
      } catch (e) {
        setState(() { item.status = 'نیازمند بررسی'; item.error = 'سرور مقصد درخواست HEAD را نپذیرفت یا لینک در دسترس نیست'; });
      } finally {
        if (mounted) setState(() => item.checking = false);
      }
      await _save();
    }
  }

  Future<void> _checkAll() async {
    if (checkingAll) return;
    setState(() => checkingAll = true);
    final pending = items.where((e) => e.sizeBytes == null && !e.checking).toList();
    for (var i = 0; i < pending.length; i += maxConcurrent) {
      final batch = pending.skip(i).take(maxConcurrent).toList();
      await Future.wait(batch.map((item) => _checkItems([item])));
    }
    if (mounted) setState(() => checkingAll = false);
  }

  void _newFolder() {
    folderController.clear();
    showDialog(context: context, builder: (_) => AlertDialog(
      title: const Text('ساخت پوشه جدید'),
      content: TextField(controller: folderController, autofocus: true, decoration: const InputDecoration(hintText: 'نام پوشه')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('انصراف')),
        FilledButton(onPressed: () {
          final name = folderController.text.trim();
          if (name.isNotEmpty && !folders.contains(name)) {
            setState(() { folders.add(name); folder = name; });
            _save();
          }
          Navigator.pop(context);
        }, child: const Text('ایجاد')),
      ],
    ));
  }

  Future<void> _validateConnection() async {
    if (token.trim().isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('ابتدا توکن Boxera را در تنظیمات وارد و ذخیره کن.')),
        );
      }
      return;
    }
    if (mounted) setState(() => connectionState = 'در حال بررسی توکن...');
    try {
      final base = apiBase.trim().replaceAll(RegExp(r'/+$'), '');
      final response = await http.get(
        Uri.parse('$base/auth/me'),
        headers: {
          'Accept': 'application/json',
          'Authorization': 'Bearer ' + token.trim(),
        },
      ).timeout(const Duration(seconds: 25));
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final decoded = jsonDecode(response.body);
        final root = decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
        final data = root['data'] is Map<String, dynamic>
            ? root['data'] as Map<String, dynamic>
            : root;
        final user = data['user'] is Map<String, dynamic>
            ? data['user'] as Map<String, dynamic>
            : <String, dynamic>{};
        final userId = user['id']?.toString();
        if (!mounted) return;
        setState(() => connectionState = userId == null
            ? 'توکن معتبر است؛ حساب متصل شد'
            : 'حساب Boxera متصل شد • شناسه ' + userId);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('اتصال Boxera با موفقیت تأیید شد.')),
        );
      } else {
        if (!mounted) return;
        setState(() => connectionState = 'اتصال ناموفق • HTTP ' + response.statusCode.toString());
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Boxera توکن را تأیید نکرد: HTTP ' + response.statusCode.toString())),
        );
      }
    } catch (error) {
      if (!mounted) return;
      final detail = error.toString();
      String message;
      if (detail.contains('SocketException') || detail.contains('Failed host lookup') ||
          detail.contains('No address associated with hostname')) {
        message = 'خطای DNS؛ دامنه Boxera از این دستگاه پیدا نشد.';
      } else if (detail.contains('HandshakeException') ||
          detail.contains('CERTIFICATE_VERIFY_FAILED') ||
          detail.contains('certificate')) {
        message = 'خطای گواهی امن SSL/TLS در ارتباط با Boxera.';
      } else if (detail.contains('TimeoutException') || detail.contains('timed out')) {
        message = 'مهلت اتصال به Boxera تمام شد؛ سرور پاسخ نداد.';
      } else if (detail.contains('FormatException')) {
        message = 'پاسخ Boxera JSON معتبر نیست؛ آدرس API یا پاسخ سرور را بررسی کن.';
      } else if (detail.contains('ClientException')) {
        message = 'ارتباط شبکه برقرار نشد؛ اینترنت، VPN یا دسترسی شبکه را بررسی کن.';
      } else {
        message = 'خطای ارتباط: ' + detail;
      }
      setState(() => connectionState = message);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 7)),
      );
    }
  }

  void _showSettings() {
    final api = TextEditingController(text: apiBase);
    final tok = TextEditingController(text: token);
    var localConcurrent = maxConcurrent;
    var localUploadConcurrent = maxConcurrentUploads;
    var localBatch = maxBatch;
    var localAutoCheck = autoCheckLinks;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: panel,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, refresh) => Padding(
          padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(ctx).viewInsets.bottom + 24),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('تنظیمات اتصال و صف', style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                TextField(controller: api, decoration: const InputDecoration(labelText: 'آدرس پایه Boxera')),
                const SizedBox(height: 12),
                TextField(
                  controller: tok,
                  obscureText: obscure,
                  decoration: InputDecoration(
                    labelText: 'توکن آپلود Boxera',
                    suffixIcon: IconButton(
                      icon: Icon(obscure ? Icons.visibility : Icons.visibility_off),
                      onPressed: () => refresh(() => obscure = !obscure),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Text('حداکثر بررسی لینک هم‌زمان: $localConcurrent'),
                Slider(value: localConcurrent.toDouble(), min: 1, max: 5, divisions: 4, onChanged: (v) => refresh(() => localConcurrent = v.round())),
                Text('حداکثر آپلود هم‌زمان: $localUploadConcurrent'),
                Slider(value: localUploadConcurrent.toDouble(), min: 1, max: 5, divisions: 4, onChanged: (v) => refresh(() => localUploadConcurrent = v.round())),
                Text('حداکثر لینک در هر دسته: $localBatch'),
                Slider(value: localBatch.toDouble(), min: 10, max: 200, divisions: 19, onChanged: (v) => refresh(() => localBatch = v.round())),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('بررسی خودکار لینک بعد از افزودن'),
                  value: localAutoCheck,
                  onChanged: (v) => refresh(() => localAutoCheck = v),
                ),
                const SizedBox(height: 8),
                const Text(
                  'توکن شخصی در فضای امن Android ذخیره می‌شود. اعتبار آن با مسیر واقعی /auth/me بررسی می‌شود. نگهداری توکن در موبایل برخلاف توصیه امنیتی Boxera برای ذخیره توکن فقط روی سرور است.',
                  style: TextStyle(color: Colors.white60, fontSize: 12),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () async {
                    setState(() {
                      apiBase = api.text.trim();
                      token = tok.text.trim();
                      maxConcurrent = localConcurrent;
                      maxConcurrentUploads = localUploadConcurrent;
                      maxBatch = localBatch;
                      autoCheckLinks = localAutoCheck;
                      connectionState = 'تنظیمات ذخیره شد؛ آماده بررسی اتصال';
                    });
                    await _save();
                    if (ctx.mounted) Navigator.pop(ctx);
                    await _validateConnection();
                  },
                  child: const Text('ذخیره و بررسی اتصال'),
                ),
                TextButton(
                  onPressed: () async {
                    setState(() {
                      token = '';
                      connectionState = 'توکن حذف شد';
                    });
                    await _save();
                    if (ctx.mounted) Navigator.pop(ctx);
                  },
                  child: const Text('حذف توکن ذخیره‌شده'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _moveItem(UploadItem item) async {
    var target = item.folder;
    final result = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('انتقال به پوشه'),
      content: DropdownButtonFormField<String>(value: target, items: folders.map((f) => DropdownMenuItem(value: f, child: Text(f))).toList(), onChanged: (v) => target = v ?? target),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('انصراف')), FilledButton(onPressed: () => Navigator.pop(ctx, target), child: const Text('انتقال'))],
    ));
    if (result != null) { setState(() => item.folder = result); await _save(); }
  }

  Future<void> _deleteItem(UploadItem item) async {
    setState(() => items.remove(item));
    await _save();
  }

  Future<void> _duplicateItem(UploadItem item) async {
    setState(() => items.insert(0, UploadItem(item.url, folder: item.folder)));
    await _save();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('یک نسخه از لینک به صف اضافه شد.')),
      );
    }
  }

  Future<void> _copyLink(UploadItem item) async {
    await Clipboard.setData(ClipboardData(text: item.url));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('لینک کپی شد.')));
  }

  Future<void> _pasteLinks() async {
    final data = await Clipboard.getData('text/plain');
    if (data?.text == null || data!.text!.trim().isEmpty) return;
    linkController.text = data.text!;
    if (mounted) setState(() => selectedNav = 1);
  }

  Future<void> _deleteFolder(String name) async {
    if (name == 'ریشه') return;
    final hasItems = items.any((e) => e.folder == name);
    if (hasItems) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('ابتدا فایل‌های این پوشه را به پوشه دیگری منتقل کن.')));
      return;
    }
    setState(() { folders.remove(name); if (folder == name) folder = 'ریشه'; });
    await _save();
  }

  Future<void> _clearHistory() async {
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('پاک کردن تاریخچه؟'),
      content: const Text('همه لینک‌های ثبت‌شده از فهرست محلی حذف می‌شوند. این کار فایل‌های Boxera را حذف نمی‌کند.'),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('پاک کردن'))],
    ));
    if (ok == true) { setState(items.clear); await _save(); }
  }

  Widget _stat(String title, String value, IconData icon) => Expanded(child: Container(
    padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: panel, borderRadius: BorderRadius.circular(16)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, color: orange), const SizedBox(height: 12),
      Text(value, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold)),
      Text(title, style: const TextStyle(color: Colors.white60, fontSize: 12)),
    ]),
  ));

  Widget _action(IconData icon, String title, VoidCallback onTap) => Card(color: panel, child: ListTile(leading: Icon(icon, color: orange), title: Text(title), trailing: const Icon(Icons.chevron_left), onTap: onTap));

  @override
  Widget build(BuildContext context) {
    final pages = [_dashboard(), _linksPage(), _historyPage(), ConnectionDiagnosticsPage(apiBase: apiBase, token: token)];
    return Directionality(textDirection: TextDirection.rtl, child: Scaffold(
      appBar: AppBar(
        title: const Row(children: [Icon(Icons.cloud_upload, color: orange), SizedBox(width: 9), Text('Filmcase Uploader', style: TextStyle(fontWeight: FontWeight.bold))]),
        actions: [IconButton(onPressed: _showSettings, icon: const Icon(Icons.settings_outlined)), const SizedBox(width: 6)],
      ),
      body: SafeArea(child: IndexedStack(index: selectedNav, children: pages)),
      bottomNavigationBar: NavigationBar(
        backgroundColor: panel, indicatorColor: orange.withOpacity(.18), selectedIndex: selectedNav,
        onDestinationSelected: (v) => setState(() => selectedNav = v),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard), label: 'خانه'),
          NavigationDestination(icon: Icon(Icons.link), label: 'لینک‌ها'),
          NavigationDestination(icon: Icon(Icons.history), label: 'صف و تاریخچه'),
          NavigationDestination(icon: Icon(Icons.network_check), label: 'عیب‌یابی'),
        ],
      ),
    ));
  }

  Widget _dashboard() => ListView(padding: const EdgeInsets.all(16), children: [
    Container(padding: const EdgeInsets.all(18), decoration: BoxDecoration(gradient: const LinearGradient(colors: [Color(0xFF392516), Color(0xFF1C1E22)]), borderRadius: BorderRadius.circular(20)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('مدیریت هوشمند آپلود', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
      const SizedBox(height: 6), Text(mode, style: const TextStyle(color: Colors.white70)),
      const SizedBox(height: 14), Row(children: [const Icon(Icons.circle, size: 9, color: orange), const SizedBox(width: 7), Expanded(child: Text(connectionState, style: const TextStyle(fontSize: 12, color: Colors.white70)))]),
    ])),
    const SizedBox(height: 16),
    Row(children: [_stat('لینک‌های ثبت‌شده', '${items.length}', Icons.link), const SizedBox(width: 10), _stat('حجم شناخته‌شده', bytesText(knownTotalBytes), Icons.data_usage)]),
    const SizedBox(height: 10),
    Row(children: [_stat('پوشه‌ها', '${folders.length}', Icons.folder), const SizedBox(width: 10), _stat('حجم نامشخص', '$unknownCount مورد', Icons.help_outline)]),
    const SizedBox(height: 10),
    Container(padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: panel, borderRadius: BorderRadius.circular(16)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('فضای حساب Boxera', style: TextStyle(fontWeight: FontWeight.bold)),
      const SizedBox(height: 8),
      const Text('تا زمان ارائه endpoint رسمی سهمیه، حجم مصرفی و ظرفیت باقی‌مانده از Boxera قابل دریافت نیست.', style: TextStyle(color: Colors.white60, fontSize: 12)),
    ])),
    const SizedBox(height: 18),
    const Text('دسترسی سریع', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
    const SizedBox(height: 10),
    _action(Icons.add_link, 'افزودن لینک تکی یا گروهی', () => setState(() => selectedNav = 1)),
    _action(Icons.content_paste, 'چسباندن لینک‌ها از کلیپ‌بورد', _pasteLinks),
    _action(Icons.playlist_add_check, 'بررسی حجم و سلامت لینک‌ها', _checkAll),
    _action(Icons.create_new_folder_outlined, 'ساخت پوشه', _newFolder),
    _action(Icons.settings_outlined, 'تنظیمات و توکن API', _showSettings),
    _action(Icons.network_check, 'عیب‌یابی اتصال Boxera', () => setState(() => selectedNav = 3)),
    const SizedBox(height: 12),
    Text('حجم شناخته‌شده لینک‌ها: ${bytesText(knownTotalBytes)} • حجم ${unknownCount} لینک هنوز مشخص نیست.', style: const TextStyle(color: Colors.white54, fontSize: 12)),
  ]);

  Widget _linksPage() => ListView(padding: const EdgeInsets.all(16), children: [
    const Text('افزودن از طریق لینک', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
    const SizedBox(height: 6),
    const Text('یک لینک یا چند لینک را کپی کن؛ هر لینک را در یک خط قرار بده. لینک‌های تکراری و نامعتبر حذف می‌شوند.', style: TextStyle(color: Colors.white60)),
    const SizedBox(height: 14),
    TextField(controller: linkController, minLines: 5, maxLines: 10, keyboardType: TextInputType.multiline, decoration: const InputDecoration(hintText: 'https://example.com/video.mp4\nhttps://example.com/film.mkv', alignLabelWithHint: true)),
    const SizedBox(height: 12),
    DropdownButtonFormField<String>(value: folder, decoration: const InputDecoration(labelText: 'پوشه مقصد'), items: folders.map((f) => DropdownMenuItem(value: f, child: Text(f))).toList(), onChanged: (v) => setState(() => folder = v ?? folder)),
    const SizedBox(height: 12),
    OutlinedButton.icon(onPressed: _newFolder, icon: const Icon(Icons.create_new_folder), label: const Text('ساخت پوشه جدید')),
    Wrap(spacing: 8, runSpacing: 8, children: folders.where((f) => f != 'ریشه').map((f) => InputChip(label: Text(f), onDeleted: () => _deleteFolder(f))).toList()),
    const SizedBox(height: 10),
    FilledButton.icon(onPressed: _addLinks, icon: const Icon(Icons.playlist_add), label: const Text('افزودن به صف')),
    const SizedBox(height: 10),
    OutlinedButton.icon(onPressed: checkingAll ? null : _checkAll, icon: checkingAll ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.fact_check), label: const Text('بررسی لینک‌ها و دریافت حجم')),
    const SizedBox(height: 14),
    Text('جمع حجم لینک‌های بررسی‌شده: ${bytesText(knownTotalBytes)}', style: const TextStyle(fontWeight: FontWeight.bold)),
    const SizedBox(height: 12),
    const Text('سرعت انتقال و زمان باقی‌مانده پس از اتصال به مسیر واقعی آپلود و دریافت رویدادهای پیشرفت قابل نمایش خواهد بود. در حال حاضر فقط بررسی لینک و اندازه فایل انجام می‌شود.\n\nاین بررسی با درخواست HTTP HEAD انجام می‌شود. بعضی سرورها این درخواست را نمی‌پذیرند یا حجم را اعلام نمی‌کنند؛ در این حالت حجم نامشخص می‌ماند. این مرحله هنوز فایل را به Boxera آپلود نمی‌کند.', style: TextStyle(color: Colors.amber, fontSize: 12)),
  ]);

  Widget _historyPage() => ListView(padding: const EdgeInsets.all(16), children: [
    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      const Text('صف و تاریخچه', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
      TextButton(onPressed: _clearHistory, child: const Text('پاک‌کردن فهرست')),
    ]),
    Row(children: [
      Expanded(child: Text('مجموع حجم شناخته‌شده: ${bytesText(knownTotalBytes)}', style: const TextStyle(color: Colors.white70))),
      TextButton.icon(onPressed: _checkAll, icon: const Icon(Icons.refresh, size: 18), label: const Text('بررسی مجدد')),
    ]),
    if (items.isEmpty) const Padding(padding: EdgeInsets.all(30), child: Center(child: Text('هنوز لینکی ثبت نشده است', style: TextStyle(color: Colors.white54)))),
    ...items.map((item) => Card(color: panel, child: ListTile(
      leading: CircleAvatar(backgroundColor: const Color(0xFF35291F), child: item.checking ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.video_file, color: orange)),
      title: Text(item.url, maxLines: 1, overflow: TextOverflow.ellipsis, textDirection: TextDirection.ltr),
      subtitle: Text('${item.folder} • ${item.status}\nحجم: ${bytesText(item.sizeBytes)}${item.error == null ? '' : ' • ${item.error}'}', style: const TextStyle(color: Colors.white60), maxLines: 3),
      isThreeLine: true,
      trailing: PopupMenuButton<String>(
        onSelected: (v) { if (v == 'move') _moveItem(item); if (v == 'delete') _deleteItem(item); if (v == 'check') _checkItems([item]); if (v == 'copy') _copyLink(item); if (v == 'duplicate') _duplicateItem(item); },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'check', child: Text('بررسی لینک')),
          PopupMenuItem(value: 'copy', child: Text('کپی لینک')),
          PopupMenuItem(value: 'duplicate', child: Text('افزودن نسخه در صف')),
          PopupMenuItem(value: 'move', child: Text('انتقال به پوشه')),
          PopupMenuItem(value: 'delete', child: Text('حذف از فهرست')),
        ],
      ),
    ))),
  ]);

  @override
  void dispose() { linkController.dispose(); folderController.dispose(); super.dispose(); }
}
