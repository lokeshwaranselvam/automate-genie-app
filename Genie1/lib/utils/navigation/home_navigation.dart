import 'package:flutter/material.dart';

/// Tracks the signed-in Home route so pages can return there directly.
class HomeNavigation {
  HomeNavigation._();

  static Object? _owner;
  static Route<dynamic>? _homeRoute;
  static VoidCallback? _selectHome;

  static void register({
    required Object owner,
    required Route<dynamic>? route,
    required VoidCallback selectHome,
  }) {
    _owner = owner;
    _homeRoute = route;
    _selectHome = selectHome;
  }

  static void unregister(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _homeRoute = null;
    _selectHome = null;
  }

  static void goHome(BuildContext context) {
    final navigator = Navigator.of(context, rootNavigator: true);
    final homeRoute = _homeRoute;

    if (homeRoute != null) {
      navigator.popUntil((route) => identical(route, homeRoute));
      _selectHome?.call();
      return;
    }

    if (navigator.canPop()) navigator.pop();
  }
}
