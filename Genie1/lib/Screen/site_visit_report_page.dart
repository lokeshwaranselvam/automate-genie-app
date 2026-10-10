import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/api/event.dart';
import '../utils/api/session_auth.dart';
import '../utils/widget/home_back_button.dart';

const _reportBlue = Color(0xFF1768C4);
const _reportInk = Color(0xFF202B3C);
const _reportMuted = Color(0xFF7B8492);
const _reportOutcomes = ['Interested', 'Not Interested', 'Follow-up Required'];

class SiteVisitReportPage extends StatefulWidget {
  const SiteVisitReportPage({super.key, required this.visit});

  final Map<String, dynamic> visit;

  @override
  State<SiteVisitReportPage> createState() => _SiteVisitReportPageState();
}

class _SiteVisitReportPageState extends State<SiteVisitReportPage> {
  late Map<String, dynamic> _visit;
  List<Map<String, dynamic>> _photos = [];
  String? _photoError;
  String? _token;
  String? _sessionSid;
  String? _profileImageUrl;
  String _userFullName = 'User';
  late final TextEditingController _observationController;
  String? _selectedOutcome;
  String? _reportError;
  bool _loading = true;
  bool _saving = false;
  bool _isSubmitted = false;

  @override
  void initState() {
    super.initState();
    _visit = Map<String, dynamic>.from(widget.visit);
    _observationController = TextEditingController();
    _loadReport();
  }

  @override
  void dispose() {
    _observationController.dispose();
    super.dispose();
  }

  String get _eventId =>
      (_visit['name'] ?? _visit['event_id'] ?? '').toString().trim();

  Future<void> _loadReport() async {
    if (mounted) setState(() => _loading = true);

    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString('token');
    final userName = await SessionAuthApi.getCurrentUserFullName() ?? 'User';
    final detailsFuture =
        _eventId.isEmpty ? null : Event.eventTimelineDetails(_eventId);
    final photosFuture =
        _eventId.isEmpty ? null : Event.visitImageFiles(_eventId);
    final reportFuture =
        _eventId.isEmpty ? null : Event.getVisitReport(_eventId);
    final profileFuture = SessionAuthApi.getCurrentUserAvatarUrl();
    final sessionFuture = SessionAuthApi.getSessionId();

    Map<String, dynamic>? details;
    if (detailsFuture != null) {
      try {
        details = await detailsFuture;
      } catch (error) {
        debugPrint('Could not refresh visit report details: $error');
      }
    }

    var photos = <Map<String, dynamic>>[];
    String? photoError;
    if (photosFuture != null) {
      try {
        photos = await photosFuture;
      } catch (error) {
        photoError = error.toString().replaceFirst('Bad state: ', '');
        debugPrint('Could not load visit report photos: $error');
      }
    }

    Map<String, dynamic>? report;
    String? reportError;
    if (reportFuture != null) {
      try {
        report = await reportFuture;
      } catch (error) {
        reportError = error.toString().replaceFirst('Bad state: ', '');
        debugPrint('Could not load saved visit report: $error');
      }
    }

    String? profileImageUrl;
    String? sessionSid;
    try {
      profileImageUrl = await profileFuture;
    } catch (error) {
      debugPrint('Could not load the signed-in user profile image: $error');
    }
    try {
      sessionSid = await sessionFuture;
    } catch (_) {}

    if (!mounted) return;
    final merged = <String, dynamic>{
      ..._visit,
      if (details != null) ...details,
    };
    if (details?['event'] is Map) {
      merged.addAll(Map<String, dynamic>.from(details!['event'] as Map));
    }
    setState(() {
      _visit = merged;
      _photos = photos;
      _photoError = photoError;
      _token = token;
      _sessionSid = sessionSid;
      _profileImageUrl = profileImageUrl;
      _userFullName = userName;
      if (report != null) {
        _observationController.text = report['observation']?.toString() ?? '';
        final savedOutcome = report['outcome']?.toString();
        _selectedOutcome =
            _reportOutcomes.contains(savedOutcome) ? savedOutcome : null;
      }
      final reportFlag = report?['is_submitted'];
      final description =
          report?['description']?.toString() ??
          merged['description']?.toString() ??
          '';
      _isSubmitted =
          reportFlag == true ||
          (description.startsWith('observation : ') &&
              description.contains('\nOutcome: ') &&
              _reportOutcomes.any(
                (outcome) => description.trimRight().endsWith(outcome),
              ));
      _reportError = reportError;
      _loading = false;
    });
  }

  String _value(List<String> keys, {String fallback = ''}) {
    for (final key in keys) {
      final value = _visit[key]?.toString().trim() ?? '';
      if (value.isNotEmpty && value.toLowerCase() != 'null') return value;
    }
    return fallback;
  }

  String _formatTime(dynamic raw) {
    final text = raw?.toString().trim() ?? '';
    if (text.isEmpty) return '';
    final date = DateTime.tryParse(text)?.toLocal();
    return date == null ? text : DateFormat('hh:mm a').format(date);
  }

  String get _visitTime {
    final checkIn = _formatTime(_value(['custom_check_in', 'starts_on']));
    final checkOut = _formatTime(_value(['custom_check_out', 'ends_on']));
    if (checkIn.isEmpty && checkOut.isEmpty) return 'Visit time not recorded';
    if (checkIn.isEmpty) return checkOut;
    if (checkOut.isEmpty) return checkIn;
    return '$checkIn - $checkOut';
  }

  String _photoUrl(Map<String, dynamic> photo) =>
      photo['file_url']?.toString() ?? '';

  void _openGallery(int initialIndex) {
    if (_photos.isEmpty) return;
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder:
            (_) => _VisitPhotoGallery(
              photos: _photos,
              token: _token,
              initialIndex: initialIndex,
            ),
      ),
    );
  }

  Future<void> _submitReport() async {
    if (_eventId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This visit has no Event ID.')),
      );
      return;
    }
    final observation = _observationController.text.trim();
    final outcome = _selectedOutcome;
    if (observation.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter the visit observations.')),
      );
      return;
    }
    if (outcome == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select the visit outcome.')),
      );
      return;
    }

    setState(() {
      _saving = true;
      _reportError = null;
    });
    try {
      final result = await Event.saveVisitReport(
        eventId: _eventId,
        observation: observation,
        outcome: outcome,
      );
      if (!mounted) return;
      setState(() {
        _selectedOutcome = result['outcome']?.toString() ?? outcome;
        _visit['description'] = result['description'];
        _isSubmitted = true;
      });
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder:
            (dialogContext) => AlertDialog(
              icon: const Icon(
                Icons.check_circle_rounded,
                color: Color(0xFF219653),
                size: 42,
              ),
              title: const Text('Report submitted'),
              content: const Text(
                'Your visit report was submitted successfully. It can no longer be edited.',
                textAlign: TextAlign.center,
              ),
              actions: [
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Done'),
                ),
              ],
            ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _reportError = error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final location = _value(['custom_location', 'location'], fallback: '—');
    final purpose = _value([
      'purpose',
      'custom_purpose',
      'event_category',
      'event_type',
    ], fallback: _value(['subject'], fallback: 'Site visit'));
    final photoCount = _photos.length;

    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      appBar: AppBar(
        leading: const HomeBackButton(color: _reportBlue),
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: _reportBlue),
        title: const Text(
          'Visit Report',
          style: TextStyle(color: _reportInk, fontWeight: FontWeight.w800),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh report',
            onPressed: _loading ? null : _loadReport,
            icon: const Icon(Icons.refresh_rounded, color: _reportInk),
          ),
        ],
      ),
      body:
          _loading && _visit.isEmpty
              ? const Center(
                child: CircularProgressIndicator(color: _reportBlue),
              )
              : RefreshIndicator(
                onRefresh: _loadReport,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
                  children: [
                    _customerHeader(),
                    const SizedBox(height: 14),
                    _visitSummary(location: location, purpose: purpose),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Site Photos ($photoCount)',
                            style: const TextStyle(
                              color: _reportInk,
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        if (_loading)
                          const SizedBox(
                            width: 15,
                            height: 15,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                      ],
                    ),
                    const SizedBox(height: 9),
                    _photoStrip(),
                    const SizedBox(height: 18),
                    _reportSection(
                      title: 'Observations',
                      child: TextField(
                        controller: _observationController,
                        enabled: !_loading && !_saving && !_isSubmitted,
                        minLines: 3,
                        maxLines: 5,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: InputDecoration(
                          hintText: 'Enter visit observations...',
                          filled: true,
                          fillColor: const Color(0xFFF8F9FB),
                          contentPadding: const EdgeInsets.all(11),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(9),
                            borderSide: const BorderSide(
                              color: Color(0xFFE8EBEF),
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(9),
                            borderSide: const BorderSide(
                              color: Color(0xFFE8EBEF),
                            ),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(9),
                            borderSide: const BorderSide(color: _reportBlue),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    _reportSection(
                      title: 'Outcome',
                      child: DropdownButtonFormField<String>(
                        value: _selectedOutcome,
                        items: [
                          for (final outcome in _reportOutcomes)
                            DropdownMenuItem(
                              value: outcome,
                              child: Text(outcome),
                            ),
                        ],
                        onChanged:
                            _loading || _saving || _isSubmitted
                                ? null
                                : (value) =>
                                    setState(() => _selectedOutcome = value),
                        decoration: InputDecoration(
                          hintText: 'Select outcome',
                          filled: true,
                          fillColor: const Color(0xFFF8F9FB),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 11,
                            vertical: 8,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(9),
                            borderSide: const BorderSide(
                              color: Color(0xFFE8EBEF),
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(9),
                            borderSide: const BorderSide(
                              color: Color(0xFFE8EBEF),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (_reportError != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _reportError!,
                        style: const TextStyle(color: Colors.red, fontSize: 12),
                      ),
                    ],
                    if (_isSubmitted) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFEAF7EF),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Row(
                          children: [
                            Icon(
                              Icons.lock_outline_rounded,
                              color: Color(0xFF218653),
                              size: 18,
                            ),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Report submitted. Editing is locked.',
                                style: TextStyle(
                                  color: Color(0xFF218653),
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (_photoError != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _photoError!,
                        style: const TextStyle(color: Colors.red, fontSize: 12),
                      ),
                    ],
                    const SizedBox(height: 20),
                    SizedBox(
                      height: 48,
                      child: FilledButton.icon(
                        onPressed:
                            _loading || _saving || _isSubmitted
                                ? null
                                : _submitReport,
                        style: FilledButton.styleFrom(
                          backgroundColor: _reportBlue,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        icon:
                            _saving
                                ? const SizedBox(
                                  height: 18,
                                  width: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                                : const Icon(Icons.check_rounded, size: 18),
                        label: Text(
                          _saving
                              ? 'Submitting...'
                              : _isSubmitted
                              ? 'Report Submitted'
                              : 'Submit Report',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
    );
  }

  Widget _customerHeader() {
    final eventName = _value(['subject'], fallback: 'Site Visit');
    return Row(
      children: [
        _profileAvatar(),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _userFullName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: _reportInk,
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                ),
              ),
              Text(
                eventName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: _reportMuted, fontSize: 12),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFFE6F7EF),
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Text(
            'Completed',
            style: TextStyle(
              color: Color(0xFF218653),
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }

  Widget _profileAvatar() {
    final imageUrl = _profileImageUrl;
    if (imageUrl == null || imageUrl.isEmpty) {
      return CircleAvatar(
        radius: 22,
        backgroundColor: const Color(0xFFEAF3FF),
        child: Text(
          _initials(_userFullName),
          style: const TextStyle(
            color: _reportBlue,
            fontWeight: FontWeight.w800,
          ),
        ),
      );
    }

    return ClipOval(
      child: Image.network(
        imageUrl,
        width: 44,
        height: 44,
        fit: BoxFit.cover,
        headers: _sessionSid == null ? null : {'Cookie': 'sid=$_sessionSid'},
        errorBuilder:
            (_, __, ___) => CircleAvatar(
              radius: 22,
              backgroundColor: const Color(0xFFEAF3FF),
              child: Text(
                _initials(_userFullName),
                style: const TextStyle(
                  color: _reportBlue,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
      ),
    );
  }

  String _initials(String name) {
    final parts = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((part) => part.isNotEmpty);
    final values = parts.take(2).map((part) => part[0].toUpperCase());
    return values.isEmpty ? 'U' : values.join();
  }

  Widget _visitSummary({required String location, required String purpose}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE8EBEF)),
      ),
      child: Column(
        children: [
          _summaryRow(Icons.schedule_rounded, 'Visit Time', _visitTime),
          const Divider(height: 18),
          _summaryRow(Icons.location_on_outlined, 'Location', location),
          const Divider(height: 18),
          _summaryRow(Icons.assignment_outlined, 'Purpose', purpose),
        ],
      ),
    );
  }

  Widget _summaryRow(IconData icon, String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: _reportBlue),
        const SizedBox(width: 9),
        SizedBox(
          width: 82,
          child: Text(
            label,
            style: const TextStyle(color: _reportMuted, fontSize: 12),
          ),
        ),
        Expanded(
          child: Text(
            value.isEmpty ? '—' : value,
            style: const TextStyle(
              color: _reportInk,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
          ),
        ),
      ],
    );
  }

  Widget _photoStrip() {
    if (_photos.isEmpty) {
      return Container(
        height: 92,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFE8EBEF)),
        ),
        child: Text(
          _photoError == null
              ? 'No site photos attached.'
              : 'Photos unavailable.',
          style: const TextStyle(color: _reportMuted, fontSize: 12),
        ),
      );
    }

    final visibleCount = _photos.length > 3 ? 3 : _photos.length;
    return SizedBox(
      height: 92,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (var index = 0; index < visibleCount; index++)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: InkWell(
                onTap: () => _openGallery(index),
                borderRadius: BorderRadius.circular(10),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: _photoImage(_photoUrl(_photos[index]), 84, 92),
                ),
              ),
            ),
          InkWell(
            onTap: () => _openGallery(0),
            borderRadius: BorderRadius.circular(10),
            child: Container(
              width: 84,
              height: 92,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFDCE2E8)),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.add_rounded, color: _reportBlue, size: 25),
                  Text(
                    _photos.length > visibleCount
                        ? '+${_photos.length - visibleCount} more'
                        : 'View all',
                    style: const TextStyle(color: _reportBlue, fontSize: 10),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _photoImage(String url, double width, double height) {
    return Image.network(
      url,
      width: width,
      height: height,
      fit: BoxFit.cover,
      headers: _token == null ? null : {'Authorization': _token!},
      errorBuilder:
          (_, __, ___) => Container(
            width: width,
            height: height,
            color: const Color(0xFFE9EEF5),
            alignment: Alignment.center,
            child: const Icon(Icons.broken_image_outlined, color: _reportMuted),
          ),
    );
  }

  Widget _reportSection({required String title, required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: const Color(0xFFE8EBEF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: _reportInk,
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 9),
          child,
        ],
      ),
    );
  }
}

class _VisitPhotoGallery extends StatefulWidget {
  const _VisitPhotoGallery({
    required this.photos,
    required this.token,
    required this.initialIndex,
  });

  final List<Map<String, dynamic>> photos;
  final String? token;
  final int initialIndex;

  @override
  State<_VisitPhotoGallery> createState() => _VisitPhotoGalleryState();
}

class _VisitPhotoGalleryState extends State<_VisitPhotoGallery> {
  late final PageController _controller = PageController(
    initialPage: widget.initialIndex,
  );
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        leading: const HomeBackButton(color: Colors.white),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text('${_index + 1} / ${widget.photos.length}'),
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: widget.photos.length,
        onPageChanged: (index) => setState(() => _index = index),
        itemBuilder: (context, index) {
          final url = widget.photos[index]['file_url']?.toString() ?? '';
          return InteractiveViewer(
            child: Center(
              child: Image.network(
                url,
                fit: BoxFit.contain,
                headers:
                    widget.token == null
                        ? null
                        : {'Authorization': widget.token!},
                errorBuilder:
                    (_, __, ___) => const Icon(
                      Icons.broken_image_outlined,
                      color: Colors.white70,
                      size: 48,
                    ),
              ),
            ),
          );
        },
      ),
    );
  }
}
