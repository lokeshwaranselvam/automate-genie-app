import 'dart:async';
import 'package:homegenie/utils/widget/live_location_service.dart';
import 'dart:convert';
import 'package:connectivity_plus/connectivity_plus.dart';

import 'attendance_page.dart';
import 'leave_application_page.dart';
import 'site_visits_page.dart';
import 'package:intl/intl.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:homegenie/Screen/login.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:homegenie/Screen/history_list.dart';
import 'package:homegenie/Screen/session_webview.dart';
import 'pending_work_page.dart';
import 'pending_work_overview_page.dart';
import 'lead_creation_page.dart';
import 'expense_claim_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import '../utils/widget/action_bottom.dart';
import '../utils/widget/warning.dart';
import '../utils/api/check_in_out.dart';
import '../utils/api/session_auth.dart';
import '../utils/api/session_web_links_api.dart';
import '../utils/api/pending_work_monitor.dart';
import '../utils/api/pending_work_api.dart';
import '../utils/api/event.dart';
import '../utils/api/location_api.dart';
import '../utils/widget/floating_widget.dart';
import '../utils/widget/glass_card.dart';
import '../utils/widget/location_tracker.dart';
import '../utils/navigation/home_navigation.dart';
import '../utils/widget/home_back_button.dart';

class _ScheduleMilestone {
  final DateTime? time;
  final String title;
  final String subtitle;
  final Color color;
  final String eventId;
  final bool clearable;

  const _ScheduleMilestone({
    required this.time,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.eventId,
    this.clearable = false,
  });
}

class Homescreen extends StatefulWidget {
  const Homescreen({super.key});

  @override
  State<Homescreen> createState() => _HomescreenState();
}

class _HomescreenState extends State<Homescreen> with WidgetsBindingObserver {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  double _distance = 0.0;
  String _version = 'Production';
  List eventData = [];
  List<String> officeTypes = [];
  List<Map<String, String>> _sessionWebLinks = [];
  bool _webLinksLoading = false;
  String? _webLinksError;
  int _webLinksRequestId = 0;
  String? _userAvatarUrl;
  String? _sessionSid;
  String? _currentUserFullName;

  Position? _position;
  Timer? _distanceTimer;
  OverlayEntry? _overlayEntry;
  late SharedPreferences prefs;

  bool _isLoading = false;
  bool _checkedIn = false;
  bool _isActionLoading = false;
  bool _attendancePageOpen = false;
  bool _leaveApplicationOpen = false;
  bool _prefsInitialized = false;
  Map<String, dynamic> _attendanceStatusDetails = {};
  int _selectedTab = 0;
  int? _homePendingCount;
  int? _homeTaskTodayCount;
  final GlobalKey<PendingWorkPageState> _pendingWorkPageKey =
      GlobalKey<PendingWorkPageState>();
  StreamSubscription<String>? _pendingWorkUpdatesSubscription;
  Timer? _pendingDashboardRefreshDebounce;
  Timer? _homeScheduleRefreshTimer;
  bool _appIsResumed = true;
  bool _refreshingHomeSchedule = false;
  Set<String> _clearedHomeScheduleIds = {};
  List<Map<String, dynamic>> _cachedHomeScheduleEvents = [];

  final TextEditingController _timeController = TextEditingController();
  final TextEditingController _locationcontroller = TextEditingController();

  String location = "Press the button to get location";

  Future<bool> _handleLocationPermission() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      Warning.show(context, 'Location services are disabled.', 'Error');
      return false;
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      await Permission.microphone.request();
      await Permission.storage.request();

      if (permission == LocationPermission.denied) {
        Warning.show(context, 'Location permission denied.', 'Error');
        return false;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      Warning.show(
        context,
        'Location permission permanently denied. Please enable it from settings.',
        'Error',
      );
      return false;
    }

    return true;
  }

  void _showDistanceOverlay() {
    _overlayEntry = OverlayEntry(
      builder:
          (context) => Positioned(
            top: 0,
            right: 10,
            child: FloatingDistanceWidget(distance: _distance),
          ),
    );

    Overlay.of(context).insert(_overlayEntry!);

    _distanceTimer = Timer.periodic(Duration(seconds: 5), (_) {
      double dist = LocationTrackerService.calculateTotalDistance();
      setState(() {
        _distance = dist;
      });
      _overlayEntry?.markNeedsBuild();
    });
  }

  void _removeDistanceOverlay() {
    _distanceTimer?.cancel();
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  Future<void> _getCurrentLocation() async {
    bool hasPermission = await _handleLocationPermission();
    if (!hasPermission) return;

    try {
      _position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      await _getAddressFromLatLng(_position!.latitude, _position!.longitude);
    } catch (e) {
      setState(() {
        location = "Failed to get current location.";
      });
    }
  }

  Future<void> _getAddressFromLatLng(double lat, double lon) async {
    String result = await LocationHelper.getAddressFromCoordinates(lat, lon);

    setState(() {
      location = result;
      _locationcontroller.text = result;
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pendingWorkUpdatesSubscription = PendingWorkMonitor.newEntrySections
        .listen((_) {
          _pendingDashboardRefreshDebounce?.cancel();
          _pendingDashboardRefreshDebounce = Timer(
            const Duration(milliseconds: 250),
            () {
              final refresh = _pendingWorkPageKey.currentState?.refresh();
              if (refresh != null) unawaited(refresh);
            },
          );
        });
    _checkPing();
    unawaited(_loadHomePendingCount());
    unawaited(_loadHomeTaskTodayCount());
    _homeScheduleRefreshTimer = Timer.periodic(const Duration(seconds: 30), (
      _,
    ) {
      if (_appIsResumed && _prefsInitialized && _selectedTab == 0) {
        unawaited(_refreshHomeSchedule());
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    HomeNavigation.register(
      owner: this,
      route: ModalRoute.of(context),
      selectHome: _returnToHome,
    );
  }

  void _returnToHome() {
    if (!mounted) return;
    final shouldRefresh =
        _selectedTab != 0 || _attendancePageOpen || _leaveApplicationOpen;
    setState(() {
      _attendancePageOpen = false;
      _leaveApplicationOpen = false;
      _selectedTab = 0;
    });
    unawaited(_loadHomeTaskTodayCount());
    if (shouldRefresh) unawaited(_refreshHomeSchedule());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_prefsInitialized) return;
    if (state == AppLifecycleState.resumed) {
      _appIsResumed = true;
      PendingWorkMonitor.start();
      if (_selectedTab == 0) unawaited(_refreshHomeSchedule());
    } else {
      _appIsResumed = false;
      PendingWorkMonitor.stop();
    }
  }

  @override
  void dispose() {
    HomeNavigation.unregister(this);
    WidgetsBinding.instance.removeObserver(this);
    PendingWorkMonitor.stop();
    _homeScheduleRefreshTimer?.cancel();
    _pendingDashboardRefreshDebounce?.cancel();
    final subscription = _pendingWorkUpdatesSubscription;
    if (subscription != null) unawaited(subscription.cancel());
    super.dispose();
  }

  Future<void> _checkPing() async {
    try {
      var connectivity = await Connectivity().checkConnectivity();

      bool noInternet = false;

      if (connectivity == ConnectivityResult.none) {
        noInternet = true;
      }

      if (connectivity.contains(ConnectivityResult.none)) {
        noInternet = true;
      }
      if (noInternet) {
        Warning.show(
          context,
          'No Internet Connection! Please check your network.',
          'Error',
        );
        return;
      }

      var pingResult = await Check.pingpong();
      if (pingResult == false) {
        Warning.show(
          context,
          'ERP Site is not in working condition! Please try again later.',
          'Error',
        );
      } else {
        final prefs = await SharedPreferences.getInstance();
        final token = prefs.getString('token') ?? "";
        final email = prefs.getString('email') ?? "";

        final sessionValid = await Check.sessionActive(token, email);

        if (!sessionValid) {
          Warning.show(
            context,
            'Session expired. Please log in again.',
            'Error',
          );
          await LiveLocationService.stopForSignOut();
          await prefs.clear();
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => const Login()),
            (route) => false,
          );
          return;
        }

        _init();
      }
    } catch (e) {
      print('Error during ping: $e');
    }
  }

  Future<void> _init() async {
    setState(() {
      _isLoading = true;
    });

    try {
      prefs = await SharedPreferences.getInstance();
      _prefsInitialized = true;
      await _loadHomeScheduleCache();
      unawaited(_loadSessionWebLinks());
      unawaited(_loadUserAvatar());
      await Future.wait([
        _setCurrentTime(),
        _getCurrentLocation(),
        _fetchEventList(),
        _fetchOfficeType(),
        _getStatusFromServer(),
        _loadVersion(),
      ]);
    } catch (e) {
      print("Initialization error: $e");
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        PendingWorkMonitor.start();
      }
    }
  }

  Future<void> _loadSessionWebLinks({bool forceRefresh = false}) async {
    if (_webLinksLoading && !forceRefresh) return;
    final requestId = ++_webLinksRequestId;
    if (mounted) {
      setState(() {
        _webLinksLoading = true;
        _webLinksError = null;
        // Remove old role-based links while the server's current permissions load.
        _sessionWebLinks = [];
      });
    }
    try {
      final links = await SessionWebLinksApi.getLinksForCurrentUser();
      if (!mounted || requestId != _webLinksRequestId) return;
      setState(() {
        _sessionWebLinks = links;
        _webLinksLoading = false;
      });
    } catch (_) {
      if (!mounted || requestId != _webLinksRequestId) return;
      setState(() {
        _sessionWebLinks = [];
        _webLinksLoading = false;
        _webLinksError =
            'Could not refresh web pages. Check your connection and try again.';
      });
    }
  }

  IconData _webLinkIcon(String? iconName) {
    switch (iconName) {
      case 'timeline':
        return Icons.timeline;
      case 'inventory':
        return Icons.inventory_2_outlined;
      case 'description':
        return Icons.description_outlined;
      case 'summarize':
        return Icons.summarize_outlined;
      default:
        return Icons.language;
    }
  }

  void _openSessionWebLink(Map<String, String> link) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            (_) => SessionWebView(
              url: link['url'] ?? '',
              title: link['title'] ?? 'Web page',
            ),
      ),
    );
  }

  void _openNavigationDrawer() {
    _scaffoldKey.currentState?.openDrawer();
  }

  Future<void> _loadUserAvatar() async {
    try {
      final results = await Future.wait([
        SessionAuthApi.getCurrentUserAvatarUrl(),
        SessionAuthApi.getSessionId(),
        SessionAuthApi.getCurrentUserFullName(),
      ]);
      if (!mounted) return;
      setState(() {
        _userAvatarUrl = results[0];
        _sessionSid = results[1];
        _currentUserFullName = results[2];
      });
    } catch (_) {
      // Keep the existing account icon when the ERP image is unavailable.
    }
  }

  Widget _buildUserAvatar(double size, {Color fallbackColor = Colors.white}) {
    final imageUrl = _userAvatarUrl;
    if (imageUrl == null || imageUrl.isEmpty) {
      return Icon(Icons.account_circle, color: fallbackColor, size: size);
    }

    final imageUri = Uri.tryParse(imageUrl);
    final siteHost = Uri.tryParse(dotenv.env['SITE_URL']?.trim() ?? '')?.host;
    final headers =
        imageUri != null &&
                siteHost != null &&
                imageUri.host == siteHost &&
                _sessionSid != null
            ? {'Cookie': 'sid=$_sessionSid'}
            : null;

    return ClipOval(
      child: Image.network(
        imageUrl,
        width: size,
        height: size,
        fit: BoxFit.cover,
        headers: headers,
        errorBuilder:
            (context, error, stackTrace) =>
                Icon(Icons.account_circle, color: fallbackColor, size: size),
      ),
    );
  }

  Future<void> _loadVersion() async {
    final packageInfo = await PackageInfo.fromPlatform();
    setState(() {
      _version = '${packageInfo.version}+${packageInfo.buildNumber}';
    });
  }

  bool isAfterMidnight() {
    final now = DateTime.now();
    return now.hour == 0 && now.minute >= 1;
  }

  Future<void> _fetchData() async {
    bool ok = await _safeCheckPing();
    if (!ok) return;

    await Future.wait([
      _setCurrentTime(),
      _getCurrentLocation(),
      _fetchEventList(),
      _fetchOfficeType(),

      _getStatusFromServer(),

      _loadVersion(),
    ]);

    if (mounted) {
      setState(() {});
    }
  }

  Future<bool> _safeCheckPing() async {
    try {
      var connectivity = await Connectivity().checkConnectivity();

      final list = connectivity;

      if (list.contains(ConnectivityResult.none)) {
        Warning.show(
          context,
          'No Internet Connection! Please check your network.',
          'Error',
        );
        return false;
      }

      var pingResult = await Check.pingpong();

      if (pingResult == false) {
        Warning.show(
          context,
          'ERP Site is not in working condition! Please try again later.',
          'Error',
        );
        return false;
      }

      return true;
    } catch (e) {
      print("Ping error: $e");
      return false;
    }
  }

  bool _previousDayPendingCheckout = false;
  Future<void> _getStatusFromServer() async {
    final email = prefs.getString('email');
    if (email == null) return;

    final response = await Check.getStatus(email);

    setState(() {
      if (response is Map) {
        _attendanceStatusDetails = Map<String, dynamic>.from(response);
      }
      _checkedIn = response["checked_in"] ?? false;
      _previousDayPendingCheckout =
          response["previous_checkout_pending"] ?? false;
    });
  }

  Future<void> _fetchOfficeType() async {
    var response = await Event.office_type_list(
      prefs.getString('email') ?? '',
      context,
    );
    officeTypes = response.map((e) => e.toString()).toList();
  }

  Future<void> _fetchEventList() async {
    final response = await Event.eventList(prefs.getString('email') ?? '');
    final withProgress = await _loadEventTimelineDetails(response);
    eventData = await _mergeHomeScheduleEvents(withProgress);
  }

  String get _homeScheduleDateKey =>
      DateFormat('yyyy-MM-dd').format(DateTime.now());

  String get _homeScheduleCacheKey =>
      'home_schedule_events_$_homeScheduleDateKey';

  String get _homeScheduleClearedKey =>
      'home_schedule_cleared_$_homeScheduleDateKey';

  Future<void> _loadHomeScheduleCache() async {
    _clearedHomeScheduleIds =
        (prefs.getStringList(_homeScheduleClearedKey) ?? <String>[]).toSet();
    final rawCache = prefs.getString(_homeScheduleCacheKey);
    if (rawCache == null || rawCache.isEmpty) return;

    try {
      final decoded = jsonDecode(rawCache);
      if (decoded is List) {
        _cachedHomeScheduleEvents =
            decoded
                .whereType<Map>()
                .map((item) => Map<String, dynamic>.from(item))
                .toList();
      }
    } catch (error) {
      debugPrint('Could not read saved Home schedule: $error');
      _cachedHomeScheduleEvents = [];
    }
  }

  Future<void> _persistHomeScheduleCache() async {
    if (!_prefsInitialized) return;
    await prefs.setString(
      _homeScheduleCacheKey,
      jsonEncode(_cachedHomeScheduleEvents),
    );
    await prefs.setStringList(
      _homeScheduleClearedKey,
      _clearedHomeScheduleIds.toList(),
    );
  }

  String? _homeEventId(Map<String, dynamic> event) {
    final id = event['name']?.toString().trim() ?? '';
    return id.isEmpty ? null : id;
  }

  bool _hasHomeEventCheckout(Map<String, dynamic> event) {
    final value = event['custom_check_out']?.toString().trim() ?? '';
    return value.isNotEmpty;
  }

  Map<String, dynamic> _mergeEventSnapshot(
    Map<String, dynamic> saved,
    Map<String, dynamic> fresh,
  ) {
    final merged = <String, dynamic>{...saved, ...fresh};
    for (final field in ['custom_check_in', 'custom_check_out']) {
      final freshValue = fresh[field]?.toString().trim() ?? '';
      final savedValue = saved[field]?.toString().trim() ?? '';
      if (freshValue.isEmpty && savedValue.isNotEmpty) {
        merged[field] = saved[field];
      }
    }
    return merged;
  }

  Future<List<dynamic>> _mergeHomeScheduleEvents(
    List<dynamic> latestEvents,
  ) async {
    if (latestEvents.isNotEmpty &&
        latestEvents.first is Map &&
        latestEvents.first['status'] == 'Error') {
      return _cachedHomeScheduleEvents;
    }

    final today = DateUtils.dateOnly(DateTime.now());
    final savedById = <String, Map<String, dynamic>>{};
    for (final event in _cachedHomeScheduleEvents) {
      final id = _homeEventId(event);
      if (id != null) savedById[id] = event;
    }
    final latestIds = <String>{};
    final merged = <dynamic>[];
    final todaySnapshots = <String, Map<String, dynamic>>{};

    for (final item in latestEvents) {
      if (item is! Map) {
        merged.add(item);
        continue;
      }

      final fresh = Map<String, dynamic>.from(item);
      final id = _homeEventId(fresh);
      if (id != null) latestIds.add(id);
      final event =
          id != null && savedById.containsKey(id)
              ? _mergeEventSnapshot(savedById[id]!, fresh)
              : fresh;
      final startsOn = _scheduleDateTime(event['starts_on']);
      final isToday = startsOn != null && DateUtils.isSameDay(startsOn, today);

      if (id != null && isToday) {
        if (_clearedHomeScheduleIds.contains(id)) continue;
        todaySnapshots[id] = event;
      }
      merged.add(event);
    }

    final missingSavedEvents = _cachedHomeScheduleEvents.where((event) {
      final id = _homeEventId(event);
      return id != null &&
          !latestIds.contains(id) &&
          !_clearedHomeScheduleIds.contains(id);
    });

    final retainedCompletedEvents = await Future.wait(
      missingSavedEvents.map((savedEvent) async {
        final id = _homeEventId(savedEvent)!;
        final details = await Event.eventTimelineDetails(id);
        if (details == null) return null;
        final detailEvent = details['event'];
        final detailFields =
            detailEvent is Map
                ? Map<String, dynamic>.from(detailEvent)
                : details;
        final event = _mergeEventSnapshot(savedEvent, detailFields);
        final startsOn = _scheduleDateTime(event['starts_on']);
        if (!_hasHomeEventCheckout(event) ||
            startsOn == null ||
            !DateUtils.isSameDay(startsOn, today)) {
          return null;
        }
        return event;
      }),
    );

    for (final event
        in retainedCompletedEvents.whereType<Map<String, dynamic>>()) {
      final id = _homeEventId(event);
      if (id == null) continue;
      todaySnapshots[id] = event;
      merged.add(event);
    }

    todaySnapshots.removeWhere((id, _) => _clearedHomeScheduleIds.contains(id));
    merged.removeWhere((item) {
      if (item is! Map) return false;
      final id = item['name']?.toString();
      return id != null && _clearedHomeScheduleIds.contains(id);
    });
    _cachedHomeScheduleEvents = todaySnapshots.values.toList();
    await _persistHomeScheduleCache();
    return merged;
  }

  void _clearHomeScheduleEvents(Set<String> eventIds) {
    final idsToClear = eventIds.where((id) => id.isNotEmpty).toSet();
    if (idsToClear.isEmpty) return;
    setState(() {
      _clearedHomeScheduleIds.addAll(idsToClear);
      eventData =
          eventData
              .where(
                (item) =>
                    item is! Map ||
                    !idsToClear.contains(item['name']?.toString()),
              )
              .toList();
      _cachedHomeScheduleEvents.removeWhere(
        (event) => idsToClear.contains(_homeEventId(event)),
      );
    });
    unawaited(_persistHomeScheduleCache());
  }

  Future<List<dynamic>> _loadEventTimelineDetails(List<dynamic> events) async {
    final updated = List<dynamic>.of(events);
    final today = DateUtils.dateOnly(DateTime.now());
    final todayEventIndexes = <int>[];

    for (var index = 0; index < updated.length; index++) {
      final item = updated[index];
      if (item is! Map) continue;
      final startsOn = DateTime.tryParse(item['starts_on']?.toString() ?? '');
      if (startsOn != null && DateUtils.isSameDay(startsOn.toLocal(), today)) {
        todayEventIndexes.add(index);
      }
    }

    todayEventIndexes.sort((firstIndex, secondIndex) {
      final first = DateTime.tryParse(
        (updated[firstIndex] as Map)['starts_on']?.toString() ?? '',
      );
      final second = DateTime.tryParse(
        (updated[secondIndex] as Map)['starts_on']?.toString() ?? '',
      );
      if (first == null || second == null) return 0;
      return first.compareTo(second);
    });
    final timelineIndexes = todayEventIndexes.take(4).toList();

    await Future.wait(
      timelineIndexes.map((index) async {
        final event = Map<String, dynamic>.from(updated[index] as Map);
        final eventName = event['name']?.toString();
        if (eventName == null || eventName.isEmpty) return;

        final details = await Event.eventTimelineDetails(eventName);
        if (details == null) return;
        final detailEvent = details['event'];
        final detailFields =
            detailEvent is Map
                ? Map<String, dynamic>.from(detailEvent)
                : details;
        updated[index] = {...event, ...detailFields};
      }),
    );

    return updated;
  }

  Future<void> _refreshHomeSchedule() async {
    if (_refreshingHomeSchedule || !_prefsInitialized) return;
    final email = prefs.getString('email') ?? '';
    if (email.isEmpty) return;

    _refreshingHomeSchedule = true;
    try {
      final latestEvents = await Event.eventList(email);
      if (!mounted) return;

      if (latestEvents.isNotEmpty) {
        final first = latestEvents.first;
        if (first is Map && first['status'] == 'Error') return;
      }

      final latestWithProgress = await _loadEventTimelineDetails(latestEvents);
      if (!mounted) return;
      final mergedEvents = await _mergeHomeScheduleEvents(latestWithProgress);
      if (!mounted) return;
      setState(() => eventData = mergedEvents);
    } catch (error) {
      debugPrint('Home schedule refresh failed: $error');
    } finally {
      _refreshingHomeSchedule = false;
    }
  }

  void _selectBottomTab(int index) {
    if (index == 0) unawaited(_loadHomeTaskTodayCount());
    if (_attendancePageOpen || _leaveApplicationOpen) {
      setState(() {
        _attendancePageOpen = false;
        _leaveApplicationOpen = false;
        _selectedTab = index;
      });
      if (index == 0) unawaited(_refreshHomeSchedule());
      return;
    }
    if (_selectedTab == index) {
      if (index == 0) unawaited(_refreshHomeSchedule());
      return;
    }
    setState(() => _selectedTab = index);
    if (index == 0) unawaited(_refreshHomeSchedule());
  }

  Future<void> _openPendingWork() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const PendingWorkOverviewPage()),
    );
    if (mounted) unawaited(_loadHomePendingCount());
  }

  Future<void> _setCurrentTime() async {
    String formattedTime = DateFormat('hh:mm a').format(DateTime.now());
    _timeController.text = formattedTime;
  }

  Widget _buildDashboardsTab() {
    return RefreshIndicator(
      onRefresh: () => _loadSessionWebLinks(forceRefresh: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Your assigned dashboards and workspace pages',
            style: TextStyle(color: Colors.black54),
          ),
          const SizedBox(height: 14),
          if (_webLinksLoading)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: CircularProgressIndicator(),
              ),
            ),
          if (_webLinksError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                _webLinksError!,
                style: const TextStyle(color: Colors.redAccent),
              ),
            ),
          if (!_webLinksLoading && _sessionWebLinks.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 28),
              child: Center(
                child: Text('No dashboards assigned to this account.'),
              ),
            ),
          ..._sessionWebLinks.map(
            (link) => GlassCard(
              margin: const EdgeInsets.only(bottom: 10),
              child: ListTile(
                leading: Icon(
                  _webLinkIcon(link['icon']),
                  color: Colors.blueAccent,
                ),
                title: Text(link['title'] ?? 'Dashboard'),
                trailing: const Icon(Icons.open_in_new, size: 18),
                onTap: () => _openSessionWebLink(link),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAttendanceTab() {
    return const SessionWebView(
      url: 'https://16.itgenie.online/GOAD',
      title: 'Attendance',
    );
  }

  void _showLogoutDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (BuildContext alertContext) {
        return AlertDialog(
          title: Text("Logout"),
          content: Text("Are you sure you want to logout?"),
          actions: <Widget>[
            TextButton(
              child: Text("Cancel", style: TextStyle(color: Colors.blueAccent)),
              onPressed: () {
                Navigator.of(alertContext).pop();
              },
            ),
            TextButton(
              child: Text("Logout", style: TextStyle(color: Colors.blueAccent)),
              onPressed: () async {
                var connectivity = await Connectivity().checkConnectivity();

                bool noInternet = false;

                if (connectivity == ConnectivityResult.none) {
                  noInternet = true;
                }

                if (connectivity.contains(ConnectivityResult.none)) {
                  noInternet = true;
                }

                if (noInternet) {
                  Warning.show(
                    context,
                    'No Internet Connection! Please check your network.',
                    'Error',
                  );
                  return;
                }
                var pingResult = await Check.pingpong();

                Navigator.of(alertContext).pop();

                if (pingResult == false) {
                  Warning.show(
                    context,
                    'ERP Site is not in working condition! Please try again later.',
                    'Error',
                  );
                  return;
                } else {
                  await SessionAuthApi.logout();
                  SharedPreferences prefs =
                      await SharedPreferences.getInstance();
                  await LiveLocationService.stopForSignOut();
                  await prefs.clear();

                  await Future.delayed(Duration(milliseconds: 300));

                  if (mounted) {
                    Navigator.of(context).pushAndRemoveUntil(
                      MaterialPageRoute(builder: (_) => const Login()),
                      (route) => false,
                    );
                  }
                }
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _loadHomePendingCount() async {
    try {
      final dashboard = await PendingWorkApi.getMobileDashboard();
      const sections = [
        'stock',
        'manufacturing',
        'projects',
        'same_area_city',
        'opportunities',
        'overdue_followups',
        'overdue_closing',
        'draft_delivery_plans',
      ];
      final rawAvailable = dashboard['available_sections'];
      final availableSections =
          rawAvailable is List
              ? rawAvailable.map((section) => section.toString()).toSet()
              : sections
                  .where(
                    (key) =>
                        (dashboard[key] as Map?)?.containsKey('count') == true,
                  )
                  .toSet();
      final count = sections.fold<int>(0, (sum, key) {
        if (!availableSections.contains(key)) return sum;
        final value = (dashboard[key] as Map?)?['count'];
        return sum +
            (value is num ? value.toInt() : int.tryParse('$value') ?? 0);
      });
      if (mounted) setState(() => _homePendingCount = count);
    } catch (_) {
      if (mounted) setState(() => _homePendingCount = null);
    }
  }

  Future<void> _loadHomeTaskTodayCount() async {
    try {
      final tasks = await PendingWorkApi.getPendingTasks();
      final count =
          tasks.where((task) {
            final status =
                (task['task_status'] ??
                        task['todo_status'] ??
                        task['status'] ??
                        task['state'] ??
                        '')
                    .toString()
                    .toLowerCase();
            return status != 'completed' &&
                status != 'complete' &&
                status != 'closed' &&
                status != 'done';
          }).length;
      if (mounted) setState(() => _homeTaskTodayCount = count);
    } catch (_) {
      if (mounted) setState(() => _homeTaskTodayCount = null);
    }
  }

  List<Map<String, dynamic>> get _todaySchedule {
    final today = DateUtils.dateOnly(DateTime.now());
    return eventData
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .where((event) {
          final startsOn = DateTime.tryParse(
            event['starts_on']?.toString() ?? '',
          );
          return startsOn != null &&
              DateUtils.isSameDay(startsOn.toLocal(), today);
        })
        .toList()
      ..sort((a, b) {
        final first = DateTime.tryParse(a['starts_on']?.toString() ?? '');
        final second = DateTime.tryParse(b['starts_on']?.toString() ?? '');
        if (first == null || second == null) return 0;
        return first.compareTo(second);
      });
  }

  int get _assignedIncompleteSiteVisitCount =>
      eventData
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .where(_isSiteVisitEvent)
          .where((event) {
            final checkout = event['custom_check_out']?.toString().trim() ?? '';
            final status = event['status']?.toString().toLowerCase() ?? '';
            return event['_visit_completed_history'] != true &&
                checkout.isEmpty &&
                status != 'completed' &&
                status != 'closed' &&
                status != 'cancelled' &&
                status != 'canceled';
          })
          .length;

  bool _isSiteVisitEvent(Map<String, dynamic> event) {
    final type = [
      event['event_type'],
      event['event_category'],
      event['custom_event_type'],
      event['purpose'],
      event['custom_purpose'],
      event['event_purpose'],
      event['subject'],
    ].map((value) => value?.toString().toLowerCase() ?? '').join(' ');
    final normalized = type.replaceAll(RegExp(r'[^a-z]'), '');
    return normalized.contains('visit') ||
        normalized.contains('inspection') ||
        normalized.contains('installation');
  }

  void _onSiteVisitsUpdated(List<Map<String, dynamic>> visits) {
    if (!mounted) return;
    setState(() => eventData = visits);
    unawaited(_refreshHomeSchedule());
  }

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good Morning';
    if (hour < 17) return 'Good Afternoon';
    return 'Good Evening';
  }

  String _scheduleTime(Map<String, dynamic> event) {
    final startsOn = DateTime.tryParse(event['starts_on']?.toString() ?? '');
    return startsOn == null
        ? '—'
        : DateFormat('hh:mm a').format(startsOn.toLocal());
  }

  DateTime? _scheduleDateTime(dynamic value) {
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty) return null;
    return DateTime.tryParse(text)?.toLocal();
  }

  String _milestoneTime(DateTime? time) {
    return time == null ? '—' : DateFormat('hh:mm a').format(time);
  }

  List<_ScheduleMilestone> _scheduleMilestones(Map<String, dynamic> event) {
    final subject = event['subject']?.toString().trim() ?? '';
    final location = event['custom_location']?.toString().trim() ?? '';
    final eventType = event['event_type']?.toString().trim() ?? '';
    final checkIn = _scheduleDateTime(event['custom_check_in']);
    final checkOut = _scheduleDateTime(event['custom_check_out']);
    final eventId = _homeEventId(event) ?? '';
    final siteVisit = _isSiteVisitEvent(event);
    final summary = [
      subject,
      if (location.isNotEmpty) location,
    ].where((part) => part.isNotEmpty).join(' · ');

    final milestones = <_ScheduleMilestone>[
      _ScheduleMilestone(
        time: _scheduleDateTime(event['starts_on']),
        title: 'Event Scheduled',
        subtitle: summary.isEmpty ? eventType : summary,
        color: const Color(0xFF4388D8),
        eventId: eventId,
      ),
    ];

    if (checkIn != null) {
      milestones.add(
        _ScheduleMilestone(
          time: checkIn,
          title: 'On Customer Site',
          subtitle: location.isNotEmpty ? location : subject,
          color:
              checkOut == null
                  ? const Color(0xFFE6A23C)
                  : const Color(0xFF16A36A),
          eventId: eventId,
        ),
      );
    }

    if (checkOut != null) {
      milestones.add(
        _ScheduleMilestone(
          time: checkOut,
          title: 'Event Completed',
          subtitle: summary.isEmpty ? eventType : summary,
          color: const Color(0xFF16A36A),
          eventId: eventId,
          clearable: eventId.isNotEmpty && !siteVisit,
        ),
      );

      if (siteVisit) {
        milestones.add(
          _ScheduleMilestone(
            time: checkOut,
            title: 'Site Visit Completed',
            subtitle: location.isNotEmpty ? location : subject,
            color: const Color(0xFF16A36A),
            eventId: eventId,
            clearable: eventId.isNotEmpty,
          ),
        );
      }
    }

    return milestones;
  }

  Widget _buildHomeDashboard() {
    final todayEvents = _todaySchedule;
    final displayEvents = todayEvents.take(4).toList();
    final scheduleMilestones =
        displayEvents.expand(_scheduleMilestones).toList();
    final clearableEventIds =
        scheduleMilestones
            .where((milestone) => milestone.clearable)
            .map((milestone) => milestone.eventId)
            .where((eventId) => eventId.isNotEmpty)
            .toSet();
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: () async {
          await Future.wait([
            _fetchData(),
            _loadHomePendingCount(),
            _loadHomeTaskTodayCount(),
            _loadSessionWebLinks(forceRefresh: true),
          ]);
        },
        color: const Color(0xFF1768C4),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 22),
          children: [
            _buildHomeTopBar(),
            const SizedBox(height: 17),
            _buildHomeProfile(),
            const SizedBox(height: 17),
            Row(
              children: [
                Expanded(
                  child: _buildMetricCard(
                    icon: Icons.event_available_rounded,
                    count:
                        _homeTaskTodayCount?.toString().padLeft(2, '0') ?? '—',
                    label: 'Tasks Today',
                    color: const Color(0xFF2D7DD2),
                    background: const Color(0xFFEAF3FF),
                    onTap: () => setState(() => _selectedTab = 1),
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: _buildMetricCard(
                    icon: Icons.apartment_rounded,
                    count: _assignedIncompleteSiteVisitCount.toString().padLeft(
                      2,
                      '0',
                    ),
                    label: 'Site Visits',
                    color: const Color(0xFF149778),
                    background: const Color(0xFFE6F7F2),
                    onTap: () => setState(() => _selectedTab = 2),
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: _buildMetricCard(
                    icon: Icons.handshake_rounded,
                    count: '—',
                    label: 'My Leads',
                    color: const Color(0xFFBE8A18),
                    background: const Color(0xFFFFF5DD),
                    onTap: () => setState(() => _selectedTab = 3),
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: _buildMetricCard(
                    icon: Icons.assignment_late_rounded,
                    count: _homePendingCount?.toString().padLeft(2, '0') ?? '—',
                    label: 'Pending',
                    color: const Color(0xFFD95060),
                    background: const Color(0xFFFFECEF),
                    onTap: _openPendingWork,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    "Today's Schedule",
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                  ),
                ),
                if (clearableEventIds.isNotEmpty)
                  TextButton(
                    onPressed:
                        () => _clearHomeScheduleEvents(clearableEventIds),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text(
                      'Clear',
                      style: TextStyle(
                        color: Color(0xFF1768C4),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                TextButton(
                  onPressed: () => setState(() => _selectedTab = 2),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.only(left: 8),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text(
                    'View All',
                    style: TextStyle(
                      color: Color(0xFF1768C4),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (_isLoading)
              const LinearProgressIndicator(
                minHeight: 2,
                color: Color(0xFF1768C4),
                backgroundColor: Color(0xFFE8EEF6),
              )
            else if (displayEvents.isEmpty)
              Container(
                padding: const EdgeInsets.symmetric(
                  vertical: 18,
                  horizontal: 4,
                ),
                alignment: Alignment.centerLeft,
                child: const Text(
                  'No events scheduled for today.',
                  style: TextStyle(color: Color(0xFF8A95A5), fontSize: 13),
                ),
              )
            else
              ...List.generate(scheduleMilestones.length, (index) {
                return _buildScheduleRow(
                  scheduleMilestones[index],
                  isLast: index == scheduleMilestones.length - 1,
                );
              }),
            const SizedBox(height: 15),
            const Divider(height: 1, color: Color(0xFFE9EDF2)),
            const SizedBox(height: 17),
            const Text(
              'Quick Actions',
              style: TextStyle(
                color: Color(0xFF202B3C),
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 15),
            Row(
              children: [
                _buildQuickAction(
                  icon:
                      _isActionLoading
                          ? Icons.hourglass_top_rounded
                          : Icons.access_time_filled_rounded,
                  label: _isActionLoading ? 'Working...' : 'Attendance',
                  color: const Color(0xFF1976D2),
                  onTap: _openAttendance,
                ),
                _buildQuickAction(
                  icon: Icons.person_add_alt_1_rounded,
                  label: 'Add Lead',
                  color: const Color(0xFF159B78),
                  onTap: () => setState(() => _selectedTab = 3),
                ),
                _buildQuickAction(
                  icon: Icons.location_on_rounded,
                  label: 'Site Visit',
                  color: const Color(0xFF8D49C6),
                  onTap: () => setState(() => _selectedTab = 2),
                ),
                _buildQuickAction(
                  icon: Icons.add_task_rounded,
                  label: 'New Task',
                  color: const Color(0xFFF07818),
                  onTap: () => setState(() => _selectedTab = 1),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHomeTopBar() {
    return Row(
      children: [
        IconButton(
          tooltip: 'Open navigation menu',
          visualDensity: VisualDensity.compact,
          onPressed: _openNavigationDrawer,
          icon: const Icon(
            Icons.menu_rounded,
            color: Color(0xFF23405F),
            size: 25,
          ),
        ),
        const SizedBox(width: 4),
        SizedBox(
          width: 136,
          height: 62,
          child: Image.asset(
            'assets/images/logoAG.png',
            fit: BoxFit.cover,
            semanticLabel: 'automategenie.ai',
          ),
        ),
        const Spacer(),
        _buildHeaderIcon(Icons.notifications_outlined, () {
          setState(() => _selectedTab = 1);
        }, badge: true),
      ],
    );
  }

  Widget _buildHeaderIcon(
    IconData icon,
    VoidCallback onTap, {
    bool badge = false,
  }) {
    return IconButton(
      visualDensity: VisualDensity.compact,
      onPressed: onTap,
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          Icon(icon, color: const Color(0xFF23405F), size: 23),
          if (badge)
            Positioned(
              right: -3,
              top: -2,
              child: Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: const Color(0xFFE64C5C),
                  border: Border.all(color: Colors.white, width: 1),
                  shape: BoxShape.circle,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildHomeProfile() {
    final displayName = _displayCurrentUserName;
    return Row(
      children: [
        Container(
          width: 57,
          height: 57,
          decoration: BoxDecoration(
            color: const Color(0xFFE6EDF6),
            border: Border.all(color: Colors.white, width: 2),
            shape: BoxShape.circle,
          ),
          child: ClipOval(
            child: _buildUserAvatar(55, fallbackColor: const Color(0xFF7E8DA2)),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _greeting(),
                style: const TextStyle(color: Color(0xFF7A8799), fontSize: 12),
              ),
              const SizedBox(height: 2),
              Text(
                displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFF1D2A3D),
                  fontWeight: FontWeight.w800,
                  fontSize: 17,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String get _displayCurrentUserName {
    final fullName = _currentUserFullName?.trim() ?? '';
    if (fullName.isNotEmpty) return fullName;
    final savedName = prefs.getString('name')?.trim() ?? '';
    final email = prefs.getString('email')?.trim() ?? '';
    if (savedName.isNotEmpty &&
        savedName != email &&
        !savedName.contains('@')) {
      return savedName;
    }
    return 'Employee';
  }

  Widget _buildMetricCard({
    required IconData icon,
    required String count,
    required String label,
    required Color color,
    required Color background,
    required VoidCallback onTap,
  }) {
    return GlassCard(
      tintColor: background.withValues(alpha: 0.72),
      borderRadius: BorderRadius.circular(15),
      onTap: onTap,
      child: SizedBox(
        height: 100,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 10),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Icon(icon, color: color, size: 23),
              Text(
                count,
                style: TextStyle(
                  color: color,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 2,
                style: TextStyle(
                  color: color,
                  fontSize: 9.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildScheduleRow(
    _ScheduleMilestone milestone, {
    required bool isLast,
  }) {
    const rowHeight = 56.0;
    return SizedBox(
      height: rowHeight,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 70,
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                _milestoneTime(milestone.time),
                style: const TextStyle(
                  fontSize: 11,
                  color: Color(0xFF48566A),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          SizedBox(
            width: 18,
            height: rowHeight,
            child: Stack(
              alignment: Alignment.topCenter,
              clipBehavior: Clip.none,
              children: [
                if (!isLast)
                  Positioned(
                    top: 8,
                    bottom: -8,
                    child: Container(
                      width: 1.5,
                      color: const Color(0xFF222222),
                    ),
                  ),
                Container(
                  margin: const EdgeInsets.only(top: 4),
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: milestone.color,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 2, bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          milestone.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF263447),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (milestone.subtitle.isNotEmpty)
                    Text(
                      milestone.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 10,
                        color: Color(0xFF8994A3),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickAction({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
          child: Column(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(icon, size: 23, color: Colors.white),
              ),
              const SizedBox(height: 7),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 10,
                  color: Color(0xFF536174),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openAttendance() async {
    setState(() => _attendancePageOpen = true);
    await _refreshAttendancePage();
  }

  Future<void> _refreshAttendancePage() async {
    await Future.wait([_getStatusFromServer(), _getCurrentLocation()]);
  }

  Future<void> _performAttendanceAction() async {
    final ok = await _safeCheckPing();
    if (!ok || !mounted) return;

    await Action_Bottom.show(
      context: context,
      title: 'Choose Location',
      options: officeTypes,
      isCheckedIn: _checkedIn || _previousDayPendingCheckout,
      onTrackingStarted: _showDistanceOverlay,
      onTrackingStopped: _removeDistanceOverlay,
      onApiStart: () {
        if (mounted) setState(() => _isActionLoading = true);
      },
      onApiEnd: () {
        if (mounted) setState(() => _isActionLoading = false);
        unawaited(_getStatusFromServer());
      },
      onStatusUpdate: (isNowCheckedIn) {
        if (!mounted) return;
        setState(() {
          _previousDayPendingCheckout = false;
          _checkedIn = isNowCheckedIn;
        });
        unawaited(_getStatusFromServer());
      },
    );
  }

  Widget _buildAttendancePage() {
    final mapPosition =
        _position == null
            ? null
            : LatLng(_position!.latitude, _position!.longitude);

    return AttendancePage(
      checkedIn: _checkedIn,
      previousDayPendingCheckout: _previousDayPendingCheckout,
      loading: _isLoading,
      actionLoading: _isActionLoading,
      status: _attendanceStatusDetails,
      position: mapPosition,
      accuracy: _position?.accuracy,
      currentAddress: location,
      onRefresh: _refreshAttendancePage,
      onBack: () => setState(() => _attendancePageOpen = false),
      onOpenHistory: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => HistoryList()),
        );
      },
      onAttendanceAction: _performAttendanceAction,
      onLeaveApplication: () => setState(() => _leaveApplicationOpen = true),
    );
  }

  Widget _buildMoreTab() {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        leading: const HomeBackButton(color: Color(0xFF1768C4)),
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        title: const Text(
          'More',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          _moreTile(
            Icons.fact_check_outlined,
            'Attendance',
            'View attendance and check-in records',
            () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => _buildAttendanceTab()),
              );
            },
          ),
          _moreTile(
            Icons.space_dashboard_outlined,
            'Dashboards',
            'Open assigned dashboards',
            () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder:
                      (_) => Scaffold(
                        appBar: AppBar(
                          leading: const HomeBackButton(),
                          title: const Text('Dashboards'),
                        ),
                        body: _buildDashboardsTab(),
                      ),
                ),
              );
            },
          ),
          _moreTile(
            Icons.history_rounded,
            'Visit History',
            'Review previous visits',
            () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => HistoryList()),
              );
            },
          ),
          _moreTile(
            Icons.receipt_long_outlined,
            'Expense Claim',
            'Submit an expense with its bill photo',
            () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ExpenseClaimPage()),
              );
            },
          ),
          _moreTile(
            Icons.event_available_outlined,
            'All Visits',
            'Browse your schedule',
            () {
              setState(() => _selectedTab = 2);
            },
          ),
          _moreTile(
            Icons.logout_rounded,
            'Log Out',
            'Sign out of automategenie.ai',
            () => _showLogoutDialog(context),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: Text(
                'Version $_version',
                style: const TextStyle(color: Color(0xFF8994A3), fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _moreTile(
    IconData icon,
    String title,
    String subtitle,
    VoidCallback onTap,
  ) {
    return GlassCard(
      margin: const EdgeInsets.only(bottom: 9),
      child: ListTile(
        leading: Icon(icon, color: const Color(0xFF1768C4)),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: onTap,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_prefsInitialized) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return WillPopScope(
      onWillPop: () async {
        if (_leaveApplicationOpen) {
          setState(() => _leaveApplicationOpen = false);
          return false;
        }
        if (_attendancePageOpen) {
          setState(() => _attendancePageOpen = false);
          return false;
        }
        if (_selectedTab != 0) {
          setState(() => _selectedTab = 0);
          return false;
        }
        SystemNavigator.pop();
        return false;
      },
      child: Scaffold(
        key: _scaffoldKey,
        onDrawerChanged: (isOpened) {
          if (isOpened) {
            unawaited(_loadSessionWebLinks(forceRefresh: true));
          }
        },
        appBar: null,
        drawer: Drawer(
          backgroundColor: Colors.white,
          child: Column(
            children: [
              SizedBox(
                height: 120,
                child: DrawerHeader(
                  decoration: BoxDecoration(color: Colors.blue),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 50,
                        height: 50,
                        child: _buildUserAvatar(50),
                      ),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _displayCurrentUserName,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: Colors.white, fontSize: 20),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    ListTile(
                      leading: Icon(Icons.home, color: Colors.blueAccent),
                      title: Text('Home'),
                      onTap: () => Navigator.pop(context),
                    ),
                    ListTile(
                      leading: Icon(Icons.event, color: Colors.blueAccent),
                      title: Text('Events'),
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder:
                                (context) => SiteVisitsPage(
                                  onVisitsUpdated: _onSiteVisitsUpdated,
                                ),
                          ),
                        );
                      },
                    ),
                    ListTile(
                      leading: Icon(Icons.history, color: Colors.blueAccent),
                      title: Text('History'),
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => HistoryList(),
                          ),
                        );
                      },
                    ),
                    ListTile(
                      leading: Icon(
                        Icons.person_add_alt_1_outlined,
                        color: Colors.blueAccent,
                      ),
                      title: Text('Create Lead'),
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const LeadCreationPage(),
                          ),
                        );
                      },
                    ),
                    if (_webLinksLoading)
                      const ListTile(
                        leading: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        title: Text('Loading web pages…'),
                      ),
                    if (!_webLinksLoading && _sessionWebLinks.isEmpty)
                      ListTile(
                        dense: true,
                        leading: const SizedBox(width: 24),
                        title: Text(
                          _webLinksError ??
                              'No web pages assigned to this account.',
                          style: const TextStyle(
                            color: Colors.black54,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ..._sessionWebLinks.map(
                      (link) => ListTile(
                        leading: Icon(
                          _webLinkIcon(link['icon']),
                          color: Colors.blueAccent,
                        ),
                        title: Text(link['title'] ?? 'Web page'),
                        trailing: const Icon(
                          Icons.open_in_new,
                          size: 18,
                          color: Colors.black45,
                        ),
                        onTap: () {
                          Navigator.pop(context);
                          _openSessionWebLink(link);
                        },
                      ),
                    ),
                    ListTile(
                      leading: Icon(Icons.logout, color: Colors.blueAccent),
                      title: Text('Logout'),
                      onTap: () => _showLogoutDialog(context),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12.0),
                child: Text(
                  'Version $_version',
                  style: TextStyle(color: Colors.grey, fontSize: 14),
                ),
              ),
            ],
          ),
        ),
        body:
            _leaveApplicationOpen
                ? LeaveApplicationPage(
                  onBack: () => setState(() => _leaveApplicationOpen = false),
                  onNotifications: () => _selectBottomTab(1),
                )
                : _attendancePageOpen
                ? _buildAttendancePage()
                : IndexedStack(
                  index: _selectedTab,
                  children: [
                    _buildHomeDashboard(),
                    PendingWorkPage(key: _pendingWorkPageKey),
                    _selectedTab == 2
                        ? SiteVisitsPage(onVisitsUpdated: _onSiteVisitsUpdated)
                        : const SizedBox.shrink(),
                    _selectedTab == 3
                        ? const LeadCreationPage()
                        : const SizedBox.shrink(),
                    _buildMoreTab(),
                  ],
                ),
        bottomNavigationBar: BottomNavigationBar(
          currentIndex: _selectedTab,
          onTap: _selectBottomTab,
          type: BottomNavigationBarType.fixed,
          backgroundColor: Colors.white,
          selectedItemColor: const Color(0xFF1768C4),
          unselectedItemColor: const Color(0xFF7F8998),
          selectedFontSize: 10,
          unselectedFontSize: 10,
          showUnselectedLabels: true,
          elevation: 8,
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.home_outlined),
              activeIcon: Icon(Icons.home_rounded),
              label: 'Home',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.assignment_outlined),
              activeIcon: Icon(Icons.assignment_rounded),
              label: 'Tasks',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.location_on_outlined),
              activeIcon: Icon(Icons.location_on_rounded),
              label: 'Visits',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.people_outline_rounded),
              activeIcon: Icon(Icons.people_rounded),
              label: 'Leads',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.more_horiz_rounded),
              activeIcon: Icon(Icons.more_horiz_rounded),
              label: 'More',
            ),
          ],
        ),
      ),
    );
  }
}
