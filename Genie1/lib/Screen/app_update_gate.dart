import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../utils/api/app_update_api.dart';
import '../utils/theme/brand_theme.dart';
import '../utils/widget/ag_path_loading_indicator.dart';

/// Mount the existing splash/session flow only after Android passes its check.
class AppUpdateGate extends StatefulWidget {
  const AppUpdateGate({super.key, required this.child});

  final Widget child;

  @override
  State<AppUpdateGate> createState() => _AppUpdateGateState();
}

class _AppUpdateGateState extends State<AppUpdateGate> {
  bool _checking = false;
  bool _failed = false;
  AppUpdateStatus? _status;

  bool get _applies =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    if (_applies) _check();
  }

  Future<void> _check() async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _failed = false;
    });
    try {
      final status = await AppUpdateApi.check();
      if (mounted) setState(() => _status = status);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_applies || (!_checking && !_failed && _status?.required == false)) {
      return widget.child;
    }
    final status = _status;
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!_checking) ...[
                      Image.asset(
                        'assets/images/logoAG.png',
                        height: 90,
                        semanticLabel: 'automategenie.ai',
                      ),
                      const SizedBox(height: 32),
                    ],
                    if (_checking) ...[
                      const AgPathLoadingIndicator(size: 80),
                      const SizedBox(height: 16),
                      const Text('Checking for updates…'),
                    ] else ...[
                      Icon(
                        _failed
                            ? Icons.cloud_off_rounded
                            : Icons.system_update_rounded,
                        size: 64,
                        color: BrandColors.indigo,
                      ),
                      const SizedBox(height: 20),
                      Text(
                        _failed
                            ? 'Unable to check for updates'
                            : 'Update required',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _failed
                            ? 'Check your internet connection and try again.'
                            : 'A new app version is available. Please install the latest APK to continue. Contact your administrator for the download link.',
                        textAlign: TextAlign.center,
                      ),
                      if (!_failed && status != null) ...[
                        const SizedBox(height: 20),
                        Text(
                          'Installed: ${status.installedVersion}+${status.installedBuild}',
                        ),
                        Text(
                          'Latest: ${status.latestVersion}+${status.latestBuild}',
                        ),
                      ],
                      const SizedBox(height: 24),
                      FilledButton(
                        onPressed: _check,
                        child: Text(_failed ? 'Retry' : 'Check again'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
