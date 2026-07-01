import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/rs_button.dart';
import '../../../core/widgets/rs_card.dart';
import 'capture_slot.dart';

/// Pre-shoot instructions for a full training-photo set (the "capture a
/// training set" home entry — Seray's bulk-capture session).
///
/// Sits between the box-first modal and the live camera: the box has already
/// been entered, this screen orients the volunteer on the 14-shot protocol,
/// then "Start capturing" replaces itself with the camera. The angle list is
/// driven off [CaptureSlot.values] so it can never drift from the flow the
/// camera actually walks through.
class CaptureInstructionsScreen extends StatelessWidget {
  const CaptureInstructionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    const slots = CaptureSlot.values;
    return Scaffold(
      appBar: AppBar(title: const Text('Capture a training set')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── What this is ─────────────────────────────────────────
              RsCard(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            color: AppColors.primaryLight,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: const Icon(
                            Icons.collections_bookmark_outlined,
                            size: 28,
                            color: AppColors.primary,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Text(
                            'A full photo set for one device',
                            style: AppTypography.h3,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'This captures a complete, labelled set of photos so the '
                      'app can learn to recognise this exact device. You will '
                      'take 14 photos in all — 7 angles of each aid, left and '
                      'right. The camera guides you one shot at a time; you '
                      'just follow along.',
                      style: AppTypography.body.copyWith(
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // ── The 7 angles ─────────────────────────────────────────
              Text('The 7 angles (per aid)', style: AppTypography.h3),
              const SizedBox(height: 4),
              Text(
                'You will shoot each of these for the left aid, then the right.',
                style: AppTypography.caption.copyWith(
                  color: AppColors.textMuted,
                ),
              ),
              const SizedBox(height: 12),
              RsCard(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  children: [
                    for (var i = 0; i < slots.length; i++) ...[
                      if (i > 0)
                        const Divider(height: 1, color: AppColors.border),
                      _AngleRow(index: i + 1, slot: slots[i]),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // ── Tips for a good shot ─────────────────────────────────
              Text('For sharp, usable photos', style: AppTypography.h3),
              const SizedBox(height: 12),
              const RsCard(
                padding: EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Tip(
                      icon: Icons.crop_free,
                      text: 'Fill the frame — get close so the aid is large and '
                          'in focus. Tap the screen to focus if it looks soft.',
                    ),
                    SizedBox(height: 12),
                    _Tip(
                      icon: Icons.wb_sunny_outlined,
                      text: 'Bright, even light. Avoid harsh shadows and glare '
                          'off the shiny shell.',
                    ),
                    SizedBox(height: 12),
                    _Tip(
                      icon: Icons.credit_card,
                      text: 'Keep a credit card handy for the first "Size" shot '
                          '— it is the scale reference.',
                    ),
                    SizedBox(height: 12),
                    _Tip(
                      icon: Icons.text_fields,
                      text: 'For the "Brand & model" shot, get the tiny printed '
                          'text as legible as you can — that is the label the '
                          'app reads.',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 28),

              RsButton(
                label: 'Start capturing',
                icon: Icons.photo_camera,
                // The box is already set (box-first modal ran before this
                // screen). Replace this screen with the camera so Back from the
                // camera returns Home, not to these instructions.
                onPressed: () => context.pushReplacement('/capture'),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}

/// One numbered angle row: step number, title, and the plain-language hint.
class _AngleRow extends StatelessWidget {
  const _AngleRow({required this.index, required this.slot});

  final int index;
  final CaptureSlot slot;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: AppColors.primaryLight,
              shape: BoxShape.circle,
            ),
            child: Text(
              '$index',
              style: AppTypography.caption.copyWith(
                color: AppColors.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(slot.title, style: AppTypography.label),
                const SizedBox(height: 2),
                Text(
                  slot.hint,
                  style: AppTypography.caption.copyWith(
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A single tip line: icon + text.
class _Tip extends StatelessWidget {
  const _Tip({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: AppColors.primary),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: AppTypography.body.copyWith(color: AppColors.textMuted),
          ),
        ),
      ],
    );
  }
}
