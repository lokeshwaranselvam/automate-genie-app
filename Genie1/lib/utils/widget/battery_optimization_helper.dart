import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'warning.dart';

/// Helper class to manage battery optimization on Android
/// Provides UI prompts and settings navigation
class BatteryOptimizationHelper {
  static const platform = MethodChannel('com.example.homegenieapp/tracking');

  /// Check if app is in battery optimization list
  static Future<bool> isBatteryOptimized() async {
    if (!Platform.isAndroid) return false;

    try {
      final result = await platform.invokeMethod<Map<dynamic, dynamic>>(
        'isBatteryOptimized',
      );
      return result?['isOptimized'] ?? false;
    } on PlatformException catch (e) {
      print("⚠️ Error checking battery optimization: ${e.message}");
      return false;
    }
  }

  /// Get explanation based on device manufacturer
  static Future<String> getBatteryOptimizationExplanation() async {
    if (!Platform.isAndroid) return "";

    try {
      final result = await platform.invokeMethod<Map<dynamic, dynamic>>(
        'isBatteryOptimized',
      );
      return result?['explanation'] ??
          "Please disable battery optimization for this app.";
    } on PlatformException catch (e) {
      print("⚠️ Error getting explanation: ${e.message}");
      return "Please disable battery optimization in your device settings.";
    }
  }

  /// Open battery optimization settings
  static Future<void> openBatteryOptimizationSettings() async {
    if (!Platform.isAndroid) return;

    try {
      await platform.invokeMethod<void>('openBatteryOptimizationSettings');
    } on PlatformException catch (e) {
      print("⚠️ Error opening settings: ${e.message}");
    }
  }

  static Future<void> requestBatteryExemption() async {
    if (!Platform.isAndroid) return;
    try {
      await platform.invokeMethod<void>('requestIgnoreBatteryOptimization');
    } on PlatformException catch (e) {
      print('Could not request battery exemption: ${e.message}');
    }
  }

  static Future<void> openAppBatterySettings() async {
    if (!Platform.isAndroid) return;
    try {
      await platform.invokeMethod<void>('openAppBatterySettings');
    } on PlatformException catch (e) {
      print('Could not open automategenie.ai app settings: ${e.message}');
    }
  }

  /// Show a dialog prompting user to disable battery optimization
  static Future<void> showBatteryOptimizationDialog(
    BuildContext context,
  ) async {
    if (!Platform.isAndroid) return;
    Map<String, dynamic> status;
    try {
      final result = await platform.invokeMethod<Map<dynamic, dynamic>>(
        'isBatteryOptimized',
      );
      status = Map<String, dynamic>.from(result ?? {});
    } on PlatformException catch (e) {
      print('Could not read background tracking settings: ${e.message}');
      return;
    }

    final isOptimized = status['isOptimized'] == true;
    final prefs = await SharedPreferences.getInstance();
    final hasShownGeneralGuidance =
        prefs.getBool('background_tracking_guidance_shown') ?? false;
    // Show setup guidance once on every Android brand, since OEM controls are
    // not consistently detectable through Android's standard battery API.
    // Keep reminding at later check-ins if Android still reports restrictions.
    if (!isOptimized && hasShownGeneralGuidance) return;

    final explanation =
        status['explanation']?.toString() ??
        await getBatteryOptimizationExplanation();

    if (!context.mounted) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder:
          (BuildContext context) => AlertDialog(
            title: const Text("⚡ Battery Optimization Detected"),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Battery restrictions can delay location updates while the screen is off. Allow automategenie.ai to run in the background for more reliable tracking. This may use more battery while you are checked in.',
                  style: TextStyle(fontSize: 14),
                ),
                const SizedBox(height: 12),
                Text(
                  explanation,
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
            actions: [
              ElevatedButton(
                onPressed: () async {
                  Navigator.of(context).pop();
                  await requestBatteryExemption();
                },
                child: const Text('Allow background tracking'),
              ),
              TextButton(
                onPressed: () async {
                  Navigator.of(context).pop();
                  await openAppBatterySettings();
                },
                child: const Text('App settings'),
              ),
            ],
          ),
    );
    await prefs.setBool('background_tracking_guidance_shown', true);
  }

  /// Show a banner/snackbar warning about battery optimization
  static void showBatteryOptimizationBanner(BuildContext context) async {
    final isOptimized = await isBatteryOptimized();
    if (!isOptimized) return;

    final explanation = await getBatteryOptimizationExplanation();

    if (!context.mounted) return;

    Warning.show(
      context,
      explanation,
      'Warning',
      actionLabel: 'Fix',
      onAction: () => openBatteryOptimizationSettings(),
    );
  }
}
