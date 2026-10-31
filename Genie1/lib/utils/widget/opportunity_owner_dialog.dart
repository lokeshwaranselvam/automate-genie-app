import 'dart:async';

import 'package:flutter/material.dart';

import '../api/opportunity_api.dart';

class OpportunityOwnerDialog extends StatefulWidget {
  const OpportunityOwnerDialog({super.key, required this.document});
  final Map<String, dynamic> document;

  @override
  State<OpportunityOwnerDialog> createState() => _OpportunityOwnerDialogState();
}

class _OpportunityOwnerDialogState extends State<OpportunityOwnerDialog> {
  final _search = TextEditingController();
  Timer? _debounce;
  int _request = 0;
  bool _loading = true;
  bool _saving = false;
  String? _error;
  String? _selected;
  List<Map<String, dynamic>> _choices = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _request++;
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _searchChanged(String _) {
    _debounce?.cancel();
    _request++;
    setState(() {
      _loading = true;
      _error = null;
      _choices = [];
    });
    _debounce = Timer(const Duration(milliseconds: 300), _load);
  }

  Future<void> _load() async {
    final request = ++_request;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final choices = await OpportunityApi.searchOwners(
        widget.document['name'].toString(),
        _search.text.trim(),
      );
      if (mounted && request == _request) {
        setState(() => _choices = choices);
      }
    } catch (error) {
      if (mounted && request == _request) {
        setState(
          () => _error = error.toString().replaceFirst('Bad state: ', ''),
        );
      }
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (_saving || _selected == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await OpportunityApi.changeOwner(
        original: widget.document,
        newOwner: _selected!,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error =
              error is OpportunityActionError
                  ? error.validationMessage ?? error.toString()
                  : error.toString().replaceFirst('Bad state: ', '');
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      title: const Text('Edit Opportunity Owner'),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Current owner: ${widget.document['opportunity_owner']}'),
              const SizedBox(height: 12),
              TextField(
                controller: _search,
                enabled: !_saving,
                maxLength: 140,
                onChanged: _searchChanged,
                decoration: const InputDecoration(
                  labelText: 'Search ERP users',
                  prefixIcon: Icon(Icons.search_rounded),
                  counterText: '',
                ),
              ),
              if (_loading) const LinearProgressIndicator(),
              SizedBox(
                height: 200,
                child:
                    _choices.isEmpty
                        ? Center(
                          child: Text(
                            _loading
                                ? 'Loading users...'
                                : 'No matching users.',
                          ),
                        )
                        : ListView.builder(
                          itemCount: _choices.length,
                          itemBuilder: (context, index) {
                            final row = _choices[index];
                            final user = row['value'] as String;
                            final label = row['label']?.toString() ?? user;
                            final description =
                                row['description']?.toString() ?? '';
                            return ListTile(
                              selected: _selected == user,
                              title: Text(label),
                              subtitle:
                                  label != user
                                      ? Text(user)
                                      : description.isNotEmpty
                                      ? Text(description)
                                      : null,
                              trailing:
                                  _selected == user
                                      ? const Icon(Icons.check_circle_outline)
                                      : null,
                              onTap:
                                  _saving ||
                                          user ==
                                              widget
                                                  .document['opportunity_owner']
                                      ? null
                                      : () => setState(() => _selected = user),
                            );
                          },
                        ),
              ),
              if (_selected != null) Text('New owner: $_selected'),
              const SizedBox(height: 8),
              const Text(
                'After reassignment, this Opportunity will leave your owner-based list.',
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                if (!_saving)
                  TextButton(
                    onPressed: _load,
                    child: const Text('Retry user search'),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving || _selected == null ? null : _save,
          child: Text(_saving ? 'Saving...' : 'Save'),
        ),
      ],
    ),
  );
}
