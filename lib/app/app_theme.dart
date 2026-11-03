import 'package:flutter/material.dart';

abstract final class AppColors {
  static const canvas = Color(0xff000000);
  static const panel = Color(0xff121212);
  static const surface = Color(0xff181818);
  static const raised = Color(0xff242424);
  static const hover = Color(0xff292929);
  static const tertiary = Color(0xff333333);
  static const border = Color(0xff333333);
  static const borderSubtle = Color(0x14ffffff);
  static const cyan = Color(0xff18d1ff);
  static const cyanDeep = Color(0xff06bbff);
  static const cyanDark = Color(0xff0097a7);
  static const yellow = Color(0xffffd600);
  static const yellowFluor = Color(0xfff3ff00);
  static const green = Color(0xff8fc31f);
  static const text = Color(0xffffffff);
  static const secondary = Color(0xffd2d2d2);
  static const subtext = Color(0xffababab);
  static const muted = Color(0xff585858);
  static const danger = Color(0xffff4444);
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
  const shape = BeveledRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(3)),
  );
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
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.panel,
      surfaceTintColor: Colors.transparent,
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      hintStyle: TextStyle(color: AppColors.muted, fontSize: 13),
      contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.zero),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.zero,
        borderSide: BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.zero,
        borderSide: BorderSide(color: AppColors.cyan, width: 1.5),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: shape,
        backgroundColor: AppColors.cyan,
        foregroundColor: AppColors.canvas,
        minimumSize: const Size(44, 44),
        textStyle: const TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 13,
          letterSpacing: 0.5,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: shape,
        minimumSize: const Size(44, 44),
        side: const BorderSide(color: AppColors.border),
        foregroundColor: AppColors.secondary,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: shape,
        minimumSize: const Size(44, 44),
        foregroundColor: AppColors.cyan,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(44, 44),
        shape: shape,
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      side: const BorderSide(color: AppColors.muted),
      checkColor: const WidgetStatePropertyAll(AppColors.canvas),
      fillColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.selected) ? AppColors.cyan : null,
      ),
    ),
    chipTheme: const ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      side: BorderSide(color: AppColors.border),
      selectedColor: Color(0x2418d1ff),
      backgroundColor: AppColors.surface,
      labelStyle: TextStyle(fontSize: 12),
    ),
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: AppColors.panel,
      indicatorColor: AppColors.surface,
      labelTextStyle: WidgetStatePropertyAll(TextStyle(fontSize: 12)),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: AppColors.raised,
      shape: shape,
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: AppColors.surface,
      contentTextStyle: TextStyle(color: AppColors.text),
      behavior: SnackBarBehavior.floating,
    ),
    sliderTheme: const SliderThemeData(
      trackHeight: 3,
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
    ),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 450),
    ),
  );
}
