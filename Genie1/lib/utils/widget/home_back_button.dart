import 'package:flutter/material.dart';

import '../navigation/home_navigation.dart';

class HomeBackButton extends StatelessWidget {
  const HomeBackButton({super.key, this.color, this.tooltip = 'Back'});

  final Color? color;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: () => HomeNavigation.goBack(context),
      icon: Icon(Icons.arrow_back_rounded, color: color),
    );
  }
}
