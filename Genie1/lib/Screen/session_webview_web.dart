import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:web/web.dart' as web;
import '../utils/api/session_auth.dart';
import '../utils/theme/brand_theme.dart';
import '../utils/widget/ag_path_loading_indicator.dart';

class SessionWebView extends StatefulWidget {
  const SessionWebView({
    super.key,
    required this.url,
    required this.title,
    this.embedded = false,
    this.blockSystemBack = true,
  });
  final String url, title;
  final bool embedded, blockSystemBack;
  @override
  State<SessionWebView> createState() => _SessionWebViewState();
}

class _SessionWebViewState extends State<SessionWebView> {
  bool _ready = false, _loading = true;
  String? _error;
  StreamSubscription<web.Event>? _load;
  Timer? _timeout;
  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    final uri = Uri.tryParse(widget.url);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      setState(() {
        _error = 'This link cannot be opened.';
        _loading = false;
      });
      return;
    }
    try {
      if (await SessionAuthApi.getActiveSessionUser() == null)
        throw StateError('Your session has expired. Please sign in again.');
      if (!mounted) return;
      setState(() => _ready = true);
      _timeout = Timer(const Duration(seconds: 20), () {
        if (mounted && _loading)
          setState(() {
            _loading = false;
            _error =
                'This page could not be displayed here. Open it in your browser to continue.';
          });
      });
    } catch (error) {
      if (mounted)
        setState(() {
          _error = error.toString();
          _loading = false;
        });
    }
  }

  Future<void> _open() async {
    final uri = Uri.tryParse(widget.url);
    if (uri != null && uri.scheme == 'https')
      await launchUrl(uri, webOnlyWindowName: '_blank');
  }

  @override
  void dispose() {
    _timeout?.cancel();
    _load?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final body = Stack(
      children: [
        if (_ready && _error == null)
          Positioned.fill(
            child: HtmlElementView.fromTagName(
              tagName: 'iframe',
              onElementCreated: (element) {
                final frame = element as web.HTMLIFrameElement;
                frame.src = widget.url;
                frame.title = widget.title;
                frame.style.border = '0';
                frame.style.width = '100%';
                frame.style.height = '100%';
                frame.allow = 'camera; microphone; geolocation';
                frame.referrerPolicy = 'same-origin';
                _load = frame.onLoad.listen((_) {
                  _timeout?.cancel();
                  if (mounted) setState(() => _loading = false);
                });
              },
            ),
          ),
        if (_loading) const Center(child: AgPathLoadingIndicator()),
        if (_error != null)
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error!, textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _open,
                    child: const Text('Open page'),
                  ),
                ],
              ),
            ),
          ),
        if (widget.embedded && !_loading)
          Positioned(
            right: 8,
            bottom: 8,
            child: IconButton.filledTonal(
              tooltip: 'Open page in browser',
              onPressed: _open,
              icon: const Icon(Icons.open_in_new),
            ),
          ),
      ],
    );
    if (widget.embedded)
      return PopScope(canPop: !widget.blockSystemBack, child: body);
    return PopScope(
      canPop: false,
      child: Scaffold(
        appBar: brandAppBar(
          leading: IconButton(
            tooltip: 'Back',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
          ),
          title: Text(widget.title),
          actions: [
            IconButton(
              tooltip: 'Open page in browser',
              onPressed: _open,
              icon: const Icon(Icons.open_in_new, color: Colors.white),
            ),
          ],
        ),
        body: body,
      ),
    );
  }
}
