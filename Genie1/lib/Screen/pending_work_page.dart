import 'package:flutter/material.dart';
import 'package:homegenie/utils/theme/brand_theme.dart';

import '../utils/widget/home_back_button.dart';
import 'session_webview.dart';

class PendingWorkPage extends StatefulWidget {
  const PendingWorkPage({super.key});

  @override
  State<PendingWorkPage> createState() => PendingWorkPageState();
}

class PendingWorkPageState extends State<PendingWorkPage> {
  // Homescreen calls this when pending-work notifications arrive. TGC owns its
  // task data now; don't reload the WebView and discard an in-progress form.
  Future<void> refresh() async {}

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: brandAppBar(
        leading: const HomeBackButton(color: Colors.white),
        title: const Text(
          'My Tasks',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
            fontSize: 19,
          ),
        ),
      ),
      body: const SessionWebView(
        url: 'https://16.itgenie.online/TGC',
        title: 'My Tasks',
        embedded: true,
      ),
    );
  }
}
