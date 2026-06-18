import 'package:flutter/material.dart';

/// Recycled Sound 15-color palette, derived from the design system wireframes.
///
/// The palette centers on a teal-green primary that evokes sustainability and
/// hearing health, with an orange accent for calls to action.
abstract final class AppColors {
  // The app is dark-themed throughout (matching the scanner/confirm "HUD"
  // aesthetic). The neutral tokens below are the dark surfaces/text that the
  // whole app draws from via [AppTheme] + [AppTypography]; flipping them here is
  // what carries every light screen (home/auth/admin/settings/devices) dark.
  // `white` stays true white because it is a *foreground* (button text on the
  // green primary, scanner overlay icons), never a surface.

  // ── Brand ──────────────────────────────────────────────────────────────
  static const primary = Color(0xFF34A07A); // a touch brighter for dark contrast
  static const primaryLight = Color(0xFF18352A); // dark green tint (icon chips)
  static const accent = Color(0xFFE67E22);

  // ── Neutrals (dark) ──────────────────────────────────────────────────────
  static const background = Color(0xFF0D0D0D); // scaffold
  static const surface = Color(0xFF1A1A1A); // cards, app bar, nav, inputs
  static const white = Color(0xFFFFFFFF); // FOREGROUND only — never a surface
  static const text = Color(0xFFF3F4F6); // primary text on dark
  static const textMuted = Color(0xFF9CA3AF); // secondary text on dark
  static const border = Color(0xFF2E2E2E); // hairlines / outlines on dark

  // ── Semantic ───────────────────────────────────────────────────────────
  static const success = Color(0xFF10B981);
  static const warning = Color(0xFFF59E0B);
  static const error = Color(0xFFEF4444);

  // ── Info / Legal (dark surfaces + legible text) ──────────────────────────
  static const infoBg = Color(0xFF14273F);
  static const infoText = Color(0xFF93C5FD);
  static const legalBg = Color(0xFF2A2410);
}
