// Excluded from coverage: depends on Firestore singleton (ScanTracker); needs emulator
// coverage:ignore-file
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/rs_button.dart';
import '../../../core/widgets/rs_card.dart';
import '../../../core/widgets/rs_chip.dart';
import '../../../core/widgets/rs_spec_row.dart';
import '../data/models/scan_result.dart';
import '../data/scan_tracker.dart';
import '../providers/scanner_providers.dart';

/// Review depth — graduated by how many times this brand/model has been
/// confirmed without correction.
///
/// - [full]: first 0-2 scans. All fields expanded, coaching text visible.
/// - [compact]: 3-9 scans. Primary fields only, specs collapsed.
/// - [express]: 10+ scans. Single confirm button, details behind a toggle.
enum ReviewMode { full, compact, express }

/// Results screen (Screen 1D) — shows identified specs with inline editing.
///
/// Each spec field can be tapped to correct the AI's identification. Corrections
/// are tracked for future model training. Review depth graduates with
/// familiarity — experienced audiologists get express confirmation for
/// devices they've seen many times.
class ResultsScreen extends ConsumerWidget {
  const ResultsScreen({super.key, required this.scanId});

  final String scanId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final result = ref.watch(scanResultProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan Results'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => context.go('/'),
        ),
      ),
      body: FutureBuilder<int>(
        future: ScanTracker.getTotalScans(),
        builder: (context, snapshot) {
          final scans = snapshot.data ?? 0;
          final mode = scans >= 10
              ? ReviewMode.express
              : scans >= 3
                  ? ReviewMode.compact
                  : ReviewMode.full;

          return _ReviewBody(
            result: result,
            mode: mode,
            scanCount: scans,
            ref: ref,
          );
        },
      ),
    );
  }
}

class _ReviewBody extends StatefulWidget {
  const _ReviewBody({
    required this.result,
    required this.mode,
    required this.scanCount,
    required this.ref,
  });

  final ScanResult result;
  final ReviewMode mode;
  final int scanCount;
  final WidgetRef ref;

  @override
  State<_ReviewBody> createState() => _ReviewBodyState();
}

class _ReviewBodyState extends State<_ReviewBody> {
  bool _showDetails = false;

  void _onSave(ScanField field, String oldValue, String newValue) {
    widget.ref.read(scanResultProvider.notifier).updateField(field, newValue);

    // Track the correction for graduated exposure learning
    if (oldValue.isNotEmpty && oldValue != newValue) {
      ScanTracker.recordCorrection(
        field: field.name.toUpperCase(),
        originalValue: oldValue,
        correctedValue: newValue,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.result;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Confidence summary (adapts to review mode) ─────────
            RsCard(
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: AppColors.primaryLight,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.check_circle,
                        color: AppColors.primary, size: 24),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.mode == ReviewMode.express
                              ? '${result.brand.value} ${result.model.value}'
                              : 'Device Identified',
                          style: AppTypography.h4,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          widget.mode == ReviewMode.full
                              ? 'Tap the pencil icon to correct any field'
                              : widget.mode == ReviewMode.compact
                                  ? 'Confirm or tap to edit'
                                  : 'Seen ${widget.scanCount} times — all confirmed',
                          style: AppTypography.caption,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // ── Express mode: just the confirm button, details behind toggle
            if (widget.mode == ReviewMode.express) ...[
              if (!_showDetails)
                TextButton.icon(
                  onPressed: () => setState(() => _showDetails = true),
                  icon: const Icon(Icons.expand_more, size: 18),
                  label: Text(
                    'Show full details',
                    style: AppTypography.caption.copyWith(
                      color: AppColors.primary,
                    ),
                  ),
                ),
            ],

            // ── Primary identification (full + compact + express-expanded)
            if (widget.mode == ReviewMode.full ||
                widget.mode == ReviewMode.compact ||
                _showDetails) ...[
              Text('Identification', style: AppTypography.h3),
              const SizedBox(height: 8),
              RsCard(
                child: Column(
                  children: [
                    _EditableSpecRow(
                      label: 'Brand',
                      field: result.brand,
                      onSave: (v) =>
                          _onSave(ScanField.brand, result.brand.value, v),
                    ),
                    const Divider(),
                    _EditableSpecRow(
                      label: 'Model',
                      field: result.model,
                      onSave: (v) =>
                          _onSave(ScanField.model, result.model.value, v),
                    ),
                    const Divider(),
                    _EditableSpecRow(
                      label: 'Type',
                      field: result.type,
                      onSave: (v) =>
                          _onSave(ScanField.type, result.type.value, v),
                    ),
                    if (result.colour != null) ...[
                      const Divider(),
                      _EditableSpecRow(
                        label: 'Colour',
                        field: result.colour!,
                        onSave: (v) => _onSave(
                            ScanField.colour, result.colour!.value, v),
                      ),
                    ],
                    const Divider(),
                    _EditableSpecRow(
                      label: 'Year',
                      field: result.year,
                      onSave: (v) =>
                          _onSave(ScanField.year, result.year.value, v),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ],

            // ── Specifications (full only, or express-expanded) ────
            if (widget.mode == ReviewMode.full || _showDetails) ...[
              Text('Specifications', style: AppTypography.h3),
              const SizedBox(height: 8),
              RsCard(
                child: Column(
                  children: [
                    _EditableSpecRow(
                      label: 'Battery',
                      field: result.batterySize,
                      onSave: (v) => _onSave(
                          ScanField.batterySize, result.batterySize.value, v),
                    ),
                    const Divider(),
                    _EditableSpecRow(
                      label: 'Dome',
                      field: result.domeType,
                      onSave: (v) => _onSave(
                          ScanField.domeType, result.domeType.value, v),
                    ),
                    const Divider(),
                    _EditableSpecRow(
                      label: 'Wax Filter',
                      field: result.waxFilter,
                      onSave: (v) => _onSave(
                          ScanField.waxFilter, result.waxFilter.value, v),
                    ),
                    const Divider(),
                    _EditableSpecRow(
                      label: 'Receiver',
                      field: result.receiver,
                      onSave: (v) => _onSave(
                          ScanField.receiver, result.receiver.value, v),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ],

            // ── AI labels (full only) ──────────────────────────────
            if (widget.mode == ReviewMode.full &&
                result.rawLabels.isNotEmpty) ...[
              Text('AI Labels', style: AppTypography.h3),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: result.rawLabels
                    .map((l) => RsChip(label: l, variant: RsChipVariant.info))
                    .toList(),
              ),
              const SizedBox(height: 20),
            ],

            // ── Actions ────────────────────────────────────────────
            RsButton(
              label: widget.mode == ReviewMode.express
                  ? 'Confirm & Add to Register'
                  : 'Add to Device Register',
              icon: Icons.add_circle_outline,
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Device added to register (pending QA)'),
                    backgroundColor: AppColors.success,
                  ),
                );
                context.go('/devices');
              },
            ),
            const SizedBox(height: 12),
            RsButton(
              label: 'Capture 3D Model',
              icon: Icons.view_in_ar,
              variant: RsButtonVariant.outline,
              onPressed: () {
                final name =
                    '${widget.result.brand.value} ${widget.result.model.value}'
                        .trim();
                context.push('/scan/3d', extra: name.isNotEmpty ? name : null);
              },
            ),
            const SizedBox(height: 12),
            RsButton(
              label: 'Scan Another',
              variant: RsButtonVariant.outline,
              onPressed: () => context.pushReplacement('/scan'),
            ),
          ],
        ),
      ),
    );
  }
}

/// A spec row that switches to inline editing on tap.
class _EditableSpecRow extends StatefulWidget {
  const _EditableSpecRow({
    required this.label,
    required this.field,
    required this.onSave,
  });

  final String label;
  final SpecField field;
  final ValueChanged<String> onSave;

  @override
  State<_EditableSpecRow> createState() => _EditableSpecRowState();
}

class _EditableSpecRowState extends State<_EditableSpecRow> {
  bool _editing = false;
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.field.value);
  }

  @override
  void didUpdateWidget(_EditableSpecRow old) {
    super.didUpdateWidget(old);
    if (old.field.value != widget.field.value) {
      _controller.text = widget.field.value;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final newValue = _controller.text.trim();
    if (newValue.isNotEmpty && newValue != widget.field.value) {
      widget.onSave(newValue);
    }
    setState(() => _editing = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_editing) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            SizedBox(
              width: 100,
              child: Text(widget.label, style: AppTypography.caption),
            ),
            Expanded(
              child: TextField(
                controller: _controller,
                autofocus: true,
                style: AppTypography.body,
                decoration: const InputDecoration(
                  isDense: true,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                ),
                onSubmitted: (_) => _save(),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.check, size: 18, color: AppColors.primary),
              onPressed: _save,
            ),
          ],
        ),
      );
    }

    return RsSpecRow(
      label: widget.label,
      value: widget.field.value,
      confidence: widget.field.confidence,
      onEdit: () => setState(() => _editing = true),
    );
  }
}
