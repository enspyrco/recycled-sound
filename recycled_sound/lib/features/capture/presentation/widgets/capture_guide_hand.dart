import 'package:flutter/material.dart';

import '../capture_slot.dart';

/// Per-slot capture-guide image: a stylized cartoon of a REAL hearing aid at
/// the orientation the volunteer should photograph for this slot. The cartoons
/// are generated from real device photos (background removed with U2Net, then
/// stylized) and stored with transparent backgrounds so they sit cleanly on
/// the dark guide box.
///
/// This replaces the v1/v2 emoji prototype (a 🤏 hand holding an 👂 ear). The
/// `slot → asset` mapping is the real interface — swapping a slot's
/// illustration is just replacing its PNG under `assets/capture_guide/`.
///
/// Deliberately pure (no async, no controllers beyond an implicit cross-fade,
/// no plugin calls) so it can never throw into or stall the capture pipeline
/// (the cosmetic-never-blocks-pipeline rule). A missing asset falls back to a
/// hearing icon rather than a broken-image glyph.
class CaptureGuideHand extends StatelessWidget {
  const CaptureGuideHand({super.key, required this.slot, this.size = 120});

  final CaptureSlot slot;
  final double size;

  String _assetFor(CaptureSlot s) => switch (s) {
        CaptureSlot.scale => 'assets/capture_guide/scale.png',
        CaptureSlot.medial => 'assets/capture_guide/medial.png',
        CaptureSlot.lateral => 'assets/capture_guide/lateral.png',
        CaptureSlot.anterior => 'assets/capture_guide/anterior.png',
        CaptureSlot.posterior => 'assets/capture_guide/posterior.png',
        CaptureSlot.superior => 'assets/capture_guide/superior.png',
        CaptureSlot.inferior => 'assets/capture_guide/inferior.png',
      };

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * 0.07),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white24),
      ),
      // Cross-fade as the slot changes — the image IS the orientation now, so
      // no rotation; the per-slot photo already shows the correct face.
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 320),
        switchInCurve: Curves.easeOut,
        child: slot == CaptureSlot.scale ? _scaleLayout() : _deviceImage(slot),
      ),
    );
  }

  /// SCALE: the hearing aid beside a credit card — the card is a known size,
  /// so the shot lets us measure the device.
  Widget _scaleLayout() => Row(
        key: const ValueKey('scale'),
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(child: _img('assets/capture_guide/scale.png')),
          SizedBox(width: size * 0.06),
          Text('💳', style: TextStyle(fontSize: size * 0.34)),
        ],
      );

  Widget _deviceImage(CaptureSlot s) =>
      KeyedSubtree(key: ValueKey(s), child: _img(_assetFor(s)));

  Widget _img(String asset) => Image.asset(
        asset,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => Center(
          child: Icon(Icons.hearing, size: size * 0.4, color: Colors.white70),
        ),
      );
}
