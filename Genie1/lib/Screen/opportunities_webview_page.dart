import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../utils/api/session_auth.dart';
import '../utils/theme/brand_theme.dart';
import '../utils/widget/ag_path_loading_indicator.dart';
import 'lead_creation_page.dart';

Uri opportunitiesWebPageUri(Uri base, {String? opportunityId}) {
  final page = base.resolve('/genie-opportunities');
  final id = opportunityId?.trim() ?? '';
  return id.isEmpty
      ? page
      : page.replace(fragment: 'opportunity=${Uri.encodeComponent(id)}');
}

bool isOpportunitiesWebPageLocation(Uri page, String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
      uri.scheme == 'https' &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      uri.origin == page.origin &&
      uri.path.replaceFirst(RegExp(r'/$'), '') == page.path;
}

/// Opportunity-only WebView. The New Lead flow stays in Flutter.
class OpportunitiesWebViewPage extends StatefulWidget {
  const OpportunitiesWebViewPage({
    super.key,
    this.canCreateLead = false,
    this.onExit,
    this.initialOpportunityId,
  });
  final bool canCreateLead;
  final VoidCallback? onExit;
  final String? initialOpportunityId;

  @override
  State<OpportunitiesWebViewPage> createState() =>
      OpportunitiesWebViewPageState();
}

class OpportunitiesWebViewPageState extends State<OpportunitiesWebViewPage> {
  WebViewController? _controller;
  Uri? _page;
  String? _user;
  String? _sid;
  String? _error;
  bool _loading = true;
  bool _details = false;
  bool _creatingLead = false;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  bool _isPage(String value) {
    return _page != null && isOpportunitiesWebPageLocation(_page!, value);
  }

  Future<void> _assertSession() async {
    final user = await SessionAuthApi.getActiveSessionUser();
    final sid = await SessionAuthApi.getSessionId();
    if (user == null || user != _user || sid == null || sid != _sid) {
      throw StateError(
        'Your session changed. Sign in again and reopen Opportunities.',
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
      _page = opportunitiesWebPageUri(
        base,
        opportunityId: widget.initialOpportunityId,
      );
      final controller = WebViewController();
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.addJavaScriptChannel(
        'GenieOpportunities',
        onMessageReceived: (message) async {
          if (!mounted || !_isPage(await controller.currentUrl() ?? '')) return;
          try {
            final data = jsonDecode(message.message);
            if (data is! Map) return;
            switch (data['action']) {
              case 'route':
                if (mounted && data['detail'] is bool) {
                  setState(() => _details = data['detail'] == true);
                }
                break;
              case 'close':
                _exit();
                break;
              case 'session_expired':
                _fail(
                  'Your ERP session expired or changed. Sign in again and reopen Opportunities.',
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
                "document.getElementById('go-app')?.dataset.started === 'true'",
              );
              if (ready != true && ready.toString() != 'true') {
                throw StateError(
                  'Publish the genie-opportunities Web Page in ERP, then retry.',
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
                'The Opportunities webpage could not be loaded. Check your connection and the ERP page deployment.',
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

  Future<void> _newLead() async {
    if (_creatingLead || !widget.canCreateLead) return;
    _creatingLead = true;
    try {
      await _assertSession();
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(builder: (_) => const LeadCreationPage()),
      );
      await _assertSession();
      if (_controller != null) {
        await _controller!.runJavaScript(
          "window.dispatchEvent(new Event('genie-opportunities-refresh'));",
        );
      }
    } catch (error) {
      _fail(error.toString().replaceFirst('Bad state: ', ''));
    } finally {
      _creatingLead = false;
    }
  }

  void _exit() {
    if (!mounted) return;
    if (widget.onExit != null) {
      widget.onExit!();
    } else if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  Future<void> handleBack() async {
    if (_details && _controller != null) {
      await _controller!.runJavaScript(
        "document.getElementById('go-back')?.click();",
      );
    } else {
      _exit();
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
        backgroundColor: const Color(0xFFF3F7FC),
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
        floatingActionButton:
            widget.canCreateLead && !_details && !_loading && _error == null
                ? brandFloatingActionButton(
                  onPressed: _newLead,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('New Lead'),
                )
                : null,
      ),
    );
    // Home handles embedded-page Back so the event is not processed twice.
    if (widget.onExit != null) return page;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) handleBack();
      },
      child: page,
    );
  }
}
