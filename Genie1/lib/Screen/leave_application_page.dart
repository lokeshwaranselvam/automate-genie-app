import '../utils/widget/pull_to_refresh.dart';
import '../utils/widget/ag_path_loading_indicator.dart';
import 'package:homegenie/utils/theme/brand_theme.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../utils/api/leave_application_api.dart';
import '../utils/api_business_policy.dart';
import '../utils/widget/warning.dart';

const _leaveBlue = BrandColors.ink;
const _leaveInk = Color(0xFF202B3C);
const _leaveBorder = Color(0xFFDDE2E7);

class LeaveApplicationPage extends StatefulWidget {
  const LeaveApplicationPage({
    super.key,
    required this.onBack,
    required this.onNotifications,
  });

  final VoidCallback onBack;
  final VoidCallback onNotifications;

  @override
  State<LeaveApplicationPage> createState() => _LeaveApplicationPageState();
}

class _LeaveApplicationPageState extends State<LeaveApplicationPage> {
  ApiBusinessPolicy get _policy =>
      _options?.businessPolicy ?? ApiBusinessPolicy.empty;
  final _formKey = GlobalKey<FormState>();
  final _reasonController = TextEditingController();
  final _api = LeaveApplicationApi();
  LeaveApplicationOptions? _options;
  String? _leaveType;
  DateTime _fromDate = DateUtils.dateOnly(DateTime.now());
  DateTime _toDate = DateUtils.dateOnly(DateTime.now());
  bool _halfDay = false;
  bool _loading = true;
  bool _submitting = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _loadOptions();
  }

  @override
  void dispose() {
    _reasonController.dispose();
    _api.close();
    super.dispose();
  }

  String _errorMessage(Object error) => error.toString().replaceFirst(
    RegExp(r'^(Bad state|StateError|FormatException):\s*'),
    '',
  );

  Future<void> _loadOptions() async {
    if (_submitting) return;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final options = await _api.loadOptions();
      if (!mounted) return;
      setState(() {
        _options = options;
        _policy.applyDefault('description', _reasonController);
        final fromDefault = DateTime.tryParse(
          _policy.field('from_date')['default']?.toString() ?? '',
        );
        final toDefault = DateTime.tryParse(
          _policy.field('to_date')['default']?.toString() ?? '',
        );
        if (fromDefault != null && _policy.readOnly('from_date'))
          _fromDate = fromDefault;
        if (toDefault != null && _policy.readOnly('to_date'))
          _toDate = toDefault;
        final typeDefault = _policy.field('leave_type')['default']?.toString();
        if ((_leaveType == null || _policy.readOnly('leave_type')) &&
            options.leaveTypes.any((option) => option.value == typeDefault))
          _leaveType = typeDefault;
        if (_policy.rules['half_day_allowed'] == false) _halfDay = false;
        final halfDayDefault = _policy.field('half_day')['default'];
        if (_policy.readOnly('half_day') && halfDayDefault is bool)
          _halfDay = halfDayDefault;
        _clampPolicyDates();
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError =
            error is TimeoutException
                ? 'Loading leave options timed out. Please try again.'
                : _errorMessage(error);
      });
    }
  }

  double get _totalDays {
    final start = DateTime.utc(_fromDate.year, _fromDate.month, _fromDate.day);
    final end = DateTime.utc(_toDate.year, _toDate.month, _toDate.day);
    // The form previews the calendar range. ERPNext calculates the final
    // leave total (including holiday rules) when the application is inserted.
    return end.difference(start).inDays + 1 - (_halfDay ? 0.5 : 0);
  }

  String _daysLabel(double days) =>
      '${NumberFormat('0.#').format(days)} ${days == 1 ? 'day' : 'days'}';

  void _clampPolicyDates() {
    final earliest = DateTime.tryParse(
      _policy.rules['earliest_date']?.toString() ?? '',
    );
    final latest = DateTime.tryParse(
      _policy.rules['latest_date']?.toString() ?? '',
    );
    if (earliest != null && _fromDate.isBefore(earliest)) _fromDate = earliest;
    if (latest != null && _fromDate.isAfter(latest)) _fromDate = latest;
    if (_toDate.isBefore(_fromDate)) _toDate = _fromDate;
    if (latest != null && _toDate.isAfter(latest)) _toDate = latest;
  }

  Future<void> _pickDate({required bool isEnd}) async {
    if (_submitting) return;
    final today = DateTime.now();
    final earliest =
        DateTime.tryParse(_policy.rules['earliest_date']?.toString() ?? '') ??
        DateTime(today.year - 5);
    final latest =
        DateTime.tryParse(_policy.rules['latest_date']?.toString() ?? '') ??
        DateTime(today.year + 5, 12, 31);
    final minimum = isEnd && _fromDate.isAfter(earliest) ? _fromDate : earliest;
    final current = isEnd ? _toDate : _fromDate;
    final selected = await showDatePicker(
      context: context,
      initialDate:
          current.isBefore(minimum)
              ? minimum
              : current.isAfter(latest)
              ? latest
              : current,
      firstDate: minimum,
      lastDate: latest,
      helpText: isEnd ? 'To Date' : 'From Date',
      builder:
          (context, child) => Theme(
            data: Theme.of(context).copyWith(
              colorScheme: Theme.of(
                context,
              ).colorScheme.copyWith(primary: _leaveBlue),
            ),
            child: child!,
          ),
    );
    if (selected == null || !mounted) return;
    setState(() {
      if (isEnd) {
        _toDate = selected;
      } else {
        _fromDate = selected;
        if (_toDate.isBefore(selected)) _toDate = selected;
      }
    });
  }

  Future<void> _submit() async {
    if (_submitting || _options == null) return;
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() => _submitting = true);
    try {
      final result = await _api.submitApplication(
        leaveType: _leaveType ?? '',
        fromDate: _fromDate,
        toDate: _toDate,
        reason: _reasonController.text,
        halfDay: _halfDay,
        csrfToken: _options!.csrfToken,
      );
      if (!mounted) return;
      final days = result.totalLeaveDays;
      Warning.show(
        context,
        'Leave Application ${result.name} created${days == null ? '.' : ' for ${_daysLabel(days)}.'}',
        'Success',
      );
      _reasonController.clear();
      _formKey.currentState!.reset();
      setState(() {
        _leaveType = null;
        _halfDay = false;
        _fromDate = DateUtils.dateOnly(DateTime.now());
        _toDate = _fromDate;
        _clampPolicyDates();
      });
      await _loadOptions();
    } catch (error) {
      if (!mounted) return;
      Warning.show(
        context,
        error is TimeoutException
            ? 'Submission timed out. Check Leave Applications in ERPNext before retrying; it may have been saved.'
            : _errorMessage(error),
        error is TimeoutException ? 'Warning' : 'Error',
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  InputDecoration _decoration({String? hint, Widget? suffixIcon}) =>
      InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Color(0xFF8B929B), fontSize: 14),
        filled: true,
        fillColor: Colors.white,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 13,
        ),
        suffixIcon: suffixIcon,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: _leaveBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: _leaveBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: _leaveBlue, width: 1.5),
        ),
      );

  String _fieldName(String label) =>
      const {
        'Reason': 'description',
        'Leave Type': 'leave_type',
        'From Date': 'from_date',
        'To Date': 'to_date',
      }[label] ??
      label;

  Widget _label(String label) =>
      !_policy.visible(_fieldName(label))
          ? const SizedBox.shrink()
          : Padding(
            padding: const EdgeInsets.only(bottom: 7),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: label),
                  if (_policy.required(_fieldName(label), true))
                    const TextSpan(
                      text: ' *',
                      style: TextStyle(color: Color(0xFFC84B55)),
                    ),
                ],
              ),
              style: const TextStyle(
                color: _leaveInk,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          );

  Widget _dateField({required bool isEnd}) => BusinessPolicyField(
    policy: _policy,
    name: isEnd ? 'to_date' : 'from_date',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _label(isEnd ? 'To Date' : 'From Date'),
        InkWell(
          key: ValueKey(isEnd ? 'leave-to-date' : 'leave-from-date'),
          onTap: _submitting ? null : () => _pickDate(isEnd: isEnd),
          borderRadius: BorderRadius.circular(8),
          child: InputDecorator(
            decoration: _decoration(
              suffixIcon: const Icon(
                Icons.calendar_month_outlined,
                size: 21,
                color: Color(0xFF727C89),
              ),
            ),
            child: Text(
              DateFormat('dd MMM yyyy').format(isEnd ? _toDate : _fromDate),
              style: const TextStyle(color: _leaveInk, fontSize: 14),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _form() => Form(
    key: _formKey,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _label('Leave Type'),
        BusinessPolicyField(
          policy: _policy,
          name: 'leave_type',
          child: DropdownButtonFormField<String>(
            key: const ValueKey('leave-type'),
            initialValue: _leaveType,
            decoration: _decoration(hint: 'Select Leave Type'),
            isExpanded: true,
            icon: const Icon(
              Icons.keyboard_arrow_down_rounded,
              size: 22,
              color: Color(0xFF727C89),
            ),
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: _leaveInk, fontSize: 14),
            items:
                _options!.leaveTypes
                    .map(
                      (type) => DropdownMenuItem(
                        value: type.value,
                        child: Text(type.label),
                      ),
                    )
                    .toList(),
            onChanged:
                _submitting || _policy.readOnly('leave_type')
                    ? null
                    : (value) => setState(() => _leaveType = value),
            validator:
                (value) => _policy.validate(
                  'leave_type',
                  value,
                  legacyRequired: true,
                  requiredMessage: 'Choose a leave type.',
                ),
          ),
        ),
        const SizedBox(height: 20),
        _dateField(isEnd: false),
        const SizedBox(height: 20),
        _dateField(isEnd: true),
        const SizedBox(height: 22),
        Row(
          children: [
            const Text(
              'Total Days',
              style: TextStyle(
                color: _leaveInk,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 24),
            Text(
              _daysLabel(_totalDays),
              key: const ValueKey('leave-total-days'),
              style: const TextStyle(
                color: _leaveInk,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        const Divider(height: 1, color: Color(0xFFEEF0F3)),
        const SizedBox(height: 18),
        _label('Reason'),
        BusinessPolicyField(
          policy: _policy,
          name: 'description',
          child: TextFormField(
            key: const ValueKey('leave-reason'),
            controller: _reasonController,
            maxLength: _policy.maxLength('description'),
            readOnly: _policy.readOnly('description'),
            enabled: !_submitting,
            minLines: 3,
            maxLines: 5,
            textCapitalization: TextCapitalization.sentences,
            style: const TextStyle(color: _leaveInk, fontSize: 14),
            decoration: _decoration(hint: 'Enter reason for leave'),
            validator:
                (value) => _policy.validate(
                  'description',
                  value,
                  legacyRequired: true,
                  requiredMessage: 'Reason is required.',
                ),
          ),
        ),
        const SizedBox(height: 8),
        BusinessPolicyField(
          policy: _policy,
          name: 'half_day',
          child: Row(
            children: [
              SizedBox(
                width: 24,
                child: Checkbox(
                  key: const ValueKey('leave-half-day'),
                  value: _halfDay,
                  activeColor: _leaveBlue,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(3),
                  ),
                  onChanged:
                      _submitting || _policy.rules['half_day_allowed'] == false
                          ? null
                          : (value) =>
                              setState(() => _halfDay = value ?? false),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: GestureDetector(
                  onTap:
                      _submitting || _policy.rules['half_day_allowed'] == false
                          ? null
                          : () => setState(() => _halfDay = !_halfDay),
                  child: const Text(
                    'Apply for half day',
                    style: TextStyle(color: _leaveInk, fontSize: 13),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        SizedBox(
          height: 48,
          child: FilledButton(
            key: const ValueKey('leave-submit'),
            onPressed: _submitting ? null : _submit,
            style: FilledButton.styleFrom(
              backgroundColor: _leaveBlue,
              foregroundColor: Colors.white,
              shape: const StadiumBorder(),
            ).copyWith(backgroundBuilder: BrandColors.buttonBackground),
            child:
                _submitting
                    ? const SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                    : const Text(
                      'Submit Application',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.white,
    appBar: brandAppBar(
      elevation: 0,
      leading: IconButton(
        tooltip: 'Back to More',
        onPressed: widget.onBack,
        icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
      ),
      titleSpacing: 0,
      title: const Text(
        'Leave Application',
        style: TextStyle(
          color: Colors.white,
          fontSize: 18,
          fontWeight: FontWeight.w700,
        ),
      ),
      actions: [
        IconButton(
          tooltip: 'Notifications',
          onPressed: widget.onNotifications,
          icon: const Icon(Icons.notifications_rounded, color: Colors.white),
        ),
        const SizedBox(width: 6),
      ],
    ),
    body: PullToRefresh(
      enabled: !_loading && !_submitting,
      onRefresh: _loadOptions,
      child: SafeArea(
        top: false,
        child:
            _loading
                ? const Center(child: AgPathLoadingIndicator())
                : _loadError != null
                ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_loadError!, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                      ],
                    ),
                  ),
                )
                : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
                  child: _form(),
                ),
      ),
    ),
  );
}
