import '../utils/widget/ag_path_loading_indicator.dart';
import 'package:homegenie/utils/theme/brand_theme.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/api/face_auth_api.dart';
import '../utils/api/session_auth.dart';
import '../utils/face/face_auth_flow.dart';
import 'login.dart';

/// Server enrollment status controls first use, including restored sessions.
/// A local preference cannot skip enrollment or overwrite the user's reference.
class FaceEnrollmentGate extends StatefulWidget {
  const FaceEnrollmentGate({
    super.key,
    required this.child,
    this.loadStatus,
    this.enrollSelfie,
    this.onSignOut,
    this.onReady,
  });

  final Widget child;
  final Future<FaceEnrollmentStatus> Function()? loadStatus;
  final Future<FaceEnrollmentStatus?> Function(
    BuildContext,
    FaceEnrollmentStatus,
  )?
  enrollSelfie;
  final Future<void> Function()? onSignOut;
  final VoidCallback? onReady;

  @override
  State<FaceEnrollmentGate> createState() => _FaceEnrollmentGateState();
}

class _FaceEnrollmentGateState extends State<FaceEnrollmentGate> {
  bool _busy = true;
  bool _ready = false;
  String? _error;
  FaceEnrollmentStatus? _status;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final status = await (widget.loadStatus ?? FaceAuthApi.instance.status)();
      if (!mounted) return;
      setState(() => _status = status);
      if (status.enrolled) {
        setState(() {
          _ready = true;
          _busy = false;
        });
        widget.onReady?.call();
        return;
      }
      await _enroll(status);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _busy = false;
        });
      }
    }
  }

  Future<void> _enroll(FaceEnrollmentStatus status) async {
    final result = await (widget.enrollSelfie ?? FaceAuthFlow.instance.enroll)(
      context,
      status,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _ready = result?.enrolled == true;
      _status = result ?? status;
      _error = _ready ? null : 'Take your first-login selfie to finish setup.';
    });
    if (_ready) widget.onReady?.call();
  }

  Future<void> _retry() async {
    if (_busy) return;
    // Refresh server state first: another successful request may have saved
    // the photo even when its response was interrupted on this phone.
    await _load();
  }

  Future<void> _signOut() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (widget.onSignOut != null) {
        await widget.onSignOut!().timeout(const Duration(seconds: 10));
        return;
      }
      try {
        await SessionAuthApi.logout().timeout(const Duration(seconds: 8));
      } catch (_) {
        // A remote network failure must not retain local biometric credentials.
      } finally {
        await SessionAuthApi.clearSession();
        final prefs = await SharedPreferences.getInstance();
        await prefs.clear();
      }
      if (mounted) {
        Navigator.of(
          context,
        ).pushReplacement(MaterialPageRoute(builder: (_) => const Login()));
      }
    } catch (error) {
      if (mounted) setState(() => _error = 'Could not sign out. Please retry.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_ready) return widget.child;
    // Checking server status is not selfie setup. Only show enrollment copy
    // after the server confirms that this user has no reference photo.
    final needsSelfie = _status != null && !_status!.enrolled;
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: const Color(0xFFF7F9FC),
        appBar:
            needsSelfie
                ? brandAppBar(
                  automaticallyImplyLeading: false,
                  title: const Text('Set up your selfie'),
                )
                : null,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (needsSelfie) ...[
                    const Icon(
                      Icons.face_retouching_natural,
                      size: 72,
                      color: BrandColors.ink,
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      'Your attendance face photo',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Look at the front camera and blink once. Your selfie will be saved privately on your ERP User record and used for attendance and visit check-in/out.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 15, height: 1.5),
                    ),
                  ],
                  if (_status != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _status!.currentUser,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.black54),
                    ),
                  ],
                  const SizedBox(height: 24),
                  if (_busy)
                    const AgPathLoadingIndicator()
                  else ...[
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 20),
                        child: Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Color(0xFFB3261E)),
                        ),
                      ),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: FilledButton.icon(
                        style: const ButtonStyle(
                          backgroundBuilder: BrandColors.buttonBackground,
                          foregroundColor: WidgetStatePropertyAll(Colors.white),
                        ),
                        onPressed: _retry,
                        icon: const Icon(Icons.camera_alt_outlined),
                        label: Text(_status == null ? 'Retry' : 'Take selfie'),
                      ),
                    ),
                    TextButton(
                      onPressed: _signOut,
                      child: const Text('Sign out'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
