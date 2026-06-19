import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/rs_button.dart';
import '../../../core/widgets/rs_card.dart';
import '../../capture/providers/capture_seed.dart';

/// Home screen (Screen 1A) — hero CTA + stats overview.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  /// Box-first entry: the box number is the FIRST thing a volunteer enters,
  /// before any camera opens. Both home CTAs route through this modal — on OK we
  /// stash the box in [scanBoxProvider] and navigate; on Cancel we do nothing.
  ///
  /// The dialog is explicitly dark-themed (not a default light AlertDialog):
  /// the app's text theme paints body text white, so a default light dialog
  /// renders white-on-white — invisible. Mirror the capture-dialog fix.
  Future<void> _startWithBox(
    BuildContext context,
    WidgetRef ref,
    String destination,
  ) async {
    final box = await showDialog<String>(
      context: context,
      builder: (context) => const _BoxEntryDialog(),
    );
    // Null = Cancel (or dismissed): do not navigate, do not touch the provider.
    if (box == null) return;
    ref.read(scanBoxProvider.notifier).state = box.trim().toUpperCase();
    if (!context.mounted) return;
    if (destination == '/scan') {
      context.go(destination);
    } else {
      context.push(destination);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recycled Sound'),
        actions: [
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Hero card ────────────────────────────────────────────
              RsCard(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        color: AppColors.primaryLight,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Icon(
                        Icons.center_focus_strong,
                        size: 36,
                        color: AppColors.primary,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text('Add a Hearing Aid', style: AppTypography.h2),
                    const SizedBox(height: 8),
                    Text(
                      'Two ways to add a donated hearing aid — pick the one that fits.',
                      style: AppTypography.body.copyWith(
                        color: AppColors.textMuted,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    // ── Scan mode ────────────────────────────────────────
                    // Sets the expectation up front: the scanner *tries* to
                    // read the device live, and a partial / blank result is
                    // normal because the model is still learning. Without this,
                    // an inconsistent field read looks like a bug to a
                    // volunteer (Delia's build-9 feedback).
                    RsButton(
                      label: 'Scan to identify',
                      icon: Icons.center_focus_strong,
                      onPressed: () => _startWithBox(context, ref, '/scan'),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Point the camera and the app tries to read the brand, '
                      'model and specs on the spot. It is still learning, so '
                      'some scans fill every field and others only the brand — '
                      'that is expected, not a fault.',
                      style: AppTypography.caption.copyWith(
                        color: AppColors.textMuted,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    // ── Capture mode ─────────────────────────────────────
                    // The complement: no live ID at all, just a guided set of
                    // photos saved for an audiologist to read later. Naming the
                    // absence of identification stops "couldn't even get the
                    // info, unlike scanning" from reading as a failure.
                    RsButton(
                      label: 'Capture photos for later',
                      icon: Icons.photo_camera_outlined,
                      variant: RsButtonVariant.outline,
                      onPressed: () => _startWithBox(context, ref, '/capture'),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'A step-by-step photo guide. It does not identify the '
                      'device — it just saves a clear set of photos for an '
                      'audiologist to review later. Use this when scanning is '
                      'hard or you just want a good photo record.',
                      style: AppTypography.caption.copyWith(
                        color: AppColors.textMuted,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),

              // ── Stats ────────────────────────────────────────────────
              Text('Impact', style: AppTypography.h3),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _StatCard(value: '20', label: 'Devices collected'),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _StatCard(value: '8', label: 'Brands on register'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _StatCard(value: '0', label: 'Devices matched'),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _StatCard(value: '0', label: 'Active recipients'),
                  ),
                ],
              ),

              const SizedBox(height: 24),

              // ── Quick actions ────────────────────────────────────────
              Text('Quick Actions', style: AppTypography.h3),
              const SizedBox(height: 12),
              _ActionTile(
                icon: Icons.list_alt,
                title: 'Device Register',
                subtitle: 'View all collected hearing aids',
                onTap: () => context.go('/devices'),
              ),
              const SizedBox(height: 8),
              _ActionTile(
                icon: Icons.assignment_turned_in,
                title: '7-Field Confirmation',
                subtitle: 'Preview with mock scan data',
                onTap: () => context.go('/scan/confirm'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Box-first entry dialog: the volunteer enters the box number before any
/// camera opens. Pops the entered text on OK, `null` on Cancel.
///
/// A `StatefulWidget` so it owns its `TextEditingController` and disposes it in
/// `State.dispose` (which runs after the route is fully gone), avoiding the
/// use-after-dispose that disposing right after `await showDialog` causes
/// during the exit animation.
///
/// Explicitly dark-styled (dark background, white text, visible field borders):
/// the app theme paints body text white, so a default light AlertDialog renders
/// white-on-white. Every text surface here sets an explicit colour.
class _BoxEntryDialog extends StatefulWidget {
  const _BoxEntryDialog();

  @override
  State<_BoxEntryDialog> createState() => _BoxEntryDialogState();
}

class _BoxEntryDialogState extends State<_BoxEntryDialog> {
  final TextEditingController _box = TextEditingController();

  @override
  void dispose() {
    _box.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const white = Colors.white;
    const muted = Color(0xFF888888);
    return AlertDialog(
      backgroundColor: const Color(0xFF1A1A1A),
      titleTextStyle: AppTypography.h3.copyWith(color: white),
      contentTextStyle: AppTypography.body.copyWith(color: white),
      title: const Text('Box number'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Enter the number on the box before you start.',
            style: AppTypography.caption.copyWith(color: muted),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _box,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            style: const TextStyle(color: white),
            cursorColor: AppColors.primary,
            // Enter from the keyboard confirms — but only with a non-empty box,
            // matching the disabled-when-empty OK button (the box is required).
            onSubmitted: (v) {
              if (v.trim().isNotEmpty) Navigator.of(context).pop(v);
            },
            decoration: const InputDecoration(
              // Override the app's light InputDecorationTheme (filled white) —
              // this field lives in a dark dialog, so a white fill would render
              // the white input text invisible (white-on-white). Dark fill keeps
              // it legible and consistent with the scanner/confirm dark surface.
              filled: true,
              fillColor: Color(0xFF222222),
              labelText: 'Box number',
              labelStyle: TextStyle(color: muted),
              hintText: 'e.g. B07, C10',
              hintStyle: TextStyle(color: Color(0xFF555555)),
              helperText: 'The label on the box',
              helperStyle: TextStyle(color: muted),
              enabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: Color(0xFF444444)),
              ),
              focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: AppColors.primary),
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel', style: TextStyle(color: muted)),
        ),
        // OK is disabled until a box number is entered — the box is required,
        // so enforce it here at the single entry point rather than letting an
        // empty box flow through to a dead-end block at capture-save.
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _box,
          builder: (context, value, _) {
            final hasText = value.text.trim().isNotEmpty;
            return TextButton(
              onPressed: hasText
                  ? () => Navigator.of(context).pop(_box.text)
                  : null,
              child: Text(
                'OK',
                style: TextStyle(
                  color: hasText ? AppColors.primary : muted,
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return RsCard(
      child: Column(
        children: [
          Text(
            value,
            style: AppTypography.h1.copyWith(color: AppColors.primary),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: AppTypography.caption,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return RsCard(
      padding: EdgeInsets.zero,
      child: ListTile(
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: AppColors.primaryLight,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: AppColors.primary, size: 20),
        ),
        title: Text(title, style: AppTypography.h4),
        subtitle: Text(subtitle, style: AppTypography.caption),
        trailing: const Icon(Icons.chevron_right, color: AppColors.textMuted),
        onTap: onTap,
      ),
    );
  }
}
