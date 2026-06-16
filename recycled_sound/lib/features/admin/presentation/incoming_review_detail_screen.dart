import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/rs_card.dart';
import '../../../core/widgets/rs_chip.dart';
import '../../../core/widgets/rs_spec_row.dart';
import '../../devices/data/models/device.dart';
import '../../devices/presentation/widgets/storage_image.dart';
import '../../devices/providers/device_providers.dart';

/// Audiologist review surface (Wireframe Flow 2, "Review Detail").
///
/// Streams a single `incoming/{id}` doc, shows the scanner-read identity
/// read-only, lets the audiologist resolve the human-determined clinical
/// fields the volunteer flagged, then Pass (persist edits → promote into
/// `devices/`) or Fail (mark `qaStatus=failed`, leave in the queue).
///
/// Reached only via `context.go('/incoming/:id/review')` from the queue —
/// `go()`-everywhere on admin routes (project law); a `push()`ed copy of a
/// streaming screen never disposes its provider subscription.
class IncomingReviewDetailScreen extends ConsumerWidget {
  const IncomingReviewDetailScreen({super.key, required this.deviceId});

  final String deviceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(incomingDeviceByIdProvider(deviceId));

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Back to queue',
          onPressed: () => context.go('/incoming'),
        ),
        title: const Text('Review device'),
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _ReviewError(error: e),
        data: (device) {
          if (device == null) {
            return const Center(
              child: Text('Device not found — it may have been promoted.'),
            );
          }
          // Keyed on the doc id so the editable form re-initialises only when a
          // genuinely different device loads, not on every stream tick (which
          // would stomp the audiologist's in-progress edits).
          return _ReviewBody(key: ValueKey(device.id), device: device);
        },
      ),
    );
  }
}

/// Permission-denied (or any stream failure) lock pane — mirrors the queue's
/// data-layer gate so a non-audiologist sees a graceful message, not a crash.
class _ReviewError extends StatelessWidget {
  const _ReviewError({required this.error});
  final Object error;

  @override
  Widget build(BuildContext context) {
    final isPermission = error.toString().contains('permission-denied');
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline, size: 48, color: AppColors.textMuted),
            const SizedBox(height: 12),
            Text(
              isPermission
                  ? 'You need an audiologist or admin role to review devices.'
                  : 'Failed to load device:\n$error',
              style: AppTypography.body,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _ReviewBody extends ConsumerStatefulWidget {
  const _ReviewBody({super.key, required this.device});
  final Device device;

  @override
  ConsumerState<_ReviewBody> createState() => _ReviewBodyState();
}

class _ReviewBodyState extends ConsumerState<_ReviewBody> {
  late Tubing _tubing;
  late PowerSource _powerSource;
  late final TextEditingController _colour;
  late final TextEditingController _location;
  late final TextEditingController _servicingNotes;
  late final TextEditingController _servicingCost;

  /// Latched at QA-action tap time, before the first await, so a double-tap
  /// can't fire two promotes/fails against the same doc.
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final d = widget.device;
    _tubing = d.tubing;
    _powerSource = d.powerSource;
    _colour = TextEditingController(text: d.colour);
    _location = TextEditingController(text: d.location);
    _servicingNotes = TextEditingController(text: d.servicingNotes);
    _servicingCost = TextEditingController(
      text: d.servicingCost == 0 ? '' : d.servicingCost.toString(),
    );
  }

  @override
  void dispose() {
    _colour.dispose();
    _location.dispose();
    _servicingNotes.dispose();
    _servicingCost.dispose();
    super.dispose();
  }

  /// Which flagged keys are still unresolved, given the *current* edit state
  /// (not just the persisted doc) — so the amber banner shrinks live as the
  /// audiologist fills fields in. A key counts resolved once its field holds a
  /// non-empty / non-`unspecified` value.
  Set<ClinicalField> get _unresolved {
    // Only the three human-determined fields editable ON THIS SCREEN can be
    // resolved here. The identity fields (brand/model/type/batterySize) are
    // read-only scanner output on this surface, so they resolve to `false` and
    // a flag on them STAYS VISIBLE in the banner — the audiologist sees it and
    // resolves it elsewhere / by overriding, rather than it being silently
    // treated as done. The typed switch is exhaustive: a future [ClinicalField]
    // forces a compile error here until its resolution rule is decided (#777).
    bool resolved(ClinicalField f) => switch (f) {
          ClinicalField.tubing => _tubing != Tubing.unspecified,
          ClinicalField.powerSource => _powerSource != PowerSource.unspecified,
          ClinicalField.colour => _colour.text.trim().isNotEmpty,
          ClinicalField.brand ||
          ClinicalField.model ||
          ClinicalField.type ||
          ClinicalField.batterySize =>
            false,
        };
    return widget.device.needsInputFields
        .where((k) => !resolved(k))
        .toSet();
  }

  double get _parsedCost {
    final t = _servicingCost.text.trim();
    if (t.isEmpty) return 0;
    // The formatter permits a trailing '.' mid-typing ("5."), which
    // double.tryParse rejects → would silently save 0. Drop it so a value
    // left as "5." persists 5.0, not 0.
    final normalised = t.endsWith('.') ? t.substring(0, t.length - 1) : t;
    return double.tryParse(normalised) ?? 0;
  }

  /// Persist the audiologist's edits onto the incoming doc. Shared by Pass
  /// (before promote) and Fail (with the failed flag).
  Future<void> _persist({QaStatus? qaStatus}) {
    final repo = ref.read(incomingDeviceRepositoryProvider);
    return repo.updateIncoming(
      widget.device.id,
      tubing: _tubing,
      powerSource: _powerSource,
      colour: _colour.text.trim(),
      location: _location.text.trim(),
      servicingNotes: _servicingNotes.text.trim(),
      servicingCost: _parsedCost,
      qaStatus: qaStatus,
    );
  }

  /// Pass QA is deliberately NOT hard-gated on `_unresolved.isEmpty`. The
  /// audiologist is the final human-in-the-loop authority, and the identity
  /// flags (`brand`/`model`/`type`/`batterySize`) can't be resolved on this
  /// screen — gating on them would deadlock those devices. The real
  /// enforcement boundary is in the queue: a flagged device can no longer be
  /// promoted via the silent quick-Approve bypass, so it MUST route through
  /// this screen, where Pass is a conscious, banner-informed human action.
  Future<void> _passQa() async {
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    final repo = ref.read(incomingDeviceRepositoryProvider);
    final d = widget.device;
    setState(() => _busy = true);
    try {
      // Persist edits FIRST: promoteToDevice re-reads the doc and copies it
      // into devices/, so the audiologist's corrections must already be on the
      // incoming doc before the batch runs. promoteToDevice flips qaStatus to
      // passed itself, so we don't pass it here.
      await _persist();
      await repo.promoteToDevice(d.id);
      router.go('/incoming');
      messenger.showSnackBar(
        SnackBar(
          content: Text('Passed QA — ${d.brand} ${d.model} added to register.'),
          backgroundColor: AppColors.success,
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      messenger.showSnackBar(
        SnackBar(
          content: Text('Pass failed: $e'),
          backgroundColor: AppColors.error,
        ),
      );
    }
  }

  Future<void> _failQa() async {
    final messenger = ScaffoldMessenger.of(context);
    final d = widget.device;
    setState(() => _busy = true);
    try {
      await _persist(qaStatus: QaStatus.failed);
      // Stays in the queue (incoming/), now flagged failed. No nav — the
      // stream re-emits with the failed chip so the audiologist sees the
      // result in place.
      if (mounted) setState(() => _busy = false);
      messenger.showSnackBar(
        SnackBar(
          content: Text('Marked ${d.brand} ${d.model} as failed QA.'),
          backgroundColor: AppColors.warning,
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      messenger.showSnackBar(
        SnackBar(
          content: Text('Fail update failed: $e'),
          backgroundColor: AppColors.error,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.device;
    final title = '${d.brand} ${d.model}'.trim();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title.isEmpty ? 'Unidentified device' : title,
                      style: AppTypography.h2,
                    ),
                  ),
                  RsChip(
                    label: d.qaStatus.wire.replaceAll('_', ' ').toUpperCase(),
                    variant: switch (d.qaStatus) {
                      QaStatus.passed => RsChipVariant.success,
                      QaStatus.failed => RsChipVariant.error,
                      QaStatus.pendingQa => RsChipVariant.warning,
                    },
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // ── NEEDS INPUT work list ──────────────────────────────
              if (_unresolved.isNotEmpty) ...[
                _NeedsInputBanner(keys: _unresolved),
                const SizedBox(height: 20),
              ] else if (d.needsInputFields.isNotEmpty) ...[
                _AllResolvedBanner(),
                const SizedBox(height: 20),
              ],

              // ── Photos ─────────────────────────────────────────────
              if (d.photos.isNotEmpty) ...[
                Text('Photos', style: AppTypography.h3),
                const SizedBox(height: 8),
                _PhotoGallery(photos: d.photos),
                const SizedBox(height: 20),
              ],

              // ── Identification (read-only, scanner-owned) ──────────
              Text('Identification', style: AppTypography.h3),
              const SizedBox(height: 8),
              RsCard(
                child: Column(
                  children: [
                    RsSpecRow(label: 'Brand', value: d.brand),
                    RsSpecRow(label: 'Model', value: d.model),
                    RsSpecRow(label: 'Type', value: d.type),
                    RsSpecRow(label: 'Year', value: d.year),
                    RsSpecRow(label: 'Battery', value: d.batterySize),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // ── Editable clinical review ───────────────────────────
              Text('Audiologist review', style: AppTypography.h3),
              const SizedBox(height: 8),
              RsCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _FieldLabel('Tubing',
                        flagged: _isFlagged(ClinicalField.tubing)),
                    _TubingPicker(
                      value: _tubing,
                      onChanged: _busy
                          ? null
                          : (v) => setState(() => _tubing = v),
                    ),
                    const SizedBox(height: 16),
                    _FieldLabel('Power',
                        flagged: _isFlagged(ClinicalField.powerSource)),
                    _PowerSourcePicker(
                      value: _powerSource,
                      onChanged: _busy
                          ? null
                          : (v) => setState(() => _powerSource = v),
                    ),
                    const SizedBox(height: 16),
                    _FieldLabel('Colour',
                        flagged: _isFlagged(ClinicalField.colour)),
                    TextField(
                      controller: _colour,
                      enabled: !_busy,
                      decoration: const InputDecoration(
                        hintText: 'e.g. Charcoal, Beige',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 16),
                    // Location is free-text metadata, never one of the 7
                    // clinical fields — so it can never appear in
                    // needsInputFields and is never flagged.
                    const _FieldLabel('Location'),
                    TextField(
                      controller: _location,
                      enabled: !_busy,
                      decoration: const InputDecoration(
                        hintText: 'e.g. B07',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 16),
                    const _FieldLabel('Servicing notes'),
                    TextField(
                      controller: _servicingNotes,
                      enabled: !_busy,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        hintText: 'Cleaning, re-tubing, repairs needed…',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const _FieldLabel('Servicing cost (AUD)'),
                    TextField(
                      controller: _servicingCost,
                      enabled: !_busy,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      // A single-decimal money formatter: the old per-char
                      // `[0-9.]` allow-filter let `1.2.3` through, which
                      // `double.tryParse` silently collapsed to 0 — quiet data
                      // loss on a cost field. This constrains the WHOLE string
                      // to `digits . up-to-2-digits`, so a second `.` is
                      // rejected at keystroke time and the parse can't fail.
                      inputFormatters: const [_CurrencyInputFormatter()],
                      decoration: const InputDecoration(
                        prefixText: r'$ ',
                        hintText: '0.00',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // ── QA actions ─────────────────────────────────────────
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _failQa,
                      icon: const Icon(Icons.close),
                      label: const Text('Fail QA'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.error,
                        side: const BorderSide(color: AppColors.error),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _busy ? null : _passQa,
                      icon: _busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.check),
                      label: Text(_busy ? 'Working…' : 'Pass QA'),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.success,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool _isFlagged(ClinicalField field) =>
      widget.device.needsInputFields.contains(field);
}

/// Amber work-list banner — the fields the volunteer flagged for the
/// audiologist to resolve, shrinking live as each is filled.
class _NeedsInputBanner extends StatelessWidget {
  const _NeedsInputBanner({required this.keys});
  final Set<ClinicalField> keys;

  @override
  Widget build(BuildContext context) {
    // Labels come straight off [ClinicalField.label] — the single source of
    // truth. The old hand-rolled key→label map (which once drifted to invented
    // keys 'make'/'style'/'battery' on PR #85) is gone: the type IS the map.
    final names = keys.map((k) => k.label).toSet().toList()..sort();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.flag_outlined,
                  size: 18, color: AppColors.warning),
              const SizedBox(width: 8),
              Text(
                'Needs your input (${names.length})',
                style: AppTypography.label.copyWith(color: AppColors.warning),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'The volunteer flagged these fields for you to determine: '
            '${names.join(', ')}.',
            style: AppTypography.body,
          ),
        ],
      ),
    );
  }
}

/// Shown once every flagged field is resolved — confirms the work list is clear.
class _AllResolvedBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.success.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.success.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.check_circle_outline,
              size: 18, color: AppColors.success),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'All flagged fields resolved — ready to pass QA.',
              style: AppTypography.body,
            ),
          ),
        ],
      ),
    );
  }
}

/// A field label with an optional amber "flagged" dot for needs-input fields.
class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text, {this.flagged = false});
  final String text;
  final bool flagged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Text(text, style: AppTypography.label),
          if (flagged) ...[
            const SizedBox(width: 6),
            const Icon(Icons.flag, size: 14, color: AppColors.warning),
          ],
        ],
      ),
    );
  }
}

/// Constrains a text field to a well-formed decimal amount — at least one
/// digit, an optional single `.`, and at most two fractional digits. Rejects
/// any edit that would produce a malformed string (a second `.`, OR a lone `.`
/// with no digit), so a non-empty value always carries real magnitude and
/// never silently collapses to 0.
class _CurrencyInputFormatter extends TextInputFormatter {
  const _CurrencyInputFormatter();

  // `(?=.*\d)` requires a digit somewhere, so a lone `.` (which
  // double.tryParse rejects → silent 0) can never be entered.
  static final _valid = RegExp(r'^(?=.*\d)\d*\.?\d{0,2}$');

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    // Empty is always allowed (lets the user clear the field).
    if (newValue.text.isEmpty || _valid.hasMatch(newValue.text)) {
      return newValue;
    }
    // Reject the edit — keep the last valid value.
    return oldValue;
  }
}

class _TubingPicker extends StatelessWidget {
  const _TubingPicker({required this.value, required this.onChanged});
  final Tubing value;
  final ValueChanged<Tubing>? onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<Tubing>(
      segments: const [
        ButtonSegment(value: Tubing.unspecified, label: Text('—')),
        ButtonSegment(value: Tubing.slim, label: Text('Slim')),
        ButtonSegment(value: Tubing.standard, label: Text('Standard')),
        ButtonSegment(value: Tubing.none, label: Text('None')),
      ],
      selected: {value},
      onSelectionChanged:
          onChanged == null ? null : (s) => onChanged!(s.first),
      showSelectedIcon: false,
    );
  }
}

class _PowerSourcePicker extends StatelessWidget {
  const _PowerSourcePicker({required this.value, required this.onChanged});
  final PowerSource value;
  final ValueChanged<PowerSource>? onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<PowerSource>(
      segments: const [
        ButtonSegment(value: PowerSource.unspecified, label: Text('—')),
        ButtonSegment(value: PowerSource.battery, label: Text('Battery')),
        ButtonSegment(
            value: PowerSource.rechargeable, label: Text('Rechargeable')),
      ],
      selected: {value},
      onSelectionChanged:
          onChanged == null ? null : (s) => onChanged!(s.first),
      showSelectedIcon: false,
    );
  }
}

/// Horizontal strip of device photo thumbnails (read-only on review).
class _PhotoGallery extends StatelessWidget {
  const _PhotoGallery({required this.photos});
  final List<String> photos;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 96,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: photos.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final ref = photos[i];
          return ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 96,
              height: 96,
              child: StorageImage(photoRef: ref),
            ),
          );
        },
      ),
    );
  }
}
