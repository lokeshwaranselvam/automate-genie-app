import 'utils/platform/app_navigation.dart';
import 'package:flutter/foundation.dart';
import 'utils/platform/browser_runtime.dart';
import 'utils/platform/web_firebase_config.dart';
import 'package:homegenie/utils/theme/brand_theme.dart';
import 'dart:async';

import 'Screen/splash.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'utils/api/fcm_device_api.dart';
import 'utils/api/fcm_notification_service.dart';
import 'utils/widget/location_permission_helper.dart';
import 'package:overlay_support/overlay_support.dart';
import 'package:permission_handler/permission_handler.dart';

void main() => runBrowserApp(_startApp);

Future<void> _startApp() async {
  WidgetsFlutterBinding.ensureInitialized();

  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: BrandColors.electricBlue,
      statusBarIconBrightness: Brightness.light,
    ),
  );

  await dotenv.load(fileName: ".env");

  if (!kIsWeb || WebFirebaseConfig.isConfigured) {
    try {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
      await FcmNotificationService.initialize();
      FcmDeviceApi.initializeTokenRefreshListener();
    } catch (error) {
      if (!kIsWeb) rethrow;
      debugPrint('Web push could not initialize: ${error.runtimeType}');
    }
  }

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
    if (kIsWeb) return;
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
      // Asked once per install; "While using the app" is enough for tracking.
      await LocationPermissionHelper.requestBackgroundOnce();
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
      navigatorKey: appNavigatorKey,
      debugShowCheckedModeBanner: false,
      scrollBehavior: const MaterialScrollBehavior().copyWith(
        physics: const ClampingScrollPhysics(),
      ),
      builder: (context, child) {
        final mediaQuery = MediaQuery.of(context);
        return MediaQuery(
          data: mediaQuery.copyWith(
            textScaler: _SlightlyLargerTextScaler(mediaQuery.textScaler, 1.18),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
      theme: ThemeData(
        scaffoldBackgroundColor: const Color(0xFFF0F4FA),
        useMaterial3: true,
        fontFamily: 'Roboto',
        colorScheme: ColorScheme.fromSeed(seedColor: BrandColors.indigo),
        filledButtonTheme: const FilledButtonThemeData(
          style: BrandButtons.style,
        ),
        outlinedButtonTheme: const OutlinedButtonThemeData(
          style: BrandButtons.style,
        ),
        textButtonTheme: const TextButtonThemeData(style: BrandButtons.style),
        iconButtonTheme: const IconButtonThemeData(
          style: ButtonStyle(shape: WidgetStatePropertyAll(CircleBorder())),
        ),
        appBarTheme: const AppBarTheme(
          systemOverlayStyle: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: Brightness.dark,
            systemNavigationBarColor: Colors.white,
            systemNavigationBarIconBrightness: Brightness.dark,
          ),
          backgroundColor: Colors.transparent,
          titleTextStyle: TextStyle(
            fontSize: 19,
            fontWeight: FontWeight.w600,
            color: Colors.white,
            fontFamily: 'Roboto',
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: BrandColors.indigo,
            foregroundColor: Colors.white,
            textStyle: const TextStyle(fontSize: 16, fontFamily: 'Roboto'),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            shape: BrandButtons.shape,
          ),
        ),
      ),
      home: Splash(),
    );
  }
}
