import 'package:adaptive_action_sheet/adaptive_action_sheet.dart'
    show BottomSheetAction;
import 'package:flutter/material.dart';

export 'package:adaptive_action_sheet/adaptive_action_sheet.dart'
    show BottomSheetAction;

/// The native package reads dart:io Platform before showing its sheet.
/// Browser attendance uses Material directly, preserving action callbacks.
Future<T?> showAdaptiveActionSheet<T>({
  required BuildContext context,
  Widget? title,
  required List<BottomSheetAction> actions,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
    ),
    clipBehavior: Clip.antiAlias,
    builder:
        (sheetContext) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(sheetContext).height * .9,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (title != null)
                    Padding(padding: const EdgeInsets.all(16), child: title),
                  for (final action in actions)
                    ListTile(
                      leading: action.leading,
                      title: action.title,
                      trailing: action.trailing,
                      onTap: () => action.onPressed(sheetContext),
                    ),
                ],
              ),
            ),
          ),
        ),
  );
}
