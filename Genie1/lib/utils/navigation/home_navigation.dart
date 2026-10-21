import 'package:flutter/material.dart';

/// Tracks the signed-in Home route so pages can return there directly.
class HomeNavigation {
  HomeNavigation._();

  static Object? _owner;
  static Route<dynamic>? _homeRoute;
  static VoidCallback? _selectHome;
  static ValueChanged<int>? _selectTab;
  static Widget Function(BuildContext)? _navigationBar;

  static void register({
    required Object owner,
    required Route<dynamic>? route,
    required VoidCallback selectHome,
    ValueChanged<int>? selectTab,
    Widget Function(BuildContext)? navigationBar,
  }) {
    _owner = owner;
    _homeRoute = route;
    _selectHome = selectHome;
    _selectTab = selectTab;
    _navigationBar = navigationBar;
  }

  static void unregister(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _homeRoute = null;
    _selectHome = null;
    _selectTab = null;
    _navigationBar = null;
  }

  static Widget? navigationBar(BuildContext context) =>
      _navigationBar?.call(context);

  static void goToTab(BuildContext context, int index) {
    final homeRoute = _homeRoute;
    if (homeRoute == null || _selectTab == null) {
      goHome(context);
      return;
    }
    Navigator.of(
      context,
      rootNavigator: true,
    ).popUntil((route) => identical(route, homeRoute));
    _selectTab?.call(index);
  }

  /// Uses the same route and embedded-page back handling as system Back.
  static Future<bool> goBack(BuildContext context) {
    return Navigator.of(context).maybePop();
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
