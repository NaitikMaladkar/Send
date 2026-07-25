import 'package:flutter/material.dart';

/// Circular avatar with the user's display name initial.
class Avatar extends StatelessWidget {
  final String displayName;
  final double radius;
  final Color? backgroundColor;
  final Color? foregroundColor;

  const Avatar({
    super.key,
    required this.displayName,
    this.radius = 22,
    this.backgroundColor,
    this.foregroundColor,
  });

  @override
  Widget build(BuildContext context) {
    final initial = displayName.isEmpty ? '?' : displayName[0].toUpperCase();
    final scheme = Theme.of(context).colorScheme;
    return CircleAvatar(
      radius: radius,
      backgroundColor: backgroundColor ?? scheme.primary,
      foregroundColor: foregroundColor ?? scheme.onPrimary,
      child: Text(
        initial,
        style: TextStyle(
          fontSize: radius * 0.95,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
