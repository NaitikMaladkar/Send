import 'package:flutter/material.dart';

/// App logo image widget.
class Logo extends StatelessWidget {
  final double size;
  const Logo({super.key, this.size = 96});

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/images/logo.png',
      width: size,
      height: size,
      fit: BoxFit.contain,
    );
  }
}
