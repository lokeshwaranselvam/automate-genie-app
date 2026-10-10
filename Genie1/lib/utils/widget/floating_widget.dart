import 'package:flutter/material.dart';

class FloatingDistanceWidget extends StatelessWidget {
  final double distance;

  const FloatingDistanceWidget({super.key, required this.distance});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        margin: EdgeInsets.only(top: 60, right: 20),
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black87,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 6)],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.directions_walk, color: Colors.white, size: 20),
            SizedBox(width: 6),
            Text(
              "${distance.toStringAsFixed(1)} m",
              style: TextStyle(color: Colors.white, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}
