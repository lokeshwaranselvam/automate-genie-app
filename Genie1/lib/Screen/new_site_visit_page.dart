import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../utils/api/location_api.dart';
import '../utils/api/site_visit_creation_api.dart';

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

  bool _loading = true;
  bool _saving = false;
  bool _eventStep = false;
  String? _error;
  String? _opportunity;
  String? _initialOpportunityQuery;
  String? _locationType;
  String? _assignedTo;
  DateTime? _visitDate;
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
    _mapLinkController.dispose();
    _summaryController.dispose();
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
        if (_opportunities.length == 1) {
          final onlyOpportunity = _opportunities.first;
          _opportunity = onlyOpportunity['name']?.toString();
          _initialOpportunityQuery = _opportunityLabel(onlyOpportunity);
        }
        if (_users.any((user) => user['name']?.toString() == currentUser)) {
          _assignedTo = currentUser;
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
    for (final key in ['opportunity_name', 'party_name', 'customer_name']) {
      final value = opportunity[key]?.toString().trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    return opportunity['name']?.toString() ?? 'Opportunity';
  }

  String _userLabel(Map<String, dynamic> user) {
    final name = user['name']?.toString() ?? '';
    final fullName = user['full_name']?.toString().trim() ?? '';
    if (fullName.isEmpty || fullName == name) return name;
    return '$fullName · $name';
  }

  Future<void> _saveLocation() async {
    if (!_locationFormKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final link = _mapLinkController.text.trim();
      final coordinates = await LocationHelper.getCoordinatesFromMapLink(link);
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
        _savedLocationRow = rowName;
        _eventStep = true;
      });
    } catch (error) {
      if (mounted) _showError(_message(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickDate() async {
    final now = DateUtils.dateOnly(DateTime.now());
    final picked = await showDatePicker(
      context: context,
      initialDate: _visitDate ?? now,
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
    if (picked != null && mounted) setState(() => _visitDate = picked);
  }

  Future<void> _createEvent() async {
    if (!_eventFormKey.currentState!.validate()) return;
    final date = _visitDate;
    if (date == null) return;
    setState(() => _saving = true);
    try {
      final startsOn = DateFormat(
        'yyyy-MM-dd HH:mm:ss',
      ).format(DateTime(date.year, date.month, date.day, 9));
      final result = await SiteVisitCreationApi.createEvent(
        opportunity: _opportunity!,
        locationRow: _savedLocationRow,
        summary: _summaryController.text.trim(),
        startsOn: startsOn,
        assignedTo: _assignedTo!,
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
        _error ?? 'No opportunities created by your signed-in user were found.',
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
                Autocomplete<Map<String, dynamic>>(
                  initialValue: TextEditingValue(
                    text: _initialOpportunityQuery ?? '',
                  ),
                  displayStringForOption: _opportunityLabel,
                  optionsBuilder: (textEditingValue) {
                    final query = textEditingValue.text.trim().toLowerCase();
                    if (query.isEmpty) return _opportunities;
                    return _opportunities.where((opportunity) {
                      final label =
                          _opportunityLabel(opportunity).toLowerCase();
                      final name =
                          opportunity['name']?.toString().toLowerCase() ?? '';
                      return label.contains(query) || name.contains(query);
                    });
                  },
                  onSelected: (opportunity) {
                    setState(
                      () => _opportunity = opportunity['name']?.toString(),
                    );
                  },
                  fieldViewBuilder:
                      (
                        context,
                        controller,
                        focusNode,
                        onFieldSubmitted,
                      ) => TextFormField(
                        controller: controller,
                        focusNode: focusNode,
                        textInputAction: TextInputAction.next,
                        decoration: _decoration(
                          'Opportunity *',
                          hint: 'Type to search opportunities',
                          prefixIcon: const Icon(Icons.search_rounded),
                        ),
                        onChanged: (_) {
                          if (_opportunity != null) {
                            setState(() => _opportunity = null);
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
                      ),
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
                                final name =
                                    opportunity['name']?.toString() ?? '';
                                final label = _opportunityLabel(opportunity);
                                return ListTile(
                                  title: Text(label),
                                  subtitle: label == name ? null : Text(name),
                                  onTap: () => onSelected(opportunity),
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                ),
                const SizedBox(height: 13),
                TextFormField(
                  controller: _mapLinkController,
                  keyboardType: TextInputType.url,
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
                  opportunity['name']?.toString() ?? '',
                ),
                const SizedBox(height: 10),
                _linkedInfo(
                  Icons.place_outlined,
                  locationLabel,
                  _mapLinkController.text.trim(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _sectionCard(
            child: Column(
              children: [
                DropdownButtonFormField<String>(
                  value: 'Installation',
                  decoration: _decoration('Category *'),
                  items: const [
                    DropdownMenuItem(
                      value: 'Installation',
                      child: Text('Installation'),
                    ),
                  ],
                  onChanged: (_) {},
                  validator:
                      (value) => value == null ? 'Select a category.' : null,
                ),
                const SizedBox(height: 13),
                FormField<DateTime>(
                  initialValue: _visitDate,
                  validator:
                      (_) => _visitDate == null ? 'Date is required.' : null,
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
                DropdownButtonFormField<String>(
                  value: _assignedTo,
                  isExpanded: true,
                  decoration: _decoration('Assigned to *'),
                  items: [
                    for (final user in _users)
                      DropdownMenuItem(
                        value: user['name']?.toString(),
                        child: Text(
                          _userLabel(user),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) => setState(() => _assignedTo = value),
                  validator:
                      (value) => value == null ? 'Choose an assignee.' : null,
                ),
                const SizedBox(height: 13),
                TextFormField(
                  controller: _summaryController,
                  textCapitalization: TextCapitalization.sentences,
                  maxLines: 2,
                  maxLength: 140,
                  decoration: _decoration(
                    'Summary *',
                    hint: 'Describe the installation visit',
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
