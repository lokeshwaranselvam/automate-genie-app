import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../utils/api/notification_inbox.dart';
import '../utils/theme/brand_theme.dart';
import '../utils/widget/ag_path_loading_indicator.dart';
import '../utils/widget/home_back_button.dart';
import '../utils/widget/pull_to_refresh.dart';

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
  final Set<String> _viewedIds = {};
  String? _scope;

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
    if (_scope != null) {
      unawaited(
        NotificationInbox.dismissViewed(Set.of(_viewedIds), scope: _scope!),
      );
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_reloadCached());
  }

  void _recordRenderedItems() {
    final ids = _items.map((item) => item.id).toSet();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      if (lifecycle == null || lifecycle == AppLifecycleState.resumed) {
        _viewedIds.addAll(ids);
      }
    });
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
    _recordRenderedItems();
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
      _recordRenderedItems();
      final items = await NotificationInbox.load();
      if (await NotificationInbox.sessionScope() != scope) return;
      if (mounted) {
        setState(() => _items = items);
        _recordRenderedItems();
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: brandAppBar(
        leading: const HomeBackButton(color: Colors.white),
        title: const Text('Notifications'),
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
        ],
      ),
    );
  }
}
