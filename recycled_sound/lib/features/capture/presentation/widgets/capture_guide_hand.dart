import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../capture_slot.dart';

/// A pose for the guide hand — where it sits and how it's tilted, per slot.
class _HandPose {
  const _HandPose(this.alignment, this.turns);

  /// Where the hand sits within the guide box.
  final Alignment alignment;

  /// Rotation in turns (1.0 == 360°), implying the orientation to hold.
  final double turns;
}

/// Cartoony capture-guide animation (v1 emoji prototype).
///
/// Shows a hand holding a hearing aid that moves/tilts to a per-slot pose,
/// coaching the volunteer on how to orient the device for the current shot.
/// This is a PROTOTYPE to nail the choreography — the `slot → pose` mapping is
/// the real interface; the emoji renderer can later be swapped for a Rive
/// widget behind the same mapping without touching the capture screen.
///
/// Deliberately pure (no async, no controllers beyond implicit animations,
/// no plugin calls) so it can never throw into or stall the capture pipeline
/// (the cosmetic-never-blocks-pipeline rule).
class CaptureGuideHand extends StatelessWidget {
  const CaptureGuideHand({super.key, required this.slot, this.size = 120});

  final CaptureSlot slot;
  final double size;

  // The choreography. Rough, prototype values — tune against real feel.
  _HandPose _poseFor(CaptureSlot s) => switch (s) {
        CaptureSlot.scale => const _HandPose(Alignment.bottomCenter, 0),
        CaptureSlot.medial => const _HandPose(Alignment.centerLeft, -0.05),
        CaptureSlot.lateral => const _HandPose(Alignment.centerRight, 0.5),
        CaptureSlot.anterior => const _HandPose(Alignment.topCenter, -0.12),
        CaptureSlot.posterior => const _HandPose(Alignment.bottomCenter, 0.12),
        CaptureSlot.superior => const _HandPose(Alignment.topCenter, 0),
        CaptureSlot.inferior => const _HandPose(Alignment.bottomCenter, 0.5),
      };

  @override
  Widget build(BuildContext context) {
    final pose = _poseFor(slot);
    const dur = Duration(milliseconds: 450);
    const curve = Curves.easeInOut;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white24),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // The "device" the hand presents — a small rounded body. For the
          // scale slot we also show a card outline behind it.
          if (slot == CaptureSlot.scale)
            Align(
              alignment: Alignment.center,
              child: Container(
                width: size * 0.5,
                height: size * 0.32,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.white38),
                ),
              ),
            ),
          Align(
            alignment: Alignment.center,
            child: Container(
              width: size * 0.18,
              height: size * 0.3,
              decoration: BoxDecoration(
                color: AppColors.accent,
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
          // The hand — animates to the slot's pose.
          AnimatedAlign(
            duration: dur,
            curve: curve,
            alignment: pose.alignment,
            child: AnimatedRotation(
              duration: dur,
              curve: curve,
              turns: pose.turns,
              child: Text('🤏', style: TextStyle(fontSize: size * 0.38)),
            ),
          ),
        ],
      ),
    );
  }
}
