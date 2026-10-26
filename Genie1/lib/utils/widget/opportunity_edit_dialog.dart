import 'dart:convert';

import 'package:flutter/material.dart';

import '../api/opportunity_api.dart';
import '../api_business_policy.dart';
import 'warning.dart';

/// Returns a patch containing only values the user changed.
class OpportunityEditDialog extends StatefulWidget {
  const OpportunityEditDialog({
    super.key,
    required this.document,
    required this.options,
    this.onSave,
  });
  final Map<String, dynamic> document;
  final OpportunityEditOptions options;
  final Future<void> Function(Map<String, dynamic>)? onSave;

  @override
  State<OpportunityEditDialog> createState() => _OpportunityEditDialogState();
}

class _OpportunityEditDialogState extends State<OpportunityEditDialog> {
  late String _status;
  late String _date;
  late final List<Map<String, dynamic>> _rows;
  final _newNote = TextEditingController();
  bool _saving = false;
  static const _eventRequiredMessage = Warning.opportunityEventRequiredMessage;

  List get _dependencies =>
      widget.options.businessPolicy.rules['dependencies'] is List
          ? widget.options.businessPolicy.rules['dependencies'] as List
          : const [
            {
              'statuses': ['Demo'],
              'message': _eventRequiredMessage,
            },
          ];
  bool _statusRequiresRelatedDocument(String status) => _dependencies
      .whereType<Map>()
      .any((rule) => (rule['statuses'] as List? ?? []).contains(status));
  String _dependencyMessage(String status) =>
      _dependencies
          .whereType<Map>()
          .where((rule) => (rule['statuses'] as List? ?? []).contains(status))
          .firstOrNull?['message']
          ?.toString() ??
      _eventRequiredMessage;

  bool get _noteRequired =>
      widget.options.businessPolicy.required('note') ||
      ((widget.options.businessPolicy.rules['note_on_status_change'] ?? true) &&
          _status != (widget.document['status']?.toString() ?? '')) ||
      ((widget.options.businessPolicy.rules['note_on_followup_change'] ??
              true) &&
          widget.options.followUpField != null &&
          _date !=
              (widget.document[widget.options.followUpField]?.toString() ??
                  ''));

  String _richText(String value) =>
      '<p>${const HtmlEscape().convert(value).replaceAll('\n', '<br>')}</p>';

  @override
  void initState() {
    super.initState();
    _status = widget.document['status']?.toString() ?? '';
    _date = widget.document[widget.options.followUpField]?.toString() ?? '';
    widget.options.businessPolicy.applyDefault('note', _newNote);
    _rows =
        (widget.document['notes'] as List? ?? [])
            .whereType<Map>()
            .map((row) => Map<String, dynamic>.from(row))
            .toList();
  }

  @override
  void dispose() {
    _newNote.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final current = DateTime.tryParse(_date);
    final firstDate = widget.options.firstFollowupDate;
    final lastDate = DateTime(2200);
    final selected = await showDatePicker(
      context: context,
      initialDate:
          current != null &&
                  !current.isBefore(firstDate) &&
                  !current.isAfter(lastDate)
              ? current
              : firstDate,
      firstDate: firstDate,
      lastDate: lastDate,
    );
    if (selected != null && mounted) {
      setState(
        () =>
            _date =
                '${selected.year.toString().padLeft(4, '0')}-${selected.month.toString().padLeft(2, '0')}-${selected.day.toString().padLeft(2, '0')}',
      );
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    final policy = widget.options.businessPolicy;
    final inputError =
        policy.validate('status', _status) ??
        policy.validate('followup_date', _date);
    if (inputError != null) {
      Warning.show(context, inputError, 'Warning');
      return;
    }
    final changes = <String, dynamic>{};
    if (_status != widget.document['status']) changes['status'] = _status;
    final dateField = widget.options.followUpField;
    if (dateField != null) {
      final dateChanged =
          _date != (widget.document[dateField]?.toString() ?? '');
      if ((dateChanged || _date.isNotEmpty) &&
          !widget.options.isAllowedFollowupDate(_date)) {
        Warning.show(
          context,
          'Select a next follow-up date on or after ${widget.options.firstFollowupDate.toIso8601String().substring(0, 10)}, then save again.',
          'Warning',
        );
        return;
      }
      if (dateChanged) changes[dateField] = _date;
    }
    final newNote = _newNote.text.trim();
    final fieldError = widget.options.businessPolicy.validate('note', newNote);
    if (fieldError != null) {
      Warning.show(context, fieldError, 'Warning');
      return;
    }
    if (_noteRequired &&
        (newNote.isEmpty || widget.options.notesType == null)) {
      Warning.show(
        context,
        widget.options.notesType == null
            ? 'Notes could not be loaded. Close and reopen this form before changing the status or next follow-up date.'
            : 'Note required: Please add a new note explaining the status or next follow-up date change, then tap Save.',
        'Warning',
      );
      return;
    }
    if (widget.options.notesType != null && newNote.isNotEmpty) {
      // Append the new note without changing existing rows or their audit fields.
      changes['notes'] = [
        ..._rows.map((row) => Map<String, dynamic>.from(row)),
        {'doctype': widget.options.notesType, 'note': _richText(newNote)},
      ];
    }
    setState(() {
      _saving = true;
    });
    try {
      if (changes.isNotEmpty) await widget.onSave?.call(changes);
      if (mounted) Navigator.pop(context, changes);
    } catch (error) {
      if (mounted) {
        final detail =
            error is OpportunityActionError ? error.validationMessage : null;
        final demoEventRejected =
            _statusRequiresRelatedDocument(_status) &&
            error is OpportunityActionError &&
            error.statusCode == 417 &&
            (detail == null ||
                RegExp(r'\bevents?\b', caseSensitive: false).hasMatch(detail));
        Warning.show(
          context,
          demoEventRejected
              ? _eventRequiredMessage
              : detail ?? error.toString().replaceFirst('Bad state: ', ''),
          demoEventRejected ? 'Warning' : 'Error',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      title: const Text('Edit Opportunity'),
      content: SizedBox(
        width: 480,
        child: AbsorbPointer(
          absorbing: _saving,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                BusinessPolicyField(
                  policy: widget.options.businessPolicy,
                  name: 'status',
                  child: DropdownButtonFormField<String>(
                    initialValue:
                        widget.options
                                .statusesFor(
                                  widget.document['status']?.toString() ?? '',
                                )
                                .contains(_status)
                            ? _status
                            : null,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Status'),
                    items:
                        widget.options
                            .statusesFor(
                              widget.document['status']?.toString() ?? '',
                            )
                            .map(
                              (value) => DropdownMenuItem(
                                value: value,
                                child: Text(value),
                              ),
                            )
                            .toList(),
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() => _status = value);
                      if (_statusRequiresRelatedDocument(value) &&
                          widget.document['status'] != value) {
                        Warning.show(
                          context,
                          _dependencyMessage(value),
                          'Warning',
                        );
                      }
                    },
                  ),
                ),
                const SizedBox(height: 16),
                if (widget.options.followUpField != null)
                  BusinessPolicyField(
                    policy: widget.options.businessPolicy,
                    name: 'followup_date',
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: _pickDate,
                            icon: const Icon(Icons.calendar_today_outlined),
                            label: Text(
                              'Next follow-up date: ${_date.isEmpty ? 'Not set' : _date}',
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  const Text(
                    'The next follow-up Date field could not be identified in ERP.',
                  ),
                if (widget.options.notesType != null &&
                    widget.options.businessPolicy.visible('note')) ...[
                  const SizedBox(height: 16),
                  TextField(
                    controller: _newNote,
                    readOnly: widget.options.businessPolicy.readOnly('note'),
                    maxLength: widget.options.businessPolicy.maxLength('note'),
                    minLines: 2,
                    maxLines: 6,
                    decoration: InputDecoration(
                      labelText: 'Add note',
                      helperText:
                          _noteRequired
                              ? 'Required when changing status or follow-up date.'
                              : 'Add a new note without changing existing notes.',
                      helperMaxLines: 2,
                    ),
                  ),
                ] else if (widget.options.notesType == null)
                  const Text('The notes table could not be identified in ERP.'),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Saving…' : 'Save'),
        ),
      ],
    ),
  );
}
