import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class RelayUploadPage extends StatefulWidget {
  const RelayUploadPage({super.key});

  @override
  State<RelayUploadPage> createState() => _RelayUploadPageState();
}

class _RelayUploadPageState extends State<RelayUploadPage> {
  late final WebViewController _controller;
  bool _loading = true;
  String? _error;

  static final Uri _url = Uri.parse('https://filmcase.ir/uploader.php');

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) => setState(() {
            _loading = true;
            _error = null;
          }),
          onPageFinished: (_) => setState(() => _loading = false),
          onWebResourceError: (error) {
            if (error.isForMainFrame ?? false) {
              setState(() {
                _loading = false;
                _error = 'بارگذاری صفحه ناموفق بود: ${error.description}';
              });
            }
          },
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            if (uri == null ||
                (uri.scheme != 'https' && uri.scheme != 'http') ||
                uri.host != 'filmcase.ir') {
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadRequest(_url);
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    await _controller.reload();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Material(
          color: const Color(0xFF1B1E23),
          child: Row(
            children: [
              const Expanded(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Text('انتقال از طریق سرور Filmcase'),
                ),
              ),
              IconButton(
                tooltip: 'بارگذاری مجدد',
                onPressed: _reload,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        if (_error != null)
          Expanded(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.cloud_off, size: 42, color: Colors.orange),
                    const SizedBox(height: 12),
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _reload,
                      icon: const Icon(Icons.refresh),
                      label: const Text('تلاش دوباره'),
                    ),
                  ],
                ),
              ),
            ),
          )
        else
          Expanded(child: WebViewWidget(controller: _controller)),
      ],
    );
  }
}
