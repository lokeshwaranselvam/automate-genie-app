import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:homegenie/utils/widget/live_location_service.dart';
import 'package:homegenie/Screen/login.dart';
import 'package:intl/intl.dart';
import 'package:flutter/material.dart';
import 'package:homegenie/utils/widget/warning.dart';
import 'package:homegenie/utils/api/check_in_out.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:month_picker_dialog/month_picker_dialog.dart';

import '../utils/api/event.dart';
import '../utils/widget/event_list.dart';
import '../utils/widget/home_back_button.dart';

class EventsPage extends StatefulWidget {
  const EventsPage({super.key});

  @override
  _EventsPageState createState() => _EventsPageState();
}

class _EventsPageState extends State<EventsPage> {
  List<Map<String, dynamic>> eventList = [];
  List<Map<String, dynamic>> filteredEventList = [];
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  late SharedPreferences prefs;

  int selectedDateIndex = 0;
  DateTime selectedMonth = DateTime.now();
  DateTime selectedDate = DateTime.now();
  List<String> days = [];
  List<String> weekDays = [];
  bool isLoading = true;

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
        _searchController.addListener(_onSearchChanged);

        DateTime now = DateTime.now();
        selectedMonth = DateTime(now.year, now.month, 1);
        selectedDate = now;
        selectedDateIndex = now.day - 1;

        _generateDays();

        WidgetsBinding.instance.addPostFrameCallback((_) async {
          await getEventDataForDate(
            DateFormat('yyyy-MM-dd').format(selectedDate),
          );

          Future.delayed(Duration(milliseconds: 50), () {
            _scrollToSelectedDate();
          });
        });
      }
    } catch (e) {
      print('Error during ping: $e');
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    String query = _searchController.text.toLowerCase();
    setState(() {
      filteredEventList =
          eventList.where((event) {
            String subject = event['subject']?.toLowerCase() ?? '';
            return subject.contains(query);
          }).toList();
    });
  }

  void _scrollToSelectedDate() {
    if (!_scrollController.hasClients) return;

    double screenWidth = MediaQuery.of(context).size.width;
    double itemWidth = 54.0;
    double offset =
        (selectedDateIndex * itemWidth) - (screenWidth / 2) + (itemWidth / 2);

    if (offset < 0) offset = 0;

    _scrollController.animateTo(
      offset,
      duration: Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  void _generateDays() {
    days.clear();
    weekDays.clear();
    int totalDays =
        DateTime(selectedMonth.year, selectedMonth.month + 1, 0).day;
    for (int i = 1; i <= totalDays; i++) {
      DateTime date = DateTime(selectedMonth.year, selectedMonth.month, i);
      days.add(DateFormat('dd').format(date));
      weekDays.add(DateFormat('E').format(date));
    }
    setState(() {});
  }

  Future<void> getEventDataForDate(String date) async {
    setState(() {
      isLoading = true;
    });
    try {
      prefs = await SharedPreferences.getInstance();
      List<Map<String, dynamic>> response = await Event.fetchEventListByDate(
        prefs.getString("email") ?? '',
        date,
        context,
      );
      eventList = response;
      filteredEventList = eventList;
    } catch (e) {
      print("❌ Error: $e");
    } finally {
      setState(() {
        isLoading = false;
      });
    }
  }

  String _formatDate(String? dateTime) {
    if (dateTime == null) return "";
    DateTime dt = DateTime.parse(dateTime);
    return "${dt.day.toString().padLeft(2, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.year.toString().substring(2)}";
  }

  String _formatTime(String? dateTime) {
    if (dateTime == null) return "";
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
  }

  List<Widget> getEventWidgets() {
    return filteredEventList.expand<Widget>((event) {
      String initials =
          event['subject'] != null && event['name'].isNotEmpty
              ? event['name'][0]
              : '';
      String title = event['subject'] ?? "No Title";
      String eventType = event['event_type'] ?? '';
      String location = event['custom_location'] ?? '';
      String date = _formatDate(event['starts_on'] ?? '');
      String time = _formatTime(event['starts_on'] ?? '');
      String name = event['name'] ?? '';

      return [
        EventCard(
          name: name,
          initials: initials,
          title: title,
          eventType: eventType,
          location: location,
          date: date,
          time: time,
        ),
        SizedBox(height: 5),
      ];
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const HomeBackButton(color: Colors.white),
        title: Text("Events"),
        backgroundColor: Colors.blue,
      ),
      body:
          isLoading
              ? Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                onRefresh: () async {
                  await _checkPing();
                  await getEventDataForDate(
                    DateFormat('yyyy-MM-dd').format(selectedDate),
                  );
                },
                color: Colors.blueAccent,
                child: SingleChildScrollView(
                  physics: AlwaysScrollableScrollPhysics(),
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            GestureDetector(
                              onTap: () async {
                                showMonthPicker(
                                  context: context,
                                  initialDate: DateTime.now(),
                                ).then((date) {
                                  if (date != null) {
                                    setState(() {
                                      selectedMonth = date;
                                      selectedDate = DateTime(
                                        date.year,
                                        date.month,
                                        1,
                                      );
                                      selectedDateIndex = 0;
                                      _generateDays();
                                    });
                                  }
                                });
                              },
                              child: Row(
                                children: [
                                  Text(
                                    "${DateFormat('MMMM yyyy').format(selectedMonth)} >",
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  SizedBox(width: 10),
                                ],
                              ),
                            ),
                            GestureDetector(
                              onTap: () async {
                                setState(() {
                                  DateTime now = DateTime.now();
                                  selectedMonth = DateTime(
                                    now.year,
                                    now.month,
                                    1,
                                  );
                                  selectedDate = now;
                                  selectedDateIndex = now.day - 1;
                                  _generateDays();
                                });
                                await getEventDataForDate(
                                  DateFormat('yyyy-MM-dd').format(selectedDate),
                                );

                                WidgetsBinding.instance.addPostFrameCallback((
                                  _,
                                ) async {
                                  await Future.delayed(
                                    Duration(milliseconds: 50),
                                    () {
                                      _scrollToSelectedDate();
                                    },
                                  );
                                });
                              },
                              child: Text(
                                "All Events",
                                style: TextStyle(color: Colors.blue),
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(
                        height: 60,
                        child: ListView.builder(
                          controller: _scrollController,
                          scrollDirection: Axis.horizontal,
                          itemCount: days.length,
                          itemBuilder: (context, index) {
                            return GestureDetector(
                              onTap: () {
                                setState(() {
                                  selectedDateIndex = index;
                                  selectedDate = DateTime(
                                    selectedMonth.year,
                                    selectedMonth.month,
                                    int.parse(days[index]),
                                  );
                                  getEventDataForDate(
                                    DateFormat(
                                      'yyyy-MM-dd',
                                    ).format(selectedDate),
                                  );
                                });
                              },
                              child: Container(
                                width: 50,
                                margin: EdgeInsets.symmetric(horizontal: 4),
                                decoration: BoxDecoration(
                                  color:
                                      selectedDateIndex == index
                                          ? Colors.blue
                                          : Colors.white,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: Colors.grey.shade300,
                                  ),
                                ),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      weekDays[index],
                                      style: TextStyle(color: Colors.black),
                                    ),
                                    Text(
                                      days[index],
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                        color:
                                            selectedDateIndex == index
                                                ? Colors.white
                                                : Colors.black,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: TextField(
                          controller: _searchController,
                          decoration: InputDecoration(
                            hintText: "Search Subject",
                            prefixIcon: Icon(Icons.search),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ),
                      ...getEventWidgets(),
                    ],
                  ),
                ),
              ),
    );
  }
}
