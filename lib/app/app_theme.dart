import 'package:flutter/material.dart';

abstract final class AppColors {
  static const canvas = Color(0xff0f0f10);
  static const panel = Color(0xff18191a);
  static const surface = Color(0xff232425);
  static const raised = Color(0xff2d2e30);
  static const hover = Color(0xff36383a);
  static const tertiary = Color(0xff313131);
  static const border = Color(0xff333538);
  static const borderSubtle = Color(0x1fffffff);
  static const borderLight = Color(0xff505256);

  /// 终端反白高亮块（白底黑字反转）
  static const active = Color(0xffffffff);
  static const onActive = Color(0xff000000);

  /// 终端指示色（高对比白/亮灰指示条，彻底摒弃商业蓝）
  static const indicator = Color(0xffffffff);

  /// 终端点缀亮灰/银白（用于战术代号、高亮标记）
  static const terminalWhite = Color(0xfff0f2f5);

  /// 功能强调与警示（仅用于特别任务、网络警告与错误）
  static const yellow = Color(0xffffd600);
  static const yellowFluor = Color(0xfff3ff00);
  static const green = Color(0xff8fc31f);
  static const danger = Color(0xffff4444);

  static const text = Color(0xffffffff);
  static const secondary = Color(0xffd2d2d2);
  static const subtext = Color(0xffa2a4a7);
  static const muted = Color(0xff5c5e62);
}

abstract final class AppTypography {
  static const bender = 'Bender';
  static const sans = 'ArchiveSans';

  /// 战术代码样式（用于章节号 14-1, CW-1、协议序号 01, 02）
  static const tacticalCode = TextStyle(
    fontFamily: bender,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.2,
  );
}

ThemeData buildAppTheme() {
  final scheme = const ColorScheme.dark(
    primary: AppColors.active,
    onPrimary: AppColors.onActive,
    secondary: AppColors.terminalWhite,
    onSecondary: AppColors.onActive,
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
    fontFamily: AppTypography.sans,
    textTheme: ThemeData.dark().textTheme.apply(
      fontFamily: AppTypography.sans,
      bodyColor: AppColors.text,
      displayColor: AppColors.text,
    ),
    dividerColor: AppColors.border,
    focusColor: AppColors.borderLight.withValues(alpha: .36),
    hoverColor: Colors.white.withValues(alpha: .04),
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
        borderSide: BorderSide(color: AppColors.active, width: 1.5),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: shape,
        backgroundColor: AppColors.active,
        foregroundColor: AppColors.onActive,
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
        foregroundColor: AppColors.text,
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
      checkColor: const WidgetStatePropertyAll(AppColors.onActive),
      fillColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.selected) ? AppColors.active : null,
      ),
    ),
    chipTheme: const ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.zero),
      side: BorderSide(color: AppColors.border),
      selectedColor: AppColors.active,
      backgroundColor: AppColors.surface,
      labelStyle: TextStyle(fontSize: 12, color: AppColors.secondary),
      secondaryLabelStyle: TextStyle(fontSize: 12, color: AppColors.onActive),
      checkmarkColor: AppColors.onActive,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppColors.terminalWhite,
      linearTrackColor: AppColors.tertiary,
      linearMinHeight: 6,
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
      activeTrackColor: AppColors.active,
      inactiveTrackColor: AppColors.tertiary,
      thumbColor: AppColors.active,
    ),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 450),
    ),
  );
}
