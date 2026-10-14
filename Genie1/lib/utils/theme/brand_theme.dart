import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Shared visual styling; navigation callbacks and application state stay local.
abstract final class BrandColors {
  static const electricBlue = Color(0xFF0055FF);
  static const indigo = Color(0xFF442FEF);
  static const purple = Color(0xFF8000E5);
  static const ink = indigo;
  static const gradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [electricBlue, indigo, purple],
  );

  static Widget buttonBackground(
    BuildContext context,
    Set<WidgetState> states,
    Widget? child,
  ) => ClipRRect(
    borderRadius: BorderRadius.circular(999),
    child: DecoratedBox(
      decoration: BoxDecoration(
        gradient: states.contains(WidgetState.disabled) ? null : gradient,
      ),
      child: child,
    ),
  );
}

abstract final class BrandButtons {
  static const shape = StadiumBorder();
  static const style = ButtonStyle(shape: WidgetStatePropertyAll(shape));
}

Widget brandFloatingActionButton({
  required VoidCallback? onPressed,
  required Widget label,
  Widget? icon,
}) => DecoratedBox(
  decoration: BoxDecoration(
    gradient: BrandColors.gradient,
    borderRadius: BorderRadius.circular(999),
  ),
  child: FloatingActionButton.extended(
    onPressed: onPressed,
    label: label,
    icon: icon,
    backgroundColor: Colors.transparent,
    foregroundColor: Colors.white,
    shape: BrandButtons.shape,
    clipBehavior: Clip.antiAlias,
    elevation: 0,
  ),
);

Widget brandCircleAvatar({double radius = 20, Widget? child}) => DecoratedBox(
  decoration: const BoxDecoration(
    gradient: BrandColors.gradient,
    shape: BoxShape.circle,
  ),
  child: CircleAvatar(
    radius: radius,
    backgroundColor: Colors.transparent,
    foregroundColor: Colors.white,
    child: child,
  ),
);

AppBar brandAppBar({
  Widget? leading,
  Widget? title,
  List<Widget>? actions,
  PreferredSizeWidget? bottom,
  bool automaticallyImplyLeading = true,
  bool? centerTitle,
  double? titleSpacing,
  double? elevation,
}) => AppBar(
  leading: leading,
  title: title,
  automaticallyImplyLeading: automaticallyImplyLeading,
  centerTitle: centerTitle,
  titleSpacing: titleSpacing,
  elevation: elevation ?? 0,
  backgroundColor: Colors.transparent,
  surfaceTintColor: Colors.transparent,
  foregroundColor: Colors.white,
  iconTheme: const IconThemeData(color: Colors.white),
  actionsIconTheme: const IconThemeData(color: Colors.white),
  systemOverlayStyle: const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
  ),
  flexibleSpace: const DecoratedBox(
    decoration: BoxDecoration(gradient: BrandColors.gradient),
    child: SizedBox.expand(),
  ),
  actions:
      actions
          ?.map(
            (action) => Builder(
              builder:
                  (context) => Theme(
                    data: Theme.of(context).copyWith(
                      textButtonTheme: TextButtonThemeData(
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white,
                          disabledForegroundColor: Colors.white60,
                          shape: BrandButtons.shape,
                        ),
                      ),
                    ),
                    child: action,
                  ),
            ),
          )
          .toList(),
  // Tab strips retain their light surface and readable selected-state colors.
  bottom:
      bottom == null
          ? null
          : PreferredSize(
            preferredSize: bottom.preferredSize,
            child: Material(color: Colors.white, child: bottom),
          ),
);

Widget brandBottomNavigationBar({
  required List<BottomNavigationBarItem> items,
  required int currentIndex,
  ValueChanged<int>? onTap,
  BottomNavigationBarType? type,
  double selectedFontSize = 12,
  double unselectedFontSize = 12,
  bool? showUnselectedLabels,
}) => DecoratedBox(
  decoration: const BoxDecoration(gradient: BrandColors.gradient),
  child: BottomNavigationBar(
    items: items,
    currentIndex: currentIndex,
    onTap: onTap,
    type: type,
    backgroundColor: Colors.transparent,
    selectedItemColor: Colors.white,
    unselectedItemColor: const Color(0xFFDAD8FF),
    selectedFontSize: selectedFontSize < 12 ? 12 : selectedFontSize,
    unselectedFontSize: unselectedFontSize < 12 ? 12 : unselectedFontSize,
    selectedLabelStyle: const TextStyle(fontWeight: FontWeight.w700),
    showUnselectedLabels: showUnselectedLabels,
    elevation: 0,
  ),
);
