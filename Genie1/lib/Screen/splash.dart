import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'login.dart';
import 'homescreen.dart';
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

  Future<void> _checkPing() async {
    try {
      var connectivity = await Connectivity().checkConnectivity();

      bool noInternet = false;

      if (connectivity == ConnectivityResult.none) {
        noInternet = true;
      }

      if (connectivity.contains(ConnectivityResult.none)) {
        noInternet = true;
      }

      if (noInternet) {
        Warning.show(
          context,
          'No Internet Connection! Please check your network.',
          'Error',
        );
        return;
      }

      var pingResult = await Check.pingpong();
      if (pingResult == false) {
        Warning.show(
          context,
          'ERP Site is not in working condition! Please try again later.',
          'Error',
        );
      } else {
        _redirect();
      }
    } catch (e) {
      print('Error during ping: $e');
    }
  }

  Future<void> _redirect() async {
    final activeUser = await SessionAuthApi.getActiveSessionUser();
    await Future.delayed(const Duration(seconds: 3));
    if (!mounted) return;

    if (activeUser != null && activeUser.isNotEmpty) {
      // A saved Frappe session skips the login screen on app restart, so
      // register/refresh its FCM token here as well as after a fresh login.
      unawaited(FcmDeviceApi.requestPermissionAndRegister());
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const Homescreen()),
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
      body: Center(
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
                  child: Image.asset(
                    'assets/images/logoAG.png',
                    fit: BoxFit.contain,
                    semanticLabel: 'automategenie.ai',
                  ),
                ),
              ),
            ),
            SizedBox(height: height * 0.35),
          ],
        ),
      ),
    );
  }
}
