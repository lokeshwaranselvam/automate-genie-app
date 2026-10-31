import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../utils/api/session_auth.dart';
import '../utils/theme/brand_theme.dart';
import '../utils/widget/ag_path_loading_indicator.dart';

bool isLeaveApplicationWebPageLocation(Uri page, String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
      uri.scheme == 'https' &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      uri.origin == page.origin &&
      uri.path.replaceFirst(RegExp(r'/$'), '') == page.path;
}

/// Leave-only WebView using the existing ERP session and leave API.
class LeaveApplicationWebViewPage extends StatefulWidget {
  const LeaveApplicationWebViewPage({
    super.key,
    required this.onBack,
    required this.onNotifications,
  });
  final VoidCallback onBack;
  final VoidCallback onNotifications;

  @override
  State<LeaveApplicationWebViewPage> createState() =>
      LeaveApplicationWebViewPageState();
}

class LeaveApplicationWebViewPageState
    extends State<LeaveApplicationWebViewPage> {
  WebViewController? _controller;
  Uri? _page;
  String? _user;
  String? _sid;
  String? _error;
  bool _loading = true;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  bool _isPage(String value) {
    return _page != null && isLeaveApplicationWebPageLocation(_page!, value);
  }

  Future<void> _assertSession() async {
    final user = await SessionAuthApi.getActiveSessionUser();
    final sid = await SessionAuthApi.getSessionId();
    if (user == null || user != _user || sid == null || sid != _sid) {
      throw StateError(
        'Your session changed. Sign in again and reopen Leave Application.',
      );
    }
  }

  void _fail(String message) {
    if (mounted) {
      setState(() {
        _error = message;
        _loading = false;
      });
    }
  }

  Future<void> _initialize() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final base = Uri.tryParse(dotenv.env['SITE_URL']?.trim() ?? '');
      if (base == null ||
          base.scheme != 'https' ||
          base.host.isEmpty ||
          base.userInfo.isNotEmpty) {
        throw StateError('The ERP site URL is not configured.');
      }
      _user = await SessionAuthApi.getActiveSessionUser();
      _sid = await SessionAuthApi.getSessionId();
      if (_user == null || _user == 'Guest' || _sid == null || _sid!.isEmpty) {
        throw StateError('Your session expired. Sign in again.');
      }
      _page = base.resolve('/genie-leave-application');
      final controller = WebViewController();
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.addJavaScriptChannel(
        'GenieLeaveApplication',
        onMessageReceived: (message) async {
          if (!mounted || !_isPage(await controller.currentUrl() ?? '')) return;
          try {
            final data = jsonDecode(message.message);
            if (data is! Map) return;
            switch (data['action']) {
              case 'busy':
                if (data['value'] is bool) {
                  setState(() => _submitting = data['value'] == true);
                }
                break;
              case 'close':
                if (!_submitting) widget.onBack();
                break;
              case 'notifications':
                if (!_submitting) {
                  await _assertSession();
                  if (mounted && !_submitting) widget.onNotifications();
                }
                break;
              case 'session_expired':
                _fail(
                  'Your ERP session expired or changed. Sign in again and reopen Leave Application.',
                );
                break;
            }
          } catch (_) {
            /* Ignore malformed messages from the page. */
          }
        },
      );
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest:
              (request) =>
                  _isPage(request.url)
                      ? NavigationDecision.navigate
                      : NavigationDecision.prevent,
          onPageStarted: (_) {
            if (mounted) setState(() => _loading = true);
          },
          onPageFinished: (url) async {
            if (!_isPage(url)) return;
            try {
              await _assertSession();
              final ready = await controller.runJavaScriptReturningResult(
                "document.getElementById('la-app')?.dataset.started === 'true'",
              );
              if (ready != true && ready.toString() != 'true') {
                throw StateError(
                  'Publish the genie-leave-application Web Page in ERP, then retry.',
                );
              }
              if (mounted) {
                setState(() {
                  _loading = false;
                  _error = null;
                });
              }
            } catch (error) {
              _fail(error.toString().replaceFirst('Bad state: ', ''));
            }
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == true) {
              _fail(
                'The Leave Application webpage could not be loaded. Check your connection and the ERP page deployment.',
              );
            }
          },
        ),
      );
      // Set only this ERP session cookie; leave other WebView cookies intact.
      await WebViewCookieManager().setCookie(
        WebViewCookie(name: 'sid', value: _sid!, domain: base.host, path: '/'),
      );
      await _assertSession();
      if (!mounted) return;
      setState(() => _controller = controller);
      await controller.loadRequest(_page!, headers: {'Cookie': 'sid=$_sid'});
    } catch (error) {
      _fail(error.toString().replaceFirst('Bad state: ', ''));
    }
  }

  Future<void> handleBack() async {
    if (!mounted || _submitting) return;
    if (_controller != null && _error == null && !_loading) {
      await _controller!.runJavaScript(
        "window.dispatchEvent(new Event('genie-leave-back'));",
      );
    } else {
      widget.onBack();
    }
  }

  @override
  Widget build(BuildContext context) {
    final page = AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
      child: Scaffold(
        backgroundColor: Colors.white,
        body: Stack(
          fit: StackFit.expand,
          children: [
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: MediaQuery.paddingOf(context).top,
              child: const DecoratedBox(
                decoration: BoxDecoration(gradient: BrandColors.gradient),
              ),
            ),
            SafeArea(
              child:
                  _error != null
                      ? Center(
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
                      )
                      : Stack(
                        children: [
                          if (_controller != null)
                            WebViewWidget(controller: _controller!),
                          if (_loading)
                            const Center(child: AgPathLoadingIndicator()),
                        ],
                      ),
            ),
          ],
        ),
      ),
    );
    // Home owns Back for this embedded form, matching the native leave page.
    return page;
  }
}
