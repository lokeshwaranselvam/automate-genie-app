import 'package:flutter/material.dart';

import '../utils/api/opportunity_api.dart';
import '../utils/api/session_auth.dart';
import '../utils/api/smartflo_call_api.dart';
import '../utils/widget/warning.dart';
import '../utils/theme/brand_theme.dart';
import '../utils/widget/ag_path_loading_indicator.dart';
import '../utils/widget/home_back_button.dart';
import '../utils/widget/crm_document_details.dart';
import '../utils/widget/opportunity_edit_dialog.dart';

class OpportunityDetailsPage extends StatefulWidget {
  const OpportunityDetailsPage({super.key, required this.opportunityId});
  final String opportunityId;

  @override
  State<OpportunityDetailsPage> createState() => _OpportunityDetailsPageState();
}

class _OpportunityDetailsPageState extends State<OpportunityDetailsPage> {
  Map<String, dynamic>? _document;
  bool _loading = false;
  String? _error;
  bool _calling = false;
  bool _editing = false;
  String? _creatorFullName;

  Future<void> _edit() async {
    if (_editing || _loading || _document == null) return;
    setState(() => _editing = true);
    try {
      final original = _document!;
      final options = await OpportunityApi.getEditOptions();
      if (!mounted) return;
      final changes = await showDialog<Map<String, dynamic>>(
        context: context,
        builder:
            (_) => OpportunityEditDialog(
              document: original,
              options: options,
              onSave: (changes) async {
                final updated = await OpportunityApi.updateDetails(
                  original: original,
                  changes: changes,
                );
                if (mounted) setState(() => _document = updated);
              },
            ),
      );
      if (changes == null || changes.isEmpty || !mounted) return;
      if (mounted) {
        Warning.show(context, 'Opportunity updated.', 'Success');
      }
    } catch (error) {
      if (mounted) {
        Warning.show(
          context,
          error.toString().replaceFirst('Bad state: ', ''),
          'Error',
        );
      }
    } finally {
      if (mounted) setState(() => _editing = false);
    }
  }

  Future<void> _callContact(String number) async {
    if (_calling || _loading || _document == null) return;
    setState(() => _calling = true);
    try {
      await SmartfloCallApi.initiateCall(
        opportunity: _document!,
        number: number,
      );
      if (mounted) {
        Warning.show(
          context,
          'Call request sent. Please check your phone.',
          'Success',
        );
      }
    } catch (error) {
      if (mounted) {
        Warning.show(
          context,
          error.toString().replaceFirst('Bad state: ', ''),
          'Error',
        );
      }
    } finally {
      if (mounted) setState(() => _calling = false);
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_loading || _editing) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final sid = await SessionAuthApi.getSessionId();
      final document = await OpportunityApi.getDetails(widget.opportunityId);
      final creatorFullName = await SessionAuthApi.getUserFullName(
        document['owner'].toString(),
      );
      if (await SessionAuthApi.getSessionId() != sid ||
          await SessionAuthApi.getSavedSessionUser() !=
              document['opportunity_owner']) {
        throw StateError('Your account changed. Reopen Opportunities.');
      }
      if (mounted) {
        setState(() {
          _document = document;
          _creatorFullName = creatorFullName;
        });
      }
    } catch (error) {
      // Never keep previously displayed details after permission/owner changes.
      if (mounted) {
        setState(() {
          _document = null;
          _error = error.toString().replaceFirst('Bad state: ', '');
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: CrmDocumentDetails.background,
    appBar: brandAppBar(
      leading: const HomeBackButton(color: Colors.white),
      title: const Text(
        'Opportunity Details',
        style: TextStyle(fontWeight: FontWeight.w800),
      ),
      actions: [
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert, color: Colors.white),
          tooltip: 'More options',
          onSelected: (_) => _load(),
          itemBuilder:
              (_) => [
                PopupMenuItem(
                  value: 'refresh',
                  enabled: !_loading && !_editing,
                  child: const Text('Refresh'),
                ),
              ],
        ),
      ],
    ),
    body: RefreshIndicator(
      onRefresh: _load,
      child:
          _document != null
              ? CrmDocumentDetails(
                document: _document!,
                documentType: 'Opportunity',
                creatorFullName: _creatorFullName,
                refreshing: _loading || _editing,
                onEditOpportunity: _edit,
                onCallContact: _callContact,
                callInProgress: _calling || _loading,
              )
              : ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(24),
                children: [
                  if (_loading) const Center(child: AgPathLoadingIndicator()),
                  if (_error != null) ...[
                    Text(_error!, textAlign: TextAlign.center),
                    TextButton(
                      onPressed: _loading ? null : _load,
                      child: const Text('Retry'),
                    ),
                  ],
                ],
              ),
    ),
  );
}
