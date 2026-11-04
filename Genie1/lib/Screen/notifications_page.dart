import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../utils/api/document_notification.dart';
import '../utils/api/notification_inbox.dart';
import '../utils/api/session_auth.dart';
import '../utils/theme/brand_theme.dart';
import '../utils/widget/ag_path_loading_indicator.dart';
import '../utils/widget/home_back_button.dart';
import '../utils/widget/pull_to_refresh.dart';
import 'session_webview.dart';
import 'sales_summary_webview_page.dart';

class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});
  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage>
    with WidgetsBindingObserver {
  List<InboxNotification> _items = [];
  bool _loading = false;
  String? _error;
  StreamSubscription<void>? _subscription;
  String? _scope;
  bool _opening = false;
  bool _clearing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _subscription = NotificationInbox.changes.listen((_) => _reloadCached());
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _subscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_reloadCached());
  }

  void _recordSeenItems() {
    final scope = _scope;
    if (scope == null) return;
    final ids = _items.map((item) => item.id).toSet();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      if (lifecycle == null || lifecycle == AppLifecycleState.resumed) {
        unawaited(NotificationInbox.markSeen(ids, scope: scope));
      }
    });
  }

  Future<void> _clearNotifications() async {
    final scope = _scope;
    if (_clearing || scope == null || _items.isEmpty) return;
    final ids = _items.map((item) => item.id).toSet();
    setState(() => _clearing = true);
    try {
      await NotificationInbox.dismissViewed(ids, scope: scope);
      await _reloadCached();
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  Future<void> _reloadCached() async {
    final scope = await NotificationInbox.sessionScope();
    final items = await NotificationInbox.cached();
    if (!mounted ||
        scope != _scope ||
        await NotificationInbox.sessionScope() != scope) {
      return;
    }
    if (!mounted) return;
    setState(() => _items = items);
    _recordSeenItems();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final scope = await NotificationInbox.sessionScope();
      if (!mounted) return;
      if (_scope != null && scope != _scope) return;
      _scope = scope;
      final cached = await NotificationInbox.cached();
      if (await NotificationInbox.sessionScope() != scope) return;
      if (!mounted) return;
      setState(() => _items = cached);
      _recordSeenItems();
      final items = await NotificationInbox.load();
      if (await NotificationInbox.sessionScope() != scope) return;
      if (mounted) {
        setState(() => _items = items);
        _recordSeenItems();
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error.toString().replaceFirst('Bad state: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  IconData _icon(String category) => switch (category) {
    'Tasks' => Icons.task_alt,
    'Leads' => Icons.person_outline,
    'Visits' => Icons.location_on_outlined,
    'Pending Work' => Icons.work_outline,
    _ => Icons.notifications_outlined,
  };

  Future<void> _openItem(InboxNotification item, {bool call = false}) async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      final scope = _scope;
      if (scope == null || await NotificationInbox.sessionScope() != scope) {
        throw StateError('Your session changed. Reopen Notifications.');
      }
      final user = await SessionAuthApi.getActiveSessionUser();
      if (!mounted) return;
      if (user == null ||
          user == 'Guest' ||
          await NotificationInbox.sessionScope() != scope) {
        throw StateError(
          'Your session changed. Sign in again and reopen Notifications.',
        );
      }
      if (!mounted) return;
      if (call) {
        if (!RegExp(r'^\+?[0-9]{7,15}$').hasMatch(item.callPhone)) return;
        if (!await launchUrl(
          Uri(scheme: 'tel', path: item.callPhone),
          mode: LaunchMode.externalApplication,
        )) {
          throw StateError('Could not open the assigned customer dialer.');
        }
      } else if (item.isSalesSummary) {
        await Navigator.of(context).push<void>(
          MaterialPageRoute(builder: (_) => const SalesSummaryWebViewPage()),
        );
      } else {
        final document = DocumentNotification.fromData({
          'type': 'DOCUMENT_NOTIFICATION',
          'doctype': item.doctype,
          'docname': item.reference,
          'for_user': user,
        });
        final uri = document?.documentUri;
        if (uri == null || uri.userInfo.isNotEmpty) {
          throw StateError('This notification has no valid ERP document link.');
        }
        await Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder:
                (_) => SessionWebView(
                  url: uri.toString(),
                  title: item.title,
                  blockSystemBack: false,
                ),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error.toString().replaceFirst('Bad state: ', '')),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: brandAppBar(
        leading: const HomeBackButton(color: Colors.white),
        title: const Text('Notifications'),
        actions: [
          IconButton(
            tooltip: 'Clear notifications',
            onPressed: _items.isEmpty || _clearing ? null : _clearNotifications,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: PullToRefresh(
        enabled: !_loading,
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(
            parent: ClampingScrollPhysics(),
          ),
          padding: const EdgeInsets.all(16),
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Color(0xFFB3261E)),
                ),
              ),
            if (_loading && _items.isEmpty)
              const Padding(
                padding: EdgeInsets.all(48),
                child: Center(child: AgPathLoadingIndicator()),
              )
            else if (_items.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 64),
                child: Column(
                  children: [
                    const Icon(
                      Icons.notifications_none,
                      size: 48,
                      color: Colors.grey,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _error != null
                          ? 'Could not load notifications'
                          : 'No notifications yet',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Swipe down to refresh.',
                      style: TextStyle(color: Colors.grey),
                    ),
                  ],
                ),
              )
            else
              for (final item in _items) _notificationCard(item),
          ],
        ),
      ),
    );
  }

  Widget _notificationCard(InboxNotification item) {
    final date = DateTime.tryParse(item.created);
    return Card(
      key: ValueKey(item.id),
      margin: const EdgeInsets.only(bottom: 10),
      child: ExpansionTile(
        leading: CircleAvatar(
          backgroundColor: const Color(0xFFEAF0FF),
          child: Icon(_icon(item.category), color: BrandColors.ink),
        ),
        title: Text(
          item.title.isEmpty ? 'New notification' : item.title,
          style: TextStyle(
            fontSize: 14,
            fontWeight: item.read ? FontWeight.w500 : FontWeight.w700,
          ),
        ),
        subtitle: Text(
          '${item.category}${date == null ? '' : ' · ${DateFormat('dd MMM, h:mm a').format(date.toLocal())}'}',
          style: const TextStyle(fontSize: 12),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (item.body.isNotEmpty) SelectableText(item.body),
          if (item.reference.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: SelectableText('Reference: ${item.reference}'),
            ),
          if (item.body.isEmpty && item.reference.isEmpty)
            const Text('No additional details.'),
          if (item.isSalesSummary ||
              (item.doctype.isNotEmpty && item.reference.isNotEmpty) ||
              item.callPhone.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 12,
                children: [
                  if (item.isSalesSummary)
                    TextButton.icon(
                      onPressed: _opening ? null : () => _openItem(item),
                      icon: const Icon(Icons.bar_chart_rounded),
                      label: const Text('View sales summary'),
                    )
                  else if (item.doctype.isNotEmpty && item.reference.isNotEmpty)
                    TextButton.icon(
                      onPressed: _opening ? null : () => _openItem(item),
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('Open in ERP'),
                    ),
                  if (item.callPhone.isNotEmpty)
                    TextButton.icon(
                      onPressed:
                          _opening ? null : () => _openItem(item, call: true),
                      icon: const Icon(Icons.call_outlined),
                      label: const Text('Call customer'),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
