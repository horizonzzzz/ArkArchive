import 'package:flutter/material.dart';

abstract final class AppColors {
  static const canvas = Color(0xff111518);
  static const panel = Color(0xff171c20);
  static const surface = Color(0xff20272c);
  static const raised = Color(0xff252d33);
  static const hover = Color(0xff303a42);
  static const tertiary = Color(0xff313b43);
  static const border = Color(0xff354048);
  static const borderSubtle = Color(0xff283138);
  static const borderLight = Color(0xff576570);
  static const active = Color(0xffe8eff2);
  static const onActive = Color(0xff152027);
  static const indicator = Color(0xffa5c7d5);
  static const terminalWhite = Color(0xffe8eff2);
  static const yellow = Color(0xffdfc080);
  static const yellowFluor = Color(0xffdfc080);
  static const green = Color(0xffa4c6a0);
  static const danger = Color(0xfff28d8d);
  static const text = Color(0xffe8edf0);
  static const secondary = Color(0xffc2ccd3);
  static const subtext = Color(0xff9ba9b3);
  static const muted = Color(0xff83939f);
}

abstract final class AppTypography {
  static const bender = 'Bender';
  static const sans = 'ArchiveSans';

  static const tacticalCode = TextStyle(
    fontFamily: bender,
    fontFamilyFallback: [sans],
    fontWeight: FontWeight.w700,
    letterSpacing: .6,
  );
}

ThemeData buildAppTheme() {
  const scheme = ColorScheme.dark(
    primary: AppColors.active,
    onPrimary: AppColors.onActive,
    secondary: AppColors.indicator,
    onSecondary: AppColors.onActive,
    surface: AppColors.panel,
    onSurface: AppColors.text,
    onSurfaceVariant: AppColors.secondary,
    outline: AppColors.border,
    error: AppColors.danger,
  );
  const shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(2)),
  );
  const controlText = TextStyle(
    fontFamily: AppTypography.sans,
    fontSize: 13,
    fontWeight: FontWeight.w500,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.canvas,
    fontFamily: AppTypography.sans,
    textTheme: ThemeData.dark().textTheme.apply(
      fontFamily: AppTypography.sans,
      bodyColor: AppColors.text,
      displayColor: AppColors.text,
    ),
    dividerColor: AppColors.borderSubtle,
    dividerTheme: const DividerThemeData(
      color: AppColors.borderSubtle,
      thickness: 1,
    ),
    focusColor: AppColors.indicator.withValues(alpha: .24),
    hoverColor: AppColors.indicator.withValues(alpha: .06),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.panel,
      surfaceTintColor: Colors.transparent,
    ),
    inputDecorationTheme: const InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      hintStyle: TextStyle(
        fontFamily: AppTypography.sans,
        color: AppColors.subtext,
        fontSize: 13,
      ),
      contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.zero),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.zero,
        borderSide: BorderSide(color: AppColors.borderSubtle),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.zero,
        borderSide: BorderSide(color: AppColors.indicator),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: shape,
        minimumSize: const Size(48, 48),
        backgroundColor: AppColors.active,
        foregroundColor: AppColors.onActive,
        textStyle: controlText,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: shape,
        minimumSize: const Size(48, 48),
        side: const BorderSide(color: AppColors.border),
        foregroundColor: AppColors.secondary,
        textStyle: controlText,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: shape,
        minimumSize: const Size(48, 48),
        foregroundColor: AppColors.secondary,
        textStyle: controlText,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(48, 48),
        foregroundColor: AppColors.secondary,
        shape: shape,
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: shape,
      side: const BorderSide(color: AppColors.muted),
      checkColor: const WidgetStatePropertyAll(AppColors.onActive),
      fillColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.selected) ? AppColors.indicator : null,
      ),
    ),
    chipTheme: const ChipThemeData(
      shape: shape,
      side: BorderSide(color: AppColors.border),
      selectedColor: AppColors.active,
      backgroundColor: AppColors.surface,
      labelStyle: controlText,
      secondaryLabelStyle: TextStyle(
        fontFamily: AppTypography.sans,
        color: AppColors.onActive,
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppColors.indicator,
      linearTrackColor: AppColors.tertiary,
      linearMinHeight: 2,
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 72,
      backgroundColor: AppColors.panel,
      surfaceTintColor: Colors.transparent,
      indicatorColor: AppColors.surface,
      indicatorShape: shape,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 22,
          color: states.contains(WidgetState.selected)
              ? AppColors.indicator
              : AppColors.subtext,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => controlText.copyWith(
          fontSize: 12,
          color: states.contains(WidgetState.selected)
              ? AppColors.text
              : AppColors.subtext,
        ),
      ),
    ),
    dialogTheme: const DialogThemeData(
      backgroundColor: AppColors.raised,
      shape: shape,
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: AppColors.surface,
      contentTextStyle: TextStyle(
        fontFamily: AppTypography.sans,
        color: AppColors.text,
      ),
      behavior: SnackBarBehavior.floating,
    ),
    sliderTheme: const SliderThemeData(
      trackHeight: 3,
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
      activeTrackColor: AppColors.indicator,
      inactiveTrackColor: AppColors.tertiary,
      thumbColor: AppColors.active,
    ),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 450),
    ),
  );
}
