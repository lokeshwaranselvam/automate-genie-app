import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../utils/api/visit_verification_api.dart';
import '../utils/theme/brand_theme.dart';

class VisitVerificationPage extends StatefulWidget {
  const VisitVerificationPage({
    super.key,
    required this.visits,
    required this.otpLength,
  });
  final List<Map<String, dynamic>> visits;
  final int otpLength;
  @override
  State<VisitVerificationPage> createState() => _VisitVerificationPageState();
}

class _VisitVerificationPageState extends State<VisitVerificationPage> {
  bool _verified = false;
  late List<Map<String, dynamic>> _visits;
  @override
  void initState() {
    super.initState();
    _visits =
        widget.visits.map((row) => Map<String, dynamic>.from(row)).toList();
  }

  Future<void> _enterOtp(Map<String, dynamic> visit) async {
    final verified = await showVisitVerificationOtpDialog(
      context,
      eventId: visit['event_id'].toString(),
      otpLength: widget.otpLength,
    );
    if (mounted && verified) {
      setState(() => visit['is_verified'] = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows =
        _visits
            .where((row) => (row['is_verified'] == true) == _verified)
            .toList();
    return Scaffold(
      appBar: brandAppBar(title: const Text('Verification')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('Not Verified'),
                  selected: !_verified,
                  onSelected: (_) => setState(() => _verified = false),
                ),
                ChoiceChip(
                  label: const Text('Verified'),
                  selected: _verified,
                  onSelected: (_) => setState(() => _verified = true),
                ),
              ],
            ),
          ),
          Expanded(
            child:
                rows.isEmpty
                    ? const Center(child: Text('No visits in this section.'))
                    : ListView.builder(
                      itemCount: rows.length,
                      itemBuilder: (context, index) {
                        final row = rows[index];
                        return ListTile(
                          title: Text(
                            (row['subject'] ?? row['event_id']).toString(),
                          ),
                          subtitle: Text(row['event_id'].toString()),
                          trailing:
                              _verified
                                  ? const Icon(
                                    Icons.check_circle,
                                    color: Colors.green,
                                  )
                                  : TextButton(
                                    onPressed: () => _enterOtp(row),
                                    child: const Text('Enter OTP'),
                                  ),
                        );
                      },
                    ),
          ),
        ],
      ),
    );
  }
}

Future<bool> showVisitVerificationOtpDialog(
  BuildContext context, {
  required String eventId,
  required int otpLength,
}) async {
  final controller = TextEditingController();
  bool submitting = false;
  String? error;
  final verified = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder:
        (dialogContext) => StatefulBuilder(
          builder:
              (context, update) => AlertDialog(
                title: const Text('Verify customer OTP'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: controller,
                      enabled: !submitting,
                      autofocus: true,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(otpLength),
                      ],
                      decoration: InputDecoration(
                        labelText: 'Customer OTP',
                        errorText: error,
                      ),
                    ),
                    if (submitting)
                      const Padding(
                        padding: EdgeInsets.only(top: 12),
                        child: LinearProgressIndicator(),
                      ),
                  ],
                ),
                actions: [
                  TextButton(
                    onPressed:
                        submitting ? null : () => Navigator.pop(dialogContext),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed:
                        submitting
                            ? null
                            : () async {
                              if (controller.text.length != otpLength) {
                                update(
                                  () =>
                                      error =
                                          'Enter the $otpLength-digit customer OTP.',
                                );
                                return;
                              }
                              update(() {
                                submitting = true;
                                error = null;
                              });
                              try {
                                final result =
                                    await VisitVerificationApi.verify(
                                      eventId,
                                      controller.text,
                                    );
                                if (!dialogContext.mounted) return;
                                if (result['status'] == 'success' &&
                                    result['is_verified'] == true &&
                                    result['event_id'] == eventId) {
                                  Navigator.pop(dialogContext, true);
                                } else {
                                  update(() {
                                    submitting = false;
                                    error =
                                        result['detail']?.toString() ??
                                        'Invalid OTP.';
                                  });
                                }
                              } catch (failure) {
                                if (dialogContext.mounted) {
                                  update(() {
                                    submitting = false;
                                    error = failure.toString().replaceFirst(
                                      'Bad state: ',
                                      '',
                                    );
                                  });
                                }
                              }
                            },
                    child: const Text('Verify'),
                  ),
                ],
              ),
        ),
  );
  // Dispose after dialog route's closing animation releases its TextField.
  await Future<void>.delayed(const Duration(milliseconds: 300));
  controller.dispose();
  return verified == true;
}
