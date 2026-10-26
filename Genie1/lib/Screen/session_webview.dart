import '../utils/widget/ag_path_loading_indicator.dart';
import 'package:homegenie/utils/theme/brand_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../utils/api/session_auth.dart';
import '../utils/connection_notice.dart';
import '../utils/canteen_payment_webview.dart';
import '../utils/widget/warning.dart';

class SessionWebView extends StatefulWidget {
  final String url;
  final String title;
  final bool embedded;
  final bool blockSystemBack;

  const SessionWebView({
    super.key,
    required this.url,
    required this.title,
    this.embedded = false,
    this.blockSystemBack = true,
  });

  @override
  State<SessionWebView> createState() => _SessionWebViewState();
}

class _SessionWebViewState extends State<SessionWebView> {
  WebViewController? _controller;
  bool _isLoading = true;
  String? _error;
  bool _openingPaymentApp = false;

  @override
  void initState() {
    super.initState();
    _initializeWebView();
  }

  Future<void> _initializeWebView() async {
    final uri = Uri.tryParse(widget.url);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      _showError('This link cannot be opened.');
      return;
    }

    try {
      final activeUser = await SessionAuthApi.getActiveSessionUser();
      final sid = await SessionAuthApi.getSessionId();
      if (activeUser == null || sid == null || sid.isEmpty) {
        _showError('Your session has expired. Please sign in again.');
        return;
      }

      final siteUrl = dotenv.env['SITE_URL']?.trim() ?? '';
      final siteHost = Uri.tryParse(siteUrl)?.host;
      final isSameSite = siteHost != null && uri.host == siteHost;

      final canteenPayments = isCanteenPaymentPage(uri);
      late final WebViewController controller;
      controller =
          WebViewController()
            ..setJavaScriptMode(JavaScriptMode.unrestricted)
            ..setNavigationDelegate(
              NavigationDelegate(
                onNavigationRequest: (request) async {
                  final navigationUri = Uri.tryParse(request.url);
                  if (navigationUri == null ||
                      navigationUri.scheme != 'https') {
                    if (canteenPayments) {
                      final paymentUri = canteenUpiUri(request.url);
                      if (paymentUri != null) {
                        await _openPaymentApp(paymentUri);
                      }
                    }
                    return NavigationDecision.prevent;
                  }
                  return NavigationDecision.navigate;
                },
                onPageStarted: (_) {
                  if (mounted) {
                    setState(() {
                      _isLoading = true;
                      _error = null;
                    });
                  }
                },
                onPageFinished: (url) async {
                  if (canteenPayments &&
                      isCanteenPaymentPage(Uri.tryParse(url) ?? Uri())) {
                    try {
                      await controller.runJavaScript(
                        canteenRazorpaySupportScript,
                      );
                    } catch (_) {
                      _paymentNotice(
                        'UPI could not be enabled. Please reopen Canteen.',
                      );
                    }
                  }
                  if (mounted) setState(() => _isLoading = false);
                },
                onWebResourceError: (error) {
                  if (error.isForMainFrame == true && mounted) {
                    _showError(
                      'This page could not be loaded (${error.errorCode}: '
                      '${error.description}).',
                    );
                  }
                },
              ),
            );

      final headers = <String, String>{};
      if (isSameSite) {
        final cookieManager = WebViewCookieManager();
        await cookieManager.clearCookies();
        await cookieManager.setCookie(
          WebViewCookie(name: 'sid', value: sid, domain: siteHost, path: '/'),
        );
        headers['Cookie'] = 'sid=$sid';
      }

      await controller.loadRequest(uri, headers: headers);
      if (!mounted) return;
      setState(() => _controller = controller);
    } catch (error) {
      _showError('Unable to open this page. $error');
    }
  }

  Future<void> _openPaymentApp(Uri uri) async {
    if (_openingPaymentApp) return;
    _openingPaymentApp = true;
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened) {
        _paymentNotice('No compatible UPI app could be opened.');
      }
    } catch (_) {
      _paymentNotice(
        'Unable to open the UPI app. Please check it is installed.',
      );
    } finally {
      _openingPaymentApp = false;
    }
    // Returning from a UPI app is not proof of payment. The Canteen page keeps
    // responsibility for its existing server verification and booking flow.
  }

  void _paymentNotice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _showError(String message) {
    if (!mounted) return;
    final connection = ConnectionNotice.fromError(message);
    final showPopup = connection != null && _error != connection.message;
    setState(() {
      _error = connection?.message ?? message;
      _isLoading = false;
    });
    if (showPopup) Warning.show(context, message, 'Error');
  }

  @override
  Widget build(BuildContext context) {
    final body =
        _error != null
            ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_error!, textAlign: TextAlign.center),
              ),
            )
            : Stack(
              children: [
                if (_controller != null)
                  WebViewWidget(controller: _controller!),
                if (_isLoading) const Center(child: AgPathLoadingIndicator()),
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
        ),
        body: body,
      ),
    );
  }
}
