import '../utils/widget/webview_pull_to_refresh.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../utils/api/pending_work_api.dart';
import '../utils/api/pending_work_monitor.dart';
import '../utils/api/session_auth.dart';
import '../utils/theme/brand_theme.dart';
import '../utils/widget/ag_path_loading_indicator.dart';
import '../utils/widget/pending_work_alarm_player.dart';
import 'opportunities_webview_page.dart';
import 'pending_section_page.dart';
import 'session_webview.dart';

const pendingWorkWebRoute = '/genie-pending-work';

bool isPendingWorkWebPageLocation(Uri page, String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      uri.origin == page.origin &&
      uri.path.replaceFirst(RegExp(r'/$'), '') == page.path;
}

const pendingWebSections = <String, ({String title, IconData icon})>{
  'stock': (title: 'Pending Transferred MTM', icon: Icons.inventory_2_outlined),
  'manufacturing': (
    title: 'Pending Jobcards',
    icon: Icons.precision_manufacturing_outlined,
  ),
  'projects': (
    title: 'Pending Production Confirm PBF',
    icon: Icons.work_outline_rounded,
  ),
  'same_area_city': (
    title: 'Same Area & City',
    icon: Icons.location_city_outlined,
  ),
  'opportunities': (
    title: 'Open Opportunities',
    icon: Icons.handshake_outlined,
  ),
  'overdue_followups': (
    title: 'Overdue Next Follow Up',
    icon: Icons.phone_callback_outlined,
  ),
  'overdue_closing': (
    title: 'Overdue Closing Date',
    icon: Icons.event_busy_outlined,
  ),
  'draft_delivery_plans': (
    title: 'Pending Draft Delivery Plans',
    icon: Icons.local_shipping_outlined,
  ),
};

/// Only the overview/category UI moves to ERP. APIs, alarms and detail routes
/// retain their existing Flutter implementations.
class PendingWorkWebViewPage extends StatefulWidget {
  const PendingWorkWebViewPage({super.key});

  @override
  State<PendingWorkWebViewPage> createState() => _PendingWorkWebViewPageState();
}

class _PendingWorkWebViewPageState extends State<PendingWorkWebViewPage> {
  WebViewController? _controller;
  Uri? _page;
  String? _user;
  String? _sid;
  String? _error;
  bool _loading = true;
  bool _opening = false;
  int _generation = 0;
  int _document = 0;
  final _requests = <String>{};
  final _rows = <String, List<Map<String, dynamic>>>{};
  final _names = <String, String>{};
  Set<String> _allowed = {};
  StreamSubscription<String>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = PendingWorkMonitor.newEntrySections.listen((section) {
      if (mounted && !_opening && ModalRoute.of(context)?.isCurrent == true) {
        unawaited(_emit('genie-pending-refresh', {'section': section}));
      }
    });
    unawaited(_initialize());
  }

  @override
  void dispose() {
    _generation++;
    unawaited(_subscription?.cancel() ?? Future<void>.value());
    super.dispose();
  }

  bool _current(int generation) => mounted && generation == _generation;

  Future<void> _assertSession({bool verifyServer = false}) async {
    // PendingWorkApi already authenticates each data request on the server.
    // Compare local identity/SID/site around it without duplicate HTTP checks.
    final user =
        verifyServer
            ? await SessionAuthApi.getActiveSessionUser()
            : await SessionAuthApi.getSavedSessionUser();
    final sid = await SessionAuthApi.getSessionId();
    final base = Uri.tryParse(dotenv.env['SITE_URL']?.trim() ?? '');
    if (user == null ||
        user == 'Guest' ||
        user != _user ||
        sid == null ||
        sid != _sid ||
        base == null ||
        base.scheme != 'https' ||
        base.userInfo.isNotEmpty ||
        base.origin != _page?.origin) {
      throw StateError(
        'Your ERP session changed. Sign in again and reopen Pending Work.',
      );
    }
  }

  void _fail(Object error) {
    if (!mounted) return;
    setState(() {
      _error = error.toString().replaceFirst('Bad state: ', '');
      _loading = false;
    });
  }

  Future<void> _emit(String event, Map<String, dynamic> detail) async {
    final controller = _controller;
    if (!mounted || controller == null || _error != null || _page == null) {
      return;
    }
    final generation = _generation;
    final document = _document;
    try {
      final url = await controller.currentUrl();
      if (!_current(generation) ||
          document != _document ||
          !isPendingWorkWebPageLocation(_page!, url ?? '')) {
        return;
      }
      await controller.runJavaScript(
        'window.dispatchEvent(new CustomEvent(${jsonEncode(event)}, '
        '{detail: ${jsonEncode(detail)}}));',
      );
    } catch (_) {
      // A navigation/disposal can race a background monitor event.
    }
  }

  Future<void> _initialize() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
      _controller = null;
      _allowed = {};
      _rows.clear();
      _names.clear();
      _requests.clear();
    });
    try {
      final base = Uri.tryParse(dotenv.env['SITE_URL']?.trim() ?? '');
      if (base == null ||
          base.scheme != 'https' ||
          base.host.isEmpty ||
          base.userInfo.isNotEmpty) {
        throw StateError('The ERP site URL is not configured with HTTPS.');
      }
      _user = await SessionAuthApi.getActiveSessionUser();
      _sid = await SessionAuthApi.getSessionId();
      if (!_current(generation)) return;
      if (_user == null || _user == 'Guest' || _sid == null || _sid!.isEmpty) {
        throw StateError('Your session expired. Sign in again.');
      }
      _page = base.resolve(pendingWorkWebRoute);
      final controller = WebViewController();
      _controller = controller;
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.setBackgroundColor(const Color(0xFFF4F7FB));
      await controller.addJavaScriptChannel(
        'GeniePendingWork',
        onMessageReceived: (message) {
          unawaited(_handle(message.message, controller, generation));
        },
      );
      await controller.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest:
              (request) =>
                  _current(generation) &&
                          _error == null &&
                          isPendingWorkWebPageLocation(_page!, request.url)
                      ? NavigationDecision.navigate
                      : NavigationDecision.prevent,
          onPageStarted: (_) {
            if (_current(generation)) {
              _document++;
              _allowed = {};
              _rows.clear();
              setState(() => _loading = true);
            }
          },
          onPageFinished: (url) async {
            if (!_current(generation) ||
                !isPendingWorkWebPageLocation(_page!, url)) {
              return;
            }
            final document = _document;
            try {
              await _assertSession(verifyServer: true);
              final ready = await controller.runJavaScriptReturningResult(
                "document.getElementById('pw-app')?.dataset.started === 'true'",
              );
              if (!_current(generation) || document != _document) return;
              if (ready != true && ready.toString() != 'true') {
                throw StateError(
                  'Publish the genie-pending-work Web Page in ERP, then retry.',
                );
              }
              setState(() => _loading = false);
              await _emit('genie-pending-session', {'user': _user});
            } catch (error) {
              if (_current(generation) && document == _document) _fail(error);
            }
          },
          onWebResourceError: (error) {
            if (_current(generation) && error.isForMainFrame == true) {
              _fail(
                'The Pending Work webpage could not be loaded. Check your connection and ERP page deployment.',
              );
            }
          },
        ),
      );
      await _assertSession();
      if (!_current(generation)) return;
      await WebViewCookieManager().setCookie(
        WebViewCookie(name: 'sid', value: _sid!, domain: base.host, path: '/'),
      );
      if (!_current(generation)) return;
      await _assertSession();
      if (!_current(generation)) return;
      setState(() {});
      await controller.loadRequest(_page!, headers: {'Cookie': 'sid=$_sid'});
    } catch (error) {
      if (_current(generation)) _fail(error);
    }
  }

  Future<void> _handle(
    String raw,
    WebViewController controller,
    int generation,
  ) async {
    if (!_current(generation) ||
        _error != null ||
        _opening ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    final document = _document;
    String? requestId;
    String? requestKey;
    bool valid() =>
        _current(generation) && document == _document && _error == null;
    try {
      final url = await controller.currentUrl();
      if (!valid() || !isPendingWorkWebPageLocation(_page!, url ?? '')) return;
      final data = jsonDecode(raw);
      if (data is! Map || data['id'] is! String || data['id'].length > 80) {
        return;
      }
      requestId = data['id'] as String;
      final action = data['action'];
      final section = data['section']?.toString() ?? '';
      final key = '$generation:$document:$action:$section';
      if (!_requests.add(key)) return;
      requestKey = key;
      await _assertSession(verifyServer: action == 'open' || action == 'svr');
      if (!mounted || !valid()) return;
      Object? result;
      switch (action) {
        case 'dashboard':
          final dashboard = await PendingWorkApi.getMobileDashboard();
          await _assertSession();
          if (!valid()) return;
          final available = dashboard['available_sections'];
          _allowed =
              pendingWebSections.keys
                  .where(
                    (key) =>
                        available is List
                            ? available.contains(key)
                            : dashboard[key] is Map,
                  )
                  .toSet();
          result = dashboard;
          break;
        case 'section':
          if (!_allowed.contains(section)) {
            throw StateError('This section is not available for your roles.');
          }
          final items = await PendingWorkApi.getPendingSectionItems(section);
          await _assertSession();
          if (!valid()) return;
          final added = await PendingWorkMonitor.recordSnapshot(
            section,
            items,
            previousItems: _rows[section] ?? [],
          );
          if (!valid()) return;
          _rows[section] = items;
          final ids = <String>{};
          for (final row in items) {
            for (final entry in row.entries) {
              final value = entry.value?.toString() ?? '';
              if (_userField(entry.key) && value.contains('@')) ids.add(value);
            }
          }
          await Future.wait(
            ids.take(12).map((id) async {
              final name = await SessionAuthApi.getUserFullName(id);
              if (valid() && name != null && name.isNotEmpty) {
                _names[id.toLowerCase()] = name;
              }
            }),
          );
          await _assertSession();
          if (!valid()) return;
          for (var i = 0; i < added; i++) {
            unawaited(PendingWorkAlarmPlayer.play());
          }
          result = {'items': items, 'names': _names};
          break;
        case 'open':
          final index = data['index'];
          final items = _rows[section];
          if (!_allowed.contains(section) ||
              index is! int ||
              items == null ||
              index < 0 ||
              index >= items.length) {
            throw StateError('Refresh the list and select an available item.');
          }
          _opening = true;
          try {
            await _openItem(section, items[index]);
          } finally {
            _opening = false;
          }
          await _assertSession();
          break;
        case 'svr':
          if (!_allowed.any(
            (key) => !{'stock', 'manufacturing', 'projects'}.contains(key),
          )) {
            throw StateError('SVR is not available in this dashboard.');
          }
          _opening = true;
          try {
            await Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder:
                    (_) => SessionWebView(
                      url: _page!.resolve('/SVR').toString(),
                      title: 'SVR',
                    ),
              ),
            );
          } finally {
            _opening = false;
          }
          await _assertSession();
          break;
        case 'close':
          Navigator.of(context).pop();
          return;
        default:
          return;
      }
      if (valid()) {
        await _emit('genie-pending-result', {'id': requestId, 'value': result});
      }
    } catch (error) {
      if (valid() &&
          error is StateError &&
          error.message ==
              'Your ERP session changed. Sign in again and reopen Pending Work.') {
        _rows.clear();
        _allowed.clear();
        _fail(error);
      } else if (valid() && requestId != null) {
        await _emit('genie-pending-result', {
          'id': requestId,
          'error': error.toString().replaceFirst('Bad state: ', ''),
        });
      }
    } finally {
      if (requestKey != null) _requests.remove(requestKey);
    }
  }

  bool _userField(String key) =>
      {
        'owner',
        'user',
        'user_id',
        'assigned_to',
        'allocated_to',
        'created_by',
        'modified_by',
      }.contains(key.toLowerCase()) ||
      key.endsWith('_owner') ||
      key.endsWith('_assigned_to') ||
      key.endsWith('_allocated_to');

  String _display(String field, dynamic value) {
    final text = value?.toString() ?? '';
    return _userField(field) && text.contains('@')
        ? _names[text.toLowerCase()] ?? 'User'
        : text;
  }

  Object? _id(Map<String, dynamic> row) =>
      row['name'] ??
      row['id'] ??
      row['stock_entry'] ??
      row['job_card'] ??
      row['project'] ??
      row['opportunity'] ??
      row['delivery_note'];

  Future<void> _openItem(String section, Map<String, dynamic> item) async {
    final info = pendingWebSections[section]!;
    if (section == 'opportunities') {
      final opportunity = item['opportunity_id']?.toString().trim() ?? '';
      final id =
          opportunity.isNotEmpty
              ? opportunity
              : item['name']?.toString().trim() ?? '';
      if (id.isNotEmpty) {
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => OpportunitiesWebViewPage(initialOpportunityId: id),
          ),
        );
        return;
      }
    }
    final fields = <String>{};
    for (final row in _rows[section] ?? <Map<String, dynamic>>[]) {
      fields.addAll(row.keys.where((key) => !key.startsWith('_')));
    }
    final columns =
        fields
            .map(
              (field) => <String, dynamic>{
                'fieldname': field,
                'label': pendingWebFieldLabel(field),
              },
            )
            .toList();
    final display = {
      for (final entry in item.entries)
        entry.key: _display(entry.key, entry.value),
    };
    final titleFields =
        (section == 'overdue_followups' || section == 'overdue_closing')
            ? ['customer', 'opportunity']
            : [
              'subject',
              'customer_name',
              'customer',
              'title',
              'project_name',
              'item_name',
              'production_item',
              'opportunity_id',
              'name',
            ];
    final title = titleFields
        .map((key) => item[key]?.toString().trim() ?? '')
        .firstWhere((text) => text.isNotEmpty, orElse: () => 'Item');
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder:
            (_) => PendingDetailPage(
              sectionTitle: info.title,
              icon: info.icon,
              title: title,
              item: display,
              columns: columns,
              section: section,
              loadItem: () async {
                await _assertSession();
                final latest = await PendingWorkApi.getPendingSectionItems(
                  section,
                );
                await _assertSession();
                final id = _id(item);
                final matches = latest.where((row) => _id(row) == id);
                if (id == null || matches.isEmpty) {
                  throw StateError(
                    'This item is no longer pending. Return to the list and refresh.',
                  );
                }
                return {
                  for (final entry in matches.first.entries)
                    entry.key: _display(entry.key, entry.value),
                };
              },
            ),
      ),
    );
  }

  Future<void> _back() async {
    if (_opening) return;
    if (_controller == null || _loading || _error != null) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    await _emit('genie-pending-back', {});
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(_back());
    },
    child: AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
      child: Scaffold(
        backgroundColor: const Color(0xFFF4F7FB),
        appBar:
            _error == null
                ? null
                : brandAppBar(
                  leading: IconButton(
                    onPressed: _back,
                    icon: const Icon(Icons.arrow_back),
                  ),
                  title: const Text('Pending Work'),
                ),
        body: WebViewPullToRefresh(
          controller: _error == null ? _controller : null,
          enabled: !_loading && !_opening,
          onRefresh: _initialize,
          child: Stack(
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
      ),
    ),
  );
}

String pendingWebFieldLabel(String field) {
  const labels = {
    'opportunity': 'Opportunity',
    'customer': 'Customer',
    'opportunity_owner': 'Opportunity Owner',
    'field_owner': 'Field Owner 1',
    'field_owner_1': 'Field Owner 2',
    'next_followup_date': 'Next Follow Up',
    'expected_closing_date': 'Expected Closing Date',
    'delivery_note': 'Delivery Note',
    'created_on': 'Created On',
    'company': 'Company',
    'owner': 'Owner',
    'overdue_days': 'Days Overdue',
  };
  return labels[field] ??
      field
          .split('_')
          .map(
            (word) =>
                word.isEmpty
                    ? word
                    : '${word[0].toUpperCase()}${word.substring(1)}',
          )
          .join(' ');
}
