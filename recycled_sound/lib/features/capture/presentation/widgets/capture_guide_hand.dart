import 'package:flutter/material.dart';

import '../capture_slot.dart';

/// A pose for the held hearing aid — where the hand+aid unit sits within the
/// guide box and how it's tilted, per slot.
class _HandPose {
  const _HandPose(this.alignment, this.turns);

  /// Where the held unit sits within the guide box.
  final Alignment alignment;

  /// Rotation in turns (1.0 == 360°), implying the orientation to hold.
  final double turns;
}

/// Cartoony capture-guide animation (v2 emoji prototype).
///
/// A hand 🤏 holding a hearing aid (shown as an ear 👂) moves/tilts to a
/// per-slot pose, coaching the volunteer on how to orient the device for the
/// current shot. The hand and the aid are ONE grouped unit that moves and
/// rotates together, so the hand always looks like it's actually holding the
/// device (the v1 bug was a hand floating around a stationary device).
///
/// The SCALE slot is special: instead of a held pose, it lays the aid flat
/// NEXT TO a credit card 💳 — the card is a known size, so that photo lets us
/// measure the device.
///
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

  // The choreography for the held (non-scale) slots. Gentle tilts — the v1
  // half-turns flipped the aid fully upside-down, which read as wrong.
  _HandPose _poseFor(CaptureSlot s) => switch (s) {
        CaptureSlot.scale => const _HandPose(Alignment.center, 0),
        CaptureSlot.medial => const _HandPose(Alignment.centerLeft, -0.05),
        CaptureSlot.lateral => const _HandPose(Alignment.centerRight, 0.05),
        CaptureSlot.anterior => const _HandPose(Alignment.topCenter, -0.12),
        CaptureSlot.posterior => const _HandPose(Alignment.bottomCenter, 0.12),
        CaptureSlot.superior => const _HandPose(Alignment.topCenter, 0),
        CaptureSlot.inferior => const _HandPose(Alignment.bottomCenter, 0.08),
      };

  @override
  Widget build(BuildContext context) {
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
      child: slot == CaptureSlot.scale
          ? _buildScale()
          : _buildHeld(_poseFor(slot), dur, curve),
    );
  }

  /// SCALE shot: the hearing aid laid flat NEXT TO a credit card. The card is a
  /// known size, so the photo lets us measure the device. Aid and card sit side
  /// by side, both flat (no held pose, no rotation).
  Widget _buildScale() {
    return Center(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text('👂', style: TextStyle(fontSize: size * 0.30)),
          SizedBox(width: size * 0.10),
          Text('💳', style: TextStyle(fontSize: size * 0.40)),
        ],
      ),
    );
  }

  /// FACE slots: a hand pinching the hearing aid (ear), presented at the slot's
  /// angle. The hand and aid are stacked into one unit and the whole unit
  /// alignment-animates + rotates together, so the hand always holds the aid.
  Widget _buildHeld(_HandPose pose, Duration dur, Curve curve) {
    return AnimatedAlign(
      duration: dur,
      curve: curve,
      alignment: pose.alignment,
      child: AnimatedRotation(
        duration: dur,
        curve: curve,
        turns: pose.turns,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The hearing aid being held up to show this face.
            Text('👂', style: TextStyle(fontSize: size * 0.26)),
            // Fingers pinching it from just below — overlapped slightly so it
            // reads as gripping the aid, not sitting under it.
            Transform.translate(
              offset: Offset(0, -size * 0.06),
              child: Text('🤏', style: TextStyle(fontSize: size * 0.30)),
            ),
          ],
        ),
      ),
    );
  }
}
