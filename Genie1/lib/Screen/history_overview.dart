import '../utils/widget/pull_to_refresh.dart';
import '../utils/widget/ag_path_loading_indicator.dart';
import 'package:homegenie/utils/theme/brand_theme.dart';
import 'dart:async';
import 'package:homegenie/utils/widget/live_location_service.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import '../utils/widget/glass_card.dart';
import 'package:geolocator/geolocator.dart';
import 'package:homegenie/Screen/login.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:homegenie/utils/api/check_in_out.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../utils/api/event.dart';
import '../utils/api/session_auth.dart';
import '../utils/widget/warning.dart';
import '../utils/api/location_api.dart';
import '../utils/widget/home_back_button.dart';

class HistoryOverview extends StatefulWidget {
  final String eventid;

  const HistoryOverview({super.key, required this.eventid});

  @override
  State<HistoryOverview> createState() => _HistoryOverviewState();
}

class _HistoryOverviewState extends State<HistoryOverview> {
  Map<String, dynamic> eventData = {};
  String? _eventOwnerFullName;

  bool _isLoading = false;
  final bool _isActionInProgress = false;

  late SharedPreferences prefs;

  @override
  void initState() {
    super.initState();
    _checkPing();
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
    prefs = await SharedPreferences.getInstance();
    await _fetchData();
    setState(() {});
  }

  Future<void> _fetchData() async {
    setState(() {
      _isLoading = true;
    });

    await Future.wait([_fetchHistoryOverview()]);

    setState(() {
      _isLoading = false;
    });
  }

  String _formatTime(String? dateTime) {
    if (dateTime == null || dateTime.isEmpty) return "--:--";

    try {
      DateTime dt = DateTime.parse(dateTime);
      String period = dt.hour >= 12 ? "pm" : "am";
      int hour =
          dt.hour > 12
              ? dt.hour - 12
              : dt.hour == 0
              ? 12
              : dt.hour;
      String minute = dt.minute.toString().padLeft(2, '0');
      return "$hour:$minute$period";
    } catch (e) {
      return "--:--";
    }
  }

  String _calculateWorkingHours(String? checkIn, String? checkOut) {
    if (checkIn == null || checkOut == null) return "--:--";

    try {
      DateTime inTime = DateTime.parse(checkIn);
      DateTime outTime = DateTime.parse(checkOut);

      Duration difference = outTime.difference(inTime);

      int hours = difference.inHours;
      int minutes = difference.inMinutes.remainder(60);

      return "${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}";
    } catch (e) {
      return "--:--";
    }
  }

  Future<void> _fetchHistoryOverview() async {
    final response = await Event.eventdetails(widget.eventid, context);

    if (!mounted) return;
    if (response is Map) {
      setState(() {
        eventData = Map<String, dynamic>.from(response);
      });
      final rawEvent = response['event'];
      final owner = rawEvent is Map ? rawEvent['owner']?.toString() : null;
      if (owner != null && owner.trim().isNotEmpty) {
        final fullName = await SessionAuthApi.getUserFullName(owner);
        if (mounted && fullName != null) {
          setState(() => _eventOwnerFullName = fullName);
        }
      }
    }
  }

  String get _eventOwnerDisplayName {
    final fullName = _eventOwnerFullName?.trim() ?? '';
    if (fullName.isNotEmpty) return fullName;
    final owner = eventData['event']?['owner']?.toString().trim() ?? '';
    return owner.contains('@') ? 'User' : owner;
  }

  String _getParticipantsTitles() {
    final participants = eventData['reference_details'];
    if (participants == null || participants is! List) return '';

    List<String> titles =
        participants
            .map<String>((p) => "${p['opportunity_from']}-${p['party_name']}")
            .toList();

    return titles.join(', ');
  }

  Future<String> _getCurrentLocationAddress() async {
    try {
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      final address = await LocationHelper.getAddressFromCoordinates(
        position.latitude,
        position.longitude,
      );

      if (address.isNotEmpty) {
        return address;
      } else {
        return "Unknown location";
      }
    } catch (e) {
      print("Error fetching location: $e");
      return "Error fetching location";
    }
  }

  void launchDialer(String phoneNumber) async {
    final Uri dialUri = Uri(scheme: 'tel', path: phoneNumber);
    if (await canLaunchUrl(dialUri)) {
      await launchUrl(dialUri, mode: LaunchMode.externalApplication);
    } else {
      throw 'Could not launch $dialUri';
    }
  }

  void openWhatsAppChat(String phoneNumber) async {
    final cleanedNumber = phoneNumber.replaceAll(RegExp(r'\D'), '');
    final formattedNumber =
        cleanedNumber.startsWith('91') ? cleanedNumber : '91$cleanedNumber';

    final uri = Uri.parse('whatsapp://send?phone=$formattedNumber');

    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      Warning.show(context, 'WhatsApp not installed or cannot open.', 'Error');
    }
  }

  @override
  Widget build(BuildContext context) {
    Color getActionColor() {
      final checkIn = eventData['event']?['custom_check_in'] ?? '';
      final checkOut = eventData['event']?['custom_check_out'] ?? '';

      if ((checkIn == null || checkIn.isEmpty) &&
          (checkOut == null || checkOut.isEmpty)) {
        return Colors.green;
      } else if ((checkIn != null && checkIn.isNotEmpty) &&
          (checkOut == null || checkOut.isEmpty)) {
        return Colors.red;
      }
      return const Color.fromARGB(231, 175, 173, 173);
    }

    String getButtonLabel() {
      final checkIn = eventData['event']?['custom_check_in'] ?? '';
      final checkOut = eventData['event']?['custom_check_out'] ?? '';

      if ((checkIn == null || checkIn.isEmpty) &&
          (checkOut == null || checkOut.isEmpty)) {
        return 'Click Here to Check In';
      } else if ((checkIn != null && checkIn.isNotEmpty) &&
          (checkOut == null || checkOut.isEmpty)) {
        return 'Click Here to Check Out';
      }
      return 'Checked In and Out';
    }

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: brandAppBar(
          leading: const HomeBackButton(color: Colors.white),
          title: Text('History Overview', style: TextStyle(fontSize: 20)),
        ),
        body:
            _isLoading
                ? Center(child: AgPathLoadingIndicator())
                : Padding(
                  padding: EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.start,
                        children: [
                          brandCircleAvatar(
                            radius: 40,
                            child: Text(
                              (eventData['reference_details'] != null &&
                                      eventData['reference_details'].isNotEmpty)
                                  ? (eventData['reference_details'][0]['party_name']
                                              ?.isNotEmpty ??
                                          false
                                      ? eventData['reference_details'][0]['party_name'][0]
                                      : '')
                                  : (eventData['event']?['name']?.isNotEmpty ??
                                          false
                                      ? eventData['event']['name'][0]
                                      : ''),
                              style: TextStyle(
                                fontSize: 18,
                                color: Colors.white,
                              ),
                            ),
                          ),

                          SizedBox(width: 20),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  (eventData['reference_details'] != null &&
                                          eventData['reference_details']
                                              .isNotEmpty)
                                      ? eventData['reference_details'][0]['party_name'] ??
                                          "No Party Name"
                                      : eventData['event']?['name'] ??
                                          "No Event Name",
                                  style: TextStyle(fontSize: 15),
                                ),
                                SizedBox(height: 5),
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Icon(
                                      Icons.location_pin,
                                      color: BrandColors.ink,
                                    ),
                                    SizedBox(width: 5),
                                    Flexible(
                                      child:
                                      //         Text(eventData['event']['subject']??'',
                                      // style: TextStyle(fontSize: 14),
                                      // maxLines: 2,
                                      //           overflow: TextOverflow.ellipsis,
                                      //         ),
                                      FutureBuilder<String>(
                                        future: _getCurrentLocationAddress(),
                                        builder: (context, snapshot) {
                                          if (snapshot.connectionState ==
                                              ConnectionState.waiting) {
                                            return Text(
                                              "Fetching location...",
                                              style: TextStyle(fontSize: 14),
                                            );
                                          } else if (snapshot.hasError) {
                                            return Text(
                                              "Location error",
                                              style: TextStyle(
                                                fontSize: 14,
                                                color: Colors.red,
                                              ),
                                            );
                                          } else {
                                            return Text(
                                              snapshot.data ??
                                                  "Location not found",
                                              style: TextStyle(fontSize: 14),
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            );
                                          }
                                        },
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),

                      Container(
                        child: TabBar(
                          tabs: [Tab(text: 'Check In'), Tab(text: 'Details')],
                        ),
                      ),
                      Expanded(
                        child: TabBarView(
                          children: [
                            PullToRefresh(
                              onRefresh: () async {
                                await _checkPing();
                                _fetchData();
                              },
                              child: SingleChildScrollView(
                                physics: const AlwaysScrollableScrollPhysics(
                                  parent: ClampingScrollPhysics(),
                                ),
                                padding: const EdgeInsets.all(16),
                                child: Container(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.center,
                                    children: [
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,

                                        children: [
                                          SizedBox(height: 250),

                                          GestureDetector(
                                            onTap: () async {},

                                            child: Stack(
                                              alignment: Alignment.center,
                                              children: [
                                                CircleAvatar(
                                                  radius: 80,
                                                  backgroundColor:
                                                      getActionColor(),
                                                  child: CircleAvatar(
                                                    radius: 60,
                                                    backgroundColor:
                                                        const Color.fromARGB(
                                                          255,
                                                          221,
                                                          217,
                                                          217,
                                                        ),
                                                    child: CircleAvatar(
                                                      radius: 40,
                                                      backgroundColor:
                                                          const Color.fromARGB(
                                                            231,
                                                            175,
                                                            173,
                                                            173,
                                                          ),
                                                      child: Icon(
                                                        Icons.touch_app,
                                                        color: Colors.white,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                                if (_isActionInProgress)
                                                  SizedBox(
                                                    height: 40,
                                                    width: 40,
                                                    child:
                                                        CircularProgressIndicator(
                                                          color: Colors.white,
                                                          strokeWidth: 3,
                                                        ),
                                                  ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                      Text(getButtonLabel()),
                                      SizedBox(height: 20),
                                      GlassCard(
                                        padding: const EdgeInsets.all(20),
                                        borderRadius: BorderRadius.circular(12),
                                        child: Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          children: [
                                            Column(
                                              children: [
                                                Icon(Icons.timer),
                                                Text(
                                                  _formatTime(
                                                    eventData['event']?['custom_check_in'] ??
                                                        '',
                                                  ),
                                                ),
                                                Text("Check In"),
                                              ],
                                            ),
                                            Column(
                                              children: [
                                                Icon(Icons.timer),
                                                Text(
                                                  _formatTime(
                                                    eventData['event']?['custom_check_out'] ??
                                                        '',
                                                  ),
                                                ),
                                                Text("Check Out"),
                                              ],
                                            ),
                                            SizedBox(
                                              width: 90,
                                              child: Column(
                                                children: [
                                                  Icon(Icons.timer),
                                                  Text(
                                                    _calculateWorkingHours(
                                                      eventData['event']?['custom_check_in'] ??
                                                          '',
                                                      eventData['event']?['custom_check_out'] ??
                                                          '',
                                                    ),
                                                  ),

                                                  Text("Working Hrs"),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            PullToRefresh(
                              onRefresh: () async {
                                await _checkPing();
                                _fetchData();
                              },
                              child: SingleChildScrollView(
                                physics: const AlwaysScrollableScrollPhysics(
                                  parent: ClampingScrollPhysics(),
                                ),
                                padding: const EdgeInsets.all(16),
                                child: Container(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      SizedBox(height: 20),

                                      Text(
                                        'Name:${eventData['event']?['name'] ?? ''}',
                                      ),
                                      SizedBox(height: 20),
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        children: [
                                          Text(
                                            (eventData['reference_details'] !=
                                                        null &&
                                                    eventData['reference_details']
                                                        .isNotEmpty)
                                                ? 'Mobile Number: ${eventData['reference_details'][0]['contact_mobile'] ?? 'null'}'
                                                : 'Mobile Number: null',
                                          ),
                                          if (eventData['reference_details'] !=
                                                  null &&
                                              eventData['reference_details']
                                                  .isNotEmpty &&
                                              eventData['reference_details'][0]['contact_mobile'] !=
                                                  null &&
                                              eventData['reference_details'][0]['contact_mobile']
                                                  .toString()
                                                  .isNotEmpty)
                                            Row(
                                              children: [
                                                IconButton(
                                                  icon: const Icon(Icons.call),
                                                  onPressed: () {
                                                    final phone =
                                                        eventData['reference_details'][0]['contact_mobile'];
                                                    launchDialer(phone);
                                                  },
                                                ),
                                                IconButton(
                                                  icon: FaIcon(
                                                    FontAwesomeIcons.whatsapp,
                                                    color: Colors.green,
                                                  ),

                                                  onPressed: () {
                                                    final phone =
                                                        eventData['reference_details'][0]['contact_mobile'];
                                                    openWhatsAppChat(phone);
                                                  },
                                                ),
                                              ],
                                            ),
                                        ],
                                      ),
                                      SizedBox(height: 20),

                                      Text('Title:${_getParticipantsTitles()}'),
                                      SizedBox(height: 20),
                                      Text(
                                        (eventData['reference_details'] !=
                                                    null &&
                                                eventData['reference_details']
                                                    .isNotEmpty)
                                            ? 'Product Enquired:${eventData['reference_details'][0]['custom_product_enquired']}'
                                            : 'Product Enquired:null',
                                      ),
                                      SizedBox(height: 20),

                                      Text(
                                        'Distance Travelled:${eventData['event']?['custom_distance'] ?? ''}',
                                      ),
                                      SizedBox(height: 20),

                                      Text(
                                        'Event Type:${eventData['event']?['event_type'] ?? ''}',
                                      ),
                                      SizedBox(height: 20),

                                      Text(
                                        'Subject:${eventData['event']?['subject'] ?? ''}',
                                      ),
                                      SizedBox(height: 20),

                                      Text('Owner:$_eventOwnerDisplayName'),
                                    ],
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
      ),
    );
  }
}
