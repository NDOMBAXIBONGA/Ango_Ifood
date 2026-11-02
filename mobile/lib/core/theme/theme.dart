import 'package:flutter/material.dart';

/// ==============================================================================
/// SISTEMA DE DESIGN & TEMA TIPOGRÁFICO MATERIAL 3 (AppThemeData)
/// ==============================================================================
/// Padronização visual completa para eliminar caracteres estrangeiros (mandarim/CJK)
/// e garantir que todos os textos herdem fontes ocidentais padronizadas (Roboto/Arial)
/// com codificação UTF-8 rigorosa e ícones nativos do Material Design.
class AppThemeData {
  // Paleta de Cores Institucional
  static const Color primaryRed = Color(0xFFEA1D2C);
  static const Color primaryGreen = Color(0xFF00A86B);
  static const Color primaryBlue = Color(0xFF1E88E5);
  static const Color primaryOrange = Color(0xFFFF6D00);

  // Cores Neutras e de Superfície
  static const Color neutralDark = Color(0xFF0F172A);
  static const Color neutralMedium = Color(0xFF64748B);
  static const Color neutralLight = Color(0xFFF8FAFC);
  static const Color surfaceWhite = Color(0xFFFFFFFF);
  static const Color borderSubtle = Color(0xFFE2E8F0);

  // Família Tipográfica Ocidental Universal (sem caracteres asiáticos)
  static const String primaryFontFamily = 'Roboto';
  static const List<String> fallbackFontFamilies = [
    'Roboto',
    'Arial',
    'Helvetica',
    'sans-serif',
  ];

  /// Constrói o TextTheme ocidental garantindo que todos os 15 estilos herdem
  /// explicitamente a codificação UTF-8 e a família tipográfica universal.
  static TextTheme _buildWesternTextTheme(Color textColor, Color secondaryColor) {
    return TextTheme(
      displayLarge: TextStyle(
        fontFamily: primaryFontFamily,
        fontFamilyFallback: fallbackFontFamilies,
        fontSize: 57.0,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.25,
        color: textColor,
      ),
      displayMedium: TextStyle(
        fontFamily: primaryFontFamily,
        fontFamilyFallback: fallbackFontFamilies,
        fontSize: 45.0,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.0,
        color: textColor,
      ),
      displaySmall: TextStyle(
        fontFamily: primaryFontFamily,
        fontFamilyFallback: fallbackFontFamilies,
        fontSize: 36.0,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.0,
        color: textColor,
      ),
      headlineLarge: TextStyle(
        fontFamily: primaryFontFamily,
        fontFamilyFallback: fallbackFontFamilies,
        fontSize: 32.0,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.5,
        color: textColor,
      ),
      headlineMedium: TextStyle(
        fontFamily: primaryFontFamily,
        fontFamilyFallback: fallbackFontFamilies,
        fontSize: 28.0,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.25,
        color: textColor,
      ),
      headlineSmall: TextStyle(
        fontFamily: primaryFontFamily,
        fontFamilyFallback: fallbackFontFamilies,
        fontSize: 24.0,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.0,
        color: textColor,
      ),
      titleLarge: TextStyle(
        fontFamily: primaryFontFamily,
        fontFamilyFallback: fallbackFontFamilies,
        fontSize: 22.0,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.0,
        color: textColor,
      ),
      titleMedium: TextStyle(
        fontFamily: primaryFontFamily,
        fontFamilyFallback: fallbackFontFamilies,
        fontSize: 16.0,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.15,
        color: textColor,
      ),
      titleSmall: TextStyle(
        fontFamily: primaryFontFamily,
        fontFamilyFallback: fallbackFontFamilies,
        fontSize: 14.0,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.1,
        color: textColor,
      ),
      bodyLarge: TextStyle(
        fontFamily: primaryFontFamily,
        fontFamilyFallback: fallbackFontFamilies,
        fontSize: 16.0,
        fontWeight: FontWeight.w400,
        letterSpacing: 0.5,
        height: 1.5,
        color: textColor,
      ),
      bodyMedium: TextStyle(
        fontFamily: primaryFontFamily,
        fontFamilyFallback: fallbackFontFamilies,
        fontSize: 14.0,
        fontWeight: FontWeight.w400,
        letterSpacing: 0.25,
        height: 1.45,
        color: secondaryColor,
      ),
      bodySmall: TextStyle(
        fontFamily: primaryFontFamily,
        fontFamilyFallback: fallbackFontFamilies,
        fontSize: 12.0,
        fontWeight: FontWeight.w400,
        letterSpacing: 0.4,
        height: 1.35,
        color: secondaryColor,
      ),
      labelLarge: TextStyle(
        fontFamily: primaryFontFamily,
        fontFamilyFallback: fallbackFontFamilies,
        fontSize: 14.0,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.2,
        color: textColor,
      ),
      labelMedium: TextStyle(
        fontFamily: primaryFontFamily,
        fontFamilyFallback: fallbackFontFamilies,
        fontSize: 12.0,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
        color: secondaryColor,
      ),
      labelSmall: TextStyle(
        fontFamily: primaryFontFamily,
        fontFamilyFallback: fallbackFontFamilies,
        fontSize: 11.0,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.5,
        color: secondaryColor,
      ),
    );
  }

  /// Tema Padrão Claro (Material Design 3)
  static ThemeData get lightTheme {
    final baseColorScheme = ColorScheme.fromSeed(
      seedColor: primaryRed,
      primary: primaryRed,
      onPrimary: Colors.white,
      secondary: primaryGreen,
      onSecondary: Colors.white,
      surface: surfaceWhite,
      onSurface: neutralDark,
      surfaceContainerLowest: surfaceWhite,
      surfaceContainerLow: neutralLight,
      surfaceContainer: const Color(0xFFF1F5F9),
      error: const Color(0xFFDC2626),
      onError: Colors.white,
      brightness: Brightness.light,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: baseColorScheme,
      scaffoldBackgroundColor: neutralLight,
      fontFamily: primaryFontFamily,
      fontFamilyFallback: fallbackFontFamilies,
      textTheme: _buildWesternTextTheme(neutralDark, neutralMedium),

      // Configuração Estrita de Ícones Material Nativos
      iconTheme: const IconThemeData(
        color: neutralDark,
        size: 24.0,
      ),
      primaryIconTheme: const IconThemeData(
        color: Colors.white,
        size: 24.0,
      ),

      // AppBar
      appBarTheme: const AppBarTheme(
        backgroundColor: surfaceWhite,
        foregroundColor: neutralDark,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontFamily: primaryFontFamily,
          fontSize: 18.0,
          fontWeight: FontWeight.w700,
          color: neutralDark,
        ),
        iconTheme: IconThemeData(
          color: neutralDark,
          size: 24.0,
        ),
      ),

      // Botões Preenchidos (FilledButton / ElevatedButton)
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primaryRed,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(52.0),
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14.0),
          ),
          textStyle: const TextStyle(
            fontFamily: primaryFontFamily,
            fontSize: 15.0,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
      ),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryRed,
          foregroundColor: Colors.white,
          elevation: 0,
          minimumSize: const Size.fromHeight(52.0),
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14.0),
          ),
          textStyle: const TextStyle(
            fontFamily: primaryFontFamily,
            fontSize: 15.0,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
      ),

      // Botões de Borda (OutlinedButton)
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: neutralDark,
          minimumSize: const Size.fromHeight(52.0),
          side: const BorderSide(color: borderSubtle, width: 1.5),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14.0),
          ),
          textStyle: const TextStyle(
            fontFamily: primaryFontFamily,
            fontSize: 15.0,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),

      // Campos de Entrada (TextField / TextFormField)
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceWhite,
        contentPadding: const EdgeInsets.symmetric(horizontal: 18.0, vertical: 16.0),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14.0),
          borderSide: const BorderSide(color: borderSubtle, width: 1.2),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14.0),
          borderSide: const BorderSide(color: borderSubtle, width: 1.2),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14.0),
          borderSide: const BorderSide(color: primaryRed, width: 2.0),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14.0),
          borderSide: const BorderSide(color: Color(0xFFDC2626), width: 1.5),
        ),
        hintStyle: const TextStyle(
          fontFamily: primaryFontFamily,
          fontSize: 14.0,
          color: Color(0xFF94A3B8),
        ),
        labelStyle: const TextStyle(
          fontFamily: primaryFontFamily,
          fontSize: 14.0,
          color: neutralMedium,
        ),
      ),

      // Cards
      cardTheme: CardTheme(
        color: surfaceWhite,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18.0),
          side: const BorderSide(color: borderSubtle, width: 1.0),
        ),
      ),
    );
  }

  /// Gera um ThemeData customizado dinamicamente com base na cor de destaque
  /// do papel ativo (Cliente = Verde, Parceiro = Azul, Entregador = Laranja)
  static ThemeData getThemeForRoleColor(Color roleColor) {
    final base = lightTheme;
    final dynamicColorScheme = ColorScheme.fromSeed(
      seedColor: roleColor,
      primary: roleColor,
      onPrimary: Colors.white,
      brightness: Brightness.light,
    );

    return base.copyWith(
      colorScheme: dynamicColorScheme,
      filledButtonTheme: FilledButtonThemeData(
        style: base.filledButtonTheme.style?.copyWith(
          backgroundColor: WidgetStateProperty.all(roleColor),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: base.elevatedButtonTheme.style?.copyWith(
          backgroundColor: WidgetStateProperty.all(roleColor),
        ),
      ),
      inputDecorationTheme: base.inputDecorationTheme.copyWith(
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14.0),
          borderSide: BorderSide(color: roleColor, width: 2.0),
        ),
      ),
    );
  }
}
