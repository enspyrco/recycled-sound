// Excluded from coverage: large stateful form depending on Firestore writes + colour pickers
// coverage:ignore-file
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../devices/data/incoming_device_repository.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/providers/firebase_providers.dart';
import '../../devices/data/models/device.dart';
import '../../devices/providers/device_providers.dart';
import '../data/brand_colour_palettes.dart';
import '../data/colour_classifier.dart';
import '../data/models/scan_result.dart';
import '../providers/scanner_providers.dart';
import '../../auth/providers/auth_providers.dart';

/// The 7-field confirmation screen — where AI meets audiologist.
///
/// This screen is the convergence point for every signal upstream (neural net,
/// OCR, CIELAB colour, CLIP style probe) and the gateway to everything
/// downstream (device register, matching, redistribution).
///
/// Design language: dark background carrying the T2 HUD aesthetic forward.
/// Green = AI confident. Amber = needs attention. Pulse = "I still need this."
/// Not a form — a conversation the scanner had with the device, presented
/// for the audiologist to confirm or correct.
class ConfirmationScreen extends ConsumerStatefulWidget {
  const ConfirmationScreen({super.key});

  @override
  ConsumerState<ConfirmationScreen> createState() => _ConfirmationScreenState();
}

class _ConfirmationScreenState extends ConsumerState<ConfirmationScreen>
    with TickerProviderStateMixin {
  late final AnimationController _pulseController;
  late final AnimationController _completionController;
  bool _completionFired = false;

  /// Free-text physical storage location (box/bag, e.g. B07). Metadata, not a
  /// clinical field — never gates the "Add to Register" completion button.
  final TextEditingController _locationController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);

    _completionController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _completionController.dispose();
    _locationController.dispose();
    super.dispose();
  }

  void _checkCompletion(ScanResult result) {
    // The completion ceremony (heavy haptic + green flash) fires only on
    // FULL verification — every field confirmed, none left as a volunteer
    // "Unknown". A record that's complete-but-flagged is registrable but not
    // a clean win, so it gets the calm amber header, not the victory party.
    if (result.isFullyVerified && !_completionFired) {
      _completionFired = true;
      HapticFeedback.heavyImpact();
      _completionController.forward();
    } else if (!result.isFullyVerified && _completionFired) {
      // A field was un-filled or flagged Unknown — reset so the ceremony can
      // fire again once the record is fully verified.
      _completionFired = false;
      _completionController.reset();
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = ref.watch(scanResultProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkCompletion(result);
    });

    final filled = result.filledFieldCount;
    final brandPalette = result.brand.value.isNotEmpty
        ? BrandColourPalettes.forBrand(result.brand.value)
        : null;

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      body: SafeArea(
        child: Column(
          children: [
            // ── Header strip ──────────────────────────────────────────
            _HeaderStrip(
              filled: filled,
              total: 7,
              isComplete: result.isComplete,
              isFullyVerified: result.isFullyVerified,
              unknownCount: result.unknownFieldCount,
              completionAnimation: _completionController,
              onClose: () => context.go('/'),
            ),

            // ── Field list ────────────────────────────────────────────
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  // 1. MAKE — AI-filled, tap to correct
                  _AiTextField(
                    label: 'MAKE',
                    field: result.brand,
                    pulseController: _pulseController,
                    onSave: (v) => ref
                        .read(scanResultProvider.notifier)
                        .updateField(ScanField.brand, v),
                  ),

                  // 2. MODEL — AI-filled, tap to correct
                  _AiTextField(
                    label: 'MODEL',
                    field: result.model,
                    pulseController: _pulseController,
                    onSave: (v) => ref
                        .read(scanResultProvider.notifier)
                        .updateField(ScanField.model, v),
                  ),

                  // 3. STYLE — chip selector (CLIP probe @ 91.2%)
                  _ChipSelectorField(
                    label: 'STYLE',
                    field: result.type,
                    options: const ['BTE', 'RIC', 'ITE', 'ITC', 'CIC', 'IIC'],
                    pulseController: _pulseController,
                    aiConfidence: result.type.confidence,
                    onSelect: (v) => ref
                        .read(scanResultProvider.notifier)
                        .updateField(ScanField.type, v),
                  ),

                  // 4. TUBING — chip selector (human only)
                  _ChipSelectorField(
                    label: 'TUBING',
                    field: result.tubing,
                    options: const ['Slim', 'Standard', 'None'],
                    pulseController: _pulseController,
                    onSelect: (v) => ref
                        .read(scanResultProvider.notifier)
                        .updateField(ScanField.tubing, v),
                  ),

                  // 5. POWER — toggle (battery vs rechargeable). No Unknown
                  // chip: power source is almost always visually determinable,
                  // so an Unknown here would mean "didn't look", not "ambiguous".
                  _ChipSelectorField(
                    label: 'POWER',
                    field: result.powerSource,
                    options: const ['Battery', 'Rechargeable'],
                    allowUnknown: false,
                    pulseController: _pulseController,
                    onSelect: (v) {
                      final notifier = ref.read(scanResultProvider.notifier);
                      notifier.updateField(ScanField.powerSource, v);
                      // Clear battery size when switching to rechargeable,
                      // set N/A so the field counts as filled.
                      if (v == 'Rechargeable') {
                        notifier.updateField(ScanField.batterySize, 'N/A');
                      }
                    },
                  ),

                  // 6. BATTERY SIZE — chip selector (4 classes)
                  _ChipSelectorField(
                    label: 'BATTERY',
                    field: _batteryDisplayField(result),
                    options: const ['10', '13', '312', '675', 'N/A'],
                    pulseController: _pulseController,
                    onSelect: (v) => ref
                        .read(scanResultProvider.notifier)
                        .updateField(ScanField.batterySize, v),
                    enabled: result.powerSource?.value != 'Rechargeable',
                  ),

                  // 7. COLOUR — brand-specific swatches
                  _ColourSwatchField(
                    label: 'COLOUR',
                    field: result.colour,
                    brandPalette: brandPalette,
                    genericPalette: ColourClassifier.palette,
                    pulseController: _pulseController,
                    onSelect: (v) => ref
                        .read(scanResultProvider.notifier)
                        .updateField(ScanField.colour, v),
                  ),

                  // LOCATION — physical storage box/bag (metadata, optional).
                  // Not one of the 7 clinical fields and not counted toward the
                  // completion gate; purely "where does this device live".
                  _LocationField(controller: _locationController),
                ],
              ),
            ),

            // ── Bottom action ─────────────────────────────────────────
            _BottomAction(
              isComplete: result.isComplete,
              unknownCount: result.unknownFieldCount,
              completionAnimation: _completionController,
              onConfirm: () => _confirmAndPersist(result),
              onScanAnother: () => context.pushReplacement('/scan'),
            ),
          ],
        ),
      ),
    );
  }

  /// Persist the confirmed scan to `incoming/`, then route to the register.
  ///
  /// The scanner already uploaded the source image to `scans/{uid}/…` (the
  /// transient scan-mode bucket), so we reference that download URL in
  /// `photos[]` rather than re-uploading. Intake photos captured via the
  /// device-intake flow land in the durable `captures/{uid}/{deviceId}/` bucket
  /// (see [IncomingDeviceRepository.createIncoming]).
  Future<void> _confirmAndPersist(ScanResult result) async {
    HapticFeedback.mediumImpact();
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    final repo = ref.read(incomingDeviceRepositoryProvider);

    // A confirmed scan has no persisted identity yet — it's a DraftDevice.
    // Firestore allocates the id inside createIncoming, where the draft is
    // promoted to a Device and `createdBy` is pinned for the rules layer.
    final draft = DraftDevice(
      brand: result.brand.value,
      model: result.model.value,
      // Style (clinical field 3) and batterySize (field 6) are closed-set enums
      // at the model boundary (#15). The scanner works in catalog STRING space
      // (fuzzy OCR/CLIP against catalog strings like 'BTE'), so parse into the
      // typed enums here; an untouched field or the volunteer's 'Unknown' flag
      // resolves to `unspecified` (the "needs input" signal rides on
      // needsInputFields below, not on the value).
      type: Style.fromWire(result.type.value),
      year: result.year.value,
      batterySize: BatterySize.fromWire(result.batterySize.value),
      // Clinical fields 4/5/7 — previously dropped at persist (issue #751).
      // ScanResult holds these as optional String SpecFields; parse into the
      // typed enums at this boundary (#15). An untouched field or the volunteer's
      // 'Unknown' provenance flag both resolve to `unspecified` — the "needs
      // input" signal rides on needsInputFields below, not on the value.
      tubing: Tubing.fromWire(result.tubing?.value),
      powerSource: PowerSource.fromWire(result.powerSource?.value),
      colour: result.colour?.value ?? '',
      domeType: result.domeType.value,
      waxFilter: result.waxFilter.value,
      receiver: result.receiver.value,
      scanId: result.scanId,
      // Physical storage location (issue #766) — trimmed + uppercased so
      // `b07` and ` B07 ` both persist as `B07`. Empty when left blank.
      location: _locationController.text.trim().toUpperCase(),
      photos: [if (result.imageUrl.isNotEmpty) result.imageUrl],
      // The volunteer→audiologist handoff: which fields the human deliberately
      // flagged undetermined. Persisted as a structured set so the register's
      // "NEEDS INPUT" flag is driven by intent, not by string-matching the
      // AI pipeline's own 'Unknown' default.
      needsInputFields: result.volunteerUnknownFields,
    );

    try {
      final id = await repo.createIncoming(draft);
      messenger.showSnackBar(
        SnackBar(
          content: Text('Added to register · $id'),
          backgroundColor: AppColors.success,
        ),
      );
      // Corrections are training telemetry — guarded separately so a failed
      // corrections write can never strand the volunteer on this screen
      // after the device was already created (re-tapping Add to Register
      // would duplicate it).
      try {
        final corrections = ref.read(scanResultProvider.notifier).corrections;
        final scanner = ref.read(scannerRepositoryProvider);
        final profile = ref.read(currentUserProfileProvider).value;
        final userRole = profile?.role.wire ?? 'volunteer';
        await scanner.submitCorrections(
          scanId: result.scanId,
          corrections: corrections,
          userId: ref.read(firebaseAuthProvider).currentUser?.uid ?? '',
          userRole: userRole,
        );
      } catch (_) {
        // Lost corrections are recoverable from the scan doc later; the
        // volunteer's flow is not.
      }

      router.go('/devices');
    } on FirebaseException catch (e) {
      // Discriminate by code so volunteers get actionable copy instead of a
      // raw exception string.
      messenger.showSnackBar(
        SnackBar(
          content: Text(PersistErrorKind.fromCode(e.code).userMessage),
          backgroundColor: AppColors.error,
        ),
      );
    } catch (_) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(PersistErrorKind.unknown.userMessage),
          backgroundColor: AppColors.error,
        ),
      );
    }
  }

  /// Battery size field — null if empty (triggers amber pulse).
  SpecField? _batteryDisplayField(ScanResult result) {
    final bs = result.batterySize;
    return bs.value.isEmpty ? null : bs;
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Header Strip — progress counter + completion flash
// ═══════════════════════════════════════════════════════════════════════════

class _HeaderStrip extends StatelessWidget {
  const _HeaderStrip({
    required this.filled,
    required this.total,
    required this.isComplete,
    required this.isFullyVerified,
    required this.unknownCount,
    required this.completionAnimation,
    required this.onClose,
  });

  final int filled;
  final int total;

  /// Every field acknowledged (gate is open) — but some may be volunteer
  /// "Unknown" flags awaiting the audiologist.
  final bool isComplete;

  /// Every field confirmed with a real value — the only state that earns the
  /// green "IDENTIFICATION COMPLETE" celebration.
  final bool isFullyVerified;
  final int unknownCount;
  final AnimationController completionAnimation;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: completionAnimation,
      builder: (context, child) {
        final glow = completionAnimation.value;
        return Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          decoration: BoxDecoration(
            color: Color.lerp(
              const Color(0xFF1A1A1A),
              AppColors.success.withValues(alpha: 0.15),
              glow,
            ),
            border: Border(
              bottom: BorderSide(
                color: isFullyVerified
                    ? AppColors.success.withValues(alpha: 0.3 + 0.4 * glow)
                    : isComplete
                    ? AppColors.warning.withValues(alpha: 0.4)
                    : const Color(0xFF333333),
                width: 1,
              ),
            ),
          ),
          child: Row(
            children: [
              // Progress dots
              ...List.generate(total, (i) {
                final isFilled = i < filled;
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isFilled
                          ? AppColors.success
                          : const Color(0xFF444444),
                      boxShadow: isFilled && isFullyVerified
                          ? [
                              BoxShadow(
                                color: AppColors.success.withValues(alpha: 0.5),
                                blurRadius: 4 + 4 * glow,
                              ),
                            ]
                          : null,
                    ),
                  ),
                );
              }),

              const SizedBox(width: 12),

              // Counter text — three states: counting up, complete-but-flagged
              // (amber), and fully verified (green celebration).
              Text(
                isFullyVerified
                    ? 'IDENTIFICATION COMPLETE'
                    : isComplete
                    ? 'READY · $unknownCount NEED INPUT'
                    : '$filled OF $total',
                style: AppTypography.monoStatus.copyWith(
                  color: isFullyVerified
                      ? AppColors.success
                      : isComplete
                      ? AppColors.warning
                      : const Color(0xFF888888),
                ),
              ),

              const Spacer(),

              // Close
              IconButton(
                icon: const Icon(Icons.close, color: Color(0xFF888888)),
                iconSize: 20,
                onPressed: onClose,
              ),
            ],
          ),
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// AI Text Field — for Make & Model (tap to edit free text)
// ═══════════════════════════════════════════════════════════════════════════

class _AiTextField extends StatefulWidget {
  const _AiTextField({
    required this.label,
    required this.field,
    required this.pulseController,
    required this.onSave,
  });

  final String label;
  final SpecField field;
  final AnimationController pulseController;
  final ValueChanged<String> onSave;

  @override
  State<_AiTextField> createState() => _AiTextFieldState();
}

class _AiTextFieldState extends State<_AiTextField> {
  bool _editing = false;
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.field.value);
  }

  @override
  void didUpdateWidget(_AiTextField old) {
    super.didUpdateWidget(old);
    if (old.field.value != widget.field.value && !_editing) {
      _controller.text = widget.field.value;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final v = _controller.text.trim();
    if (v.isNotEmpty && v != widget.field.value) {
      HapticFeedback.lightImpact();
      widget.onSave(v);
    }
    setState(() => _editing = false);
  }

  @override
  Widget build(BuildContext context) {
    final hasFill = widget.field.value.isNotEmpty;
    final confidence = widget.field.confidence;

    return _FieldContainer(
      hasFill: hasFill,
      pulseController: widget.pulseController,
      child: Row(
        children: [
          _FieldLabel(label: widget.label),
          if (_editing) ...[
            Expanded(
              child: TextField(
                controller: _controller,
                autofocus: true,
                style: _valueStyle(true),
                cursorColor: AppColors.success,
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 4),
                ),
                onSubmitted: (_) => _save(),
              ),
            ),
            _ActionButton(
              icon: Icons.check,
              color: AppColors.success,
              onTap: _save,
            ),
          ] else ...[
            Expanded(
              child: Text(
                hasFill ? widget.field.value : '— tap to enter —',
                style: _valueStyle(hasFill),
              ),
            ),
            if (hasFill) _ConfidenceBadge(confidence: confidence),
            const SizedBox(width: 8),
            _ActionButton(
              icon: hasFill ? Icons.edit_outlined : Icons.add,
              color: hasFill ? const Color(0xFF666666) : _amberColor,
              onTap: () => setState(() => _editing = true),
            ),
          ],
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Chip Selector Field — for Style, Tubing, Power, Battery Size
// ═══════════════════════════════════════════════════════════════════════════

class _ChipSelectorField extends StatelessWidget {
  const _ChipSelectorField({
    required this.label,
    required this.field,
    required this.options,
    required this.pulseController,
    required this.onSelect,
    this.aiConfidence,
    this.enabled = true,
    this.allowUnknown = true,
  });

  final String label;
  final SpecField? field;
  final List<String> options;
  final AnimationController pulseController;
  final ValueChanged<String> onSelect;
  final int? aiConfidence;
  final bool enabled;

  /// Appends an amber "Unknown" chip so a volunteer who genuinely can't
  /// determine a constrained field can flag it for the audiologist rather than
  /// guessing or stalling the completion gate. Disabled for fields that are
  /// almost always visually determinable (e.g. Power), where an `Unknown`
  /// tends to mean "didn't look" more than "ambiguous".
  final bool allowUnknown;

  @override
  Widget build(BuildContext context) {
    final current = field?.value ?? '';
    final hasFill = current.isNotEmpty && current != '—';

    // The real options plus the Unknown escape valve, de-duplicated in case a
    // caller already lists it explicitly.
    final chips = [
      ...options,
      if (allowUnknown && !options.contains(kUnknownValue)) kUnknownValue,
    ];

    return _FieldContainer(
      hasFill: hasFill,
      pulseController: pulseController,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _FieldLabel(label: label),
              if (hasFill && aiConfidence != null && aiConfidence! > 0)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: _ConfidenceBadge(confidence: aiConfidence!),
                ),
              if (!enabled)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text(
                    'N/A',
                    style: AppTypography.monoStatus.copyWith(
                      color: const Color(0xFF555555),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: chips.map((option) {
              final isSelected = current == option;
              final isUnknown = option == kUnknownValue;
              // The Unknown chip reads as amber — a flag, not a confident
              // value — so a selected Unknown is visually distinct from a
              // confirmed (green) answer both here and in the audiologist's
              // mental model when they later review the record.
              final accent = isUnknown ? AppColors.warning : AppColors.success;
              return GestureDetector(
                onTap: enabled
                    ? () {
                        HapticFeedback.selectionClick();
                        onSelect(option);
                      }
                    : null,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? accent.withValues(alpha: 0.15)
                        : enabled
                        ? const Color(0xFF222222)
                        : const Color(0xFF1A1A1A),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isSelected
                          ? accent.withValues(alpha: 0.6)
                          : isUnknown && enabled
                          ? AppColors.warning.withValues(alpha: 0.4)
                          : enabled
                          ? const Color(0xFF444444)
                          : const Color(0xFF333333),
                      width: isSelected ? 1.5 : 1,
                    ),
                  ),
                  child: Text(
                    option,
                    style: AppTypography.monoValue.copyWith(
                      fontWeight: isSelected
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: isSelected
                          ? accent
                          : isUnknown && enabled
                          ? AppColors.warning.withValues(alpha: 0.8)
                          : enabled
                          ? const Color(0xFFAAAAAA)
                          : const Color(0xFF555555),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Colour Swatch Field — brand-specific or generic palette
// ═══════════════════════════════════════════════════════════════════════════

class _ColourSwatchField extends StatelessWidget {
  const _ColourSwatchField({
    required this.label,
    required this.field,
    required this.brandPalette,
    required this.genericPalette,
    required this.pulseController,
    required this.onSelect,
  });

  final String label;
  final SpecField? field;
  final List<BrandColour>? brandPalette;
  final List<HearingAidColour> genericPalette;
  final AnimationController pulseController;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final current = field?.value ?? '';
    final hasFill = current.isNotEmpty;

    // Use brand palette if available, otherwise generic
    final swatches =
        brandPalette ??
        genericPalette.map((c) => BrandColour(c.name, c.color)).toList();

    return _FieldContainer(
      hasFill: hasFill,
      pulseController: pulseController,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _FieldLabel(label: label),
              if (hasFill) ...[
                const SizedBox(width: 8),
                _ConfidenceBadge(confidence: field!.confidence),
              ],
              if (brandPalette != null) ...[
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(4),
                    color: AppColors.primary.withValues(alpha: 0.15),
                  ),
                  child: Text(
                    'BRAND PALETTE',
                    style: AppTypography.monoMicro.copyWith(
                      color: AppColors.primary.withValues(alpha: 0.8),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: swatches.map((swatch) {
              final isSelected = current == swatch.name;
              return GestureDetector(
                onTap: () {
                  HapticFeedback.selectionClick();
                  onSelect(swatch.name);
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: swatch.color,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isSelected
                              ? AppColors.success
                              : const Color(0xFF555555),
                          width: isSelected ? 2.5 : 1,
                        ),
                        boxShadow: isSelected
                            ? [
                                BoxShadow(
                                  color: AppColors.success.withValues(
                                    alpha: 0.3,
                                  ),
                                  blurRadius: 8,
                                ),
                              ]
                            : null,
                      ),
                      child: isSelected
                          ? const Icon(
                              Icons.check,
                              size: 18,
                              color: Colors.white,
                            )
                          : null,
                    ),
                    const SizedBox(height: 4),
                    SizedBox(
                      width: 52,
                      child: Text(
                        swatch.name,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.monoMicro.copyWith(
                          fontWeight: isSelected
                              ? FontWeight.w600
                              : FontWeight.w400,
                          color: isSelected
                              ? AppColors.success
                              : const Color(0xFF888888),
                          height: 1.2,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Location Field — free-text physical storage box/bag (metadata)
// ═══════════════════════════════════════════════════════════════════════════

/// A single labelled free-text field for the physical storage Location ID
/// (box/bag number, e.g. `B07`, `C10`). Deliberately NOT a chip selector: the
/// storage layout is open-ended and not a clinical spec. It does not count
/// toward the 7-field completion gate — purely "where does this device live".
///
/// Uppercasing happens at persist time (see `_confirmAndPersist`), so the
/// raw text is shown as typed and normalised only on save.
class _LocationField extends StatelessWidget {
  const _LocationField({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 2),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Container(
          color: const Color(0xFF151515),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(width: 3, color: const Color(0xFF3A3A3A)),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Row(
                      children: [
                        const _FieldLabel(label: 'BOX'),
                        Expanded(
                          child: TextField(
                            controller: controller,
                            textCapitalization:
                                TextCapitalization.characters,
                            style: _valueStyle(true),
                            cursorColor: AppColors.success,
                            decoration: const InputDecoration(
                              isDense: true,
                              border: InputBorder.none,
                              hintText: 'Location ID — e.g. B07 (optional)',
                              hintStyle: TextStyle(
                                color: Color(0xFF555555),
                                fontSize: 14,
                              ),
                              contentPadding: EdgeInsets.symmetric(vertical: 4),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Bottom Action Bar
// ═══════════════════════════════════════════════════════════════════════════

class _BottomAction extends StatelessWidget {
  const _BottomAction({
    required this.isComplete,
    required this.completionAnimation,
    required this.onConfirm,
    required this.onScanAnother,
    this.unknownCount = 0,
  });

  final bool isComplete;

  /// How many of the 7 fields were flagged `Unknown`. When non-zero the bar
  /// shows an amber note so the volunteer (and later the audiologist) know the
  /// record is complete-but-unverified, not fully confirmed.
  final int unknownCount;
  final AnimationController completionAnimation;
  final VoidCallback onConfirm;
  final VoidCallback onScanAnother;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: completionAnimation,
      builder: (context, child) {
        final glow = completionAnimation.value;
        return Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            border: Border(
              top: BorderSide(
                color: isComplete
                    ? AppColors.success.withValues(alpha: 0.3 + 0.4 * glow)
                    : const Color(0xFF333333),
                width: 1,
              ),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Complete-but-unverified: some fields were flagged Unknown, so
              // the record can be registered but still needs the audiologist.
              if (isComplete && unknownCount > 0) ...[
                Row(
                  children: [
                    Icon(
                      Icons.flag_outlined,
                      size: 14,
                      color: AppColors.warning.withValues(alpha: 0.9),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '$unknownCount field${unknownCount == 1 ? '' : 's'} '
                        'flagged for audiologist',
                        style: AppTypography.monoStatus.copyWith(
                          color: AppColors.warning.withValues(alpha: 0.9),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
              ],
              Row(
                children: [
                  // Scan Another (always available)
                  Expanded(
                    child: OutlinedButton(
                      onPressed: onScanAnother,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF888888),
                        side: const BorderSide(color: Color(0xFF444444)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: Text(
                        'Scan Another',
                        style: AppTypography.monoButton,
                      ),
                    ),
                  ),

                  const SizedBox(width: 12),

                  // Add to Register (enabled when complete)
                  Expanded(
                    flex: 2,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      decoration: isComplete
                          ? BoxDecoration(
                              borderRadius: BorderRadius.circular(10),
                              boxShadow: [
                                BoxShadow(
                                  color: AppColors.success.withValues(
                                    alpha: 0.3 * glow,
                                  ),
                                  blurRadius: 12,
                                ),
                              ],
                            )
                          : null,
                      child: FilledButton.icon(
                        onPressed: isComplete ? onConfirm : null,
                        icon: Icon(
                          isComplete ? Icons.check_circle : Icons.pending,
                          size: 18,
                        ),
                        label: Text(
                          isComplete
                              ? 'Add to Register'
                              : 'Complete All Fields',
                          style: AppTypography.monoValue,
                        ),
                        style: FilledButton.styleFrom(
                          backgroundColor: isComplete
                              ? AppColors.success
                              : const Color(0xFF333333),
                          foregroundColor: isComplete
                              ? Colors.white
                              : const Color(0xFF666666),
                          disabledBackgroundColor: const Color(0xFF333333),
                          disabledForegroundColor: const Color(0xFF666666),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// Shared primitives
// ═══════════════════════════════════════════════════════════════════════════

const _amberColor = Color(0xFFD4A026);
const _greenColor = AppColors.success;

/// Container for each field row — handles the left accent bar and pulse.
class _FieldContainer extends StatelessWidget {
  const _FieldContainer({
    required this.hasFill,
    required this.pulseController,
    required this.child,
  });

  final bool hasFill;
  final AnimationController pulseController;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: pulseController,
      builder: (context, child) {
        final pulseAlpha = hasFill ? 0.0 : 0.15 + 0.15 * pulseController.value;
        final accentColor = hasFill
            ? _greenColor.withValues(alpha: 0.6)
            : _amberColor.withValues(alpha: pulseAlpha + 0.2);
        final bgColor = hasFill
            ? const Color(0xFF151515)
            : Color.lerp(
                const Color(0xFF151515),
                _amberColor.withValues(alpha: 0.05),
                pulseController.value,
              )!;

        // Use a Row with a coloured strip instead of Border(left:) + borderRadius,
        // which Flutter doesn't officially support together.
        // IntrinsicHeight is required: ListView gives children unbounded
        // height, and a stretch-Row under unbounded height forces the strip
        // to h=Infinity — a layout exception that blanked the entire field
        // list (the black "4 OF 7" screen in issue #70).
        return Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Container(
              color: bgColor,
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(width: 3, color: accentColor),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: child!,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
      child: child,
    );
  }
}

/// Monospace field label.
class _FieldLabel extends StatelessWidget {
  const _FieldLabel({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 72,
      child: Text(label, style: AppTypography.monoLabel),
    );
  }
}

/// Confidence badge — green/amber/red based on percentage.
class _ConfidenceBadge extends StatelessWidget {
  const _ConfidenceBadge({required this.confidence});
  final int confidence;

  @override
  Widget build(BuildContext context) {
    final color = confidence >= 90
        ? _greenColor
        : confidence >= 70
        ? _amberColor
        : AppColors.error;
    final label = confidence >= 90
        ? 'HIGH'
        : confidence >= 70
        ? 'MED'
        : 'LOW';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(3),
        color: color.withValues(alpha: 0.15),
      ),
      child: Text(
        '$label $confidence%',
        style: AppTypography.monoSmall.copyWith(
          color: color.withValues(alpha: 0.9),
        ),
      ),
    );
  }
}

/// Small icon button used for edit/add/confirm actions.
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          color: color.withValues(alpha: 0.1),
        ),
        child: Icon(icon, size: 16, color: color),
      ),
    );
  }
}

TextStyle _valueStyle(bool hasFill) => AppTypography.monoValueLarge.copyWith(
  fontWeight: hasFill ? FontWeight.w600 : FontWeight.w400,
  color: hasFill ? Colors.white : const Color(0xFF555555),
);
