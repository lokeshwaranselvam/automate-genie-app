import 'package:homegenie/utils/theme/brand_theme.dart';
import 'dart:collection';

import 'package:flutter/material.dart';
import '../../Screen/session_webview.dart';
import '../short_visit_checkout_notice.dart';
import '../connection_notice.dart';

class Warning extends StatelessWidget {
  static const opportunityEventRequiredMessage =
      'Create an event first for this Opportunity before saving Demo. If an event already exists, check that it is linked to this Opportunity in ERP, then try again.';

  final String message;

  const Warning(context, {super.key, required this.message, required type});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();

  static final Queue<_PopupRequest> _pending = Queue<_PopupRequest>();
  static bool _showingPopup = false;

  static void show(
    BuildContext context,
    String message,
    String type, {
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      _pending.add(
        _PopupRequest(
          context: context,
          message: message,
          type: type,
          actionLabel: actionLabel,
          onAction: onAction,
        ),
      );
      _showNextPopup();
    });
  }

  static void _showNextPopup() {
    if (_showingPopup || _pending.isEmpty) return;

    final request = _pending.removeFirst();
    if (!request.context.mounted) {
      _showNextPopup();
      return;
    }

    _showingPopup = true;
    final eventRequired =
        request.type != 'Success' &&
        request.message.trim() == opportunityEventRequiredMessage;
    final popupType = eventRequired ? 'Warning' : request.type;
    final connectionNotice =
        request.type == 'Success'
            ? null
            : ConnectionNotice.fromError(request.message);
    final shortVisitNotice =
        request.type == 'Success'
            ? null
            : ShortVisitCheckoutNotice.fromMessage(request.message);
    final color = switch (popupType) {
      'Warning' => Colors.orange.shade700,
      'Error' => Colors.red.shade700,
      'Success' => Colors.green.shade700,
      _ => BrandColors.ink,
    };
    final icon = switch (popupType) {
      'Warning' || 'Error' => Icons.warning_amber_rounded,
      'Success' => Icons.check_circle_outline,
      _ => Icons.info_outline,
    };
    final title = switch (request.type) {
      'Session Expired' => 'Session Expired',
      'Warning' => 'Warning',
      'Error' => 'Something went wrong',
      'Success' => 'Success',
      _ => 'Notice',
    };

    showDialog<void>(
      context: request.context,
      useRootNavigator: true,
      barrierDismissible: request.type != 'Session Expired',
      barrierColor: Colors.black54,
      builder: (dialogContext) {
        final screenHeight = MediaQuery.sizeOf(dialogContext).height;
        final dialog = Dialog(
          elevation: 12,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 32,
            vertical: 24,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 360,
              maxHeight: screenHeight * 0.82,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (request.type != 'Session Expired') Align(
                    alignment: Alignment.centerRight,
                    child: IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ),
                  CircleAvatar(
                    radius: 30,
                    backgroundColor: color.withValues(alpha: 0.12),
                    child: Icon(
                      connectionNotice == null
                          ? icon
                          : connectionNotice.timedOut
                          ? Icons.hourglass_empty_rounded
                          : Icons.wifi_off_rounded,
                      color: color,
                      size: 34,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    connectionNotice?.title ??
                        (eventRequired
                            ? 'Create event'
                            : shortVisitNotice == null
                            ? title
                            : 'Checkout restricted'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Flexible(
                    fit: FlexFit.loose,
                    child: SingleChildScrollView(
                      child: Text(
                        connectionNotice?.message ??
                            shortVisitNotice?.message ??
                            request.message,
                        textAlign:
                            shortVisitNotice == null
                                ? TextAlign.center
                                : TextAlign.start,
                        style: const TextStyle(fontSize: 15, height: 1.4),
                      ),
                    ),
                  ),
                  if (shortVisitNotice != null) ...[
                    const SizedBox(height: 14),
                    TextButton(
                      onPressed: () {
                        Navigator.of(dialogContext).pop();
                        if (!request.context.mounted) return;
                        Navigator.of(request.context).push<void>(
                          MaterialPageRoute<void>(
                            builder:
                                (_) => const SessionWebView(
                                  url: ShortVisitCheckoutNotice.url,
                                  title: 'SVR',
                                ),
                          ),
                        );
                      },
                      child: const Text(
                        ShortVisitCheckoutNotice.actionLabel,
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed:
                        request.onAction == null
                            ? () => Navigator.of(dialogContext).pop()
                            : () {
                              Navigator.of(dialogContext).pop();
                              request.onAction!();
                            },
                    child: Text(request.actionLabel ?? 'OK'),
                  ),
                ],
              ),
            ),
          ),
        );
        return PopScope(
          canPop: request.type != 'Session Expired',
          child: dialog,
        );
      },
    ).whenComplete(() {
      _showingPopup = false;
      _showNextPopup();
    });
  }
}

class _PopupRequest {
  const _PopupRequest({
    required this.context,
    required this.message,
    required this.type,
    this.actionLabel,
    this.onAction,
  });

  final BuildContext context;
  final String message;
  final String type;
  final String? actionLabel;
  final VoidCallback? onAction;
}
