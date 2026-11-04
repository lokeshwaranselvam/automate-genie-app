import '../utils/widget/webview_pull_to_refresh.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../utils/api/sales_summary_notification.dart';
import '../utils/api/session_auth.dart';
import '../utils/theme/brand_theme.dart';
import '../utils/widget/ag_path_loading_indicator.dart';

bool isSalesSummaryWebLocation(Uri page, String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      uri.origin == page.origin &&
      uri.path.replaceFirst(RegExp(r'/$'), '') == salesSummaryRoute;
}

/// Dedicated read-only summary; no arbitrary notification URLs are followed.
class SalesSummaryWebViewPage extends StatefulWidget {
  const SalesSummaryWebViewPage({super.key});
  @override
  State<SalesSummaryWebViewPage> createState() =>
      _SalesSummaryWebViewPageState();
}

class _SalesSummaryWebViewPageState extends State<SalesSummaryWebViewPage> {
  WebViewController? _controller;
  String? _user;
  String? _sid;
  Uri? _page;
  String? _error;
  bool _loading = true;
  int _generation = 0;
  int _document = 0;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  Future<void> _assertSession() async {
    if (await SessionAuthApi.getSavedSessionUser() != _user ||
        await SessionAuthApi.getSessionId() != _sid ||
        salesSummaryPageUri() != _page) {
      throw StateError('Your session changed. Reopen the sales summary.');
    }
  }

  void _fail(Object error, int generation) {
    if (!mounted || generation != _generation) return;
    setState(() {
      _error = error.toString().replaceFirst('Bad state: ', '');
      _loading = false;
    });
  }

  Future<void> _initialize() async {
    final generation = ++_generation;
    setState(() {
      _controller = null;
      _error = null;
      _loading = true;
    });
    try {
      _page = salesSummaryPageUri();
      if (_page == null) throw StateError('Configure a valid HTTPS ERP site.');
      _user = await SessionAuthApi.getActiveSessionUser();
      _sid = await SessionAuthApi.getSessionId();
      if (!mounted || generation != _generation) return;
      if (_user == null || _user == 'Guest' || _sid == null || _sid!.isEmpty) {
        throw StateError('Your session expired. Sign in again.');
      }
      final controller = WebViewController();
      _controller = controller;
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.setBackgroundColor(const Color(0xFFF4F7FB));
      await controller.addJavaScriptChannel(
        'GenieSalesSummary',
        onMessageReceived: (message) async {
          if (!mounted || generation != _generation) return;
          final document = _document;
          final url = await controller.currentUrl();
          if (!mounted ||
              generation != _generation ||
              !isSalesSummaryWebLocation(_page!, url ?? '')) {
            return;
          }
          if (message.message == 'session_expired') {
            _fail(
              'Your session expired or changed. Reopen the sales summary.',
              generation,
            );
          }
          if (message.message == 'verify_session') {
            try {
              await _assertSession();
              if (!mounted ||
                  generation != _generation ||
                  document != _document) {
                return;
              }
              await controller.runJavaScript(
                "window.dispatchEvent(new CustomEvent('genie-sales-summary-verified', {detail: {user: ${jsonEncode(_user)}, valid: true}}));",
              );
            } catch (error) {
              _fail(error, generation);
            }
          }
        },
      );
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest:
              (request) =>
                  mounted &&
                          generation == _generation &&
                          _error == null &&
                          isSalesSummaryWebLocation(_page!, request.url)
                      ? NavigationDecision.navigate
                      : NavigationDecision.prevent,
          onPageStarted: (_) {
            if (mounted && generation == _generation) {
              _document++;
              setState(() => _loading = true);
            }
          },
          onPageFinished: (url) async {
            final document = _document;
            if (!mounted ||
                generation != _generation ||
                !isSalesSummaryWebLocation(_page!, url)) {
              return;
            }
            try {
              await _assertSession();
              final ready = await controller.runJavaScriptReturningResult(
                "document.getElementById('ss-app')?.dataset.started === 'true'",
              );
              if (!mounted ||
                  generation != _generation ||
                  document != _document) {
                return;
              }
              if (ready != true && ready.toString() != 'true') {
                throw StateError(
                  'Publish the genie-sales-summary Web Page in ERP, then retry.',
                );
              }
              await controller.runJavaScript(
                "window.dispatchEvent(new CustomEvent('genie-sales-summary-session', {detail: {user: ${jsonEncode(_user)}}}));",
              );
              if (mounted &&
                  generation == _generation &&
                  document == _document) {
                setState(() => _loading = false);
              }
            } catch (error) {
              _fail(error, generation);
            }
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == true) {
              _fail(
                'Could not load the sales summary. Check your connection and ERP page deployment.',
                generation,
              );
            }
          },
        ),
      );
      await _assertSession();
      if (!mounted || generation != _generation) return;
      await WebViewCookieManager().setCookie(
        WebViewCookie(
          name: 'sid',
          value: _sid!,
          domain: _page!.host,
          path: '/',
        ),
      );
      await _assertSession();
      if (!mounted || generation != _generation) return;
      setState(() {});
      await controller.loadRequest(_page!, headers: {'Cookie': 'sid=$_sid'});
    } catch (error) {
      _fail(error, generation);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFFF4F7FB),
    appBar: brandAppBar(
      title: const Text('Sales summary', style: TextStyle(color: Colors.white)),
    ),
    body: WebViewPullToRefresh(
      controller: _error == null ? _controller : null,
      enabled: !_loading,
      onRefresh: _initialize,
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
                  if (_loading) const Center(child: AgPathLoadingIndicator()),
                ],
              ),
    ),
  );
}
