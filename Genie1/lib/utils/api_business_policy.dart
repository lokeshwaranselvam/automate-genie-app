import 'dart:io';
import 'package:flutter/widgets.dart';

/// Generic interpretation of server-owned fields, actions and upload constraints.
class ApiBusinessPolicy {
  const ApiBusinessPolicy(this.data);
  final Map<String, dynamic> data;
  static const empty = ApiBusinessPolicy({});
  factory ApiBusinessPolicy.fromApi(Object? raw) {
    if (raw == null) {
      return empty; // Compatibility with older API responses only.
    }
    if (raw is! Map || raw['fields'] is! Map || raw['rules'] is! Map) {
      throw const FormatException('ERP returned an invalid form policy.');
    }
    return ApiBusinessPolicy(Map<String, dynamic>.from(raw));
  }
  Map get rules => data['rules'] is Map ? data['rules'] as Map : const {};
  Map get uploads => data['uploads'] is Map ? data['uploads'] as Map : const {};
  Map field(String name) =>
      (data['fields'] as Map?)?[name] is Map
          ? (data['fields'] as Map)[name] as Map
          : const {};
  bool hasField(String name) =>
      (data['fields'] as Map?)?.containsKey(name) == true;
  bool visible(String name) => field(name)['visible'] != false;
  bool readOnly(String name) => field(name)['read_only'] == true;
  void applyDefault(String name, TextEditingController controller) {
    if (field(name).containsKey('default') &&
        (readOnly(name) || controller.text.isEmpty)) {
      controller.text = field(name)['default']?.toString() ?? '';
    }
  }

  bool required(String name, [bool legacy = false]) =>
      hasField(name) ? field(name)['required'] == true : legacy;
  int? maxLength(String name, [int? legacy]) {
    final value = hasField(name) ? field(name)['max_length'] as int? : legacy;
    return value != null && value > 0 ? value : null;
  }

  List<String> options(String name, List<String> legacy) =>
      field(name)['options'] is List
          ? List<String>.from(field(name)['options'])
          : legacy;
  String? validate(
    String name,
    Object? value, {
    bool legacyRequired = false,
    String? requiredMessage,
  }) {
    if (required(name, legacyRequired) &&
        (value == null || value.toString().trim().isEmpty)) {
      return requiredMessage ?? '${name.replaceAll('_', ' ')} is required.';
    }
    final max = maxLength(name);
    if (max != null && value != null && value.toString().length > max) {
      return '${name.replaceAll('_', ' ')} is too long.';
    }
    final choices = field(name)['options'];
    if (choices is List &&
        value != null &&
        value.toString().isNotEmpty &&
        !choices.contains(value)) {
      return 'Choose a valid ${name.replaceAll('_', ' ')}.';
    }
    final rule = field(name);
    if (value != null &&
        value.toString().trim().isNotEmpty &&
        rule['type'] == 'number') {
      final number = double.tryParse(value.toString().replaceAll(',', ''));
      if (number == null || !number.isFinite) {
        return 'Choose a valid number for $name.';
      }
      if (rule['min_exclusive'] is num &&
          number <= (rule['min_exclusive'] as num)) {
        return '$name must be greater than ${rule['min_exclusive']}.';
      }
      if (rule['max_value'] is num && number > (rule['max_value'] as num)) {
        return '$name exceeds the permitted amount.';
      }
    }
    return null;
  }

  String? actionBlockReason(String name, {bool allowPreparation = false}) {
    final action = (data['actions'] as Map?)?[name];
    if (action is! Map || action['allowed'] is! bool) {
      return 'Refresh this page to verify the available actions.';
    }
    return action['allowed'] == true ||
            (allowPreparation && action['can_prepare'] == true)
        ? null
        : action['reason']?.toString() ?? 'This action is unavailable.';
  }

  int get minimumUploads => uploads['min_count'] as int? ?? 0;
  Future<String?> validateUploads(
    List<String> paths, {
    bool enforceMinimum = true,
  }) async {
    final currentCount = uploads['current_count'] as int? ?? 0;
    if (enforceMinimum && paths.length + currentCount < minimumUploads) {
      return 'Attach at least $minimumUploads file(s).';
    }
    final maxCount = uploads['max_count'] as int? ?? 0;
    if (maxCount > 0 && paths.length + currentCount > maxCount) {
      return 'The permitted attachment count has been exceeded.';
    }
    for (final path in paths) {
      final extensions = uploads['extensions'];
      if (extensions is List &&
          extensions.isNotEmpty &&
          !extensions.any(
            (extension) =>
                path.toLowerCase().endsWith(extension.toString().toLowerCase()),
          )) {
        return 'This attachment format is not allowed.';
      }
      final max = uploads['max_bytes'] as int? ?? 0;
      if (max > 0 && !await File(path).exists()) {
        return 'The selected attachment is missing. Choose it again.';
      }
      if (max > 0 && await File(path).length() > max) {
        return 'The attachment exceeds the permitted file size.';
      }
    }
    return null;
  }
}

/// Existing fields retain their widgets; API metadata controls presentation.
class BusinessPolicyField extends StatelessWidget {
  const BusinessPolicyField({
    super.key,
    required this.policy,
    required this.name,
    required this.child,
  });
  final ApiBusinessPolicy policy;
  final String name;
  final Widget child;
  @override
  Widget build(BuildContext context) =>
      !policy.visible(name)
          ? const SizedBox.shrink()
          : AbsorbPointer(absorbing: policy.readOnly(name), child: child);
}
