import 'dart:async';

import 'Screen/splash.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'utils/api/fcm_device_api.dart';
import 'utils/api/fcm_notification_service.dart';
import 'package:overlay_support/overlay_support.dart';
import 'package:permission_handler/permission_handler.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(statusBarColor: Colors.blueAccent),
  );

  await dotenv.load(fileName: ".env");

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await FcmNotificationService.initialize();
  FcmDeviceApi.initializeTokenRefreshListener();

  runApp(const OverlaySupport.global(child: Myapp()));
}

class Myapp extends StatefulWidget {
  const Myapp({super.key});

  @override
  State<Myapp> createState() => _MyappState();
}

class _SlightlyLargerTextScaler extends TextScaler {
  const _SlightlyLargerTextScaler(this.parent, this.factor);

  final TextScaler parent;
  final double factor;

  @override
  double scale(double fontSize) => parent.scale(fontSize * factor);

  @override
  @Deprecated('Use scale instead.')
  double get textScaleFactor => scale(1.0);
}

class _MyappState extends State<Myapp> {
  @override
  void initState() {
    super.initState();
    _requestPermissions();
  }

  Future<void> _requestPermissions() async {
    // Android 13+ requires this runtime permission for the live-tracking
    // foreground-service notification to appear in the notification drawer.
    final notificationStatus = await Permission.notification.request();
    debugPrint("Notification permission: ${notificationStatus.name}");

    final microphoneStatus = await Permission.microphone.request();
    final phoneStatus = await Permission.phone.request();

    final locationWhenInUse = await Permission.location.request();
    debugPrint(
      "Location (While Using App) permission: ${locationWhenInUse.name}",
    );

    if (locationWhenInUse.isGranted) {
      final backgroundLocation = await Permission.locationAlways.request();
      debugPrint(
        "Background Location (Always) permission: ${backgroundLocation.name}",
      );
    }

    debugPrint("Microphone permission: ${microphoneStatus.name}");
    debugPrint("Phone permission: ${phoneStatus.name}");
  }

  void showCustomNotification(String message) {
    showSimpleNotification(
      const Text("New Message"),
      subtitle: Text(message),
      background: Colors.green[600],
      duration: const Duration(seconds: 4),
      slideDismissDirection: DismissDirection.horizontal,
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      builder: (context, child) {
        final mediaQuery = MediaQuery.of(context);
        return MediaQuery(
          data: mediaQuery.copyWith(
            textScaler: _SlightlyLargerTextScaler(mediaQuery.textScaler, 1.08),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFFF0F4FA),
        useMaterial3: true,
        fontFamily: 'Roboto',
        appBarTheme: const AppBarTheme(
          systemOverlayStyle: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: Brightness.dark,
            systemNavigationBarColor: Colors.white,
            systemNavigationBarIconBrightness: Brightness.dark,
          ),
          backgroundColor: Colors.transparent,
          titleTextStyle: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.normal,
            color: Colors.white,
            fontFamily: 'Roboto',
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.deepPurple,
            foregroundColor: Colors.white,
            textStyle: const TextStyle(fontSize: 16, fontFamily: 'Roboto'),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
      ),
      home: Splash(),
    );
  }
}
