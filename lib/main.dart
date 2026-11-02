import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'boxera_api.dart';
import 'connection_diagnostics_page.dart';
import 'import_service.dart';
import 'upload_manager.dart';

void main() => runApp(const FilmcaseUploaderApp());

const orange = Color(0xFFFF8A24);
const bg = Color(0xFF101114);
const panel = Color(0xFF1B1E23);

String bytesText(int? value) =>
    value == null ? 'نامشخص' : formatByteCount(value);

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
    'url': url,
    'folder': folder,
    'status': status,
    'sizeBytes': sizeBytes,
    'contentType': contentType,
    'error': error,
  };

  factory UploadItem.fromJson(Map<String, dynamic> json) {
    final item = UploadItem(
      json['url'] as String? ?? '',
      folder: json['folder'] as String? ?? 'ریشه',
    );
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
        filled: true,
        fillColor: panel,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
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
  late final VideoUploadManager uploads;
  final imports = ImportDelegate();
  String apiBase = 'https://boxera.ir/api';
  String token = '';
  String channelId = '43';
  String importBase = '';
  String importToken = '';
  String movieFolderId = '27576';
  String seriesFolderId = '27577';
  String? importHealthText;
  bool importHealthBusy = false;
  bool publicVideo = false;
  bool? canUpload;
  bool? idempotentInit;
  String? accountId;
  DateTime? verifiedAt;
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
  bool autoCheckLinks = true;

  int get knownTotalBytes =>
      items.fold<int>(0, (sum, item) => sum + (item.sizeBytes ?? 0));
  int get knownCount => items.where((item) => item.sizeBytes != null).length;
  int get unknownCount => items.length - knownCount;

  @override
  void initState() {
    super.initState();
    uploads = VideoUploadManager()..addListener(_onUploadsChanged);
    imports.addListener(_onUploadsChanged);
    _load();
  }

  void _onUploadsChanged() {
    if (mounted) setState(() {});
  }

  ImportService _importService() =>
      ImportService(baseUrl: importBase, token: importToken);

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final savedToken = await _secure.read(key: 'boxera_upload_token') ?? '';
    final savedImportToken =
        await _secure.read(key: 'import_server_token') ?? '';
    await uploads.load();
    if (!mounted) return;
    setState(() {
      apiBase = p.getString('apiBase') ?? apiBase;
      token = savedToken;
      connectionState = savedToken.isEmpty
          ? 'تنظیم نشده'
          : 'توکن ذخیره شده؛ اتصال در این اجرا بررسی نشده';
      channelId = p.getString('channelId') ?? '43';
      importBase = p.getString('importBase') ?? '';
      importToken = savedImportToken;
      movieFolderId = p.getString('movieFolderId') ?? '27576';
      seriesFolderId = p.getString('seriesFolderId') ?? '27577';
      publicVideo = p.getBool('publicVideo') ?? false;
      maxConcurrent = p.getInt('maxConcurrent') ?? 2;
      maxConcurrentUploads = p.getInt('maxConcurrentUploads') ?? 2;
      maxBatch = p.getInt('maxBatch') ?? 50;
      autoCheckLinks = p.getBool('autoCheckLinks') ?? true;
      folders
        ..clear()
        ..addAll(
          p.getStringList('folders') ??
              ['ریشه', 'فیلم‌ها', 'سریال‌ها', 'دوبله', 'زیرنویس'],
        );
      for (final line in p.getStringList('history') ?? <String>[]) {
        try {
          items.add(
            UploadItem.fromJson(jsonDecode(line) as Map<String, dynamic>),
          );
        } catch (_) {}
      }
    });
    await imports.load();
    imports.currentService = _importService();
  }

  Future<void> _save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('apiBase', apiBase);
    if (token.isEmpty) {
      await _secure.delete(key: 'boxera_upload_token');
    } else {
      await _secure.write(key: 'boxera_upload_token', value: token);
    }
    await p.setString('channelId', channelId);
    await p.setString('importBase', importBase);
    if (importToken.isEmpty) {
      await _secure.delete(key: 'import_server_token');
    } else {
      await _secure.write(key: 'import_server_token', value: importToken);
    }
    await p.setString('movieFolderId', movieFolderId);
    await p.setString('seriesFolderId', seriesFolderId);
    await p.setBool('publicVideo', publicVideo);
    await p.setInt('maxConcurrent', maxConcurrent);
    await p.setInt('maxConcurrentUploads', maxConcurrentUploads);
    await p.setInt('maxBatch', maxBatch);
    await p.setBool('autoCheckLinks', autoCheckLinks);
    await p.setStringList('folders', folders);
    await p.setStringList(
      'history',
      items.map((e) => jsonEncode(e.toJson())).toList(),
    );
  }

  List<String> _parseLinks(String text) => text
      .split(RegExp(r'[\r\n]+'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toSet()
      .toList();

  bool _validUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        (uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.host.isNotEmpty;
  }

  Future<void> _addLinks() async {
    final links = _parseLinks(linkController.text);
    final valid = links.where(_validUrl).toList();
    final invalid = links.length - valid.length;
    final existing = items.map((e) => e.url).toSet();
    final fresh = valid
        .where((e) => !existing.contains(e))
        .take(maxBatch)
        .toList();
    setState(() {
      for (final url in fresh) {
        items.insert(0, UploadItem(url, folder: folder));
      }
    });
    await _save();
    linkController.clear();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${fresh.length} لینک اضافه شد؛ ${invalid} نامعتبر و ${valid.length - fresh.length} تکراری/بیش از سقف دسته حذف شد.',
        ),
      ),
    );
    if (autoCheckLinks && fresh.isNotEmpty)
      _checkItems(
        fresh.map((url) => items.firstWhere((e) => e.url == url)).toList(),
      );
  }

  Future<void> _checkItems(List<UploadItem> selected) async {
    for (final item in selected) {
      if (!mounted) return;
      setState(() {
        item.checking = true;
        item.error = null;
        item.status = 'در حال بررسی لینک';
      });
      try {
        final response = await http
            .head(
              Uri.parse(item.url),
              headers: {'User-Agent': 'FilmcaseUploader'},
            )
            .timeout(const Duration(seconds: 20));
        final rawLength = response.headers['content-length'];
        final length = rawLength == null ? null : int.tryParse(rawLength);
        if (response.statusCode >= 200 && response.statusCode < 400) {
          setState(() {
            item.sizeBytes = length;
            item.contentType = response.headers['content-type'];
            item.status = length == null
                ? 'لینک بررسی شد؛ حجم نامشخص'
                : 'لینک بررسی شد';
          });
        } else {
          setState(() {
            item.status = 'بررسی ناموفق';
            item.error = 'HTTP ${response.statusCode}';
          });
        }
      } catch (e) {
        setState(() {
          item.status = 'نیازمند بررسی';
          item.error =
              'سرور مقصد درخواست HEAD را نپذیرفت یا لینک در دسترس نیست';
        });
      } finally {
        if (mounted) setState(() => item.checking = false);
      }
      await _save();
    }
  }

  Future<void> _checkAll() async {
    if (checkingAll) return;
    setState(() => checkingAll = true);
    final pending = items
        .where((e) => e.sizeBytes == null && !e.checking)
        .toList();
    for (var i = 0; i < pending.length; i += maxConcurrent) {
      final batch = pending.skip(i).take(maxConcurrent).toList();
      await Future.wait(batch.map((item) => _checkItems([item])));
    }
    if (mounted) setState(() => checkingAll = false);
  }

  void _newFolder() {
    folderController.clear();
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('ساخت دسته محلی جدید'),
        content: TextField(
          controller: folderController,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'نام دسته'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () {
              final name = folderController.text.trim();
              if (name.isNotEmpty && !folders.contains(name)) {
                setState(() {
                  folders.add(name);
                  folder = name;
                });
                _save();
              }
              Navigator.pop(context);
            },
            child: const Text('ایجاد'),
          ),
        ],
      ),
    );
  }

  BoxeraApi _api() => BoxeraApi(baseUrl: apiBase, token: token);

  Future<void> _validateConnection() async {
    if (token.trim().isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('ابتدا توکن Boxera را در تنظیمات وارد و ذخیره کن.'),
          ),
        );
      }
      return;
    }
    if (mounted) setState(() => connectionState = 'در حال بررسی توکن...');
    try {
      final info = await _api().authMe();
      if (!mounted) return;
      setState(() {
        canUpload = info.canUpload;
        accountId = info.userId;
        idempotentInit = info.idempotentInit;
        verifiedAt = DateTime.now();
        final parts = <String>[];
        if (info.userId != null) parts.add('شناسه ${info.userId}');
        if (info.canUpload == true) parts.add('مجوز آپلود فعال');
        if (info.canUpload == false) parts.add('مجوز آپلود غیرفعال');
        if (info.idempotentInit == true) parts.add('idempotency فعال');
        if (info.idempotentInit == false) parts.add('idempotency گزارش‌نشده');
        connectionState = parts.isEmpty
            ? 'حساب Boxera متصل شد'
            : 'متصل شد • ${parts.join(' • ')}';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('اتصال Boxera با موفقیت تأیید شد.')),
      );
    } on BoxeraException catch (error) {
      if (!mounted) return;
      setState(() {
        canUpload = null;
        accountId = null;
        idempotentInit = null;
        verifiedAt = null;
        connectionState = 'اتصال ناموفق • ${error.message}';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Boxera توکن را تأیید نکرد: ${error.message}')),
      );
    } catch (error) {
      if (!mounted) return;
      final detail = error.toString();
      String message;
      if (detail.contains('SocketException') ||
          detail.contains('Failed host lookup') ||
          detail.contains('No address associated with hostname')) {
        message = 'خطای DNS؛ دامنه Boxera از این دستگاه پیدا نشد.';
      } else if (detail.contains('HandshakeException') ||
          detail.contains('CERTIFICATE_VERIFY_FAILED') ||
          detail.contains('certificate')) {
        message = 'خطای گواهی امن SSL/TLS در ارتباط با Boxera.';
      } else if (detail.contains('TimeoutException') ||
          detail.contains('timed out')) {
        message = 'مهلت اتصال به Boxera تمام شد؛ سرور پاسخ نداد.';
      } else if (detail.contains('FormatException')) {
        message =
            'پاسخ Boxera JSON معتبر نیست؛ آدرس API یا پاسخ سرور را بررسی کن.';
      } else if (detail.contains('ClientException')) {
        message =
            'ارتباط شبکه برقرار نشد؛ اینترنت، VPN یا دسترسی شبکه را بررسی کن.';
      } else {
        message = 'خطای ارتباط: $detail';
      }
      setState(() {
        canUpload = null;
        accountId = null;
        idempotentInit = null;
        verifiedAt = null;
        connectionState = message;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 7)),
      );
    }
  }

  void _showSettings() {
    final api = TextEditingController(text: apiBase);
    final tok = TextEditingController(text: token);
    final chan = TextEditingController(text: channelId);
    final impApi = TextEditingController(text: importBase);
    final impTok = TextEditingController(text: importToken);
    final impMovie = TextEditingController(text: movieFolderId);
    final impSeries = TextEditingController(text: seriesFolderId);
    var localConcurrent = maxConcurrent;
    var localUploadConcurrent = maxConcurrentUploads;
    var localBatch = maxBatch;
    var localAutoCheck = autoCheckLinks;
    var localPublic = publicVideo;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: panel,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, refresh) => Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            20,
            20,
            MediaQuery.of(ctx).viewInsets.bottom + 24,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'تنظیمات اتصال و صف',
                  style: TextStyle(fontSize: 21, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: api,
                  decoration: const InputDecoration(
                    labelText: 'آدرس پایه Boxera',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: tok,
                  obscureText: obscure,
                  decoration: InputDecoration(
                    labelText: 'توکن آپلود Boxera',
                    suffixIcon: IconButton(
                      icon: Icon(
                        obscure ? Icons.visibility : Icons.visibility_off,
                      ),
                      onPressed: () => refresh(() => obscure = !obscure),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: chan,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'شناسه کانال Boxera (channel_id)',
                    hintText: 'پیش‌فرض ۴۳ برای کانال فیلم کیس',
                  ),
                ),
                const SizedBox(height: 14),
                Text('حداکثر بررسی لینک هم‌زمان: $localConcurrent'),
                Slider(
                  value: localConcurrent.toDouble(),
                  min: 1,
                  max: 5,
                  divisions: 4,
                  onChanged: (v) => refresh(() => localConcurrent = v.round()),
                ),
                Text('حداکثر آپلود ویدیو هم‌زمان: $localUploadConcurrent'),
                Slider(
                  value: localUploadConcurrent.toDouble(),
                  min: 1,
                  max: 5,
                  divisions: 4,
                  onChanged: (v) =>
                      refresh(() => localUploadConcurrent = v.round()),
                ),
                Text('حداکثر لینک در هر دسته: $localBatch'),
                Slider(
                  value: localBatch.toDouble(),
                  min: 10,
                  max: 200,
                  divisions: 19,
                  onChanged: (v) => refresh(() => localBatch = v.round()),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('بررسی خودکار لینک بعد از افزودن'),
                  value: localAutoCheck,
                  onChanged: (v) => refresh(() => localAutoCheck = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('انتشار عمومی ویدیوها'),
                  subtitle: const Text(
                    'پیش‌فرض: فهرست‌نشده (unlisted)؛ لینک M3U8 برای هر کسی که لینک را دارد پخش می‌شود.',
                  ),
                  value: localPublic,
                  onChanged: (v) => refresh(() => localPublic = v),
                ),
                const SizedBox(height: 14),
                const Text(
                  'سرور بارگذاری از لینک (اختیاری)',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: impApi,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'آدرس سرور import',
                    hintText: 'http://10.0.0.5:8787 یا https://import.example',
                    helperText:
                        'خالی بگذار تا لینک‌ها فقط از طریق گوشی منتقل شوند. با سرور، لینک را خودِ سرور می‌خواند و اینترنت و حافظهٔ گوشی اصلاً درگیر نمی‌شود.',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: impTok,
                  obscureText: obscure,
                  decoration: const InputDecoration(
                    labelText: 'توکن سرور import (IMPORT_TOKEN)',
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: impMovie,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'شناسهٔ فولدر فیلم',
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: impSeries,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'شناسهٔ فولدر سریال',
                        ),
                      ),
                    ),
                  ],
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
                      channelId = chan.text.trim();
                      importBase = impApi.text.trim();
                      importToken = impTok.text.trim();
                      movieFolderId = impMovie.text.trim();
                      seriesFolderId = impSeries.text.trim();
                      importHealthText = null;
                      publicVideo = localPublic;
                      maxConcurrent = localConcurrent;
                      maxConcurrentUploads = localUploadConcurrent;
                      maxBatch = localBatch;
                      autoCheckLinks = localAutoCheck;
                      canUpload = null;
                      accountId = null;
                      idempotentInit = null;
                      verifiedAt = null;
                      connectionState = 'تنظیمات ذخیره شد؛ آماده بررسی اتصال';
                    });
                    imports.currentService = _importService();
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
                      canUpload = null;
                      accountId = null;
                      idempotentInit = null;
                      verifiedAt = null;
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
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('انتقال به دسته محلی'),
        content: DropdownButtonFormField<String>(
          value: target,
          items: folders
              .map((f) => DropdownMenuItem(value: f, child: Text(f)))
              .toList(),
          onChanged: (v) => target = v ?? target,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, target),
            child: const Text('انتقال'),
          ),
        ],
      ),
    );
    if (result != null) {
      setState(() => item.folder = result);
      await _save();
    }
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
    if (mounted)
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('لینک کپی شد.')));
  }

  Future<void> _pasteLinks() async {
    final data = await Clipboard.getData('text/plain');
    if (data?.text == null || data!.text!.trim().isEmpty) return;
    linkController.text = data.text!;
    if (mounted) setState(() => selectedNav = 1);
  }

  void _uploadLinkQueue() {
    final added = uploads.addLinks(items.map((item) => item.url));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          added == 0
              ? 'لینک معتبر جدیدی در صف نبود (تکراری یا نامعتبر).'
              : '$added لینک برای انتقال تکه‌ای به Boxera اضافه شد؛ در تب آپلود صف را شروع کن.',
        ),
      ),
    );
    if (added > 0) setState(() => selectedNav = 2);
  }

  Future<void> _checkImportServer() async {
    final service = _importService();
    if (!service.isConfigured) {
      setState(
        () => importHealthText = 'آدرس سرور import در تنظیمات وارد نشده است.',
      );
      return;
    }
    setState(() {
      importHealthBusy = true;
      importHealthText = 'در حال درخواست /health از سرور...';
    });
    try {
      final health = await service.health();
      if (!mounted) return;
      setState(() {
        importHealthText =
            'سرور پاسخ داد • Boxera توکن روی سرور ${health.hasBoxeraToken ? 'تنظیم است' : 'تنظیم نیست'} • صف: ${health.running} در حال اجرا، ${health.pending} در انتظار';
      });
    } catch (error) {
      if (!mounted) return;
      setState(
        () => importHealthText = 'سرور پاسخ نداد: ${describeError(error)}',
      );
    } finally {
      if (mounted) setState(() => importHealthBusy = false);
    }
  }

  Future<void> _delegateToServer(
    List<String> urls, {
    required String kind,
    int? folderId,
    int? channelId,
  }) async {
    final service = _importService();
    if (!service.isConfigured) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'ابتدا آدرس سرور import را در تنظیمات وارد کن؛ بدون سرور، لینک فقط از طریق گوشی منتقل می‌شود.',
          ),
        ),
      );
      return;
    }
    if (urls.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('لینکی برای سپردن به سرور وجود ندارد.')),
      );
      return;
    }
    final pending = urls
        .where((url) => !(imports.forUrl(url)?.isSucceeded ?? false))
        .toList();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${pending.length} لینک به سرور سپرده می‌شود؛ نتیجه همین‌جا تازه می‌شود.',
        ),
      ),
    );
    await imports.delegate(
      service: service,
      urls: pending,
      kind: kind,
      folderId: folderId,
      channelId: channelId,
    );
  }

  Future<void> _delegateChooser(List<String> urls) async {
    if (!_importService().isConfigured) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'ابتدا آدرس سرور import را در تنظیمات وارد کن؛ بدون سرور، لینک فقط از طریق گوشی منتقل می‌شود.',
          ),
        ),
      );
      _showSettings();
      return;
    }
    var destination = 'movie';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, refresh) => AlertDialog(
          title: const Text('سپردن لینک‌ها به سرور'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'سرور لینک را خودش می‌خواند و به Boxera می‌فرستد؛ بایت‌های ویدیو روی گوشی ذخیره نمی‌شوند و از اینترنت گوشی عبور نمی‌کنند. فقط چند درخواست کوتاه برای ثبت و پرسیدن وضعیت با دادهٔ گوشی فرستاده می‌شود.',
                style: TextStyle(fontSize: 12, color: Colors.white70),
              ),
              const SizedBox(height: 10),
              RadioGroup<String>(
                groupValue: destination,
                onChanged: (v) => refresh(() => destination = v ?? destination),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    RadioListTile<String>(
                      value: 'movie',
                      title: Text(
                        'فایل در فولدر فیلم (folder_id $movieFolderId)',
                      ),
                    ),
                    RadioListTile<String>(
                      value: 'series',
                      title: Text(
                        'فایل در فولدر سریال (folder_id $seriesFolderId)',
                      ),
                    ),
                    RadioListTile<String>(
                      value: 'video',
                      title: Text('ویدیوی Boxera در کانال $channelId'),
                      subtitle: const Text(
                        'بعد از تبدیل، لینک M3U8 در همین فهرست نمایش داده می‌شود.',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('انصراف'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('سپردن'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    switch (destination) {
      case 'movie':
        await _delegateToServer(
          urls,
          kind: 'drive',
          folderId: int.tryParse(movieFolderId),
        );
      case 'series':
        await _delegateToServer(
          urls,
          kind: 'drive',
          folderId: int.tryParse(seriesFolderId),
        );
      default:
        await _delegateToServer(
          urls,
          kind: 'video',
          channelId: int.tryParse(channelId),
        );
    }
  }

  Widget _importTaskTile(ImportTask task) => Card(
    color: panel,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            task.url,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textDirection: TextDirection.ltr,
            style: const TextStyle(fontSize: 12, color: Colors.white70),
          ),
          const SizedBox(height: 6),
          Text(
            '${task.stateLabel} • ${task.kind == 'drive' ? 'فایل در فولدر ${task.folderId ?? '-'}' : 'ویدیوی Boxera'}',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
          ),
          if (task.detail.isNotEmpty)
            Text(
              task.detail,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          if (task.size > 0) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: task.progress.clamp(0, 1).toDouble(),
              minHeight: 5,
              color: orange,
              backgroundColor: const Color(0xFF2A2E34),
            ),
            const SizedBox(height: 4),
            Text(
              '${bytesText(task.uploadedBytes)} از ${bytesText(task.size)}'
              '${task.error == null ? '' : '\n${task.error}'}',
              style: TextStyle(
                color: task.error == null ? Colors.white54 : Colors.redAccent,
                fontSize: 12,
              ),
            ),
          ] else if (task.error != null)
            Text(
              task.error!,
              style: const TextStyle(color: Colors.redAccent, fontSize: 12),
            ),
          if (task.m3u8Url != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(Icons.play_circle_outline, color: orange, size: 18),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    task.m3u8Url!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textDirection: TextDirection.ltr,
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: task.m3u8Url!));
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('لینک M3U8 کپی شد.')),
                    );
                  },
                ),
              ],
            ),
          ],
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              onPressed: () => imports.forget(task),
              child: const Text('حذف از فهرست سرور'),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _importServerCard() => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: panel,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.dns_outlined, color: orange),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'بارگذاری با سرور (بدون اینترنت گوشی)',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              ),
            ),
            if (imports.currentService?.isConfigured ?? false)
              IconButton(
                icon: const Icon(Icons.refresh, size: 20),
                onPressed: imports.refreshing
                    ? null
                    : () => imports.refresh(_importService()),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          importBase.isEmpty
              ? 'آدرس سرور وارد نشده است. راهنمای اجرای سرور در README و فایل tools/boxera-link-importer.mjs آمده؛ بعد از اجرا آدرس و توکن آن را در تنظیمات وارد کن.'
              : 'سرور: $importBase',
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
        if (importHealthText != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              importHealthText!,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: importHealthBusy ? null : _checkImportServer,
              icon: const Icon(Icons.network_check, size: 18),
              label: const Text('تست سرور'),
            ),
            FilledButton.icon(
              onPressed: items.isEmpty
                  ? null
                  : () => _delegateChooser(items.map((e) => e.url).toList()),
              icon: const Icon(Icons.cloud_outlined, size: 18),
              label: const Text('سپردن لینک‌های فهرست به سرور'),
            ),
          ],
        ),
        ...imports.tasks.map(_importTaskTile),
      ],
    ),
  );

  Future<void> _deleteFolder(String name) async {
    if (name == 'ریشه') return;
    final hasItems = items.any((e) => e.folder == name);
    if (hasItems) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('ابتدا لینک‌های این دسته را به دسته دیگری منتقل کن.'),
        ),
      );
      return;
    }
    setState(() {
      folders.remove(name);
      if (folder == name) folder = 'ریشه';
    });
    await _save();
  }

  Future<void> _clearHistory() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('پاک کردن تاریخچه؟'),
        content: const Text(
          'همه لینک‌های ثبت‌شده از فهرست محلی حذف می‌شوند. این کار فایل‌های Boxera را حذف نمی‌کند.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('پاک کردن'),
          ),
        ],
      ),
    );
    if (ok == true) {
      setState(items.clear);
      await _save();
    }
  }

  String _clockText(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}/${two(time.month)}/${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }

  String _queueSpeedText() {
    final speed = uploads.queueSpeed;
    if (speed == null) return 'انتقال فعال نیست';
    return '${formatByteCount(speed.round())}/ث';
  }

  Widget _stat(String title, String value, IconData icon) => Expanded(
    child: Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: panel,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: orange),
          const SizedBox(height: 12),
          Text(
            value,
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold),
          ),
          Text(
            title,
            style: const TextStyle(color: Colors.white60, fontSize: 12),
          ),
        ],
      ),
    ),
  );

  Widget _action(IconData icon, String title, VoidCallback onTap) => Card(
    color: panel,
    child: ListTile(
      leading: Icon(icon, color: orange),
      title: Text(title),
      trailing: const Icon(Icons.chevron_left),
      onTap: onTap,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final pages = [
      _dashboard(),
      _linksPage(),
      _uploadPage(),
      _historyPage(),
      ConnectionDiagnosticsPage(apiBase: apiBase, token: token),
    ];
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Row(
            children: [
              Icon(Icons.cloud_upload, color: orange),
              SizedBox(width: 9),
              Text(
                'Filmcase Uploader',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          actions: [
            IconButton(
              onPressed: _showSettings,
              icon: const Icon(Icons.settings_outlined),
            ),
            const SizedBox(width: 6),
          ],
        ),
        body: SafeArea(
          child: IndexedStack(index: selectedNav, children: pages),
        ),
        bottomNavigationBar: NavigationBar(
          backgroundColor: panel,
          indicatorColor: orange.withOpacity(.18),
          selectedIndex: selectedNav,
          onDestinationSelected: (v) => setState(() => selectedNav = v),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.dashboard_outlined),
              selectedIcon: Icon(Icons.dashboard),
              label: 'خانه',
            ),
            NavigationDestination(icon: Icon(Icons.link), label: 'لینک‌ها'),
            NavigationDestination(
              icon: Icon(Icons.video_library_outlined),
              selectedIcon: Icon(Icons.video_library),
              label: 'آپلود',
            ),
            NavigationDestination(icon: Icon(Icons.history), label: 'تاریخچه'),
            NavigationDestination(
              icon: Icon(Icons.network_check),
              label: 'عیب‌یابی',
            ),
          ],
        ),
      ),
    );
  }

  Widget _dashboard() => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF392516), Color(0xFF1C1E22)],
          ),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'مدیریت هوشمند آپلود',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 6),
            Text(
              'سرور: $apiBase • کانال: $channelId',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                const Icon(Icons.circle, size: 9, color: orange),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    connectionState,
                    style: const TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      Row(
        children: [
          _stat('لینک‌های ثبت‌شده', '${items.length}', Icons.link),
          const SizedBox(width: 10),
          _stat('حجم شناخته‌شده', bytesText(knownTotalBytes), Icons.data_usage),
        ],
      ),
      const SizedBox(height: 10),
      Row(
        children: [
          _stat('دسته‌های محلی', '${folders.length}', Icons.folder),
          const SizedBox(width: 10),
          _stat('حجم نامشخص', '$unknownCount مورد', Icons.help_outline),
        ],
      ),
      const SizedBox(height: 10),
      Row(
        children: [
          _stat(
            'ویدیوهای در صف',
            '${uploads.jobs.length}',
            Icons.video_library_outlined,
          ),
          const SizedBox(width: 10),
          _stat(
            'آماده پخش',
            '${uploads.readyCount}',
            Icons.play_circle_outline,
          ),
        ],
      ),
      const SizedBox(height: 10),
      Row(
        children: [
          _stat('سرعت سنجیده‌شده صف', _queueSpeedText(), Icons.speed),
          const SizedBox(width: 10),
          _stat(
            'آپلودشده به Boxera',
            bytesText(uploads.movedBytes),
            Icons.import_export,
          ),
        ],
      ),
      const SizedBox(height: 10),
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: panel,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'حساب Boxera',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              verifiedAt == null
                  ? 'اتصال در این اجرا با مسیر واقعی /auth/me تأیید نشده است؛ توکن را در تنظیمات ذخیره کن و «ذخیره و بررسی اتصال» را بزن.'
                  : 'تأییدشده با /auth/me در ${_clockText(verifiedAt!)}\n'
                        'شناسه حساب: ${accountId ?? 'پاسخ سرور شناسه نداشت'}\n'
                        'مجوز آپلود: ${switch (canUpload) {
                          null => 'در پاسخ سرور نبود',
                          true => 'فعال',
                          false => 'غیرفعال',
                        }}\n'
                        'ارسال تکراری امن (idempotency): ${switch (idempotentInit) {
                          null => 'در پاسخ سرور نبود',
                          true => 'فعال',
                          false => 'غیرفعال',
                        }}',
              style: const TextStyle(color: Colors.white60, fontSize: 12),
            ),
            const SizedBox(height: 6),
            const Text(
              'سهمیه و سقف هر فایل را پنل Boxera تعیین می‌کند و در این پاسخ API گزارش نمی‌شود. عدد «آپلودشده به Boxera» و سرعت‌ها اندازه‌گیری واقعی همین دستگاه است، نه گزارش سرور.',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ],
        ),
      ),
      const SizedBox(height: 18),
      const Text(
        'دسترسی سریع',
        style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 10),
      _action(Icons.video_library_outlined, 'آپلود ویدیو از گوشی', _pickVideos),
      _action(Icons.link, 'آپلود ویدیو از لینک', _addLinkJobs),
      _action(
        Icons.cloud_queue,
        'صف آپلود و پردازش ویدیو',
        () => setState(() => selectedNav = 2),
      ),
      _action(
        Icons.add_link,
        'افزودن لینک تکی یا گروهی',
        () => setState(() => selectedNav = 1),
      ),
      _action(Icons.content_paste, 'چسباندن لینک‌ها از کلیپ‌بورد', _pasteLinks),
      _action(Icons.playlist_add_check, 'بررسی حجم و سلامت لینک‌ها', _checkAll),
      _action(Icons.create_new_folder_outlined, 'ساخت دسته محلی', _newFolder),
      _action(Icons.settings_outlined, 'تنظیمات و توکن API', _showSettings),
      _action(
        Icons.network_check,
        'عیب‌یابی اتصال Boxera',
        () => setState(() => selectedNav = 4),
      ),
      const SizedBox(height: 12),
      Text(
        'حجم شناخته‌شده لینک‌ها: ${bytesText(knownTotalBytes)} • حجم $unknownCount لینک هنوز مشخص نیست.',
        style: const TextStyle(color: Colors.white54, fontSize: 12),
      ),
    ],
  );

  Widget _linksPage() => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      const Text(
        'افزودن از طریق لینک',
        style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 6),
      const Text(
        'یک لینک یا چند لینک را کپی کن؛ هر لینک را در یک خط قرار بده. لینک‌های تکراری و نامعتبر حذف می‌شوند.',
        style: TextStyle(color: Colors.white60),
      ),
      const SizedBox(height: 14),
      TextField(
        controller: linkController,
        minLines: 5,
        maxLines: 10,
        keyboardType: TextInputType.multiline,
        decoration: const InputDecoration(
          hintText:
              'https://example.com/video.mp4\nhttps://example.com/film.mkv',
          alignLabelWithHint: true,
        ),
      ),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        value: folder,
        decoration: const InputDecoration(
          labelText: 'دسته محلی (فقط در این اپ)',
          helperText:
              'این دسته به Boxera فرستاده نمی‌شود؛ فقط برای سازمان‌دهی فهرست است.',
        ),
        items: folders
            .map((f) => DropdownMenuItem(value: f, child: Text(f)))
            .toList(),
        onChanged: (v) => setState(() => folder = v ?? folder),
      ),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        onPressed: _newFolder,
        icon: const Icon(Icons.create_new_folder),
        label: const Text('ساخت دسته محلی جدید'),
      ),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: folders
            .where((f) => f != 'ریشه')
            .map(
              (f) =>
                  InputChip(label: Text(f), onDeleted: () => _deleteFolder(f)),
            )
            .toList(),
      ),
      const SizedBox(height: 10),
      FilledButton.icon(
        onPressed: _addLinks,
        icon: const Icon(Icons.playlist_add),
        label: const Text('افزودن به صف'),
      ),
      const SizedBox(height: 10),
      OutlinedButton.icon(
        onPressed: items.isEmpty ? null : _uploadLinkQueue,
        icon: const Icon(Icons.cloud_upload_outlined),
        label: const Text('ارسال لینک‌های صف به آپلود Boxera'),
      ),
      const SizedBox(height: 10),
      OutlinedButton.icon(
        onPressed: checkingAll ? null : _checkAll,
        icon: checkingAll
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.fact_check),
        label: const Text('بررسی لینک‌ها و دریافت حجم'),
      ),
      const SizedBox(height: 14),
      Text(
        'جمع حجم لینک‌های بررسی‌شده: ${bytesText(knownTotalBytes)}',
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
      const SizedBox(height: 12),
      _importServerCard(),
      const SizedBox(height: 12),
      const Text(
        'این صفحه فقط لینک‌ها را با درخواست HTTP HEAD بررسی می‌کند و خودش فایل را آپلود نمی‌کند. برای آپلود واقعی، با دکمه «ارسال لینک‌های صف به آپلود Boxera» لینک‌ها را به صف انتقال بفرست و از تب «آپلود» شروع کن؛ لینکی که پشتیبانی Range داشته باشد تکه‌تکه مستقیم به Boxera می‌رود و روی گوشی ذخیره نمی‌شود.\n\nبعضی سرورها درخواست HEAD را نمی‌پذیرند یا حجم را اعلام نمی‌کنند؛ در این حالت حجم نامشخص می‌ماند. برای آپلود، لینک باید مستقیم به فایل ویدیویی برسد.',
        style: TextStyle(color: Colors.amber, fontSize: 12),
      ),
    ],
  );

  Widget _historyPage() => ListView(
    padding: const EdgeInsets.all(16),
    children: [
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text(
            'صف و تاریخچه',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          TextButton(
            onPressed: _clearHistory,
            child: const Text('پاک‌کردن فهرست'),
          ),
        ],
      ),
      Row(
        children: [
          Expanded(
            child: Text(
              'مجموع حجم شناخته‌شده: ${bytesText(knownTotalBytes)}',
              style: const TextStyle(color: Colors.white70),
            ),
          ),
          TextButton.icon(
            onPressed: _checkAll,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('بررسی مجدد'),
          ),
        ],
      ),
      if (items.isEmpty)
        const Padding(
          padding: EdgeInsets.all(30),
          child: Center(
            child: Text(
              'هنوز لینکی ثبت نشده است',
              style: TextStyle(color: Colors.white54),
            ),
          ),
        ),
      ...items.map(
        (item) => Card(
          color: panel,
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: const Color(0xFF35291F),
              child: item.checking
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.video_file, color: orange),
            ),
            title: Text(
              item.url,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textDirection: TextDirection.ltr,
            ),
            subtitle: Text(
              '${item.folder} • ${item.status}'
              '${imports.forUrl(item.url) == null ? '' : '\nسرور: ${imports.forUrl(item.url)!.stateLabel}'}\n'
              'حجم: ${bytesText(item.sizeBytes)}${item.error == null ? '' : ' • ${item.error}'}',
              style: const TextStyle(color: Colors.white60),
              maxLines: 4,
            ),
            isThreeLine: true,
            trailing: PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'move') _moveItem(item);
                if (v == 'delete') _deleteItem(item);
                if (v == 'check') _checkItems([item]);
                if (v == 'copy') _copyLink(item);
                if (v == 'duplicate') _duplicateItem(item);
                if (v == 'server') _delegateChooser([item.url]);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'check', child: Text('بررسی لینک')),
                PopupMenuItem(value: 'copy', child: Text('کپی لینک')),
                PopupMenuItem(
                  value: 'duplicate',
                  child: Text('افزودن نسخه در صف'),
                ),
                PopupMenuItem(
                  value: 'server',
                  child: Text('سپردن به سرور import'),
                ),
                PopupMenuItem(value: 'move', child: Text('انتقال به دسته')),
                PopupMenuItem(value: 'delete', child: Text('حذف از فهرست')),
              ],
            ),
          ),
        ),
      ),
    ],
  );

  Future<void> _pickVideos() async {
    try {
      final files = await FilePicker.pickFiles(type: FileType.video);
      if (files.isEmpty) return;
      final picked = <PickedVideo>[];
      for (final file in files) {
        final path = file.path;
        if (path == null || path.isEmpty) continue;
        final size = file.lengthSync() ?? await file.length() ?? 0;
        picked.add(PickedVideo(path: path, name: file.name, size: size));
      }
      final added = uploads.addVideos(picked);
      if (!mounted) return;
      setState(() => selectedNav = 2);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            added == 0
                ? 'ویدیوی جدیدی اضافه نشد (تکراری یا خالی).'
                : '$added ویدیو به صف آپلود اضافه شد.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('انتخاب ویدیو ناموفق بود: $error')),
      );
    }
  }

  Future<void> _addLinkJobs() async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('آپلود از لینک'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'اگر لینک از Range پشتیبانی کند، ویدیو تکه‌تکه مستقیم به Boxera فرستاده می‌شود و هیچ فایلی روی گوشی ذخیره نمی‌شود.',
              style: TextStyle(fontSize: 12, color: Colors.white70),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: controller,
              autofocus: true,
              minLines: 3,
              maxLines: 8,
              keyboardType: TextInputType.multiline,
              textDirection: TextDirection.ltr,
              decoration: const InputDecoration(
                hintText: 'https://example.com/movie.mp4\nهر لینک در یک خط',
                alignLabelWithHint: true,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('افزودن'),
          ),
        ],
      ),
    );
    if (value == null) return;
    final added = uploads.addLinks(value.split(RegExp(r'[\r\n]+')));
    if (!mounted) return;
    setState(() => selectedNav = 2);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          added == 0
              ? 'لینک معتبر جدیدی پیدا نشد (تکراری یا نامعتبر).'
              : '$added لینک برای انتقال به Boxera اضافه شد.',
        ),
      ),
    );
  }

  void _startUploads({VideoUploadJob? only}) {
    if (token.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('ابتدا توکن آپلود Boxera را در تنظیمات ذخیره کن.'),
        ),
      );
      return;
    }
    if (uploads.jobs.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('اول یک ویدیو یا لینک به صف اضافه کن.')),
      );
      return;
    }
    uploads.startAll(
      apiFactory: _api,
      concurrency: maxConcurrentUploads,
      channelId: channelId,
      publicVideo: publicVideo,
      targets: only == null ? null : [only],
    );
  }

  Future<void> _copyText(String value, String message) async {
    if (value.trim().isEmpty) return;
    await Clipboard.setData(ClipboardData(text: value.trim()));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _renameJob(VideoUploadJob job) async {
    final controller = TextEditingController(text: job.title);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('عنوان ویدیو'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'عنوان نمایشی در Boxera'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('انصراف'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('ذخیره'),
          ),
        ],
      ),
    );
    if (result != null) uploads.rename(job, result);
  }

  Future<void> _jobAction(VideoUploadJob job, String action) async {
    switch (action) {
      case 'start':
        _startUploads(only: job);
        break;
      case 'copy':
        await _copyText(job.shareUrl ?? '', 'لینک پخش M3U8 کپی شد.');
        break;
      case 'rename':
        await _renameJob(job);
        break;
      case 'stop':
        uploads.cancel(job);
        break;
      case 'delete':
        uploads.remove(job);
        break;
    }
  }

  IconData _jobIcon(VideoUploadJob job) {
    if (job.isReady) return Icons.play_circle_outline;
    if (job.state == VideoUploadJob.stateFailed) return Icons.error_outline;
    if (job.state == VideoUploadJob.stateProcessing) return Icons.hourglass_top;
    if (job.state == VideoUploadJob.stateDownloading)
      return Icons.download_outlined;
    if (job.state == VideoUploadJob.stateCancelled)
      return Icons.pause_circle_outline;
    if (job.isRunning) return Icons.cloud_upload_outlined;
    return Icons.schedule;
  }

  Color _jobColor(VideoUploadJob job) {
    if (job.isReady) return const Color(0xFF7ED8A0);
    if (job.state == VideoUploadJob.stateFailed) return const Color(0xFFFF8A80);
    return orange;
  }

  String _jobProgressText(VideoUploadJob job) {
    final rate = _rateText(job);
    if (job.state == VideoUploadJob.stateDownloading) {
      final percent = (job.progress * 100).round();
      final detail = job.detail ?? 'دانلود از لینک';
      return [
        job.size <= 0 ? detail : '$detail • $percent%',
        rate,
      ].where((e) => e.isNotEmpty).join(' • ');
    }
    if (job.state == VideoUploadJob.stateProcessing) {
      final percent = job.transcodePercent;
      return percent == null
          ? 'در حال پردازش ویدیو در Boxera...'
          : 'پردازش ویدیو: $percent%';
    }
    if (job.state == VideoUploadJob.stateUploading) {
      final base =
          '${bytesText(job.uploadedBytes)} از ${bytesText(job.size)} • ${(job.progress * 100).round()}%';
      return rate.isEmpty ? base : '$base • $rate';
    }
    if (job.state == VideoUploadJob.stateCompleting ||
        job.state == VideoUploadJob.stateRegistering) {
      return job.detail ?? 'نهایی‌سازی در Boxera';
    }
    return 'در انتظار پاسخ Boxera...';
  }

  String _rateText(VideoUploadJob job) {
    final speed = job.bytesPerSecond;
    if (speed == null) return '';
    final rate = 'سرعت ${formatByteCount(speed.round())}/ث';
    final eta = etaText(job.remainingSeconds);
    return eta.isEmpty ? rate : '$rate • باقی‌مانده $eta';
  }

  Widget _jobCard(VideoUploadJob job) {
    final running = job.isRunning;
    final link = job.shareUrl ?? '';
    return Card(
      color: panel,
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: const Color(0xFF35291F),
                  child: Icon(_jobIcon(job), color: _jobColor(job), size: 20),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        job.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${bytesText(job.size)} • ${job.stateLabel}${job.detail == null ? '' : ' • ${job.detail}'}',
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 12,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (job.isLink) ...[
                        const SizedBox(height: 2),
                        Text(
                          job.sourceUrl!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textDirection: TextDirection.ltr,
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  onSelected: (value) => _jobAction(job, value),
                  itemBuilder: (_) => [
                    if (!running && !job.isReady)
                      const PopupMenuItem(
                        value: 'start',
                        child: Text('شروع / ادامه'),
                      ),
                    if (link.isNotEmpty)
                      const PopupMenuItem(
                        value: 'copy',
                        child: Text('کپی لینک پخش'),
                      ),
                    const PopupMenuItem(
                      value: 'rename',
                      child: Text('تغییر عنوان'),
                    ),
                    if (running)
                      const PopupMenuItem(value: 'stop', child: Text('توقف')),
                    const PopupMenuItem(
                      value: 'delete',
                      child: Text('حذف از صف'),
                    ),
                  ],
                ),
              ],
            ),
            if (running || job.state == VideoUploadJob.stateProcessing) ...[
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value:
                      (job.state == VideoUploadJob.stateUploading ||
                              job.state == VideoUploadJob.stateDownloading) &&
                          job.size > 0
                      ? job.progress
                      : null,
                  minHeight: 6,
                  backgroundColor: Colors.white10,
                  color: orange,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _jobProgressText(job),
                style: const TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ],
            if (job.state == VideoUploadJob.stateFailed &&
                job.error != null) ...[
              const SizedBox(height: 8),
              Text(
                job.error!,
                style: const TextStyle(color: Color(0xFFFF8A80), fontSize: 12),
              ),
            ],
            if (job.isReady) ...[
              const SizedBox(height: 8),
              if (link.isNotEmpty)
                SelectableText(
                  link,
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(
                    color: Color(0xFF7ED8A0),
                    fontSize: 12,
                  ),
                )
              else
                Text(
                  job.detail ?? 'لینک عمومی M3U8 در دسترس نیست.',
                  style: const TextStyle(color: Colors.amber, fontSize: 12),
                ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                children: [
                  if (link.isNotEmpty)
                    TextButton.icon(
                      onPressed: () => _copyText(link, 'لینک پخش M3U8 کپی شد.'),
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('کپی M3U8'),
                    ),
                  if ((job.previewUrl ?? '').isNotEmpty)
                    TextButton.icon(
                      onPressed: () =>
                          _copyText(job.previewUrl!, 'لینک پیش‌نمایش کپی شد.'),
                      icon: const Icon(Icons.play_circle_outline, size: 16),
                      label: const Text('پیش‌نمایش موقت'),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _uploadPage() {
    final jobs = uploads.jobs;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'آپلود ویدیو از گوشی یا لینک',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 6),
        const Text(
          'ویدیو را انتخاب کن یا لینک مستقیم بده؛ در حالت لینک، فایل تکه‌تکه از لینک خوانده و همان‌طور به Boxera فرستاده می‌شود و روی گوشی ذخیره نمی‌شود. فقط اگر لینک پشتیبانی Range نداشته باشد، برنامه ناچار می‌شود فایل را در حافظهٔ موقت دانلود کند. بعد از انتقال، ویدیو ثبت و پردازش می‌شود و در پایان لینک M3U8 آماده است.',
          style: TextStyle(color: Colors.white60),
        ),
        const SizedBox(height: 12),
        if (token.trim().isEmpty)
          Container(
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF3A2A16),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Text(
              'برای آپلود، ابتدا توکن آپلود Boxera را از تنظیمات وارد کن.',
              style: TextStyle(color: Colors.amber, fontSize: 12),
            ),
          ),
        FilledButton.icon(
          onPressed: _pickVideos,
          icon: const Icon(Icons.video_library_outlined),
          label: const Text('انتخاب ویدیو از گوشی'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _addLinkJobs,
          icon: const Icon(Icons.link),
          label: const Text('افزودن لینک مستقیم'),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: jobs.isEmpty ? null : () => _startUploads(),
                icon: const Icon(Icons.cloud_upload_outlined),
                label: const Text('شروع / ادامه صف'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: uploads.hasRunning ? uploads.stopAll : null,
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('توقف همه'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          '${jobs.length} ویدیو در صف • ${uploads.activeCount} کار فعال • ${uploads.readyCount} آماده پخش • سرعت سنجیده‌شده: ${_queueSpeedText()}',
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
        const SizedBox(height: 8),
        if (jobs.isEmpty)
          const Padding(
            padding: EdgeInsets.all(30),
            child: Center(
              child: Text(
                'هنوز ویدیو یا لینکی اضافه نشده است.',
                style: TextStyle(color: Colors.white54),
              ),
            ),
          ),
        ...jobs.map(_jobCard),
        const SizedBox(height: 12),
        const Text(
          'این بخش با API رسمی آپلود Boxera کار می‌کند: شروع آپلود، انتقال S3 چندبخشی یا TUS، ثبت رایگان ویدیو و پیگیری پردازش. فقط لینک غیرخالی M3U8 را برای مخاطب ذخیره کن؛ preview_url مخصوص پیش‌نمایش مالک است و ممکن است منقضی شود.\n\nاگر برنامه بسته شود، آپلود نیمه‌کاره با همان file_id ادامه پیدا می‌کند؛ فایل انتخاب‌شده باید در حافظه موقت برنامه باقی بماند. کانال پیش‌فرض ۴۳ (فیلم کیس) است و از تنظیمات قابل تغییر است.\n\nدر حالت لینک، آدرس باید مستقیم به فایل ویدیویی (mp4، mkv و...) برسد، نه صفحه پخش یا فهرست m3u8. Boxera مسیری برای دریافت مستقیم لینک ندارد، پس بایت‌ها از گوشی تو عبور می‌کند؛ اما در حالت تکه‌ای (Range) هیچ فایلی روی گوشی ذخیره نمی‌شود و فقط یک بخش زیر ۸ مگابایت در حافظه می‌ماند. اگر لینک Range پشتیبانی نکند، فایل کامل در حافظهٔ موقت دانلود می‌شود و بعد از آماده‌شدن ویدیو حذف می‌گردد.',
          style: TextStyle(color: Colors.amber, fontSize: 12),
        ),
      ],
    );
  }

  @override
  void dispose() {
    uploads.removeListener(_onUploadsChanged);
    uploads.dispose();
    linkController.dispose();
    folderController.dispose();
    super.dispose();
  }
}
