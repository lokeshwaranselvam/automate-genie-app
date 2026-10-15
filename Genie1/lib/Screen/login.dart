import '../utils/widget/ag_path_loading_indicator.dart';
import 'package:homegenie/utils/theme/brand_theme.dart';
import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:homegenie/Screen/homescreen.dart';
import 'package:homegenie/utils/api/check_in_out.dart';

import '../utils/api/fcm_device_api.dart';
import '../utils/api/login_api.dart';
import '../utils/widget/warning.dart';
import 'face_enrollment_gate.dart';

const _brandBlue = BrandColors.ink;
const _ink = Color(0xFF18243A);

class Login extends StatefulWidget {
  const Login({super.key});

  @override
  State<Login> createState() => _LoginState();
}

class _LoginState extends State<Login> {
  static const _secureStorage = FlutterSecureStorage();
  static const _rememberKey = 'remember_login_enabled';
  static const _usernameKey = 'remembered_login_username';
  static const _passwordKey = 'remembered_login_password';

  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final FocusNode _emailFocusNode = FocusNode();
  bool _isPasswordVisible = false;
  bool _isLoading = false;
  bool _rememberMe = false;

  @override
  void initState() {
    super.initState();
    _restoreRememberedLogin();
    _checkPing();
  }

  Future<void> _restoreRememberedLogin() async {
    try {
      final remember = await _secureStorage.read(key: _rememberKey) == 'true';
      if (!remember) return;

      final username = await _secureStorage.read(key: _usernameKey);
      final password = await _secureStorage.read(key: _passwordKey);
      if (!mounted) return;

      setState(() => _rememberMe = true);
      _emailController.text = username ?? '';
      _passwordController.text = password ?? '';
    } catch (error) {
      debugPrint('Could not restore remembered login: $error');
    }
  }

  Future<void> _setRememberMe(bool value) async {
    setState(() => _rememberMe = value);
    try {
      if (!value) {
        await _secureStorage.delete(key: _rememberKey);
        await _secureStorage.delete(key: _usernameKey);
        await _secureStorage.delete(key: _passwordKey);
        return;
      }

      await _secureStorage.write(key: _rememberKey, value: 'true');
      await _saveRememberedLogin();
    } catch (error) {
      debugPrint('Could not update remembered login: $error');
    }
  }

  Future<void> _saveRememberedLogin() async {
    if (!_rememberMe) return;
    try {
      await _secureStorage.write(
        key: _usernameKey,
        value: _emailController.text.trim(),
      );
      await _secureStorage.write(
        key: _passwordKey,
        value: _passwordController.text,
      );
    } catch (error) {
      debugPrint('Could not save remembered login: $error');
    }
  }

  Future<void> _checkPing() async {
    try {
      final connectivity = await Connectivity().checkConnectivity();
      if (!mounted) return;

      final noInternet = connectivity.contains(ConnectivityResult.none);
      if (noInternet) {
        Warning.show(
          context,
          'No Internet Connection! Please check your network.',
          'Error',
        );
        return;
      }

      final pingResult = await Check.pingpong();
      if (!mounted) return;
      if (!pingResult) {
        Warning.show(
          context,
          'ERP Site is not in working condition! Please try again later.',
          'Error',
        );
      }
    } catch (error) {
      debugPrint('Error during ping: $error');
    }
  }

  @override
  void dispose() {
    _emailFocusNode.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> login() async {
    if (_isLoading) return;
    final username = _emailController.text.trim();
    final password = _passwordController.text;

    if (username.isEmpty) {
      Warning.show(context, 'Please enter your Employee ID.', 'Warning');
      return;
    }
    if (password.trim().isEmpty) {
      Warning.show(context, 'Password cannot be empty.', 'Warning');
      return;
    }

    if (_rememberMe) await _saveRememberedLogin();

    setState(() => _isLoading = true);
    unawaited(_checkPing());

    try {
      final user = await LoginApi.login(username, password);
      if (!mounted) return;
      setState(() => _isLoading = false);
      if (user.containsKey('error')) {
        Warning.show(context, user['error'], 'Warning');
        return;
      }

      Warning.show(context, 'Login Successful', 'Success');
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder:
              (context) => FaceEnrollmentGate(
                child: Homescreen(),
                onReady:
                    () =>
                        unawaited(FcmDeviceApi.requestPermissionAndRegister()),
              ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      Warning.show(context, 'Login error. Please try again.', 'Warning');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F9FC),
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 26,
                  vertical: 28,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 430),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: 8),
                        _buildBrand(),
                        const SizedBox(height: 35),
                        _buildEmployeeField(),
                        const SizedBox(height: 19),
                        _buildPasswordField(),
                        const SizedBox(height: 8),
                        _buildRememberAndForgot(),
                        const SizedBox(height: 16),
                        _buildLoginButton(),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (_isLoading)
              ColoredBox(
                color: Colors.black.withValues(alpha: 0.12),
                child: const Center(
                  child: AgPathLoadingIndicator(showBackground: true),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBrand() {
    return Column(
      children: [
        Image.asset(
          'assets/images/logoAG.png',
          width: 250,
          height: 130,
          fit: BoxFit.contain,
          semanticLabel: 'automategenie.ai',
        ),
        const SizedBox(height: 1),
        const Text(
          'Employee Super App',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: _ink,
          ),
        ),
      ],
    );
  }

  Widget _buildEmployeeField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _FieldLabel('Employee ID'),
        const SizedBox(height: 7),
        TextField(
          controller: _emailController,
          focusNode: _emailFocusNode,
          textInputAction: TextInputAction.next,
          autofillHints: const [AutofillHints.username],
          style: const TextStyle(fontSize: 15, color: _ink),
          decoration: _inputDecoration(hintText: 'Enter your Employee ID'),
        ),
      ],
    );
  }

  Widget _buildPasswordField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _FieldLabel('Password'),
        const SizedBox(height: 7),
        TextField(
          controller: _passwordController,
          obscureText: !_isPasswordVisible,
          textInputAction: TextInputAction.done,
          autofillHints: const [AutofillHints.password],
          onSubmitted: (_) => login(),
          style: const TextStyle(fontSize: 15, color: _ink),
          decoration: _inputDecoration(
            hintText: 'Enter your password',
            suffixIcon: IconButton(
              tooltip: _isPasswordVisible ? 'Hide password' : 'Show password',
              onPressed:
                  () =>
                      setState(() => _isPasswordVisible = !_isPasswordVisible),
              icon: Icon(
                _isPasswordVisible ? Icons.visibility : Icons.visibility_off,
                color: const Color(0xFF7B8492),
                size: 21,
              ),
            ),
          ),
        ),
      ],
    );
  }

  InputDecoration _inputDecoration({String? hintText, Widget? suffixIcon}) {
    return InputDecoration(
      hintText: hintText,
      hintStyle: const TextStyle(color: Color(0xFFB1B8C4), fontSize: 14),
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
      suffixIcon: suffixIcon,
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(11),
        borderSide: const BorderSide(color: Color(0xFFE5E9EF)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(11),
        borderSide: const BorderSide(color: _brandBlue, width: 1.4),
      ),
    );
  }

  Widget _buildRememberAndForgot() {
    return Row(
      children: [
        SizedBox(
          height: 38,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Checkbox(
                value: _rememberMe,
                activeColor: _brandBlue,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged:
                    _isLoading
                        ? null
                        : (value) => _setRememberMe(value ?? false),
              ),
              const Text(
                'Keep me logged in',
                style: TextStyle(fontSize: 12, color: Color(0xFF5F6B7A)),
              ),
            ],
          ),
        ),
        const Spacer(),
        const Text(
          'Forgot Password?',
          style: TextStyle(
            color: _brandBlue,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  Widget _buildLoginButton() {
    return SizedBox(
      height: 51,
      child: ElevatedButton(
        onPressed: _isLoading ? null : login,
        style: ElevatedButton.styleFrom(
          backgroundColor: _brandBlue,
          foregroundColor: Colors.white,
          elevation: 1,
          shape: const StadiumBorder(),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ).copyWith(backgroundBuilder: BrandColors.buttonBackground),
        child: const Text('Login'),
      ),
    );
  }


}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Text(
    label,
    style: const TextStyle(
      color: Color(0xFF586477),
      fontSize: 13,
      fontWeight: FontWeight.w600,
    ),
  );
}
