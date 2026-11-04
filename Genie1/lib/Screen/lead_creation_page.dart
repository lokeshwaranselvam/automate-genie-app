import '../utils/widget/webview_pull_to_refresh.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:geolocator/geolocator.dart';
import 'package:homegenie/utils/platform/erp_webview.dart';

import '../utils/api/location_api.dart';
import '../utils/api/session_auth.dart';
import '../utils/theme/brand_theme.dart';
import '../utils/widget/ag_path_loading_indicator.dart';
import '../utils/widget/home_back_button.dart';
import '../utils/widget/warning.dart';

const leadCreationRoute = '/create_lead_from_mobile';

bool isLeadCreationWebPageLocation(Uri page, String? value) {
  final uri = Uri.tryParse(value ?? '');
  return uri != null &&
      isTrustedErpPageUri(uri) &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty &&
      uri.origin == page.origin &&
      uri.path.replaceFirst(RegExp(r'/$'), '') == page.path;
}

/// Existing Lead routes open the ERP Web Page, as Expense Claim does.
class LeadCreationPage extends StatefulWidget {
  const LeadCreationPage({super.key});
  @override
  State<LeadCreationPage> createState() => _LeadCreationPageState();
}

class _LeadCreationPageState extends State<LeadCreationPage> {
  WebViewController? _controller;
  Uri? _page;
  String? _sid;
  String? _user;
  String? _site;
  String? _error;
  bool _loading = true;
  bool _pageReady = false;
  bool _initializing = false;
  bool _submitting = false;
  bool _locating = false;
  int _generation = 0;
  int _document = 0;
  int? _bindingDocument;
  int? _boundDocument;
  Timer? _loadTimer;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  @override
  void dispose() {
    _generation++;
    _loadTimer?.cancel();
    _controller = null;
    super.dispose();
  }

  bool _current(int generation, WebViewController controller) =>
      mounted &&
      generation == _generation &&
      identical(controller, _controller);
  bool _isPage(String? url) =>
      _page != null && isLeadCreationWebPageLocation(_page!, url);
  String _message(Object error) => error.toString().replaceFirst(
    RegExp(r'^(Bad state|StateError|FormatException):\s*'),
    '',
  );

  Future<void> _assertSession() async {
    if (_sid == null ||
        await SessionAuthApi.getSessionId() != _sid ||
        dotenv.env['SITE_URL']?.trim() != _site) {
      throw StateError(
        'Your ERP session or site changed. Sign in again and reopen Create Lead.',
      );
    }
  }

  void _fail(String message, int generation) {
    if (!mounted || generation != _generation) return;
    _loadTimer?.cancel();
    setState(() {
      _error =
          _submitting
              ? '$message Check My Leads before submitting again.'
              : message;
      _pageReady = false;
      _loading = false;
      _submitting = false;
    });
  }

  Future<void> _initialize() async {
    if (_initializing || _submitting || _locating) return;
    final generation = ++_generation;
    _loadTimer?.cancel();
    setState(() {
      _initializing = true;
      _loading = true;
      _pageReady = false;
      _error = null;
      _controller = null;
      _document = 0;
      _boundDocument = null;
      _bindingDocument = null;
    });
    try {
      _site = dotenv.env['SITE_URL']?.trim();
      final base = Uri.tryParse(_site ?? '');
      if (base == null ||
          !isTrustedErpPageUri(base) ||
          base.host.isEmpty ||
          base.userInfo.isNotEmpty) {
        throw StateError('The ERP site URL is not configured.');
      }
      final user = await SessionAuthApi.getActiveSessionUser();
      final sid = await SessionAuthApi.getSessionId();
      if (!mounted || generation != _generation) return;
      if (user == null || user == 'Guest' || sid == null || sid.isEmpty) {
        throw StateError(
          'Your Frappe session has expired. Please sign in again.',
        );
      }
      _user = user;
      _sid = sid;
      _page = erpWebPageUri(base, leadCreationRoute);
      final controller = WebViewController();
      _controller = controller;
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.setBackgroundColor(Colors.white);
      await controller.addJavaScriptChannel(
        'GenieLead',
        onMessageReceived: (message) {
          unawaited(_handle(message.message, generation, controller));
        },
      );
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest:
              (request) =>
                  _current(generation, controller) &&
                          _error == null &&
                          !_submitting &&
                          !_locating &&
                          _isPage(request.url)
                      ? NavigationDecision.navigate
                      : NavigationDecision.prevent,
          onPageStarted: (url) {
            if (!_current(generation, controller)) return;
            if (!_isPage(url)) {
              _fail(
                'Only the Create Lead webpage can be opened here.',
                generation,
              );
              return;
            }
            setState(() {
              _document++;
              _boundDocument = null;
              _bindingDocument = null;
              _pageReady = false;
              _loading = true;
            });
          },
          onPageFinished: (url) async {
            if (_current(generation, controller) && _isPage(url)) {
              await _bindPage(controller, generation, requireMarker: true);
            }
          },
          onWebResourceError: (error) {
            if (_current(generation, controller) &&
                error.isForMainFrame == true) {
              _fail(
                'The Create Lead webpage could not be loaded. Check your connection and ERP page publication.',
                generation,
              );
            }
          },
        ),
      );
      await _assertSession();
      if (!_current(generation, controller)) return;
      // Preserve all other WebViews' cookies; set only this ERP login cookie.
      await WebViewCookieManager().setCookie(
        WebViewCookie(name: 'sid', value: sid, domain: base.host, path: '/'),
      );
      await _assertSession();
      if (!_current(generation, controller)) return;
      setState(() {});
      _loadTimer = Timer(const Duration(seconds: 35), () {
        if (_current(generation, controller) && !_pageReady) {
          _fail(
            erpPageLoadMessage('Create Lead did not finish loading. Publish the updated create_lead_from_mobile Web Page in ERP, then retry.'),
            generation,
          );
        }
      });
      await controller.loadRequest(_page!, headers: {'Cookie': 'sid=$sid'});
    } catch (error) {
      _fail(_message(error), generation);
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _initializing = false);
      }
    }
  }

  Future<void> _bindPage(
    WebViewController controller,
    int generation, {
    bool requireMarker = false,
  }) async {
    final document = _document;
    bool valid() =>
        _current(generation, controller) &&
        _error == null &&
        document == _document;
    if (!valid() ||
        _bindingDocument == document ||
        _boundDocument == document) {
      return;
    }
    _bindingDocument = document;
    try {
      if (!_isPage(await controller.currentUrl()) || !valid()) return;
      await _assertSession();
      if (!valid()) return;
      final ready = await controller.runJavaScriptReturningResult(
        "window.LeadForm?.version === 'hosted-v1' && document.getElementById('lc-app')?.dataset.started === 'true'",
      );
      if (!valid()) return;
      if (ready != true && ready.toString() != 'true') {
        if (requireMarker) {
          throw StateError(
            erpPageLoadMessage('Publish the updated create_lead_from_mobile Web Page in ERP, then retry.'),
          );
        }
        return;
      }
      // Only identity crosses this bridge; the webpage verifies its cookie user.
      await controller.runJavaScript(
        "window.dispatchEvent(new CustomEvent('genie-lead-session', {detail: {user: ${jsonEncode(_user)}}}));",
      );
      if (!valid()) return;
      _boundDocument = document;
      _loadTimer?.cancel();
      setState(() {
        _pageReady = true;
        _loading = false;
      });
    } catch (error) {
      if (valid()) _fail(_message(error), generation);
    } finally {
      if (_current(generation, controller) && _bindingDocument == document) {
        _bindingDocument = null;
      }
    }
  }

  Future<void> _handle(
    String raw,
    int generation,
    WebViewController controller,
  ) async {
    String? id;
    String? action;
    try {
      if (!_current(generation, controller) ||
          _error != null ||
          raw.length > 8192 ||
          !_isPage(await controller.currentUrl())) {
        return;
      }
      final data = jsonDecode(raw);
      if (data is! Map || data['action'] is! String) return;
      action = data['action'] as String;
      if (action == 'ready') {
        await _bindPage(controller, generation);
        return;
      }
      if (!_pageReady) return;
      await _assertSession();
      if (!_current(generation, controller)) return;
      if (action == 'busy') {
        if (data['value'] is bool) {
          setState(() => _submitting = data['value'] == true);
        }
      } else if (action == 'session_expired') {
        _fail(
          'Your ERP session expired or changed. Sign in again and reopen Create Lead.',
          generation,
        );
      } else if (action == 'success') {
        if (mounted) {
          Warning.show(context, 'Lead created successfully!', 'Success');
          WidgetsBinding.instance.scheduleFrame();
        }
      } else if (action == 'close') {
        if (mounted && !_submitting && !_locating) {
          Navigator.of(context).maybePop();
        }
      } else if (action == 'location' && data['id'] is String) {
        id = data['id'] as String;
        if (id.length > 80) return;
        if (_locating || _submitting) {
          throw StateError('A Lead request is already in progress.');
        }
        _locating = true;
        try {
          final address = await _getCurrentLocation();
          await _assertSession();
          await _respond(controller, generation, {'id': id, 'result': address});
        } finally {
          _locating = false;
        }
      }
    } catch (error) {
      if (id != null) {
        if (mounted && _current(generation, controller)) {
          Warning.show(context, _message(error), 'Location');
          WidgetsBinding.instance.scheduleFrame();
        }
        await _respond(controller, generation, {
          'id': id,
          'error': _message(error),
          'shown': true,
        });
      } else if (action != null) {
        _fail(_message(error), generation);
      }
    }
  }

  Future<void> _respond(
    WebViewController controller,
    int generation,
    Map data,
  ) async {
    try {
      if (!_current(generation, controller) ||
          _error != null ||
          !_isPage(await controller.currentUrl())) {
        return;
      }
      if (!_current(generation, controller)) return;
      await controller.runJavaScript(
        'window.LeadForm.receive(${jsonEncode(data)});',
      );
    } catch (_) {
      /* Ignore a disposed document. */
    }
  }

  Future<String> _getCurrentLocation() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw StateError('Turn on location services and try again.');
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw StateError('Location permission is required.');
    }
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
      return await LocationHelper.getAddressFromCoordinates(
        position.latitude,
        position.longitude,
      ).timeout(
        const Duration(seconds: 10),
        onTimeout:
            () =>
                throw StateError(
                  'Could not find the address in time. Try again or type it.',
                ),
      );
    } on TimeoutException {
      throw StateError(
        'Could not get your GPS location in time. Move to an open area and try again.',
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.white,
    appBar: brandAppBar(
      leading: const HomeBackButton(color: Colors.white),
      elevation: 0,
      title: const Text(
        'Create Lead',
        style: TextStyle(
          color: Colors.white,
          fontSize: 17,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
    body: WebViewPullToRefresh(
      controller: _error == null ? _controller : null,
      enabled: !_loading && !_initializing && !_submitting && !_locating,
      onRefresh: _initialize,
      child:
          _error != null
              ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!, textAlign: TextAlign.center),
                      const SizedBox(height: 12),
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
