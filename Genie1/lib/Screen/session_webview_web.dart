import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:web/web.dart' as web;
import '../utils/api/session_auth.dart';
import '../utils/navigation/home_navigation.dart';
import '../utils/platform/embedded_page_uri.dart';
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
  Uri? _frameUri;
  int _generation = 0;
  String? _error;
  StreamSubscription<web.Event>? _load;
  Timer? _timeout;
  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    final generation = ++_generation;
    _timeout?.cancel();
    _load?.cancel();
    final uri = embeddedPageUri(
      widget.url,
      app: Uri.base,
      site: dotenv.env['SITE_URL'],
      proxyErpOrigin: dotenv.env['WEB_PROXY_ERP_ORIGIN'],
    );
    setState(() {
      _ready = false;
      _loading = true;
      _error = null;
      _frameUri = uri;
    });
    if (uri == null) {
      setState(() {
        _error = 'This link cannot be opened.';
        _loading = false;
      });
      return;
    }
    try {
      final user = await SessionAuthApi.getActiveSessionUser();
      if (!mounted || generation != _generation) return;
      if (user == null) {
        throw StateError('Your session has expired. Please sign in again.');
      }
      setState(() => _ready = true);
      _timeout = Timer(const Duration(seconds: 20), () {
        if (mounted && generation == _generation && _loading) {
          setState(() {
            _loading = false;
            _error =
                'This page did not finish loading. Retry, or ask your ERP administrator to check that the page allows embedding inside the web app.';
          });
        }
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = error.toString().replaceFirst('Bad state: ', '');
          _loading = false;
        });
      }
    }
  }

  @override
  void didUpdateWidget(covariant SessionWebView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) _initialize();
  }

  @override
  void dispose() {
    _generation++;
    _timeout?.cancel();
    _load?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final generation = _generation;
    final frameUri = _frameUri;
    final body = Stack(
      children: [
        if (_ready && _error == null)
          Positioned.fill(
            child: HtmlElementView.fromTagName(
              key: ValueKey(generation),
              tagName: 'iframe',
              onElementCreated: (element) {
                if (!mounted || generation != _generation) return;
                final frame = element as web.HTMLIFrameElement;
                frame.title = widget.title;
                frame.style.border = '0';
                frame.style.width = '100%';
                frame.style.height = '100%';
                frame.allow = 'camera; microphone; geolocation';
                frame.referrerPolicy = 'same-origin';
                _load = frame.onLoad.listen((_) {
                  if (!mounted || generation != _generation) return;
                  _timeout?.cancel();
                  String? error;
                  if (frameUri?.origin == Uri.base.origin) {
                    try {
                      if (frame.contentDocument == null) {
                        error =
                            'ERP did not allow this page inside the web app. Ask your ERP administrator to check its framing policy and redirects.';
                      }
                    } catch (_) {
                      error =
                          'The page redirected to another host and cannot be verified inside the web app.';
                    }
                  }
                  setState(() {
                    _loading = false;
                    _error = error;
                  });
                });
                frame.src = frameUri.toString();
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
                    onPressed: _initialize,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
        if (widget.embedded && !_loading && _error == null)
          Positioned(
            right: 8,
            bottom: 8,
            child: IconButton.filledTonal(
              tooltip: 'Reload page',
              onPressed: _initialize,
              icon: const Icon(Icons.refresh),
            ),
          ),
      ],
    );
    if (widget.embedded) {
      return PopScope(canPop: !widget.blockSystemBack, child: body);
    }
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
              tooltip: 'Reload page',
              onPressed: _initialize,
              icon: const Icon(Icons.refresh, color: Colors.white),
            ),
          ],
        ),
        body: body,
        bottomNavigationBar: HomeNavigation.navigationBar(context),
      ),
    );
  }
}
