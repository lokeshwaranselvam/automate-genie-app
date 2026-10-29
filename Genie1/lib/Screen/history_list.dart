import '../utils/widget/pull_to_refresh.dart';
import '../utils/widget/ag_path_loading_indicator.dart';
import 'package:homegenie/utils/theme/brand_theme.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:homegenie/utils/widget/live_location_service.dart';
import 'package:homegenie/Screen/login.dart';
import 'package:intl/intl.dart';
import '../utils/api/event.dart';
import 'package:flutter/material.dart';
import 'package:homegenie/utils/widget/warning.dart';
import 'package:homegenie/utils/api/check_in_out.dart';
import 'package:homegenie/Screen/history_overview.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/widget/home_back_button.dart';
import '../utils/widget/load_failed_view.dart';

class HistoryList extends StatefulWidget {
  const HistoryList({super.key});

  @override
  State<HistoryList> createState() => _HistoryListState();
}

class _HistoryListState extends State<HistoryList> {
  List<Map<String, dynamic>> historyData = [];
  String searchQuery = '';
  String? errorMessage;
  DateTime? toDate;
  DateTime? fromDate;
  late SharedPreferences prefs;

  bool isLoading = true;
  bool showFilterRow = false;
  bool showSearchBar = false;

  @override
  void initState() {
    super.initState();
    _checkPing();
  }

  void _showLoadError(String message) {
    if (!mounted) return;
    setState(() {
      isLoading = false;
      errorMessage = message;
    });
    Warning.show(context, message, 'Error');
  }

  void _retryLoad() {
    setState(() {
      isLoading = true;
      errorMessage = null;
    });
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
        _showLoadError('No Internet Connection! Please check your network.');
        return;
      }
      var pingResult = await Check.pingpong();
      if (!mounted) return;
      if (pingResult == false) {
        _showLoadError(
          'ERP Site is not in working condition! Please try again later.',
        );
      } else {
        final prefs = await SharedPreferences.getInstance();
        final token = prefs.getString('token') ?? "";
        final email = prefs.getString('email') ?? "";

        final sessionValid = await Check.sessionActive(token, email);
        if (!mounted) return;

        if (!sessionValid) {
          Warning.show(
            context,
            'Session expired. Please log in again.',
            'Error',
          );
          await LiveLocationService.stopForSignOut();
          await prefs.clear();
          if (!mounted) return;
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (_) => const Login()),
            (route) => false,
          );
          return;
        }
        DateTime now = DateTime.now();
        fromDate = now.subtract(const Duration(days: 1));
        toDate = now;

        fetchHistoryData();
      }
    } catch (e) {
      print('Error during ping: $e');
      _showLoadError('Could not reach ERP. Please try again.');
    }
  }

  Future<void> fetchHistoryData() async {
    try {
      prefs = await SharedPreferences.getInstance();
      String username = prefs.getString('email') ?? '';

      final String from = DateFormat('yyyy-MM-dd').format(fromDate!);
      final String to = DateFormat('yyyy-MM-dd').format(toDate!);

      List<dynamic> response = await Event.HistoryList(
        username,
        from,
        to,
        context,
      );

      for (var entry in response) {
        final missing = _getMissingField(entry);

        if (missing != null) {
          String field = missing['field'];
          Map<String, dynamic> badEntry = missing['entry'];

          Warning.show(
            context,
            "Missing required field: $field\n"
                "Entry Name: ${badEntry['name'] ?? 'Unknown'}\n"
                "Please correct the data.",
            "Error",
          );

          setState(() {
            isLoading = false;
          });
          return;
        }
      }

      setState(() {
        historyData =
            response.map<Map<String, dynamic>>((entry) {
              return {
                'remarks': entry['subject'],
                'from_time': DateTime.parse(entry['starts_on']),
                'to_time': DateTime.parse(entry['ends_on']),
                'total_hours': entry['custom_duration'] ?? '',
                'custom_distance': entry['custom_distance'] ?? '',
                'name': entry['name'],
              };
            }).toList();

        isLoading = false;
      });
    } catch (e) {
      setState(() {
        errorMessage = e.toString();
        isLoading = false;
      });
    }
  }

  Map<String, dynamic>? _getMissingField(Map<String, dynamic> entry) {
    List<String> requiredFields = ['subject', 'starts_on', 'ends_on', 'name'];

    for (var field in requiredFields) {
      var value = entry[field];

      if (value == null || value.toString().trim().isEmpty) {
        return {'field': field, 'entry': entry};
      }
    }

    return null;
  }

  double calculateTotalDistance(List<Map<String, dynamic>> data) {
    double totalMeters = 0.0;

    for (var entry in data) {
      String raw = (entry['custom_distance'] ?? '').toLowerCase().trim();

      if (raw.endsWith('km')) {
        final value = raw.replaceAll('km', '').trim();

        try {
          totalMeters += double.parse(value) * 1000;
        } catch (e) {
          final parts = value.split('.');
          double approx = 0.0;
          for (int i = 0; i < parts.length; i++) {
            double part = double.tryParse(parts[i]) ?? 0.0;
            approx += part / (i == 0 ? 1 : (10 * i));
          }
          totalMeters += approx * 1000;
        }
      } else if (raw.endsWith('m')) {
        final value = raw.replaceAll('m', '').trim();
        totalMeters += double.tryParse(value) ?? 0.0;
      }
    }

    return totalMeters / 1000;
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return Scaffold(
        appBar: brandAppBar(
          leading: const HomeBackButton(),
          title: Text("History"),
        ),
        body: Center(child: AgPathLoadingIndicator()),
      );
    }

    if (errorMessage != null) {
      return Scaffold(
        appBar: brandAppBar(
          leading: const HomeBackButton(),
          title: const Text("History"),
        ),
        body: LoadFailedView(
          message: errorMessage!,
          onRetry: _retryLoad,
        ),
      );
    }

    List<Map<String, dynamic>> filteredHistory =
        historyData
            .where(
              (history) => history['remarks'].toString().toLowerCase().contains(
                searchQuery.toLowerCase(),
              ),
            )
            .toList();

    Map<String, List<Map<String, dynamic>>> groupedByDate = {};

    for (var entry in filteredHistory) {
      String dateKey = DateFormat('EEE d, MMM').format(entry['from_time']);
      groupedByDate.putIfAbsent(dateKey, () => []).add(entry);
    }
    final totalKm = calculateTotalDistance(filteredHistory);
    return Scaffold(
      appBar: brandAppBar(
        leading: const HomeBackButton(color: Colors.white),
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text('History'),
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.filter_alt, color: Colors.white),
                  tooltip: 'Toggle Filter',
                  onPressed: () {
                    setState(() {
                      showFilterRow = !showFilterRow;
                    });
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.search, color: Colors.white),
                  tooltip: 'Toggle Search',
                  onPressed: () {
                    setState(() {
                      showSearchBar = !showSearchBar;
                    });
                  },
                ),

                const Icon(
                  Icons.directions_walk,
                  size: 18,
                  color: Colors.white,
                ),
                const SizedBox(width: 4),
                Text(
                  "$totalKm km",
                  style: const TextStyle(fontSize: 14, color: Colors.white),
                ),
              ],
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          if (showFilterRow)
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: fromDate ?? DateTime.now(),
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                      );
                      if (picked != null) {
                        setState(() => fromDate = picked);
                        if (toDate != null && fromDate!.isAfter(toDate!)) {
                          Warning.show(
                            context,
                            'From Date cannot be after To Date',
                            'Warning',
                          );
                        } else {
                          fetchHistoryData();
                        }
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 16,
                      ),
                      margin: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        fromDate != null
                            ? DateFormat('yyyy-MM-dd').format(fromDate!)
                            : 'From Date',
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: InkWell(
                    onTap: () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: toDate ?? DateTime.now(),
                        firstDate: DateTime(2000),
                        lastDate: DateTime(2100),
                      );
                      if (picked != null) {
                        setState(() => toDate = picked);
                        if (fromDate != null && fromDate!.isAfter(toDate!)) {
                          Warning.show(
                            context,
                            'To Date cannot be before From Date',
                            'Warning',
                          );
                        } else {
                          fetchHistoryData();
                        }
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 16,
                      ),
                      margin: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        toDate != null
                            ? DateFormat('yyyy-MM-dd').format(toDate!)
                            : 'To Date',
                      ),
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.clear, color: Colors.red),
                  tooltip: 'Clear Filters',
                  onPressed: () {
                    setState(() {
                      DateTime now = DateTime.now();
                      fromDate = DateTime(now.year, now.month, 1);
                      toDate = now;
                      searchQuery = '';
                    });
                    fetchHistoryData();
                  },
                ),
              ],
            ),

          if (showSearchBar)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: TextField(
                onChanged: (value) => setState(() => searchQuery = value),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Search history...',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),

          Expanded(
            child: PullToRefresh(
              onRefresh: () async {
                await _checkPing();
                await fetchHistoryData();
              },
              child:
                  filteredHistory.isEmpty
                      ? Center(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 100),
                          child: Text(
                            'No history found for selected filters.',
                            style: TextStyle(
                              fontSize: 16,
                              color: Colors.grey[600],
                            ),
                          ),
                        ),
                      )
                      : ListView(
                        children:
                            groupedByDate.entries.map((entry) {
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 8,
                                    ),
                                    child: Text(
                                      entry.key,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  ...entry.value.map(
                                    (history) => HistoryItem(history: history),
                                  ),
                                ],
                              );
                            }).toList(),
                      ),
            ),
          ),
        ],
      ),
    );
  }
}

class HistoryItem extends StatelessWidget {
  final Map<String, dynamic> history;

  const HistoryItem({super.key, required this.history});

  @override
  Widget build(BuildContext context) {
    String remarks = history['remarks'];
    String displayRemarks =
        remarks.length > 20 ? '${remarks.substring(0, 20)}...' : remarks;

    String fromTime = DateFormat.Hm().format(history['from_time']);
    String toTime = DateFormat.Hm().format(history['to_time']);
    String timeRange = '$fromTime To $toTime';

    return ListTile(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => HistoryOverview(eventid: history['name']),
          ),
        );
      },
      leading: CircleAvatar(child: Text(remarks[0].toUpperCase())),
      title: Text(displayRemarks),
      subtitle: Text(timeRange),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [Text(history['total_hours']), const Text('Working Hours')],
      ),
    );
  }
}
