import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

void main() => runApp(const FilmcaseUploaderApp());

const orange = Color(0xFFFF8A24);
const bg = Color(0xFF101114);
const panel = Color(0xFF1B1E23);

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
      fontFamily: 'Roboto',
      inputDecorationTheme: InputDecorationTheme(
        filled: true, fillColor: panel,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      ),
    ),
    home: const HomePage(),
  );
}

class UploadItem {
  UploadItem(this.url, {this.folder = 'ریشه'});
  final String url;
  final String folder;
  String status = 'در انتظار اتصال API';
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _secure = FlutterSecureStorage();
  int tab = 0;
  String mode = 'مستقل با Boxera';
  String apiBase = 'https://boxera.ir/api';
  String token = '';
  String backend = '';
  String folder = 'ریشه';
  final folders = <String>['ریشه', 'فیلم‌ها', 'سریال‌ها', 'دوبله', 'زیرنویس'];
  final items = <UploadItem>[];
  final linkController = TextEditingController();
  final folderController = TextEditingController();
  bool obscure = true;
  bool busy = false;
  String connectionState = 'تنظیم نشده';
  int selectedNav = 0;

  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final savedToken = await _secure.read(key: 'boxera_upload_token') ?? '';
    if (!mounted) return;
    setState(() {
      mode = p.getString('mode') ?? mode;
      apiBase = p.getString('apiBase') ?? apiBase;
      token = savedToken;
      backend = p.getString('backend') ?? '';
      folders
        ..clear()
        ..addAll(p.getStringList('folders') ?? ['ریشه', 'فیلم‌ها', 'سریال‌ها', 'دوبله', 'زیرنویس']);
      final saved = p.getStringList('history') ?? [];
      for (final line in saved) {
        try { final m = jsonDecode(line) as Map<String, dynamic>; items.add(UploadItem(m['url'] ?? '', folder: m['folder'] ?? 'ریشه')); } catch (_) {}
      }
    });
  }
  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('mode', mode);
    await p.setString('apiBase', apiBase);
    if (token.isEmpty) { await _secure.delete(key: 'boxera_upload_token'); } else { await _secure.write(key: 'boxera_upload_token', value: token); }
    await p.setString('backend', backend);
    await p.setStringList('folders', folders);
    await p.setStringList('history', items.map((e) => jsonEncode({'url': e.url, 'folder': e.folder})).toList());
  }

  void _addLinks() {
    final links = linkController.text.split(RegExp(r'\s+')).map((e) => e.trim()).where((e) => e.isNotEmpty).toSet().toList();
    final valid = links.where((e) { final u = Uri.tryParse(e); return u != null && (u.scheme == 'https' || u.scheme == 'http') && u.host.isNotEmpty; }).toList();
    final invalid = links.length - valid.length;
    setState(() { for (final u in valid) { if (!items.any((x) => x.url == u)) items.insert(0, UploadItem(u, folder: folder)); } });
    _save();
    linkController.clear();
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${valid.length} لینک اضافه شد؛ ${invalid} لینک نامعتبر یا تکراری حذف شد.')));
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
          if (name.isNotEmpty && !folders.contains(name)) { setState(() { folders.add(name); folder = name; }); _save(); }
          Navigator.pop(context);
        }, child: const Text('ایجاد')),
      ],
    ));
  }

  void _showSettings() {
    final api = TextEditingController(text: apiBase);
    final tok = TextEditingController(text: token);
    final be = TextEditingController(text: backend);
    showModalBottomSheet(context: context, isScrollControlled: true, backgroundColor: panel, builder: (ctx) => StatefulBuilder(builder: (ctx, refresh) => Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(ctx).viewInsets.bottom + 24),
      child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        const Text('تنظیمات اتصال', style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(value: mode, decoration: const InputDecoration(labelText: 'روش اتصال'), items: const [
          DropdownMenuItem(value: 'مستقل با Boxera', child: Text('مستقل با Boxera')),
          DropdownMenuItem(value: 'از طریق بک‌اند Filmcase', child: Text('از طریق بک‌اند Filmcase')),
        ], onChanged: (v) => refresh(() => mode = v ?? mode)),
        const SizedBox(height: 12),
        TextField(controller: api, decoration: const InputDecoration(labelText: 'آدرس پایه Boxera')),
        const SizedBox(height: 12),
        TextField(controller: tok, obscureText: obscure, decoration: InputDecoration(labelText: 'توکن آپلود Boxera', suffixIcon: IconButton(icon: Icon(obscure ? Icons.visibility : Icons.visibility_off), onPressed: () => refresh(() => obscure = !obscure)))),
        const SizedBox(height: 12),
        TextField(controller: be, decoration: const InputDecoration(labelText: 'آدرس بک‌اند Filmcase')),
        const SizedBox(height: 8),
        const Text('توکن فقط در حالت مستقل استفاده می‌شود. در حالت Filmcase باید توکن روی سرور بماند. این نسخه فعلاً توکن را در فضای محلی برنامه نگه می‌دارد؛ برای انتشار باید secure storage جایگزین شود.', style: TextStyle(color: Colors.white60, fontSize: 12)),
        const SizedBox(height: 16),
        FilledButton(onPressed: () async {
          setState(() { apiBase = api.text.trim(); token = tok.text; backend = be.text.trim(); connectionState = 'تنظیمات ذخیره شد؛ API هنوز اعتبارسنجی نشده'; });
          await _save(); if (ctx.mounted) Navigator.pop(ctx);
        }, child: const Text('ذخیره تنظیمات')),
      ])),
    )));
  }

  Widget _stat(String title, String value, IconData icon) => Expanded(child: Container(
    padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: panel, borderRadius: BorderRadius.circular(16)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, color: orange), const SizedBox(height: 12),
      Text(value, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.bold)),
      Text(title, style: const TextStyle(color: Colors.white60, fontSize: 12)),
    ]),
  ));

  @override
  Widget build(BuildContext context) {
    final pages = [_dashboard(), _linksPage(), _historyPage()];
    return Directionality(textDirection: TextDirection.rtl, child: Scaffold(
      appBar: AppBar(
        title: const Row(children: [Icon(Icons.cloud_upload, color: orange), SizedBox(width: 9), Text('Filmcase Uploader', style: TextStyle(fontWeight: FontWeight.bold))]),
        actions: [IconButton(onPressed: _showSettings, icon: const Icon(Icons.settings_outlined)), const SizedBox(width: 6)],
      ),
      body: SafeArea(child: IndexedStack(index: selectedNav, children: pages)),
      floatingActionButton: selectedNav == 1 ? FloatingActionButton.extended(onPressed: _addLinks, backgroundColor: orange, foregroundColor: Colors.black, icon: const Icon(Icons.playlist_add), label: const Text('افزودن لینک‌ها')) : null,
      bottomNavigationBar: NavigationBar(
        backgroundColor: panel, indicatorColor: orange.withOpacity(.18), selectedIndex: selectedNav,
        onDestinationSelected: (v) => setState(() => selectedNav = v),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.dashboard_outlined), selectedIcon: Icon(Icons.dashboard), label: 'خانه'),
          NavigationDestination(icon: Icon(Icons.link), label: 'لینک‌ها'),
          NavigationDestination(icon: Icon(Icons.history), label: 'تاریخچه'),
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
    Row(children: [_stat('لینک‌های ثبت‌شده', '${items.length}', Icons.link), const SizedBox(width: 10), _stat('در صف', '${items.length}', Icons.pending_actions)]),
    const SizedBox(height: 10),
    Row(children: [_stat('پوشه‌ها', '${folders.length}', Icons.folder), const SizedBox(width: 10), _stat('فضای مصرفی', 'نامشخص', Icons.storage)]),
    const SizedBox(height: 18),
    const Text('دسترسی سریع', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
    const SizedBox(height: 10),
    _action(Icons.add_link, 'افزودن لینک تکی یا گروهی', () => setState(() => selectedNav = 1)),
    _action(Icons.create_new_folder_outlined, 'ساخت پوشه', _newFolder),
    _action(Icons.settings_outlined, 'تنظیمات و توکن API', _showSettings),
    const SizedBox(height: 14),
    const Text('اطلاعات فضای Boxera فقط پس از اتصال به endpoint رسمی سهمیه قابل نمایش است.', style: TextStyle(color: Colors.white54, fontSize: 12)),
  ]);

  Widget _action(IconData icon, String title, VoidCallback onTap) => Card(color: panel, child: ListTile(leading: Icon(icon, color: orange), title: Text(title), trailing: const Icon(Icons.chevron_left), onTap: onTap));

  Widget _linksPage() => ListView(padding: const EdgeInsets.all(16), children: [
    const Text('افزودن از طریق لینک', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
    const SizedBox(height: 6),
    const Text('یک لینک یا چند لینک را وارد کن؛ هر لینک در یک خط. لینک‌های تکراری حذف می‌شوند.', style: TextStyle(color: Colors.white60)),
    const SizedBox(height: 14),
    TextField(controller: linkController, minLines: 5, maxLines: 10, keyboardType: TextInputType.multiline, decoration: const InputDecoration(hintText: 'https://example.com/video.mp4\nhttps://example.com/film.mkv', alignLabelWithHint: true)),
    const SizedBox(height: 12),
    DropdownButtonFormField<String>(value: folder, decoration: const InputDecoration(labelText: 'پوشه مقصد'), items: folders.map((f) => DropdownMenuItem(value: f, child: Text(f))).toList(), onChanged: (v) => setState(() => folder = v ?? folder)),
    const SizedBox(height: 12),
    OutlinedButton.icon(onPressed: _newFolder, icon: const Icon(Icons.create_new_folder), label: const Text('ساخت پوشه جدید')),
    const SizedBox(height: 10),
    FilledButton.icon(onPressed: _addLinks, icon: const Icon(Icons.playlist_add), label: const Text('افزودن به صف')),
    const SizedBox(height: 18),
    const Text('نکته: افزودن لینک به صف به معنی شروع آپلود نیست. دریافت فایل از URL و ارسال آن به Boxera پس از تکمیل مستندات رسمی API فعال می‌شود.', style: TextStyle(color: Colors.amber, fontSize: 12)),
  ]);

  Widget _historyPage() => ListView(padding: const EdgeInsets.all(16), children: [
    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      const Text('صف و تاریخچه', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
      TextButton(onPressed: () => setState(() { items.clear(); _save(); }), child: const Text('پاک‌کردن')),
    ]),
    if (items.isEmpty) const Padding(padding: EdgeInsets.all(30), child: Center(child: Text('هنوز لینکی ثبت نشده است', style: TextStyle(color: Colors.white54)))),
    ...items.map((item) => Card(color: panel, child: ListTile(
      leading: const CircleAvatar(backgroundColor: Color(0xFF35291F), child: Icon(Icons.video_file, color: orange)),
      title: Text(item.url, maxLines: 1, overflow: TextOverflow.ellipsis, textDirection: TextDirection.ltr),
      subtitle: Text('${item.folder} • ${item.status}', style: const TextStyle(color: Colors.white60)),
      trailing: const Icon(Icons.more_vert),
    ))),
  ]);

  @override
  void dispose() { linkController.dispose(); folderController.dispose(); super.dispose(); }
}
