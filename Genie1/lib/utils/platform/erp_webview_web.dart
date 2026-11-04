import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

extension type _FrameWindow(JSObject _) implements JSObject {
  external JSAny? eval(JSString script);
}

enum JavaScriptMode { disabled, unrestricted }
enum NavigationDecision { navigate, prevent }
class NavigationRequest {
  const NavigationRequest({required this.url, this.isMainFrame = true});
  final String url;
  final bool isMainFrame;
}
class JavaScriptMessage {
  const JavaScriptMessage(this.message);
  final String message;
}
class WebResourceError {
  const WebResourceError({required this.description, this.isForMainFrame = true});
  final String description;
  final bool? isForMainFrame;
}
class NavigationDelegate {
  const NavigationDelegate({this.onNavigationRequest, this.onPageStarted,
    this.onPageFinished, this.onWebResourceError, this.onProgress});
  final FutureOr<NavigationDecision> Function(NavigationRequest)? onNavigationRequest;
  final void Function(String)? onPageStarted;
  final void Function(String)? onPageFinished;
  final void Function(WebResourceError)? onWebResourceError;
  final void Function(int)? onProgress;
}
class WebViewCookie {
  const WebViewCookie({required this.name, required this.value, required this.domain, this.path = '/'});
  final String name, value, domain, path;
}
class WebViewCookieManager {
  // Browser-managed HttpOnly cookies are automatic; browser-* is not a real SID.
  Future<void> setCookie(WebViewCookie cookie) async {}
  Future<bool> clearCookies() async => false;
}

/// Same-origin iframe adapter for the ERP pages' existing JavaScript channels.
/// Native pages continue using webview_flutter through the conditional export.
class WebViewController {
  final platform = Object();
  Future<void> Function()? onPullToRefresh;
  final _channels = <String, void Function(JavaScriptMessage)>{};
  final _token = 'genie-erp-${List.generate(16, (_) => Random.secure().nextInt(256)).join('-')}';
  NavigationDelegate? _delegate;
  web.HTMLIFrameElement? _frame;
  Uri? _uri;
  StreamSubscription<web.Event>? _load;
  StreamSubscription<web.MessageEvent>? _messages;
  Timer? _timeout;

  Future<void> setJavaScriptMode(JavaScriptMode mode) async {}
  Future<void> setBackgroundColor(Color color) async {}
  Future<void> addJavaScriptChannel(String name,
      {required void Function(JavaScriptMessage) onMessageReceived}) async {
    if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(name)) {
      throw ArgumentError('Invalid JavaScript channel name.');
    }
    _channels[name] = onMessageReceived;
  }
  Future<void> setNavigationDelegate(NavigationDelegate delegate) async {
    _delegate = delegate;
  }
  Future<void> loadRequest(Uri uri, {Map<String, String> headers = const {}}) async {
    if (uri.userInfo.isNotEmpty || uri.origin != Uri.base.origin) {
      throw StateError('ERP pages must use the same origin as the PWA.');
    }
    final decision = await _delegate?.onNavigationRequest?.call(NavigationRequest(url: '$uri'));
    if (decision == NavigationDecision.prevent) return;
    _uri = uri;
    _delegate?.onPageStarted?.call('$uri');
    _delegate?.onProgress?.call(0);
    _timeout?.cancel();
    _timeout = Timer(const Duration(seconds: 25), () => _error('The ERP page did not finish loading. Retry when connected.'));
    _frame?.src = '$uri';
  }
  Future<String?> currentUrl() async {
    final frame = _frame;
    if (frame == null) return _uri?.toString();
    try {
      return _evaluate('location.href')?.dartify()?.toString();
    } catch (_) {
      return null; // Cross-origin redirects cannot send trusted channel messages.
    }
  }
  Future<void> reload() async {
    if (_uri != null) await loadRequest(_uri!);
  }
  Future<bool> canGoBack() async => false;
  Future<void> goBack() async {}
  JSAny? _evaluate(String script) {
    final window = _frame?.contentWindow;
    if (window == null) throw StateError('The ERP page is not ready.');
    return _FrameWindow(window).eval(script.toJS);
  }
  Future<void> runJavaScript(String script) async { _evaluate(script); }
  Future<Object> runJavaScriptReturningResult(String script) async =>
      _evaluate(script)?.dartify() ?? 'null';
  void _error(String message) {
    _timeout?.cancel();
    _delegate?.onWebResourceError?.call(WebResourceError(description: message));
  }
  void _attach(web.HTMLIFrameElement frame) {
    _detach();
    _frame = frame;
    frame.style.border = '0';
    frame.style.width = '100%';
    frame.style.height = '100%';
    frame.title = 'ERP employee page';
    frame.name = _token;
    frame.allow = 'camera; microphone; geolocation';
    frame.referrerPolicy = 'same-origin';
    frame.setAttribute('sandbox', 'allow-scripts allow-same-origin allow-forms allow-downloads');
    _messages = web.window.onMessage.listen((event) async {
      if (event.origin != Uri.base.origin || event.source != frame.contentWindow) return;
      final raw = event.data.dartify();
      if (raw is! Map || raw['token'] != _token) return;
      final name = raw['channel'];
      if (name == '__refresh') {
        await onPullToRefresh?.call();
        return;
      }
      if (name == '__navigation') {
        final target = Uri.tryParse('${raw['message']}');
        if (target != null) await loadRequest(target);
        return;
      }
      if (name is String && raw['message'] is String) {
        _channels[name]?.call(JavaScriptMessage(raw['message'] as String));
      }
    });
    _load = frame.onLoad.listen((_) async {
      if (_frame != frame || _uri == null) return;
      final actual = await currentUrl();
      if (actual == 'about:blank') return;
      if (actual == null) { _error('ERP redirected outside the PWA origin.'); return; }
      final decision = await _delegate?.onNavigationRequest?.call(NavigationRequest(url: actual));
      if (decision == NavigationDecision.prevent) {
        _error('ERP returned an unexpected page. Check your login and page deployment.'); return;
      }
      try {
        final origin = jsonEncode(Uri.base.origin), token = jsonEncode(_token);
        for (final channel in _channels.keys) {
          _evaluate('window[${jsonEncode(channel)}]={postMessage:function(message){parent.postMessage({token:$token,channel:${jsonEncode(channel)},message:String(message)},$origin)}};');
        }
        // Block unexpected document navigation before the iframe follows it.
        _evaluate("""if(!window.__genieNavigationInstalled){
          window.__genieNavigationInstalled=true;
          document.addEventListener('click',function(event){
            const anchor=event.target.closest&&event.target.closest('a[href]');
            if(!anchor)return;
            const target=new URL(anchor.href,location.href);
            if(target.origin!==location.origin||target.pathname!==location.pathname){
              event.preventDefault();
              parent.postMessage({token:$token,channel:'__navigation',message:target.href},$origin);
            }
          },true);
        }""");
        _timeout?.cancel();
        _delegate?.onProgress?.call(100);
        _delegate?.onPageFinished?.call(actual);
      } catch (_) {
        _error('The ERP page could not initialize. Check its deployment and retry.');
      }
    });
    if (_uri != null) {
      _timeout = Timer(const Duration(seconds: 25), () => _error('The ERP page did not finish loading. Retry when connected.'));
      frame.src = '$_uri';
    }
  }
  void _detach() {
    _timeout?.cancel();
    _load?.cancel(); _load = null;
    _messages?.cancel(); _messages = null;
    _frame?.removeAttribute('src');
    _frame = null;
  }
}
class WebViewWidget extends StatefulWidget {
  const WebViewWidget({super.key, required this.controller});
  final WebViewController controller;
  @override State<WebViewWidget> createState() => _WebViewWidgetState();
}
class _WebViewWidgetState extends State<WebViewWidget> {
  @override void didUpdateWidget(covariant WebViewWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) oldWidget.controller._detach();
  }
  @override void dispose() { widget.controller._detach(); super.dispose(); }
  @override Widget build(BuildContext context) => HtmlElementView.fromTagName(
    key: ObjectKey(widget.controller), tagName: 'iframe',
    onElementCreated: (element) => widget.controller._attach(element as web.HTMLIFrameElement),
  );
}
