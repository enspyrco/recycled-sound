// Excluded from coverage: HUD overlay on live camera; renders DetectionState animations
// coverage:ignore-file
import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_typography.dart';
import 'slot_reel_text.dart';

/// A single field in the 7-field HUD.
class HudField {
  const HudField({
    required this.label,
    required this.value,
    this.confidence,
    this.colourRgb,
    this.colourConfidence = 0.0,
    this.colourConfirmed = false,
    this.onTap,
    this.slotCandidates = const [],
  });

  /// Field label shown on the left, e.g. "MAKE", "STYLE".
  final String label;

  /// Detected value, or null if not yet detected.
  final String? value;

  /// Optional confidence label, e.g. "EXACT", "85% AI".
  final String? confidence;

  /// For the COLOUR field — the swatch colour.
  final Color? colourRgb;

  /// For the COLOUR field — confidence 0.0–1.0 while building.
  final double colourConfidence;

  /// For the COLOUR field — whether locked.
  final bool colourConfirmed;

  /// Called when the user taps this field (e.g. colour picker).
  final VoidCallback? onTap;

  /// Values to cycle through in the slot reel animation.
  final List<String> slotCandidates;

  bool get isDetected => value != null && value!.isNotEmpty;
}

/// Bottom HUD panel for the live scanner — 7-field audiologist model.
///
/// Shows all 7 fields from Seray's identification model:
/// Make, Model, Style, Tubing, Power, Battery Size, Colour.
/// Unfilled fields are dimmed placeholders. Detected fields light up green.
class ScanHud extends StatelessWidget {
  const ScanHud({
    super.key,
    required this.fields,
    required this.crossRefText,
    required this.showHint,
    required this.onReview,
    required this.onFallback,
    required this.totalScans,
  });

  /// The 7 fields to display.
  final List<HudField> fields;

  /// Transient cross-reference text, e.g. "23 OTICON DEVICES IN DATABASE".
  final String? crossRefText;

  final bool showHint;
  final VoidCallback onReview;
  final VoidCallback onFallback;

  /// Total scans this user has completed. Controls hint graduation.
  final int totalScans;

  bool get _hasDetections => fields.any((f) => f.isDetected);
  bool get _hasBrand => fields.isNotEmpty && fields[0].isDetected;

  /// How many of the 7 fields are filled.
  int get _filledCount => fields.where((f) => f.isDetected).length;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Color(0xDD000000)],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(20, 32, 20, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Cross-reference flash
          if (crossRefText != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                crossRefText!,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                  color: Color(0x88FFFFFF),
                  letterSpacing: 1.0,
                ),
              ),
            ),

          // 7-field readout
          for (var i = 0; i < fields.length; i++) ...[
            if (i > 0) const SizedBox(height: 3),
            _FieldRow(field: fields[i], index: i),
          ],

          const SizedBox(height: 8),

          // Field count badge
          if (_hasDetections)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '$_filledCount/7 FIELDS IDENTIFIED',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                  color: _filledCount == 7
                      ? AppColors.success
                      : const Color(0x66FFFFFF),
                  letterSpacing: 1.5,
                ),
              ),
            ),

          // Instruction / hint — graduated by totalScans
          if (!_hasDetections && !showHint && totalScans <= 10)
            Text(
              totalScans <= 3 ? 'Slowly rotate the hearing aid' : 'Scanning…',
              style: AppTypography.bodySmall.copyWith(
                color: AppColors.white.withValues(alpha: 0.7),
              ),
            ),

          if (!_hasDetections && showHint && totalScans <= 10) ...[
            if (totalScans <= 3)
              Text(
                'Try holding closer',
                style: AppTypography.bodySmall.copyWith(
                  color: AppColors.white.withValues(alpha: 0.7),
                ),
              ),
            if (totalScans <= 3) const SizedBox(height: 4),
            GestureDetector(
              onTap: onFallback,
              child: Text(
                'Or take a photo instead',
                style: AppTypography.bodySmall.copyWith(
                  color: AppColors.primary,
                  decoration: TextDecoration.underline,
                  decorationColor: AppColors.primary,
                ),
              ),
            ),
          ],

          if (_hasDetections && !_hasBrand && totalScans <= 3)
            Text(
              'Keep rotating for more fields',
              style: AppTypography.caption.copyWith(
                color: AppColors.white.withValues(alpha: 0.5),
              ),
            ),

          // Review button — available once brand is detected
          if (_hasBrand) ...[
            const SizedBox(height: 4),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onReview,
                icon: const Icon(Icons.arrow_forward, size: 18),
                label: const Text('Review Results'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: AppColors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Per-field accent colors — each field gets a distinct slam color.
const _fieldAccentColors = [
  Color(0xFF10B981), // MAKE — emerald green
  Color(0xFF22D3EE), // MODEL — cyan
  Color(0xFFA78BFA), // STYLE — violet
  Color(0xFFF59E0B), // TUBING — amber
  Color(0xFFEC4899), // POWER — pink
  Color(0xFF3B82F6), // BAT SIZE — blue
  Color(0xFFF97316), // COLOUR — orange
];

/// A single field row in the 7-field HUD.
///
/// Detected fields show a colored check + value with slam animation.
/// Undetected fields show a dim circle + placeholder dots.
/// Colour field has a swatch + confidence ring.
class _FieldRow extends StatelessWidget {
  const _FieldRow({required this.field, required this.index});

  final HudField field;
  final int index;

  @override
  Widget build(BuildContext context) {
    final detected = field.isDetected;
    final isColour = field.label == 'COLOUR';

    return GestureDetector(
      onTap: field.onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedOpacity(
        opacity: detected ? 1.0 : 0.4,
        duration: const Duration(milliseconds: 300),
        child: Row(
          children: [
            // Status icon
            if (isColour && !field.colourConfirmed && field.colourRgb != null)
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  value: field.colourConfidence,
                  strokeWidth: 2,
                  color: AppColors.success,
                  backgroundColor: const Color(0x33FFFFFF),
                ),
              )
            else
              Icon(
                detected
                    ? Icons.check_circle
                    : Icons.radio_button_unchecked,
                size: 16,
                color: detected
                    ? _fieldAccentColors[
                        index.clamp(0, _fieldAccentColors.length - 1)]
                    : AppColors.white.withValues(alpha: 0.3),
              ),
            const SizedBox(width: 8),

            // Field label
            SizedBox(
              width: 72,
              child: Text(
                field.label,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: Color(0x99FFFFFF),
                  letterSpacing: 0.5,
                ),
              ),
            ),

            // Colour swatch (colour field only)
            if (isColour && field.colourRgb != null) ...[
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: field.colourRgb!.withValues(
                    alpha: 0.4 + 0.6 * field.colourConfidence,
                  ),
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(
                    color: const Color(0x55FFFFFF),
                    width: 1,
                  ),
                ),
              ),
              const SizedBox(width: 6),
            ],

            // Value — slot reel when candidates available, static otherwise
            Expanded(
              child: field.slotCandidates.isNotEmpty
                  ? SlotReelText(
                      candidates: field.slotCandidates,
                      targetValue: field.value,
                      accentColor: _fieldAccentColors[
                          index.clamp(0, _fieldAccentColors.length - 1)],
                    )
                  : Text(
                      detected ? field.value! : '· · ·',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        fontWeight:
                            detected ? FontWeight.w600 : FontWeight.w400,
                        color: detected
                            ? _fieldAccentColors[
                                index.clamp(0, _fieldAccentColors.length - 1)]
                                .withValues(alpha: 0.6)
                            : const Color(0x33FFFFFF),
                        letterSpacing: 0.3,
                      ),
                    ),
            ),

            // Confidence badge
            if (detected && field.confidence != null)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(3),
                  color: const Color(0x33FFFFFF),
                ),
                child: Text(
                  field.confidence!,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    color: Color(0x99FFFFFF),
                    letterSpacing: 0.5,
                  ),
                ),
              ),

            // Edit badge for confirmed colour
            if (isColour && field.colourConfirmed)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(3),
                  color: const Color(0x33FFFFFF),
                ),
                child: const Text(
                  'EDIT',
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    color: Color(0x99FFFFFF),
                    letterSpacing: 0.5,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
