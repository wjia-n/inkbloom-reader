import 'package:flutter/material.dart';

/// Soft, squishy touch feedback: the child gently shrinks
/// while pressed and springs back on release — the "juicy"
/// feel the user asked for (2026-10-21). It never steals
/// the child's own tap: onTapDown/onTapUp/onTapCancel fire
/// even when a button inside wins the gesture arena, and
/// onTapCancel always restores the scale, so the widget can
/// never get stuck small.
class Squishy extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  const Squishy({super.key, required this.child, this.onTap});

  @override
  State<Squishy> createState() => _SquishyState();
}

class _SquishyState extends State<Squishy> {
  double _scale = 1.0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _scale = 0.94),
      onTapUp: (_) => setState(() => _scale = 1.0),
      onTapCancel: () => setState(() => _scale = 1.0),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _scale,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}
