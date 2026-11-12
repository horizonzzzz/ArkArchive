import 'package:flutter/material.dart';

class AppColors {
  const AppColors._(this.isLight);

  final bool isLight;
  static const dark = AppColors._(false);
  static const light = AppColors._(true);
  static AppColors of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.light ? light : dark;

  Color get canvas =>
      isLight ? const Color(0xfff5f5f5) : const Color(0xff111518);
  Color get panel =>
      isLight ? const Color(0xffffffff) : const Color(0xff171c20);
  Color get surface =>
      isLight ? const Color(0xffeef1f3) : const Color(0xff20272c);
  Color get raised =>
      isLight ? const Color(0xffffffff) : const Color(0xff252d33);
  Color get hover =>
      isLight ? const Color(0xffe1e8ec) : const Color(0xff303a42);
  Color get tertiary =>
      isLight ? const Color(0xffd6dfe4) : const Color(0xff313b43);
  Color get border =>
      isLight ? const Color(0xffaab8c0) : const Color(0xff354048);
  Color get borderSubtle =>
      isLight ? const Color(0xffd6dfe4) : const Color(0xff283138);
  Color get borderLight =>
      isLight ? const Color(0xff879aa5) : const Color(0xff576570);
  Color get active =>
      isLight ? const Color(0xff006e9f) : const Color(0xffe8eff2);
  Color get onActive =>
      isLight ? const Color(0xffffffff) : const Color(0xff152027);
  Color get indicator =>
      isLight ? const Color(0xff007fb8) : const Color(0xffa5c7d5);
  Color get terminalWhite =>
      isLight ? const Color(0xff18252c) : const Color(0xffe8eff2);
  Color get yellow =>
      isLight ? const Color(0xff805800) : const Color(0xffdfc080);
  Color get yellowFluor =>
      isLight ? const Color(0xff805800) : const Color(0xffdfc080);
  Color get green =>
      isLight ? const Color(0xff3c7040) : const Color(0xffa4c6a0);
  Color get danger =>
      isLight ? const Color(0xffb12c35) : const Color(0xfff28d8d);
  Color get text => isLight ? const Color(0xff18252c) : const Color(0xffe8edf0);
  Color get secondary =>
      isLight ? const Color(0xff394b55) : const Color(0xffc2ccd3);
  Color get subtext =>
      isLight ? const Color(0xff526772) : const Color(0xff9ba9b3);
  Color get muted =>
      isLight ? const Color(0xff5d707a) : const Color(0xff83939f);
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

ThemeData buildAppTheme({bool light = false}) {
  final colors = light ? AppColors.light : AppColors.dark;
  final scheme = (light ? const ColorScheme.light() : const ColorScheme.dark())
      .copyWith(
        primary: colors.active,
        onPrimary: colors.onActive,
        secondary: colors.indicator,
        onSecondary: colors.onActive,
        surface: colors.panel,
        onSurface: colors.text,
        onSurfaceVariant: colors.secondary,
        outline: colors.border,
        error: colors.danger,
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
    scaffoldBackgroundColor: colors.canvas,
    fontFamily: AppTypography.sans,
    textTheme: (light ? ThemeData.light() : ThemeData.dark()).textTheme.apply(
      fontFamily: AppTypography.sans,
      bodyColor: colors.text,
      displayColor: colors.text,
    ),
    dividerColor: colors.borderSubtle,
    dividerTheme: DividerThemeData(color: colors.borderSubtle, thickness: 1),
    focusColor: colors.indicator.withValues(alpha: .24),
    hoverColor: colors.indicator.withValues(alpha: .06),
    appBarTheme: AppBarTheme(
      backgroundColor: colors.panel,
      surfaceTintColor: Colors.transparent,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.surface,
      hintStyle: TextStyle(
        fontFamily: AppTypography.sans,
        color: colors.subtext,
        fontSize: 13,
      ),
      contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.zero),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.zero,
        borderSide: BorderSide(color: colors.borderSubtle),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.zero,
        borderSide: BorderSide(color: colors.indicator),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: shape,
        minimumSize: const Size(48, 48),
        backgroundColor: colors.active,
        foregroundColor: colors.onActive,
        textStyle: controlText,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: shape,
        minimumSize: const Size(48, 48),
        side: BorderSide(color: colors.border),
        foregroundColor: colors.secondary,
        textStyle: controlText,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: shape,
        minimumSize: const Size(48, 48),
        foregroundColor: colors.secondary,
        textStyle: controlText,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(48, 48),
        foregroundColor: colors.secondary,
        shape: shape,
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: shape,
      side: BorderSide(color: colors.muted),
      checkColor: WidgetStatePropertyAll(colors.onActive),
      fillColor: WidgetStateProperty.resolveWith(
        (states) =>
            states.contains(WidgetState.selected) ? colors.indicator : null,
      ),
    ),
    chipTheme: ChipThemeData(
      shape: shape,
      side: BorderSide(color: colors.border),
      selectedColor: colors.active,
      backgroundColor: colors.surface,
      labelStyle: controlText,
      secondaryLabelStyle: TextStyle(
        fontFamily: AppTypography.sans,
        color: colors.onActive,
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: colors.indicator,
      linearTrackColor: colors.tertiary,
      linearMinHeight: 2,
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 72,
      backgroundColor: colors.panel,
      surfaceTintColor: Colors.transparent,
      indicatorColor: colors.surface,
      indicatorShape: shape,
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 22,
          color: states.contains(WidgetState.selected)
              ? colors.indicator
              : colors.subtext,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => controlText.copyWith(
          fontSize: 12,
          color: states.contains(WidgetState.selected)
              ? colors.text
              : colors.subtext,
        ),
      ),
    ),
    dialogTheme: DialogThemeData(backgroundColor: colors.raised, shape: shape),
    popupMenuTheme: PopupMenuThemeData(
      color: colors.raised,
      surfaceTintColor: Colors.transparent,
      elevation: 3,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(2)),
        side: BorderSide(color: colors.border),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? controlText.copyWith(color: colors.muted)
            : controlText.copyWith(color: colors.text),
      ),
      mouseCursor: WidgetStateMouseCursor.clickable,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: colors.surface,
      contentTextStyle: TextStyle(
        fontFamily: AppTypography.sans,
        color: colors.text,
      ),
      behavior: SnackBarBehavior.floating,
    ),
    sliderTheme: SliderThemeData(
      trackHeight: 3,
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: 6),
      activeTrackColor: colors.indicator,
      inactiveTrackColor: colors.tertiary,
      thumbColor: colors.active,
    ),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 450),
    ),
  );
}
