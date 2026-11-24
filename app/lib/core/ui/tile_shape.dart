import 'package:flutter/material.dart';

/// Local silhouette override. Empty/unknown values inherit the theme for old profiles.
class DeckTileShapeScope extends InheritedWidget {
  const DeckTileShapeScope({
    super.key,
    required this.shape,
    required super.child,
  });
  final String? shape;

  static String? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DeckTileShapeScope>()?.shape;

  static double radius(BuildContext context, double fallback) =>
      switch (of(context)) {
        'square' => 2,
        'rounded' => 12,
        'squircle' => 20,
        _ => fallback,
      };

  static ShapeBorder border(
    BuildContext context,
    ShapeBorder fallback, {
    BorderSide side = BorderSide.none,
  }) => switch (of(context)) {
    'square' => RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(2),
      side: side,
    ),
    'rounded' => RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
      side: side,
    ),
    'squircle' => ContinuousRectangleBorder(
      borderRadius: BorderRadius.circular(40),
      side: side,
    ),
    _ => fallback,
  };

  @override
  bool updateShouldNotify(DeckTileShapeScope oldWidget) =>
      oldWidget.shape != shape;
}
