import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/rs_button.dart';
import '../../../core/widgets/rs_card.dart';

/// Home screen (Screen 1A) — hero CTA + stats overview.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
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
                      style:
                          AppTypography.body.copyWith(color: AppColors.textMuted),
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
                      onPressed: () => context.go('/scan'),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Point the camera and the app tries to read the brand, '
                      'model and specs on the spot. It is still learning, so '
                      'some scans fill every field and others only the brand — '
                      'that is expected, not a fault.',
                      style: AppTypography.caption
                          .copyWith(color: AppColors.textMuted),
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
                      onPressed: () => context.push('/capture'),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'A step-by-step photo guide. It does not identify the '
                      'device — it just saves a clear set of photos for an '
                      'audiologist to review later. Use this when scanning is '
                      'hard or you just want a good photo record.',
                      style: AppTypography.caption
                          .copyWith(color: AppColors.textMuted),
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
                  Expanded(child: _StatCard(value: '20', label: 'Devices collected')),
                  const SizedBox(width: 12),
                  Expanded(child: _StatCard(value: '8', label: 'Brands on register')),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(child: _StatCard(value: '0', label: 'Devices matched')),
                  const SizedBox(width: 12),
                  Expanded(child: _StatCard(value: '0', label: 'Active recipients')),
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

class _StatCard extends StatelessWidget {
  const _StatCard({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return RsCard(
      child: Column(
        children: [
          Text(value, style: AppTypography.h1.copyWith(color: AppColors.primary)),
          const SizedBox(height: 4),
          Text(label, style: AppTypography.caption, textAlign: TextAlign.center),
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
