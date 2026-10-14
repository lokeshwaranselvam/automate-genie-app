import 'package:homegenie/utils/theme/brand_theme.dart';
import 'dart:collection';

import 'package:flutter/material.dart';

class Warning extends StatelessWidget {
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
    final color = switch (request.type) {
      'Warning' => Colors.orange.shade700,
      'Error' => Colors.red.shade700,
      'Success' => Colors.green.shade700,
      _ => BrandColors.ink,
    };
    final icon = switch (request.type) {
      'Warning' || 'Error' => Icons.warning_amber_rounded,
      'Success' => Icons.check_circle_outline,
      _ => Icons.info_outline,
    };
    final title = switch (request.type) {
      'Warning' => 'Warning',
      'Error' => 'Something went wrong',
      'Success' => 'Success',
      _ => 'Notice',
    };

    showDialog<void>(
      context: request.context,
      useRootNavigator: true,
      barrierDismissible: true,
      barrierColor: Colors.black54,
      builder: (dialogContext) {
        final screenHeight = MediaQuery.sizeOf(dialogContext).height;
        return Dialog(
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
                  Align(
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
                    child: Icon(icon, color: color, size: 34),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    title,
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
                        request.message,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 15, height: 1.4),
                      ),
                    ),
                  ),
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
