import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../utils/theme/brand_theme.dart';

const _homeInk = Color(0xFF07143E);
const _homeMuted = Color(0xFF8290A9);

/// Presentation only: the Home controller supplies all live data and actions.
class HomeDashboardView extends StatelessWidget {
  const HomeDashboardView({
    super.key,
    required this.avatar,
    required this.name,
    required this.greeting,
    required this.date,
    required this.taskCount,
    required this.visitCount,
    required this.leadCount,
    required this.pendingCount,
    required this.loading,
    required this.attendanceBusy,
    required this.schedule,
    required this.onRefresh,
    required this.onMenu,
    required this.onNotifications,
    required this.onTasks,
    required this.onVisits,
    required this.onLeads,
    required this.onPending,
    required this.onAttendance,
    required this.onAddLead,
    this.onClearSchedule,
  });

  final Widget avatar;
  final String name, greeting, taskCount, visitCount, leadCount, pendingCount;
  final DateTime date;
  final bool loading, attendanceBusy;
  final List<Widget> schedule;
  final Future<void> Function() onRefresh;
  final VoidCallback onMenu, onNotifications, onTasks, onVisits, onLeads;
  final VoidCallback onPending, onAttendance, onAddLead;
  final VoidCallback? onClearSchedule;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFFF0F6FF), Color(0xFFF8FBFF), Color(0xFFEFF5FF)],
      ),
    ),
    child: SafeArea(
      bottom: false,
      child: RefreshIndicator(
        onRefresh: onRefresh,
        color: BrandColors.indigo,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 24),
          children: [
            _header(),
            const SizedBox(height: 20),
            _profile(),
            const SizedBox(height: 18),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _metric(
                  Icons.event_available_rounded,
                  taskCount,
                  'Tasks Today',
                  const Color(0xFF4514EE),
                  const Color(0xFFF0EDFF),
                  onTasks,
                ),
                const SizedBox(width: 7),
                _metric(
                  Icons.apartment_rounded,
                  visitCount,
                  'Site Visits',
                  const Color(0xFF008F73),
                  const Color(0xFFE8FAF4),
                  onVisits,
                ),
                const SizedBox(width: 7),
                _metric(
                  Icons.handshake_rounded,
                  leadCount,
                  'My Leads',
                  const Color(0xFFAC7309),
                  const Color(0xFFFFF6E5),
                  onLeads,
                ),
                const SizedBox(width: 7),
                _metric(
                  Icons.assignment_late_rounded,
                  pendingCount,
                  'Pending',
                  const Color(0xFFE30C4D),
                  const Color(0xFFFFEDF2),
                  onPending,
                ),
              ],
            ),
            const SizedBox(height: 22),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    "Today's Schedule",
                    style: TextStyle(
                      color: _homeInk,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (onClearSchedule != null)
                  TextButton(
                    onPressed: onClearSchedule,
                    child: const Text('Clear'),
                  ),
                TextButton(
                  onPressed: onVisits,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.only(left: 4),
                    minimumSize: Size.zero,
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'View All',
                        style: TextStyle(
                          color: Color(0xFF4514EE),
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Icon(
                        Icons.chevron_right,
                        size: 20,
                        color: Color(0xFF4514EE),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (loading)
              const LinearProgressIndicator(
                color: BrandColors.indigo,
                minHeight: 2,
              )
            else if (schedule.isEmpty)
              _emptySchedule()
            else
              _surface(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(children: schedule),
                ),
              ),
            const SizedBox(height: 22),
            const Text(
              'Quick Actions',
              style: TextStyle(
                color: _homeInk,
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _quickAction(
                  attendanceBusy
                      ? Icons.hourglass_top_rounded
                      : Icons.access_time_filled_rounded,
                  attendanceBusy ? 'Working...' : 'Attendance',
                  'Mark your day',
                  const [Color(0xFF2969FF), Color(0xFF3911F4)],
                  onAttendance,
                ),
                _quickAction(
                  Icons.person_add_alt_1_rounded,
                  'Add Lead',
                  'Capture new opportunities',
                  const [Color(0xFF30D47B), Color(0xFF00A48B)],
                  onAddLead,
                ),
                _quickAction(
                  Icons.location_on_rounded,
                  'Site Visit',
                  'Log a site visit',
                  const [Color(0xFFB449E8), Color(0xFF8120CD)],
                  onVisits,
                ),
                _quickAction(
                  Icons.add_task_rounded,
                  'New Task',
                  'Create a task',
                  const [Color(0xFFFFA035), Color(0xFFFF641F)],
                  onTasks,
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );

  Widget _surface({required Widget child, double radius = 16}) => Container(
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(radius),
      boxShadow: const [
        BoxShadow(
          color: Color(0x0A4768A2),
          blurRadius: 24,
          offset: Offset(0, 8),
        ),
      ],
    ),
    child: child,
  );

  Widget _header() => _surface(
    radius: 18,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Open navigation menu',
            onPressed: onMenu,
            icon: const Icon(Icons.menu_rounded, color: _homeInk, size: 27),
          ),
          const Expanded(child: _HomeLogo()),
          IconButton(
            tooltip: 'Notifications',
            onPressed: onNotifications,
            icon: Stack(
              clipBehavior: Clip.none,
              children: [
                const Icon(
                  Icons.notifications_none_rounded,
                  color: _homeInk,
                  size: 27,
                ),
                Positioned(
                  right: -2,
                  top: -1,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: Color(0xFFFF4167),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget _profile() => LayoutBuilder(
    builder: (context, constraints) {
      final narrow = constraints.maxWidth < 345;
      final size = narrow ? 48.0 : 58.0;
      return Row(
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFFE7EDF7),
                  border: Border.all(color: Colors.white, width: 3),
                ),
                padding: const EdgeInsets.all(3),
                child: ClipOval(child: avatar),
              ),
              Positioned(
                right: 2,
                bottom: 1,
                child: Container(
                  width: 13,
                  height: 13,
                  decoration: BoxDecoration(
                    color: const Color(0xFF17CB76),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  greeting,
                  style: const TextStyle(color: _homeMuted, fontSize: 12),
                ),
                const SizedBox(height: 2),
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _homeInk,
                    fontSize: narrow ? 16 : 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                const Text(
                  "Let's make today productive",
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: _homeMuted, fontSize: 10.5),
                ),
                const SizedBox(height: 7),
                Container(
                  key: const ValueKey('profile-date-row'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEBEEFF),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.wb_sunny_rounded,
                        color: Color(0xFFFFA300),
                        size: 16,
                      ),
                      const SizedBox(width: 7),
                      Flexible(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            DateFormat('EEE, d MMM yyyy').format(date),
                            maxLines: 1,
                            style: const TextStyle(
                              color: Color(0xFF6F7D96),
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    },
  );

  Widget _metric(
    IconData icon,
    String count,
    String label,
    Color color,
    Color background,
    VoidCallback onTap,
  ) => Expanded(
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(13),
        child: Ink(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [background.withValues(alpha: .6), background],
            ),
            border: Border.all(color: Colors.white, width: 1.3),
            borderRadius: BorderRadius.circular(13),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(9, 10, 5, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: switch (icon) {
                        Icons.handshake_rounded => const [
                          Color(0xFFFFE47D),
                          Color(0xFFFFCA83),
                        ],
                        Icons.apartment_rounded => const [
                          Color(0xFF25DC80),
                          Color(0xFF00A88A),
                        ],
                        Icons.assignment_late_rounded => const [
                          Color(0xFFFF657D),
                          Color(0xFFF30B4D),
                        ],
                        _ => const [Color(0xFF7C54FF), Color(0xFF4514FF)],
                      },
                    ),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(
                    icon,
                    color:
                        icon == Icons.handshake_rounded ? color : Colors.white,
                    size: 21,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  count,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: color,
                    fontSize: 23,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 1),
                Row(
                  children: [
                    Expanded(
                      child: FittedBox(
                        alignment: Alignment.centerLeft,
                        fit: BoxFit.scaleDown,
                        child: Text(
                          label,
                          style: TextStyle(
                            color: color,
                            fontSize: 9,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    Container(
                      width: 18,
                      height: 18,
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.chevron_right, color: color, size: 15),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget _emptySchedule() => _surface(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 20),
      child: Row(
        children: [
          const SizedBox(width: 88, height: 86, child: _ScheduleIllustration()),
          const SizedBox(width: 13),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'No events scheduled for today.',
                  style: TextStyle(
                    color: _homeInk,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(height: 6),
                Text(
                  'Take a moment to plan your day.',
                  style: TextStyle(
                    color: _homeMuted,
                    fontSize: 11,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget _quickAction(
    IconData icon,
    String label,
    String description,
    List<Color> colors,
    VoidCallback onTap,
  ) => Expanded(
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Column(
          children: [
            Container(
              width: 60,
              height: 57,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: colors,
                ),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: colors.last.withValues(alpha: .15),
                    blurRadius: 12,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: Icon(icon, color: Colors.white, size: 29),
            ),
            const SizedBox(height: 8),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                style: const TextStyle(
                  color: _homeInk,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 3),
            Text(
              description,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: _homeMuted,
                fontSize: 9.5,
                height: 1.3,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _HomeLogo extends StatelessWidget {
  const _HomeLogo();

  @override
  Widget build(BuildContext context) => Center(
    child: SizedBox(
      width: 136,
      height: 62,
      child: Image.asset(
        'assets/images/logoAG.png',
        fit: BoxFit.cover,
        semanticLabel: 'automategenie.ai',
      ),
    ),
  );
}

class _ScheduleIllustration extends StatelessWidget {
  const _ScheduleIllustration();

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned.fill(
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFFF2F0FF),
            borderRadius: BorderRadius.circular(30),
          ),
        ),
      ),
      Positioned(
        left: 16,
        top: 19,
        child: Container(
          width: 55,
          height: 58,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            boxShadow: const [
              BoxShadow(color: Color(0x1F7259EB), blurRadius: 12),
            ],
          ),
          child: Column(
            children: [
              Container(
                height: 15,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Color(0xFFB99AFF), Color(0xFF6950FF)],
                  ),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
                ),
              ),
              const SizedBox(height: 6),
              for (var row = 0; row < 3; row++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      for (var dot = 0; dot < 4; dot++)
                        Container(
                          width: 5,
                          height: 5,
                          decoration: const BoxDecoration(
                            color: Color(0xFFDADDEB),
                            shape: BoxShape.circle,
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
      for (final left in [26.0, 55.0])
        Positioned(
          left: left,
          top: 14,
          child: Container(
            width: 6,
            height: 12,
            decoration: BoxDecoration(
              color: const Color(0xFF7047FA),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ),
      Positioned(
        right: 5,
        bottom: 3,
        child: Container(
          width: 28,
          height: 28,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              colors: [Color(0xFFAD8AFF), Color(0xFF7668FC)],
            ),
          ),
          child: const Icon(Icons.schedule, size: 23, color: Colors.white),
        ),
      ),
    ],
  );
}

class HomeNavigationBar extends StatelessWidget {
  const HomeNavigationBar({
    super.key,
    required this.currentIndex,
    required this.onTap,
  });
  final int currentIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
    child: DecoratedBox(
      decoration: const BoxDecoration(gradient: BrandColors.gradient),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 10, 4, 8),
          child: Row(
            children: [
              for (var index = 0; index < 5; index++)
                Expanded(
                  child: Semantics(
                    selected: index == currentIndex,
                    button: true,
                    child: InkWell(
                      onTap: () => onTap(index),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            [
                              Icons.home_rounded,
                              Icons.assignment_outlined,
                              Icons.location_on_outlined,
                              Icons.people_outline_rounded,
                              Icons.more_horiz_rounded,
                            ][index],
                            size: 25,
                            color:
                                index == currentIndex
                                    ? Colors.white
                                    : const Color(0xFFE2DDFF),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            ['Home', 'Tasks', 'Visits', 'Leads', 'More'][index],
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight:
                                  index == currentIndex
                                      ? FontWeight.w700
                                      : FontWeight.w400,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Container(
                            width: 27,
                            height: 4,
                            decoration: BoxDecoration(
                              color:
                                  index == currentIndex
                                      ? Colors.white
                                      : Colors.transparent,
                              borderRadius: BorderRadius.circular(5),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}
