import 'package:flutter/material.dart';

abstract final class AppColors {
  static const canvas = Color(0xff0a0d12);
  static const panel = Color(0xff12161f);
  static const raised = Color(0xff181d26);
  static const surface = Color(0xff1f2633);
  static const border = Color(0xff2b3545);
  static const cyan = Color(0xff00e5ff);
  static const yellow = Color(0xfff6c344);
  static const text = Color(0xfff1f5fa);
  static const secondary = Color(0xffa2b0c2);
  static const muted = Color(0xff8291a6);
  static const danger = Color(0xffff7777);
}

ThemeData buildAppTheme() {
  final scheme = const ColorScheme.dark(
    primary: AppColors.cyan,
    onPrimary: AppColors.canvas,
    secondary: AppColors.yellow,
    onSecondary: AppColors.canvas,
    surface: AppColors.panel,
    onSurface: AppColors.text,
    onSurfaceVariant: AppColors.secondary,
    outline: AppColors.border,
    error: AppColors.danger,
  );
  const shape = BeveledRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(3)));
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.canvas,
    fontFamily: 'ArchiveSans',
    textTheme: ThemeData.dark().textTheme.apply(
      fontFamily: 'ArchiveSans',
      bodyColor: AppColors.text,
      displayColor: AppColors.text,
    ),
    dividerColor: AppColors.border,
    focusColor: AppColors.cyan.withValues(alpha: .24),
    hoverColor: AppColors.cyan.withValues(alpha: .08),
    appBarTheme: const AppBarTheme(backgroundColor: AppColors.panel, surfaceTintColor: Colors.transparent),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.canvas,
      hintStyle: const TextStyle(color: AppColors.muted, fontSize: 13),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(3))),
      enabledBorder: const OutlineInputBorder(borderSide: BorderSide(color: AppColors.border)),
      focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: AppColors.cyan, width: 2)),
    ),
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(
      shape: shape, minimumSize: const Size(44, 44),
      textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
    )),
    outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(
      shape: shape, minimumSize: const Size(44, 44),
      side: const BorderSide(color: AppColors.border),
      foregroundColor: AppColors.secondary,
    )),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(
      shape: shape, minimumSize: const Size(44, 44),
    )),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(
      minimumSize: const Size(44, 44), shape: shape,
    )),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(2)),
      side: const BorderSide(color: AppColors.muted),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
      side: const BorderSide(color: AppColors.border),
      selectedColor: AppColors.cyan.withValues(alpha: .12),
      backgroundColor: AppColors.panel,
      labelStyle: const TextStyle(fontSize: 12),
    ),
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: AppColors.panel, indicatorColor: AppColors.surface,
      labelTextStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12)),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: AppColors.raised, shape: shape,
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: AppColors.surface,
      contentTextStyle: TextStyle(color: AppColors.text),
      behavior: SnackBarBehavior.floating,
    ),
    sliderTheme: const SliderThemeData(trackHeight: 3, thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6)),
    tooltipTheme: const TooltipThemeData(waitDuration: Duration(milliseconds: 450)),
  );
}
