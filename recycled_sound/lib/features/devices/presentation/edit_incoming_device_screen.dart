import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/rs_button.dart';
import '../../../core/widgets/rs_card.dart';
import '../data/incoming_device_repository.dart';
import '../data/models/device.dart';
import '../providers/device_providers.dart';

/// Edit a pending `incoming/{id}` capture — the volunteer fixing what the
/// scanner or capture flow got wrong on their own device.
///
/// Scope is deliberately the OWNER-editable identity fields (brand, model,
/// style, battery size). The clinical/triage fields (tubing, power, colour, QA)
/// are the audiologist's call and are NOT editable here — the Firestore rules
/// enforce that (`creatorEditableFields()`), and this form never changes them:
/// it passes their CURRENT values straight back through [updateIncoming], so
/// the rule's `diff().affectedKeys()` only ever sees the allow-listed fields.
class EditIncomingDeviceScreen extends ConsumerWidget {
  const EditIncomingDeviceScreen({super.key, required this.deviceId});

  final String deviceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(incomingDeviceByIdProvider(deviceId));
    return Scaffold(
      appBar: AppBar(title: const Text('Edit device')),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Failed to load: $e')),
        data: (device) => device == null
            ? const Center(child: Text('Device not found.'))
            : _EditForm(device: device),
      ),
    );
  }
}

class _EditForm extends ConsumerStatefulWidget {
  const _EditForm({required this.device});

  final Device device;

  @override
  ConsumerState<_EditForm> createState() => _EditFormState();
}

class _EditFormState extends ConsumerState<_EditForm> {
  late final TextEditingController _brand;
  late final TextEditingController _model;
  late Style _type;
  late BatterySize _batterySize;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    // Seed once from the loaded device; the form owns edits from here.
    _brand = TextEditingController(text: widget.device.brand);
    _model = TextEditingController(text: widget.device.model);
    _type = widget.device.type;
    _batterySize = widget.device.batterySize;
  }

  @override
  void dispose() {
    _brand.dispose();
    _model.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final device = widget.device;
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    try {
      await ref.read(incomingDeviceRepositoryProvider).updateIncoming(
            device.id,
            // Owner-editable fields — the only ones this form changes.
            brand: _brand.text.trim(),
            model: _model.text.trim(),
            type: _type,
            batterySize: _batterySize,
            // Passed through UNCHANGED so the owner rule's delta-check never
            // sees a non-allow-listed field as "affected".
            tubing: device.tubing,
            powerSource: device.powerSource,
            colour: device.colour,
            location: device.location,
            servicingNotes: device.servicingNotes,
            servicingCost: device.servicingCost,
          );
      if (router.canPop()) {
        router.pop();
      } else {
        router.go('/devices/${device.id}');
      }
    } on FirebaseException catch (e) {
      if (mounted) setState(() => _saving = false);
      messenger.showSnackBar(
        SnackBar(
          content: Text(PersistErrorKind.fromCode(e.code).userMessage),
          backgroundColor: AppColors.error,
        ),
      );
    } catch (_) {
      if (mounted) setState(() => _saving = false);
      messenger.showSnackBar(
        SnackBar(
          content: Text(PersistErrorKind.unknown.userMessage),
          backgroundColor: AppColors.error,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Fix the brand, model, style or battery for this device. '
              'Clinical fields (tubing, power, colour, QA) are set by an '
              'audiologist and cannot be changed here.',
              style: AppTypography.caption.copyWith(
                color: AppColors.textMuted,
              ),
            ),
            const SizedBox(height: 16),
            RsCard(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _label('Brand'),
                  TextField(
                    controller: _brand,
                    textCapitalization: TextCapitalization.words,
                    decoration: _dec('e.g. Phonak'),
                  ),
                  const SizedBox(height: 16),
                  _label('Model'),
                  TextField(
                    controller: _model,
                    textCapitalization: TextCapitalization.words,
                    decoration: _dec('e.g. Audéo P90'),
                  ),
                  const SizedBox(height: 16),
                  _label('Style'),
                  DropdownButtonFormField<Style>(
                    initialValue: _type,
                    decoration: _dec(null),
                    items: [
                      for (final s in Style.values)
                        DropdownMenuItem(value: s, child: Text(s.label)),
                    ],
                    onChanged: (v) => setState(() => _type = v ?? _type),
                  ),
                  const SizedBox(height: 16),
                  _label('Battery'),
                  DropdownButtonFormField<BatterySize>(
                    initialValue: _batterySize,
                    decoration: _dec(null),
                    items: [
                      for (final b in BatterySize.values)
                        DropdownMenuItem(value: b, child: Text(b.label)),
                    ],
                    onChanged: (v) =>
                        setState(() => _batterySize = v ?? _batterySize),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            RsButton(
              label: 'Save changes',
              icon: Icons.check,
              isLoading: _saving,
              onPressed: _saving ? null : _save,
            ),
            const SizedBox(height: 8),
            RsButton(
              label: 'Cancel',
              variant: RsButtonVariant.ghost,
              onPressed: _saving
                  ? null
                  : () => context.canPop()
                      ? context.pop()
                      : context.go('/devices/${widget.device.id}'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text, style: AppTypography.label),
      );

  InputDecoration _dec(String? hint) => InputDecoration(
        hintText: hint,
        isDense: true,
        border: const OutlineInputBorder(),
      );
}
