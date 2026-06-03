import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/rs_card.dart';

/// Settings screen — the app's primary settings list.
///
/// Currently surfaces a single **Device Info** entry (on-device telemetry
/// transparency). Designed as a growable list so future settings (account,
/// notifications, about) slot in as additional tiles.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SettingsTile(
                icon: Icons.smartphone,
                title: 'Device Info',
                subtitle: 'What the app knows about your device',
                onTap: () => context.push('/settings/device-info'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  const _SettingsTile({
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
