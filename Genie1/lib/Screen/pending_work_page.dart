import '../utils/widget/pull_to_refresh.dart';
import '../utils/widget/ag_path_loading_indicator.dart';
import 'package:homegenie/utils/theme/brand_theme.dart';
import 'package:flutter/material.dart';

import 'session_webview.dart';
import '../utils/api/pending_work_api.dart';
import '../utils/widget/home_back_button.dart';

const _blue = BrandColors.ink;
const _ink = Color(0xFF202B3C);
const _muted = Color(0xFF7B8492);

class PendingWorkPage extends StatefulWidget {
  const PendingWorkPage({super.key});

  @override
  State<PendingWorkPage> createState() => PendingWorkPageState();
}

class PendingWorkPageState extends State<PendingWorkPage> {
  List<Map<String, dynamic>> _tasks = [];
  final Set<String> _selectedTaskIds = {};
  final _searchController = TextEditingController();
  String _search = '';
  int _tab = 0;
  bool _loading = true;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      if (mounted)
        setState(() => _search = _searchController.text.trim().toLowerCase());
    });
    refresh();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> refresh() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final tasks = await PendingWorkApi.getPendingTasks();
      if (!mounted) return;
      setState(() {
        _tasks = tasks;
        final pendingIds = <String>{};
        for (var i = 0; i < tasks.length; i++) {
          if (!_isDone(tasks[i])) pendingIds.add(_taskId(tasks[i], i));
        }
        _selectedTaskIds.removeWhere((id) => !pendingIds.contains(id));
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  String _taskId(Map<String, dynamic> task, int index) =>
      (task['name'] ?? task['id'] ?? task['task_id'] ?? index).toString();

  bool _isDone(Map<String, dynamic> task) {
    final status =
        (task['task_status'] ??
                task['todo_status'] ??
                task['status'] ??
                task['state'] ??
                '')
            .toString()
            .toLowerCase();
    return status == 'completed' ||
        status == 'complete' ||
        status == 'closed' ||
        status == 'done';
  }

  DateTime? _startsOn(Map<String, dynamic> task) {
    for (final key in [
      'todo_date',
      'due_date',
      'starts_on',
      'start_date',
      'date',
    ]) {
      final value = task[key]?.toString();
      if (value != null && value.trim().isNotEmpty) {
        final parsed = DateTime.tryParse(value);
        if (parsed != null) return parsed.toLocal();
      }
    }
    return null;
  }

  String _priority(Map<String, dynamic> task) {
    // Respect the priority saved by the task creator. Due-date urgency is
    // displayed separately and must not silently replace that selection.
    const labels = {
      'low': 'Low',
      'medium': 'Medium',
      'high': 'High',
      'urgent': 'Urgent',
    };
    for (final key in ['task_priority', 'priority', 'todo_priority']) {
      final label = labels[task[key]?.toString().trim().toLowerCase()];
      if (label != null) return label;
    }
    // Preserve the existing fallback for older responses without a priority.
    final date = _startsOn(task);
    if (date == null) return 'Low';
    final today = DateUtils.dateOnly(DateTime.now());
    final days = DateUtils.dateOnly(date).difference(today).inDays;
    if (days <= 0) return 'High';
    if (days <= 3) return 'Medium';
    return 'Low';
  }

  String _dateLabel(DateTime? date, {required bool done}) {
    if (date == null) return 'No due date';
    final today = DateUtils.dateOnly(DateTime.now());
    final day = DateUtils.dateOnly(date);
    if (!done && day.isBefore(today)) {
      return 'Overdue \u2022 ${date.day} ${_month(date.month)}';
    }
    if (day == today) {
      final hour = date.hour % 12 == 0 ? 12 : date.hour % 12;
      final minute = date.minute.toString().padLeft(2, '0');
      return date.hour == 0 && date.minute == 0
          ? 'Due Today'
          : 'Due Today • $hour:$minute ${date.hour >= 12 ? 'PM' : 'AM'}';
    }
    if (day == today.add(const Duration(days: 1))) return 'Due Tomorrow';
    return 'Due ${date.day} ${_month(date.month)}';
  }

  String _month(int month) =>
      const [
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec',
      ][month - 1];

  String _title(Map<String, dynamic> task) =>
      (task['subject'] ??
              task['title'] ??
              task['task_description'] ??
              task['description'] ??
              task['name'] ??
              'Task')
          .toString()
          .trim();

  String _subtitle(Map<String, dynamic> task) {
    for (final key in [
      'custom_project_name',
      'project',
      'assigned_user_name',
      'customer',
      'company',
      'reference_name',
      'assigned_to',
    ]) {
      final value = task[key]?.toString().trim();
      if (value != null && value.isNotEmpty) return value;
    }
    return (task['task_status'] ??
            task['todo_status'] ??
            task['status'] ??
            task['state'] ??
            'Task')
        .toString();
  }

  List<MapEntry<int, Map<String, dynamic>>> get _visibleTasks {
    final rows = <MapEntry<int, Map<String, dynamic>>>[];
    for (var i = 0; i < _tasks.length; i++) {
      final task = _tasks[i];
      final done = _isDone(task);
      if (_tab == 1 && done || _tab == 2 && !done) continue;
      if (_search.isNotEmpty &&
          !task.values.join(' ').toLowerCase().contains(_search))
        continue;
      rows.add(MapEntry(i, task));
    }
    rows.sort((a, b) {
      const rank = {'Urgent': 0, 'High': 1, 'Medium': 2, 'Low': 3};
      final priorityOrder = rank[_priority(a.value)]!.compareTo(
        rank[_priority(b.value)]!,
      );
      if (priorityOrder != 0) return priorityOrder;
      final da = _startsOn(a.value) ?? DateTime(9999);
      final db = _startsOn(b.value) ?? DateTime(9999);
      final dateOrder = da.compareTo(db);
      return dateOrder != 0 ? dateOrder : a.key.compareTo(b.key);
    });
    return rows;
  }

  int _count(int tab) =>
      List.generate(_tasks.length, (i) => i)
          .where(
            (i) =>
                tab == 0 ||
                (tab == 1 && !_isDone(_tasks[i])) ||
                (tab == 2 && _isDone(_tasks[i])),
          )
          .length;

  void _toggleSelected(int index, Map<String, dynamic> task) {
    if (_isDone(task) || _submitting) return;
    final id = _taskId(task, index);
    setState(() {
      if (!_selectedTaskIds.add(id)) _selectedTaskIds.remove(id);
    });
  }

  Future<void> _submitSelected() async {
    if (_submitting || _selectedTaskIds.isEmpty) return;
    final selected = <Map<String, dynamic>>[];
    for (var i = 0; i < _tasks.length; i++) {
      if (_selectedTaskIds.contains(_taskId(_tasks[i], i)) &&
          !_isDone(_tasks[i])) {
        selected.add(_tasks[i]);
      }
    }
    if (selected.isEmpty) return;

    setState(() => _submitting = true);
    var completed = 0;
    final failures = <String>[];
    for (final task in selected) {
      try {
        await PendingWorkApi.completePendingTask(task);
        if (mounted) {
          setState(
            () => _selectedTaskIds.remove(_taskId(task, _tasks.indexOf(task))),
          );
        }
        completed++;
      } catch (error) {
        failures.add(
          '${_title(task)}: ${error.toString().replaceFirst('StateError: ', '')}',
        );
      }
    }

    if (mounted) await refresh();
    if (!mounted) return;
    setState(() => _submitting = false);
    final message =
        failures.isEmpty
            ? '$completed task${completed == 1 ? '' : 's'} submitted and marked completed in ERP.'
            : '$completed completed; ${failures.length} failed. ${failures.first}';
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openTaskCreator() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder:
            (_) => const SessionWebView(
              url: 'https://16.itgenie.online/TGC',
              title: 'New Task',
            ),
      ),
    );
    // A task may have been assigned while the user was in TGC.
    if (mounted) await refresh();
  }

  @override
  Widget build(BuildContext context) {
    final tasks = _visibleTasks;
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      appBar: brandAppBar(
        elevation: 0,
        leading: const HomeBackButton(color: Colors.white),
        title: const Text(
          'My Tasks',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: 19,
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed:
                _selectedTaskIds.isEmpty || _submitting
                    ? null
                    : _submitSelected,
            icon:
                _submitting
                    ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                    : const Icon(Icons.check_circle_outline, size: 18),
            label: Text(
              _submitting
                  ? 'Submitting'
                  : 'Submit (${_selectedTaskIds.length})',
            ),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Row(
            children: [
              _tabLabel('All', 0),
              _tabLabel('Pending', 1),
              _tabLabel('Completed', 2),
            ],
          ),
        ),
      ),
      body: PullToRefresh(
        enabled: !_loading && !_submitting,
        onRefresh: refresh,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 13, 16, 10),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        hintText: 'Search tasks...',
                        hintStyle: const TextStyle(color: _muted, fontSize: 14),
                        prefixIcon: const Icon(Icons.search, color: _muted),
                        filled: true,
                        fillColor: Colors.white,
                        contentPadding: EdgeInsets.zero,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  IconButton.filledTonal(
                    onPressed: () {},
                    tooltip: 'Filter tasks',
                    icon: const Icon(Icons.filter_list, color: _ink),
                  ),
                ],
              ),
            ),
            Expanded(
              child:
                  _loading && _tasks.isEmpty
                      ? const Center(child: AgPathLoadingIndicator())
                      : _error != null && _tasks.isEmpty
                      ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(_error!, textAlign: TextAlign.center),
                              const SizedBox(height: 12),
                            ],
                          ),
                        ),
                      )
                      : tasks.isEmpty
                      ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(
                          parent: ClampingScrollPhysics(),
                        ),
                        children: const [
                          SizedBox(height: 120),
                          Center(
                            child: Text(
                              'No tasks found',
                              style: TextStyle(color: _muted),
                            ),
                          ),
                        ],
                      )
                      : ListView.separated(
                        physics: const AlwaysScrollableScrollPhysics(
                          parent: ClampingScrollPhysics(),
                        ),
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 100),
                        itemCount: tasks.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, row) {
                          final index = tasks[row].key;
                          final task = tasks[row].value;
                          final done = _isDone(task);
                          final selected = _selectedTaskIds.contains(
                            _taskId(task, index),
                          );
                          final priority = _priority(task);
                          final badgeColor =
                              priority == 'Urgent'
                                  ? const Color(0xFFB3261E)
                                  : priority == 'High'
                                  ? const Color(0xFFE64B55)
                                  : priority == 'Medium'
                                  ? const Color(0xFFD99B24)
                                  : const Color(0xFF36A879);
                          final date = _startsOn(task);
                          return Container(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(13),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 14,
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Checkbox(
                                    value: done || selected,
                                    onChanged:
                                        done || _submitting
                                            ? null
                                            : (_) =>
                                                _toggleSelected(index, task),
                                    activeColor: _blue,
                                    visualDensity: VisualDensity.compact,
                                  ),
                                  const SizedBox(width: 9),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          _title(task),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: _ink,
                                            fontSize: 14,
                                            fontWeight: FontWeight.w700,
                                            decoration:
                                                done
                                                    ? TextDecoration.lineThrough
                                                    : null,
                                          ),
                                        ),
                                        const SizedBox(height: 5),
                                        Text(
                                          _subtitle(task),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: _muted,
                                            fontSize: 12,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          _dateLabel(date, done: done),
                                          style: TextStyle(
                                            color:
                                                date != null &&
                                                        !done &&
                                                        !DateUtils.dateOnly(
                                                          date,
                                                        ).isAfter(
                                                          DateUtils.dateOnly(
                                                            DateTime.now(),
                                                          ),
                                                        )
                                                    ? const Color(0xFFD9534F)
                                                    : _muted,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 9,
                                      vertical: 5,
                                    ),
                                    decoration: BoxDecoration(
                                      color: badgeColor.withValues(alpha: .12),
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    child: Text(
                                      priority,
                                      style: TextStyle(
                                        color: badgeColor,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
            ),
          ],
        ),
      ),
      floatingActionButton: brandFloatingActionButton(
        onPressed: _openTaskCreator,
        icon: const Icon(Icons.add),
        label: const Text(
          'New Task',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  Widget _tabLabel(String label, int index) {
    final selected = _tab == index;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _tab = index),
        child: Column(
          children: [
            SizedBox(
              height: 46,
              child: Center(
                child: Text(
                  '$label (${_count(index)})',
                  style: TextStyle(
                    color: selected ? _blue : _ink,
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
            ),
            Container(
              height: 2,
              decoration: BoxDecoration(
                gradient: selected ? BrandColors.gradient : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
