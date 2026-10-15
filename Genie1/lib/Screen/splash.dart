import '../utils/widget/pull_to_refresh.dart';
import 'dart:async';
import '../utils/widget/ag_path_loading_indicator.dart';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'login.dart';
import 'homescreen.dart';
import 'face_enrollment_gate.dart';
import 'package:flutter/material.dart';
import 'package:homegenie/utils/widget/warning.dart';
import 'package:homegenie/utils/api/check_in_out.dart';
import 'package:homegenie/utils/api/fcm_device_api.dart';
import 'package:homegenie/utils/api/session_auth.dart';

class Splash extends StatefulWidget {
  const Splash({super.key});

  @override
  State<Splash> createState() => _SplashState();
}

class _SplashState extends State<Splash> {
  @override
  initState() {
    super.initState();
    _checkPing();
  }

  // Shown when the connectivity or ERP check fails, so the user can retry
  // instead of being left on the splash screen with no way forward.
  bool _showRetry = false;

  Future<void> _retry() async {
    setState(() => _showRetry = false);
    await _checkPing();
  }

  Future<void> _checkPing() async {
    try {
      var connectivity = await Connectivity().checkConnectivity();
      if (!mounted) return;

      if (connectivity.contains(ConnectivityResult.none)) {
        Warning.show(
          context,
          'No Internet Connection! Please check your network.',
          'Error',
        );
        setState(() => _showRetry = true);
        return;
      }

      var pingResult = await Check.pingpong();
      if (!mounted) return;
      if (pingResult == false) {
        Warning.show(
          context,
          'ERP Site is not in working condition! Please try again later.',
          'Error',
        );
        setState(() => _showRetry = true);
      } else {
        await _redirect();
      }
    } catch (e) {
      print('Error during ping: $e');
      if (mounted) setState(() => _showRetry = true);
    }
  }

  Future<void> _redirect() async {
    final activeUser = await SessionAuthApi.getActiveSessionUser();
    if (!mounted) return;

    if (activeUser != null && activeUser.isNotEmpty) {
      unawaited(FcmDeviceApi.requestPermissionAndRegister());
      // A saved Frappe session skips the login screen on app restart, so
      // register/refresh its FCM token here as well as after a fresh login.
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (context) => FaceEnrollmentGate(child: const Homescreen()),
        ),
      );
    } else {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const Login()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    double height = MediaQuery.of(context).size.height;
    return Scaffold(
      body: PullToRefresh(
        enabled: _showRetry,
        onRefresh: _retry,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(height: height * 0.38),
              Padding(
                padding: const EdgeInsets.all(18.0),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(
                    height: 150,
                    width: 300,
                    child:
                        _showRetry
                            ? Image.asset(
                              'assets/images/logoAG.png',
                              fit: BoxFit.contain,
                              semanticLabel: 'automategenie.ai',
                            )
                            : const Center(
                              child: AgPathLoadingIndicator(size: 150),
                            ),
                  ),
                ),
              ),
              if (_showRetry) const Text('Swipe down to retry'),
              SizedBox(height: height * 0.35),
            ],
          ),
        ),
      ),
    );
  }
}
