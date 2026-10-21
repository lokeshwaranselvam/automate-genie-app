import 'dart:convert';

import 'package:flutter/material.dart';

import '../api/opportunity_api.dart';

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
  late final List<TextEditingController> _notes;
  late final List<String> _initialNotes;
  final _newNote = TextEditingController();
  bool _saving = false;
  String? _error;

  String _plainText(String value) =>
      value
          .replaceAll(
            RegExp(r'<br\s*/?>|</p>|</div>', caseSensitive: false),
            '\n',
          )
          .replaceAll(RegExp(r'<[^>]*>'), '')
          .replaceAll('&nbsp;', ' ')
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .replaceAll('&quot;', '"')
          .replaceAll('&#39;', "'")
          .replaceAll('&amp;', '&')
          .trim();

  String _richText(String value) =>
      '<p>${const HtmlEscape().convert(value).replaceAll('\n', '<br>')}</p>';

  @override
  void initState() {
    super.initState();
    _status = widget.document['status']?.toString() ?? '';
    _date = widget.document[widget.options.followUpField]?.toString() ?? '';
    _rows =
        (widget.document['notes'] as List? ?? [])
            .whereType<Map>()
            .map((row) => Map<String, dynamic>.from(row))
            .toList();
    // Keep original rich text unchanged unless the user edits that row.
    _initialNotes =
        _rows.map((row) => _plainText(row['note']?.toString() ?? '')).toList();
    _notes =
        _initialNotes.map((text) => TextEditingController(text: text)).toList();
  }

  @override
  void dispose() {
    for (final controller in _notes) {
      controller.dispose();
    }
    _newNote.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final current = DateTime.tryParse(_date);
    final firstDate = OpportunityApi.earliestFollowUpDate;
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
    final changes = <String, dynamic>{};
    if (_status != widget.document['status']) changes['status'] = _status;
    final dateField = widget.options.followUpField;
    if (dateField != null &&
        _date != (widget.document[dateField]?.toString() ?? '')) {
      if (!OpportunityApi.isFutureFollowUpDate(_date)) {
        setState(
          () => _error = 'Select a next follow-up date from tomorrow onward.',
        );
        return;
      }
      changes[dateField] = _date;
    }
    if (widget.options.notesType != null) {
      var edited = false;
      final rows = <Map<String, dynamic>>[];
      for (var i = 0; i < _rows.length; i++) {
        final row = {..._rows[i]};
        if (_notes[i].text != _initialNotes[i]) {
          row['note'] = _richText(_notes[i].text);
          edited = true;
        }
        rows.add(row);
      }
      if (_newNote.text.trim().isNotEmpty) {
        rows.add({
          'doctype': widget.options.notesType,
          'note': _richText(_newNote.text.trim()),
        });
        edited = true;
      }
      if (edited) changes['notes'] = rows;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (changes.isNotEmpty) await widget.onSave?.call(changes);
      if (mounted) Navigator.pop(context, changes);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error.toString().replaceFirst('Bad state: ', ''),
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
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                DropdownButtonFormField<String>(
                  initialValue:
                      OpportunityApi.editableStatuses.contains(_status)
                          ? _status
                          : null,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Status'),
                  items:
                      OpportunityApi.editableStatuses
                          .map(
                            (value) => DropdownMenuItem(
                              value: value,
                              child: Text(value),
                            ),
                          )
                          .toList(),
                  onChanged: (value) {
                    if (value != null) setState(() => _status = value);
                  },
                ),
                const SizedBox(height: 16),
                if (widget.options.followUpField != null)
                  Row(
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
                  )
                else
                  const Text(
                    'The next follow-up Date field could not be identified in ERP.',
                  ),
                if (widget.options.notesType != null) ...[
                  for (var i = 0; i < _notes.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: TextField(
                        controller: _notes[i],
                        minLines: 2,
                        maxLines: 6,
                        decoration: InputDecoration(labelText: 'Note ${i + 1}'),
                      ),
                    ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _newNote,
                    minLines: 2,
                    maxLines: 6,
                    decoration: const InputDecoration(labelText: 'Add note'),
                  ),
                ] else
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
