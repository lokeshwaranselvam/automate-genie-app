import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../utils/api/session_auth.dart';
import '../utils/theme/brand_theme.dart';
import '../utils/widget/ag_path_loading_indicator.dart';

bool isExpenseClaimWebPageLocation(Uri page, String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
      uri.scheme == 'https' &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      uri.origin == page.origin &&
      uri.path.replaceFirst(RegExp(r'/$'), '') == page.path;
}

class _ExpenseSessionException implements Exception {
  const _ExpenseSessionException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Expense-only WebView. The webpage uses the existing Expense Claim API.
class ExpenseClaimWebViewPage extends StatefulWidget {
  const ExpenseClaimWebViewPage({super.key});

  @override
  State<ExpenseClaimWebViewPage> createState() =>
      _ExpenseClaimWebViewPageState();
}

class _ExpenseClaimWebViewPageState extends State<ExpenseClaimWebViewPage> {
  final _picker = ImagePicker();
  WebViewController? _controller;
  Uri? _page;
  String? _user;
  String? _sid;
  String? _error;
  int _generation = 0;
  int _document = 0;
  int? _bindingDocument;
  int? _boundDocument;
  bool _initializing = false;
  bool _loading = true;
  bool _pageReady = false;
  bool _pageFailed = false;
  bool _submitting = false;
  bool _choosingPhoto = false;
  bool _dispatchingBack = false;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  @override
  void dispose() {
    // Pending session checks, picker results and old controllers are ignored.
    _generation++;
    _controller = null;
    super.dispose();
  }

  bool _isCurrent(int generation, [WebViewController? controller]) =>
      mounted &&
      !_closing &&
      generation == _generation &&
      (controller == null || identical(controller, _controller));

  bool _isPage(String value) =>
      _page != null && isExpenseClaimWebPageLocation(_page!, value);

  bool _isCurrentDocument(
    int generation,
    WebViewController controller,
    int document,
  ) =>
      _isCurrent(generation, controller) &&
      document == _document &&
      !_pageFailed;

  Future<void> _assertSession(int generation) async {
    final expectedUser = _user;
    final expectedSid = _sid;
    final expectedPage = _page;
    final user = await SessionAuthApi.getActiveSessionUser();
    final sid = await SessionAuthApi.getSessionId();
    if (!_isCurrent(generation)) return;
    final base = Uri.tryParse(dotenv.env['SITE_URL']?.trim() ?? '');
    if (expectedUser == null ||
        expectedSid == null ||
        expectedPage == null ||
        user == null ||
        user == 'Guest' ||
        user != expectedUser ||
        sid == null ||
        sid.isEmpty ||
        sid != expectedSid ||
        base == null ||
        base.scheme != 'https' ||
        base.host.isEmpty ||
        base.userInfo.isNotEmpty ||
        base.origin != expectedPage.origin) {
      throw const _ExpenseSessionException(
        'Your ERP session or site changed. Sign in again and reopen Expense Claim.',
      );
    }
  }

  String _message(Object error) =>
      error.toString().replaceFirst(RegExp(r'^(Bad state|StateError):\s*'), '');

  void _fail(String message, int generation) {
    if (!_isCurrent(generation)) return;
    final uncertain = _submitting;
    setState(() {
      _pageFailed = true;
      _pageReady = false;
      _loading = false;
      _submitting = false;
      _error = uncertain
          ? '$message If you were submitting a claim, check Expense Claims in ERPNext before trying again.'
          : message;
    });
  }

  Future<void> _initialize() async {
    if (!mounted || _initializing || _submitting || _choosingPhoto) return;
    final generation = ++_generation;
    setState(() {
      _initializing = true;
      _loading = true;
      _pageReady = false;
      _pageFailed = false;
      _error = null;
      _controller = null;
      _bindingDocument = null;
      _boundDocument = null;
      _document = 0;
    });
    try {
      final base = Uri.tryParse(dotenv.env['SITE_URL']?.trim() ?? '');
      if (base == null ||
          base.scheme != 'https' ||
          base.host.isEmpty ||
          base.userInfo.isNotEmpty) {
        throw StateError('The ERP site URL is not configured.');
      }
      final user = await SessionAuthApi.getActiveSessionUser();
      final sid = await SessionAuthApi.getSessionId();
      if (!_isCurrent(generation)) return;
      if (user == null || user == 'Guest' || sid == null || sid.isEmpty) {
        throw const _ExpenseSessionException(
          'Your session expired. Sign in again and reopen Expense Claim.',
        );
      }
      _user = user;
      _sid = sid;
      _page = base.resolve('/genie-expense-claim');
      final controller = WebViewController();
      _controller = controller;
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.setBackgroundColor(Colors.white);
      await controller.addJavaScriptChannel(
        'GenieExpenseClaim',
        onMessageReceived: (message) async {
          if (!_isCurrent(generation, controller) || _pageFailed) return;
          try {
            final url = await controller.currentUrl();
            if (!_isCurrent(generation, controller) || !_isPage(url ?? '')) {
              return;
            }
            final data = jsonDecode(message.message);
            if (data is! Map) return;
            switch (data['action']) {
              case 'ready':
                await _bindPage(controller, generation);
                break;
              case 'busy':
                if (data['value'] is bool) {
                  setState(() => _submitting = data['value'] == true);
                }
                break;
              case 'close':
                _close();
                break;
              case 'session_expired':
                _fail(
                  'Your ERP session expired or changed. Sign in again and reopen Expense Claim.',
                  generation,
                );
                break;
            }
          } on FormatException {
            // Ignore malformed messages; no action is taken.
          } catch (error) {
            if (error is _ExpenseSessionException) {
              _fail(error.message, generation);
            }
          }
        },
      );
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) =>
              _isCurrent(generation, controller) &&
                      !_pageFailed &&
                      !_submitting &&
                      !_choosingPhoto &&
                      _isPage(request.url)
                  ? NavigationDecision.navigate
                  : NavigationDecision.prevent,
          onPageStarted: (url) {
            if (!_isCurrent(generation, controller)) return;
            if (!_isPage(url)) {
              _fail('This page cannot be opened in Expense Claim.', generation);
              return;
            }
            setState(() {
              _document++;
              _bindingDocument = null;
              _boundDocument = null;
              _loading = true;
              _pageReady = false;
              _pageFailed = false;
              _error = null;
            });
          },
          onPageFinished: (url) async {
            if (_isCurrent(generation, controller) && _isPage(url)) {
              await _bindPage(controller, generation, requireMarker: true);
            }
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == true &&
                _isCurrent(generation, controller)) {
              _fail(
                'The Expense Claim webpage could not be loaded. Check your connection and the ERP page deployment.',
                generation,
              );
            }
          },
        ),
      );
      final platform = controller.platform;
      if (platform is AndroidWebViewController) {
        await platform.setOnShowFileSelector(
          (params) => _selectBillPhotos(params, controller, generation),
        );
      }
      await _assertSession(generation);
      if (!_isCurrent(generation, controller)) return;
      // Keep other WebViews' cookies intact. Only set this site's login cookie.
      await WebViewCookieManager().setCookie(
        WebViewCookie(name: 'sid', value: sid, domain: base.host, path: '/'),
      );
      await _assertSession(generation);
      if (!_isCurrent(generation, controller)) return;
      setState(() {});
      await controller.loadRequest(_page!, headers: {'Cookie': 'sid=$sid'});
    } catch (error) {
      _fail(_message(error), generation);
    } finally {
      if (_isCurrent(generation)) setState(() => _initializing = false);
    }
  }

  Future<void> _bindPage(
    WebViewController controller,
    int generation, {
    bool requireMarker = false,
  }) async {
    final document = _document;
    if (!_isCurrentDocument(generation, controller, document) ||
        _bindingDocument == document ||
        _boundDocument == document) {
      return;
    }
    _bindingDocument = document;
    try {
      final url = await controller.currentUrl();
      if (!_isCurrentDocument(generation, controller, document) ||
          !_isPage(url ?? '')) {
        return;
      }
      await _assertSession(generation);
      if (!_isCurrentDocument(generation, controller, document)) return;
      final ready = await controller.runJavaScriptReturningResult(
        "document.getElementById('ec-app')?.dataset.started === 'true'",
      );
      if (!_isCurrentDocument(generation, controller, document)) return;
      if (ready != true && ready.toString() != 'true') {
        if (requireMarker) {
          throw StateError(
            'Publish the genie-expense-claim Web Page in ERP, then retry.',
          );
        }
        return;
      }
      // Only the username crosses this bridge. The sid stays in the cookie jar.
      // The webpage checks this username against its authenticated ERP session.
      await controller.runJavaScript(
        "window.dispatchEvent(new CustomEvent('genie-expense-session', "
        '{detail: {user: ${jsonEncode(_user)}}}));',
      );
      if (!_isCurrentDocument(generation, controller, document)) return;
      _boundDocument = document;
      setState(() {
        _pageReady = true;
        _loading = false;
      });
    } catch (error) {
      if (_isCurrentDocument(generation, controller, document)) {
        _fail(_message(error), generation);
      }
    } finally {
      if (_isCurrent(generation, controller) &&
          _bindingDocument == document) {
        _bindingDocument = null;
      }
    }
  }

  Future<List<String>> _selectBillPhotos(
    FileSelectorParams params,
    WebViewController controller,
    int generation,
  ) async {
    final document = _document;
    if (!_isCurrentDocument(generation, controller, document) ||
        !_pageReady ||
        _submitting ||
        _choosingPhoto ||
        ModalRoute.of(context)?.isCurrent != true ||
        params.mode == FileSelectorMode.save) {
      return [];
    }
    // This screen accepts bill photos, matching the existing native form.
    if (params.acceptTypes.isNotEmpty &&
        !params.acceptTypes.any(
          (type) => type.isEmpty || type.toLowerCase().startsWith('image/'),
        )) {
      return [];
    }
    setState(() => _choosingPhoto = true);
    try {
      final url = await controller.currentUrl();
      if (!_isCurrentDocument(generation, controller, document) ||
          !_isPage(url ?? '')) {
        return [];
      }
      await _assertSession(generation);
      if (!_isCurrentDocument(generation, controller, document) ||
          ModalRoute.of(context)?.isCurrent != true) {
        return [];
      }
      final List<XFile> selected;
      if (params.isCaptureEnabled) {
        // CAMERA is already declared by the app; request it only for Take photo.
        final permission = await Permission.camera.request();
        if (!_isCurrentDocument(generation, controller, document) ||
            ModalRoute.of(context)?.isCurrent != true) {
          return [];
        }
        if (!permission.isGranted) {
          _showPhotoMessage(
            'Allow camera access in app settings to take a bill photo, or choose a photo from the gallery.',
          );
          return [];
        }
        final image = await _picker.pickImage(
          source: ImageSource.camera,
          imageQuality: 88,
          maxWidth: 2200,
        );
        selected = image == null ? [] : [image];
      } else if (params.mode == FileSelectorMode.openMultiple) {
        selected = await _picker.pickMultiImage(
          imageQuality: 88,
          maxWidth: 2200,
        );
      } else {
        final image = await _picker.pickImage(
          source: ImageSource.gallery,
          imageQuality: 88,
          maxWidth: 2200,
        );
        selected = image == null ? [] : [image];
      }
      if (!_isCurrentDocument(generation, controller, document) ||
          selected.isEmpty) {
        return [];
      }
      await _assertSession(generation);
      final currentUrl = await controller.currentUrl();
      if (!_isCurrentDocument(generation, controller, document) ||
          !_isPage(currentUrl ?? '') ||
          _submitting ||
          ModalRoute.of(context)?.isCurrent != true) {
        return [];
      }
      final uris = <String>[];
      for (final image in selected) {
        if (image.path.isEmpty || !await File(image.path).exists()) {
          throw StateError('The selected bill image is missing. Choose it again.');
        }
        uris.add(Uri.file(image.path).toString());
      }
      if (!_isCurrentDocument(generation, controller, document)) return [];
      return uris;
    } on _ExpenseSessionException catch (error) {
      if (_isCurrentDocument(generation, controller, document)) {
        _fail(error.message, generation);
      }
      return [];
    } catch (error) {
      if (_isCurrentDocument(generation, controller, document)) {
        _showPhotoMessage('Could not select the bill photo: ${_message(error)}');
      }
      return [];
    } finally {
      if (_isCurrent(generation, controller)) {
        setState(() => _choosingPhoto = false);
      }
    }
  }

  void _showPhotoMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _close() {
    if (!mounted || _closing || _submitting || _choosingPhoto) return;
    final navigator = Navigator.of(context);
    if (!navigator.canPop()) return;
    _closing = true;
    navigator.pop();
  }

  Future<void> _handleBack() async {
    if (!mounted || _submitting || _choosingPhoto || _dispatchingBack) return;
    _dispatchingBack = true;
    try {
      final controller = _controller;
      if (controller != null && _pageReady && _error == null && !_loading) {
        await controller.runJavaScript(
          "window.dispatchEvent(new Event('genie-expense-back'));",
        );
      } else {
        _close();
      }
    } catch (_) {
      _close();
    } finally {
      _dispatchingBack = false;
    }
  }

  Widget _buildPage() {
    if (_error != null) {
      return Scaffold(
        backgroundColor: Colors.white,
        appBar: brandAppBar(
          leading: IconButton(
            tooltip: 'Back',
            onPressed: _choosingPhoto ? null : _close,
            icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
          ),
          title: const Text('Expense Claim'),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_error!, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed:
                      _initializing || _submitting || _choosingPhoto
                          ? null
                          : _initialize,
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Scaffold(
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
            child: Stack(
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
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(_handleBack());
    },
    child: AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
      child: _buildPage(),
    ),
  );
}
