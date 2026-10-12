import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:intl/intl.dart';

import '../utils/api/location_api.dart';
import '../utils/api/site_visit_creation_api.dart';
import '../utils/site_visit_schedule.dart';

const _visitBlue = Color(0xFF1768C4);
const _visitInk = Color(0xFF202B3C);
const _visitMuted = Color(0xFF7B8492);
const _siteLocationTypes = ['Site', 'Home', 'Others'];

class NewSiteVisitPage extends StatefulWidget {
  const NewSiteVisitPage({super.key});

  @override
  State<NewSiteVisitPage> createState() => _NewSiteVisitPageState();
}

class _NewSiteVisitPageState extends State<NewSiteVisitPage> {
  final _locationFormKey = GlobalKey<FormState>();
  final _eventFormKey = GlobalKey<FormState>();
  final _mapLinkController = TextEditingController();
  final _summaryController = TextEditingController();
  final _mobileController = TextEditingController();
  final _locationSearchController = TextEditingController();
  List<LocationSuggestion> _locationSearchResults = [];
  Timer? _locationSearchDebounce;
  String? _locationSearchSession;
  bool _searchingLocation = false;
  String? _locationSearchError;
  int _locationSearchRequestId = 0;
  GoogleMapController? _locationMapController;
  LatLng? _selectedCoordinates;
  String? _resolvedMapLink;
  bool _resolvingMapLink = false;
  String? _mapLinkError;
  int _mapLinkRequestId = 0;
  String? _product;
  List<String> _productOptions = [];
  List<String> _eventCategories = [];
  String? _eventCategory;
  // The Autocomplete owns the opportunity text field; keep references so a
  // mobile-number search can fill or focus it.
  TextEditingController? _opportunityFieldController;
  FocusNode? _opportunityFocusNode;
  Timer? _mobileSearchDebounce;
  int _mobileSearchId = 0;
  bool _mobileSearching = false;
  bool _mobileSearchFailed = false;
  String? _mobileSearchMessage;
  // Null when no mobile search is active; the opportunity field then searches
  // the initial opportunity dropdown.
  List<Map<String, dynamic>>? _mobileMatches;

  bool _loading = true;
  bool _saving = false;
  bool _eventStep = false;
  String? _error;
  String? _opportunity;
  String? _initialOpportunityQuery;
  String? _locationType;
  String? _assignedTo;
  DateTime? _visitDate;
  DateTime? _startsOn;
  DateTime? _endsOn;
  String _currentUser = '';
  String _savedLocationRow = '';
  List<Map<String, dynamic>> _opportunities = [];
  List<Map<String, dynamic>> _users = [];

  @override
  void initState() {
    super.initState();
    _loadOptions();
  }

  @override
  void dispose() {
    _mobileSearchDebounce?.cancel();
    _locationSearchDebounce?.cancel();
    _mapLinkController.dispose();
    _summaryController.dispose();
    _mobileController.dispose();
    _locationSearchController.dispose();
    super.dispose();
  }

  Future<void> _loadOptions() async {
    try {
      final result = await SiteVisitCreationApi.loadOptions();
      if (!mounted) return;
      final opportunities =
          (result['opportunities'] as List)
              .whereType<Map>()
              .map((row) => Map<String, dynamic>.from(row))
              .toList();
      final users =
          (result['users'] as List)
              .whereType<Map>()
              .map((row) => Map<String, dynamic>.from(row))
              .toList();
      final currentUser = result['current_user']?.toString() ?? '';
      setState(() {
        _opportunities = opportunities;
        _users = users;
        _currentUser = currentUser;
        _productOptions =
            (result['product_enquired_options'] as List)
                .map((value) => value.toString().trim())
                .where((value) => value.isNotEmpty)
                .toSet()
                .toList();
        _eventCategories =
            (result['event_categories'] as List)
                .map((value) => value.toString().trim())
                .where((value) => value.isNotEmpty)
                .toSet()
                .toList();
        _eventCategory =
            _eventCategories.contains('Installation') ? 'Installation' : null;
        if (_users.any((user) => user['name']?.toString() == currentUser)) {
          _assignedTo = currentUser;
        }
        if (_opportunities.length == 1) {
          final onlyOpportunity = _opportunities.first;
          _opportunity = onlyOpportunity['name']?.toString();
          _initialOpportunityQuery = _opportunityLabel(onlyOpportunity);
          _setOpportunityDefaults(onlyOpportunity);
        }
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = _message(error);
        _loading = false;
      });
    }
  }

  String _message(Object error) => error
      .toString()
      .replaceFirst('Bad state: ', '')
      .replaceFirst('Exception: ', '');

  String _opportunityLabel(Map<String, dynamic> opportunity) {
    for (final key in [
      'title',
      'opportunity_name',
      'customer_name',
      'party_name',
    ]) {
      final value = opportunity[key]?.toString().trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    return opportunity['name']?.toString() ?? 'Opportunity';
  }

  String _productEnquired(Map<String, dynamic> opportunity) =>
      opportunity['product_enquired']?.toString().trim() ?? '';

  void _setOpportunityDefaults(Map<String, dynamic> opportunity) {
    final value = _productEnquired(opportunity);
    _product = _productOptions.contains(value) ? value : null;
    final assignedUser =
        opportunity['assigned_to']?.toString().trim() ?? _currentUser;
    _assignedTo =
        _users.any((user) => user['name']?.toString() == assignedUser)
            ? assignedUser
            : null;
  }

  void _selectOpportunity(Map<String, dynamic> opportunity) {
    setState(() {
      _opportunity = opportunity['name']?.toString();
      // Restores the field text when returning from the event step.
      _initialOpportunityQuery = _opportunityLabel(opportunity);
      _setOpportunityDefaults(opportunity);
      // Mobile search may return a newly created opportunity outside the
      // initial options. Keep its title and party available in step two.
      if (!_opportunities.any((row) => row['name'] == opportunity['name'])) {
        _opportunities.add(opportunity);
      }
    });
  }

  void _onMobileChanged(String value) {
    _mobileSearchDebounce?.cancel();
    final searchId = ++_mobileSearchId;
    final digits = value.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 5) {
      setState(() {
        _mobileSearching = false;
        _mobileSearchFailed = false;
        _mobileMatches = null;
        _mobileSearchMessage =
            digits.isEmpty ? null : 'Enter at least 5 digits to search.';
      });
      return;
    }
    setState(() {
      _mobileSearching = true;
      _mobileSearchFailed = false;
      _mobileMatches = [];
      _mobileSearchMessage = null;
      _opportunity = null;
      _product = null;
      _initialOpportunityQuery = null;
    });
    _opportunityFieldController?.clear();
    _mobileSearchDebounce = Timer(
      const Duration(milliseconds: 500),
      () => _searchByMobile(digits, searchId),
    );
  }

  Future<void> _searchByMobile(String digits, int searchId) async {
    if (!mounted || searchId != _mobileSearchId) return;
    try {
      final matches = await SiteVisitCreationApi.searchByMobile(digits);
      // Ignore results from an older search the user has typed past.
      if (!mounted || searchId != _mobileSearchId) return;
      setState(() {
        _mobileSearching = false;
        _mobileSearchFailed = false;
        _mobileMatches = matches;
        _mobileSearchMessage =
            matches.isEmpty
                ? 'No opportunities found for this mobile number.'
                : matches.length == 1
                ? '1 opportunity found and selected.'
                : '${matches.length} opportunities found. Choose one below.';
      });
      final controller = _opportunityFieldController;
      if (matches.length == 1) {
        _selectOpportunity(matches.first);
        controller?.text = _opportunityLabel(matches.first);
      } else {
        setState(() {
          _opportunity = null;
          _product = null;
        });
        controller?.clear();
        if (matches.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && searchId == _mobileSearchId) {
              _opportunityFocusNode?.requestFocus();
            }
          });
        }
      }
    } catch (error) {
      if (!mounted || searchId != _mobileSearchId) return;
      setState(() {
        _mobileSearching = false;
        _mobileSearchFailed = true;
        _mobileMatches = [];
        _mobileSearchMessage =
            error is TimeoutException
                ? 'Phone search timed out. Tap retry to try again.'
                : _message(error);
      });
    }
  }

  Future<void> _saveLocation() async {
    if (!_locationFormKey.currentState!.validate()) return;
    _locationSearchDebounce?.cancel();
    _locationSearchSession = null;
    _mapLinkRequestId++;
    _locationSearchRequestId++;
    setState(() => _saving = true);
    try {
      final link = _mapLinkController.text.trim();
      final coordinates =
          _resolvedMapLink == link && _selectedCoordinates != null
              ? _selectedCoordinates!
              : LocationHelper.tryCoordinatesFromMapLink(link) ??
                  await LocationHelper.getCoordinatesFromMapLink(link);
      final result = await SiteVisitCreationApi.saveLocation(
        opportunity: _opportunity!,
        mapLink: link,
        latitude: coordinates.latitude,
        longitude: coordinates.longitude,
        locationType: _locationType!,
      );
      final rowName = result['location_row']?.toString().trim() ?? '';
      if (rowName.isEmpty) {
        throw const FormatException(
          'The saved customer location has no ERP ID.',
        );
      }
      if (!mounted) return;
      setState(() {
        _selectedCoordinates = coordinates;
        _resolvedMapLink = link;
        _resolvingMapLink = false;
        _searchingLocation = false;
        _locationMapController = null;
        _savedLocationRow = rowName;
        _eventStep = true;
      });
    } catch (error) {
      if (mounted) _showError(_message(error));
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
          _resolvingMapLink = false;
          _searchingLocation = false;
        });
      }
    }
  }

  void _onMapLinkChanged(String value) {
    _locationSearchDebounce?.cancel();
    _locationSearchSession = null;
    _mapLinkRequestId++;
    _locationSearchRequestId++;
    setState(() {
      _selectedCoordinates = null;
      _resolvedMapLink = null;
      _mapLinkError = null;
      _resolvingMapLink = false;
      _searchingLocation = false;
      _locationSearchResults = [];
      _locationSearchError = null;
    });
  }

  void _selectMapLocation(LatLng point) {
    if (_saving) return;
    _locationSearchDebounce?.cancel();
    _locationSearchSession = null;
    _mapLinkRequestId++;
    _locationSearchRequestId++;
    final link =
        'https://www.google.com/maps/search/?api=1&query=${point.latitude},${point.longitude}';
    _mapLinkController.text = link;
    setState(() {
      _selectedCoordinates = point;
      _resolvedMapLink = link;
      _mapLinkError = null;
      _resolvingMapLink = false;
      _searchingLocation = false;
      _locationSearchResults = [];
      _locationSearchError = null;
    });
  }

  Future<void> _previewMapLink() async {
    if (_saving || _resolvingMapLink) return;
    _locationSearchDebounce?.cancel();
    _locationSearchSession = null;
    final link = _mapLinkController.text.trim();
    if (link.isEmpty) {
      setState(
        () => _mapLinkError = 'Paste a map link or choose a point on the map.',
      );
      return;
    }
    final requestId = ++_mapLinkRequestId;
    _locationSearchRequestId++;
    setState(() {
      _resolvingMapLink = true;
      _mapLinkError = null;
      _searchingLocation = false;
      _locationSearchResults = [];
      _locationSearchError = null;
    });
    try {
      final point =
          LocationHelper.tryCoordinatesFromMapLink(link) ??
          await LocationHelper.getCoordinatesFromMapLink(link);
      if (!mounted || requestId != _mapLinkRequestId) return;
      setState(() {
        _selectedCoordinates = point;
        _resolvedMapLink = link;
        _resolvingMapLink = false;
      });
      final controller = _locationMapController;
      if (controller != null) {
        await controller.animateCamera(CameraUpdate.newLatLngZoom(point, 16));
      }
    } catch (error) {
      if (!mounted || requestId != _mapLinkRequestId) return;
      setState(() {
        _resolvingMapLink = false;
        _mapLinkError = _message(error);
      });
    }
  }

  void _onLocationSearchChanged(String value) {
    _locationSearchDebounce?.cancel();
    _locationSearchRequestId++;
    setState(() {
      _searchingLocation = false;
      _locationSearchResults = [];
      _locationSearchError = null;
    });
    if (value.trim().length < 3) {
      if (value.trim().isEmpty) _locationSearchSession = null;
      return;
    }
    _locationSearchDebounce = Timer(
      const Duration(milliseconds: 400),
      () => _searchMapLocation(keepFocus: true),
    );
  }

  Future<void> _searchMapLocation({bool keepFocus = false}) async {
    if (_saving || _searchingLocation) return;
    _locationSearchDebounce?.cancel();
    final query = _locationSearchController.text.trim();
    if (query.isEmpty) {
      setState(() => _locationSearchError = 'Enter an address, area or city.');
      return;
    }
    if (!keepFocus) FocusScope.of(context).unfocus();
    final sessionToken =
        _locationSearchSession ??= LocationHelper.newLocationSearchSession();
    final requestId = ++_locationSearchRequestId;
    setState(() {
      _searchingLocation = true;
      _locationSearchResults = [];
      _locationSearchError = null;
    });
    try {
      final results = await LocationHelper.suggestLocations(
        query,
        sessionToken: sessionToken,
        bias: _selectedCoordinates ?? const LatLng(13.0827, 80.2707),
      );
      if (!mounted || requestId != _locationSearchRequestId) return;
      setState(() {
        _searchingLocation = false;
        _locationSearchResults = results;
        _locationSearchError =
            results.isEmpty
                ? 'No locations found. Try a more specific address.'
                : null;
      });
    } catch (error) {
      if (!mounted || requestId != _locationSearchRequestId) return;
      setState(() {
        _searchingLocation = false;
        _locationSearchError =
            error is TimeoutException
                ? 'Location search timed out. Please try again.'
                : _message(error);
      });
    }
  }

  Future<void> _selectLocationSearchResult(
    LocationSuggestion suggestion,
  ) async {
    if (_saving || _searchingLocation) return;
    _locationSearchDebounce?.cancel();
    final requestId = ++_locationSearchRequestId;
    final sessionToken =
        _locationSearchSession ??= LocationHelper.newLocationSearchSession();
    // Details completes this session even if a new query starts before it returns.
    _locationSearchSession = null;
    setState(() {
      _searchingLocation = true;
      _locationSearchError = null;
    });
    late LocationSearchResult result;
    try {
      result = await LocationHelper.resolveLocationSuggestion(
        suggestion,
        sessionToken: sessionToken,
      );
    } catch (error) {
      if (!mounted || requestId != _locationSearchRequestId) return;
      setState(() {
        _searchingLocation = false;
        _locationSearchSession = null;
        _locationSearchError =
            error is TimeoutException
                ? 'Location search timed out. Please try again.'
                : _message(error);
      });
      return;
    }
    if (!mounted || requestId != _locationSearchRequestId) return;
    _selectMapLocation(result.coordinates);
    _locationSearchController.text = result.address;
    FocusScope.of(context).unfocus();
    final controller = _locationMapController;
    if (controller != null) {
      try {
        await controller.animateCamera(
          CameraUpdate.newLatLngZoom(result.coordinates, 16),
        );
      } catch (_) {
        if (mounted) {
          setState(
            () =>
                _locationSearchError =
                    'Location selected, but the map could not be centered.',
          );
        }
      }
    }
  }

  Widget _locationMapPicker() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      TextField(
        controller: _locationSearchController,
        enabled: !_saving,
        textInputAction: TextInputAction.search,
        decoration: _decoration(
          'Search location',
          hint: 'Type a place, address or city',
          prefixIcon: const Icon(Icons.search_rounded),
        ).copyWith(
          suffixIcon:
              _searchingLocation
                  ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                  : IconButton(
                    tooltip: 'Search map location',
                    icon: const Icon(Icons.arrow_forward_rounded),
                    onPressed: _saving ? null : _searchMapLocation,
                  ),
        ),
        onChanged: _onLocationSearchChanged,
        onSubmitted: (_) => _searchMapLocation(),
      ),
      if (_locationSearchError != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            _locationSearchError!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      for (final result in _locationSearchResults)
        Material(
          color: Colors.transparent,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.place_outlined, color: _visitBlue),
            title: Text(
              result.address,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            onTap:
                _saving || _searchingLocation
                    ? null
                    : () => _selectLocationSearchResult(result),
          ),
        ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: _saving || _resolvingMapLink ? null : _previewMapLink,
        icon:
            _resolvingMapLink
                ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
                : const Icon(Icons.map_outlined),
        label: Text(_resolvingMapLink ? 'Locating...' : 'Show link on map'),
      ),
      if (_mapLinkError != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            _mapLinkError!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      const SizedBox(height: 6),
      ClipRRect(
        borderRadius: BorderRadius.circular(13),
        child: SizedBox(
          height: 260,
          width: double.infinity,
          child: GoogleMap(
            initialCameraPosition: CameraPosition(
              target: _selectedCoordinates ?? const LatLng(13.0827, 80.2707),
              zoom: _selectedCoordinates == null ? 12 : 16,
            ),
            onMapCreated: (controller) {
              if (mounted && !_eventStep) _locationMapController = controller;
            },
            onTap: _saving ? null : _selectMapLocation,
            markers: {
              if (_selectedCoordinates != null)
                Marker(
                  markerId: const MarkerId('visit-customer-location'),
                  position: _selectedCoordinates!,
                  draggable: !_saving,
                  onDragEnd: _selectMapLocation,
                  infoWindow: const InfoWindow(title: 'Customer location'),
                ),
            },
            zoomControlsEnabled: true,
            zoomGesturesEnabled: true,
            scrollGesturesEnabled: true,
            myLocationButtonEnabled: false,
            mapToolbarEnabled: false,
            gestureRecognizers: {
              Factory<OneSequenceGestureRecognizer>(
                () => EagerGestureRecognizer(),
              ),
            },
          ),
        ),
      ),
      const SizedBox(height: 8),
      const Text(
        'Tap the map or drag the pin to choose the location. Pinch or use + / - to zoom.',
        style: TextStyle(color: _visitMuted, fontSize: 12, height: 1.4),
      ),
    ],
  );

  Future<void> _pickDate() async {
    final now = DateUtils.dateOnly(DateTime.now());
    final picked = await showDatePicker(
      context: context,
      initialDate:
          _visitDate == null || _visitDate!.isBefore(now) ? now : _visitDate!,
      firstDate: now,
      lastDate: DateTime(now.year + 5),
      builder:
          (context, child) => Theme(
            data: Theme.of(context).copyWith(
              colorScheme: Theme.of(
                context,
              ).colorScheme.copyWith(primary: _visitBlue),
            ),
            child: child!,
          ),
    );
    if (picked != null && mounted) {
      setState(() {
        if (_visitDate != picked) {
          _startsOn = null;
          _endsOn = null;
        }
        _visitDate = picked;
      });
    }
  }

  String _timeLabel(DateTime time) {
    final label = DateFormat('h:mm a').format(time);
    return _visitDate != null && !DateUtils.isSameDay(time, _visitDate)
        ? '$label (next day)'
        : label;
  }

  Future<void> _pickTime({required bool isEnd}) async {
    final date = _visitDate;
    if (date == null) {
      _showError('Select the visit date first.');
      return;
    }
    if (isEnd && _startsOn == null) {
      _showError('Select the start time first.');
      return;
    }
    final slots = SiteVisitSchedule.slots(
      date: date,
      now: DateTime.now(),
      after: isEnd ? _startsOn : null,
      includeMidnight: isEnd,
    );
    if (slots.isEmpty) {
      _showError('No available times. Choose a later visit date.');
      return;
    }
    final selected = isEnd ? _endsOn : _startsOn;
    final picked = await showModalBottomSheet<DateTime>(
      context: context,
      builder:
          (context) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    isEnd ? 'Select end time' : 'Select start time',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: slots.length,
                    itemBuilder:
                        (context, index) => ListTile(
                          title: Text(_timeLabel(slots[index])),
                          selected: slots[index] == selected,
                          onTap: () {
                            if (slots[index].isBefore(DateTime.now())) {
                              _showError(
                                'This time has passed. Choose a later time.',
                              );
                              return;
                            }
                            Navigator.of(context).pop(slots[index]);
                          },
                        ),
                  ),
                ),
              ],
            ),
          ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (isEnd) {
        _endsOn = picked;
      } else {
        _startsOn = picked;
        if (_endsOn != null && !_endsOn!.isAfter(picked)) _endsOn = null;
      }
    });
  }

  Future<void> _createEvent() async {
    if (!_eventFormKey.currentState!.validate()) return;
    final date = _visitDate;
    if (date == null) return;
    final timeError = SiteVisitSchedule.validate(
      start: _startsOn,
      end: _endsOn,
      now: DateTime.now(),
    );
    if (timeError != null) {
      _showError(timeError);
      return;
    }
    setState(() => _saving = true);
    try {
      final startsOn = DateFormat('yyyy-MM-dd HH:mm:ss').format(_startsOn!);
      final endsOn = DateFormat('yyyy-MM-dd HH:mm:ss').format(_endsOn!);
      final result = await SiteVisitCreationApi.createEvent(
        opportunity: _opportunity!,
        locationRow: _savedLocationRow,
        summary: _summaryController.text.trim(),
        startsOn: startsOn,
        endsOn: endsOn,
        assignedTo: _assignedTo!,
        category: _eventCategory!,
        productEnquired: _product ?? '',
      );
      if (!mounted) return;
      final eventName = result['event']?.toString() ?? '';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            eventName.isEmpty
                ? 'Site visit created.'
                : 'Site visit $eventName created.',
          ),
        ),
      );
      Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) _showError(_message(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  InputDecoration _decoration(
    String label, {
    String? hint,
    Widget? prefixIcon,
  }) => InputDecoration(
    labelText: label,
    hintText: hint,
    prefixIcon: prefixIcon,
    filled: true,
    fillColor: Colors.white,
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(13),
      borderSide: const BorderSide(color: Color(0xFFE3E8EF)),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(13),
      borderSide: const BorderSide(color: Color(0xFFE3E8EF)),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(13),
      borderSide: const BorderSide(color: _visitBlue, width: 1.5),
    ),
  );

  Widget _sectionCard({required Widget child}) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: const Color(0xFFE8EBEF)),
    ),
    child: child,
  );

  Widget _buildLocationStep() {
    if (_opportunities.isEmpty) {
      return _emptyMessage(
        _error ?? 'No opportunities were found.',
        canRetry: _error != null,
      );
    }
    return Form(
      key: _locationFormKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _StepHeading(number: '1', title: 'Customer location'),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _mobileController,
                  keyboardType: TextInputType.phone,
                  textInputAction: TextInputAction.next,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9+ ]')),
                  ],
                  decoration: _decoration(
                    'Mobile number',
                    hint: 'Search opportunities by mobile number',
                    prefixIcon: const Icon(Icons.phone_outlined),
                  ).copyWith(
                    helperText: _mobileSearchMessage,
                    helperMaxLines: 2,
                    suffixIcon:
                        _mobileSearching
                            ? const Padding(
                              padding: EdgeInsets.all(14),
                              child: SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: _visitBlue,
                                ),
                              ),
                            )
                            : _mobileController.text.isEmpty
                            ? null
                            : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (_mobileSearchFailed)
                                  IconButton(
                                    tooltip: 'Retry mobile search',
                                    icon: const Icon(Icons.refresh_rounded),
                                    onPressed:
                                        () => _onMobileChanged(
                                          _mobileController.text,
                                        ),
                                  ),
                                IconButton(
                                  tooltip: 'Clear mobile search',
                                  icon: const Icon(Icons.close_rounded),
                                  onPressed: () {
                                    _mobileController.clear();
                                    _onMobileChanged('');
                                  },
                                ),
                              ],
                            ),
                  ),
                  onChanged: _onMobileChanged,
                ),
                const SizedBox(height: 13),
                Autocomplete<Map<String, dynamic>>(
                  key: ValueKey(
                    'opportunity-$_mobileSearchId-$_mobileSearching',
                  ),
                  initialValue: TextEditingValue(
                    text: _initialOpportunityQuery ?? '',
                  ),
                  displayStringForOption: _opportunityLabel,
                  optionsBuilder: (textEditingValue) {
                    // A mobile search narrows the list to its matches.
                    final source = _mobileMatches ?? _opportunities;
                    final query = textEditingValue.text.trim().toLowerCase();
                    if (query.isEmpty) return source;
                    return source.where((opportunity) {
                      final label =
                          _opportunityLabel(opportunity).toLowerCase();
                      final name =
                          opportunity['name']?.toString().toLowerCase() ?? '';
                      final party =
                          opportunity['party_name']?.toString().toLowerCase() ??
                          '';
                      return label.contains(query) ||
                          party.contains(query) ||
                          name.contains(query);
                    });
                  },
                  onSelected: _selectOpportunity,
                  fieldViewBuilder: (
                    context,
                    controller,
                    focusNode,
                    onFieldSubmitted,
                  ) {
                    _opportunityFieldController = controller;
                    _opportunityFocusNode = focusNode;
                    return TextFormField(
                      controller: controller,
                      focusNode: focusNode,
                      textInputAction: TextInputAction.next,
                      decoration: _decoration(
                        'Opportunity *',
                        hint:
                            _mobileMatches == null
                                ? 'Type to search opportunities'
                                : 'Choose from mobile number matches',
                        prefixIcon: const Icon(Icons.search_rounded),
                      ),
                      onChanged: (_) {
                        if (_opportunity != null) {
                          setState(() {
                            _opportunity = null;
                            _product = null;
                          });
                        }
                      },
                      onFieldSubmitted: (_) => onFieldSubmitted(),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Opportunity is required.';
                        }
                        if (_opportunity == null) {
                          return 'Select an opportunity from suggestions.';
                        }
                        return null;
                      },
                    );
                  },
                  optionsViewBuilder:
                      (context, onSelected, options) => Align(
                        alignment: Alignment.topLeft,
                        child: Material(
                          elevation: 5,
                          borderRadius: BorderRadius.circular(12),
                          clipBehavior: Clip.antiAlias,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 250),
                            child: ListView.builder(
                              padding: EdgeInsets.zero,
                              shrinkWrap: true,
                              itemCount: options.length,
                              itemBuilder: (context, index) {
                                final opportunity = options.elementAt(index);
                                final label = _opportunityLabel(opportunity);
                                final party =
                                    opportunity['party_name']
                                        ?.toString()
                                        .trim() ??
                                    '';
                                return ListTile(
                                  title: Text(label),
                                  subtitle: party.isEmpty ? null : Text(party),
                                  onTap: () => onSelected(opportunity),
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                ),
                const SizedBox(height: 13),
                DropdownButtonFormField<String>(
                  key: ValueKey('product-$_opportunity-$_product'),
                  initialValue: _product,
                  isExpanded: true,
                  hint: const Text('Select product enquired'),
                  decoration: _decoration(
                    'Product enquired',
                    hint: 'Select product enquired',
                    prefixIcon: const Icon(Icons.inventory_2_outlined),
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: '',
                      child: Text('Select product enquired'),
                    ),
                    for (final product in _productOptions)
                      DropdownMenuItem(
                        value: product,
                        child: Text(product, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (value) => setState(() => _product = value),
                ),
                const SizedBox(height: 13),
                TextFormField(
                  controller: _mapLinkController,
                  enabled: !_saving,
                  keyboardType: TextInputType.url,
                  onChanged: _onMapLinkChanged,
                  onFieldSubmitted: (_) => _previewMapLink(),
                  textInputAction: TextInputAction.next,
                  decoration: _decoration(
                    'Customer map link *',
                    hint: 'Paste a Google Maps link',
                    prefixIcon: const Icon(Icons.link_rounded),
                  ),
                  validator:
                      (value) =>
                          value == null || value.trim().isEmpty
                              ? 'Map link is required.'
                              : null,
                ),
                const SizedBox(height: 13),
                DropdownButtonFormField<String>(
                  value: _locationType,
                  isExpanded: true,
                  decoration: _decoration('Location type *'),
                  items: [
                    for (final type in _siteLocationTypes)
                      DropdownMenuItem(value: type, child: Text(type)),
                  ],
                  onChanged: (value) => setState(() => _locationType = value),
                  validator:
                      (value) =>
                          value == null ? 'Select a location type.' : null,
                ),
                const SizedBox(height: 10),
                _locationMapPicker(),
                const SizedBox(height: 10),
                const Text(
                  'The map link will be resolved to latitude and longitude and saved with this opportunity location.',
                  style: TextStyle(
                    color: _visitMuted,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _primaryButton(
            label: 'Save location and continue',
            onPressed: _saving ? null : _saveLocation,
          ),
        ],
      ),
    );
  }

  Widget _buildEventStep() {
    final opportunity = _opportunities.firstWhere(
      (item) => item['name']?.toString() == _opportunity,
      orElse: () => <String, dynamic>{},
    );
    final locationLabel = _locationType ?? 'Customer location';
    return Form(
      key: _eventFormKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _StepHeading(number: '2', title: 'Event details'),
                const SizedBox(height: 14),
                _linkedInfo(
                  Icons.business_outlined,
                  _opportunityLabel(opportunity),
                  opportunity['party_name']?.toString() ?? '',
                ),
                const SizedBox(height: 10),
                _linkedInfo(
                  Icons.place_outlined,
                  locationLabel,
                  _mapLinkController.text.trim(),
                ),
                if (_product?.isNotEmpty ?? false) ...[
                  const SizedBox(height: 10),
                  _linkedInfo(
                    Icons.inventory_2_outlined,
                    'Product enquired',
                    _product!,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 12),
          _sectionCard(
            child: Column(
              children: [
                DropdownButtonFormField<String>(
                  initialValue: _eventCategory,
                  isExpanded: true,
                  hint: const Text('Select event category'),
                  decoration: _decoration('Event category *'),
                  items: [
                    for (final category in _eventCategories)
                      DropdownMenuItem(
                        value: category,
                        child: Text(category, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (value) => setState(() => _eventCategory = value),
                  validator:
                      (value) => value == null ? 'Select a category.' : null,
                ),
                const SizedBox(height: 13),
                FormField<DateTime>(
                  initialValue: _visitDate,
                  validator: (_) {
                    if (_visitDate == null) return 'Date is required.';
                    if (_visitDate!.isBefore(
                      DateUtils.dateOnly(DateTime.now()),
                    )) {
                      return 'The visit date cannot be in the past.';
                    }
                    return null;
                  },
                  builder:
                      (field) => Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          InkWell(
                            borderRadius: BorderRadius.circular(13),
                            onTap: _pickDate,
                            child: InputDecorator(
                              decoration: _decoration(
                                'Date *',
                                prefixIcon: const Icon(
                                  Icons.calendar_month_outlined,
                                ),
                              ).copyWith(errorText: field.errorText),
                              child: Text(
                                _visitDate == null
                                    ? 'Select visit date'
                                    : DateFormat(
                                      'EEE, d MMM yyyy',
                                    ).format(_visitDate!),
                                style: TextStyle(
                                  color:
                                      _visitDate == null
                                          ? _visitMuted
                                          : _visitInk,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                ),
                const SizedBox(height: 13),
                _timeField(isEnd: false),
                const SizedBox(height: 13),
                _timeField(isEnd: true),
                const SizedBox(height: 13),
                TextFormField(
                  key: ValueKey('assignee-$_opportunity-$_assignedTo'),
                  initialValue:
                      _assignedTo == _currentUser
                          ? 'Assign to me ($_currentUser)'
                          : _assignedTo ?? '',
                  readOnly: true,
                  decoration: _decoration('Assigned to *').copyWith(
                    hintText: 'Search and select a user',
                    suffixIcon: const Icon(Icons.search_rounded),
                  ),
                  onTap: _pickAssignee,
                  validator:
                      (_) => _assignedTo == null ? 'Choose an assignee.' : null,
                ),
                const SizedBox(height: 13),
                TextFormField(
                  controller: _summaryController,
                  textCapitalization: TextCapitalization.sentences,
                  maxLines: 2,
                  maxLength: 140,
                  decoration: _decoration(
                    'Summary *',
                    hint: 'Describe the visit',
                  ),
                  validator:
                      (value) =>
                          value == null || value.trim().isEmpty
                              ? 'Summary is required.'
                              : null,
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _primaryButton(
            label: 'Create site visit',
            onPressed: _saving ? null : _createEvent,
          ),
          const SizedBox(height: 8),
          Center(
            child: TextButton.icon(
              onPressed:
                  _saving ? null : () => setState(() => _eventStep = false),
              icon: const Icon(Icons.arrow_back_rounded),
              label: const Text('Edit customer location'),
              style: TextButton.styleFrom(foregroundColor: _visitBlue),
            ),
          ),
        ],
      ),
    );
  }

  Widget _timeField({required bool isEnd}) {
    final value = isEnd ? _endsOn : _startsOn;
    return FormField<DateTime>(
      key: ValueKey('${isEnd ? 'end' : 'start'}-$value'),
      initialValue: value,
      validator: (_) {
        if (value == null) {
          return isEnd ? 'Select an end time.' : 'Select a start time.';
        }
        if (!isEnd && value.isBefore(DateTime.now())) {
          return 'The start time cannot be in the past.';
        }
        if (isEnd) {
          return SiteVisitSchedule.validate(
            start: _startsOn,
            end: _endsOn,
            now: DateTime.now(),
          );
        }
        return null;
      },
      builder:
          (field) => InkWell(
            borderRadius: BorderRadius.circular(13),
            onTap: () => _pickTime(isEnd: isEnd),
            child: InputDecorator(
              decoration: _decoration(
                isEnd ? 'End time *' : 'Start time *',
                prefixIcon: const Icon(Icons.access_time_rounded),
              ).copyWith(errorText: field.errorText),
              child: Text(
                value == null
                    ? 'Select time (15-minute intervals)'
                    : _timeLabel(value),
                style: TextStyle(
                  color: value == null ? _visitMuted : _visitInk,
                ),
              ),
            ),
          ),
    );
  }

  Future<void> _pickAssignee() async {
    final items = _assigneeItems();
    var query = '';
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder:
          (context) => StatefulBuilder(
            builder: (context, setSheetState) {
              final matches =
                  items.where((item) {
                    final username = item.value?.toLowerCase() ?? '';
                    final label =
                        (item.child as Text).data?.toLowerCase() ?? '';
                    return username.contains(query) || label.contains(query);
                  }).toList();
              final keyboardHeight = MediaQuery.viewInsetsOf(context).bottom;
              return SafeArea(
                child: Padding(
                  padding: EdgeInsets.only(bottom: keyboardHeight),
                  child: SizedBox(
                    height:
                        (MediaQuery.sizeOf(context).height - keyboardHeight) *
                        0.7,
                    child: Column(
                      children: [
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text(
                            'Assigned to',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: TextField(
                            autofocus: true,
                            decoration: _decoration(
                              'Search username',
                              hint: 'Type a username or email',
                              prefixIcon: const Icon(Icons.search_rounded),
                            ),
                            onChanged:
                                (value) => setSheetState(() {
                                  query = value.trim().toLowerCase();
                                }),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child:
                              matches.isEmpty
                                  ? const Center(
                                    child: Text('No matching users.'),
                                  )
                                  : ListView.builder(
                                    itemCount: matches.length,
                                    itemBuilder: (context, index) {
                                      final item = matches[index];
                                      return ListTile(
                                        title: item.child,
                                        trailing:
                                            item.value == _assignedTo
                                                ? const Icon(
                                                  Icons.check_rounded,
                                                  color: _visitBlue,
                                                )
                                                : null,
                                        onTap:
                                            () => Navigator.of(
                                              context,
                                            ).pop(item.value),
                                      );
                                    },
                                  ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
    );
    if (selected != null && mounted) {
      setState(() => _assignedTo = selected);
    }
  }

  /// "Assign to me" first, then other enabled users by ERP login username.
  List<DropdownMenuItem<String>> _assigneeItems() {
    final others =
        _users
            .where((user) => user['name']?.toString() != _currentUser)
            .toList()
          ..sort(
            (a, b) => (a['name']?.toString() ?? '').toLowerCase().compareTo(
              (b['name']?.toString() ?? '').toLowerCase(),
            ),
          );
    final me = _users.where((user) => user['name']?.toString() == _currentUser);
    return [
      if (me.isNotEmpty)
        DropdownMenuItem(
          value: _currentUser,
          child: Text(
            'Assign to me ($_currentUser)',
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      for (final user in others)
        DropdownMenuItem(
          value: user['name']?.toString(),
          child: Text(
            user['name']?.toString() ?? '',
            overflow: TextOverflow.ellipsis,
          ),
        ),
    ];
  }

  Widget _linkedInfo(IconData icon, String title, String subtitle) => Row(
    children: [
      Icon(icon, size: 19, color: _visitBlue),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                color: _visitInk,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (subtitle.isNotEmpty)
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: _visitMuted, fontSize: 12),
              ),
          ],
        ),
      ),
    ],
  );

  Widget _primaryButton({
    required String label,
    required VoidCallback? onPressed,
  }) => SizedBox(
    width: double.infinity,
    height: 50,
    child: FilledButton.icon(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: _visitBlue,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      icon:
          _saving
              ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
              : const Icon(Icons.arrow_forward_rounded),
      label: Text(
        _saving ? 'Saving...' : label,
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
  );

  Widget _emptyMessage(String message, {bool canRetry = false}) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.event_busy_outlined, size: 42, color: _visitMuted),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: _visitMuted),
          ),
          if (canRetry) ...[
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () {
                setState(() {
                  _loading = true;
                  _error = null;
                });
                _loadOptions();
              },
              child: const Text('Try again'),
            ),
          ],
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        elevation: 0,
        iconTheme: const IconThemeData(color: _visitInk),
        title: Text(
          _eventStep ? 'Event Details' : 'New Visit',
          style: const TextStyle(color: _visitInk, fontWeight: FontWeight.w800),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(4),
          child: LinearProgressIndicator(
            value: _eventStep ? 1 : 0.5,
            minHeight: 3,
            backgroundColor: const Color(0xFFEAF0F8),
            color: _visitBlue,
          ),
        ),
      ),
      body:
          _loading
              ? const Center(
                child: CircularProgressIndicator(color: _visitBlue),
              )
              : SafeArea(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
                  child: _eventStep ? _buildEventStep() : _buildLocationStep(),
                ),
              ),
    );
  }
}

class _StepHeading extends StatelessWidget {
  const _StepHeading({required this.number, required this.title});

  final String number;
  final String title;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      CircleAvatar(
        radius: 15,
        backgroundColor: const Color(0xFFEAF3FF),
        child: Text(
          number,
          style: const TextStyle(
            color: _visitBlue,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      const SizedBox(width: 10),
      Text(
        title,
        style: const TextStyle(
          color: _visitInk,
          fontSize: 16,
          fontWeight: FontWeight.w800,
        ),
      ),
    ],
  );
}
