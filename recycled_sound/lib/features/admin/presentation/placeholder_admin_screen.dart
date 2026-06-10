import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import 'admin_shell.dart';

/// Stub screen for admin sections that haven't shipped yet. Carries the
/// shell + section selection so the sidebar highlights the right entry
/// even when the content is a "coming soon" panel.
class PlaceholderAdminScreen extends StatelessWidget {
  const PlaceholderAdminScreen({
    super.key,
    required this.section,
    required this.title,
    required this.tagline,
  });

  final AdminSection section;
  final String title;
  final String tagline;

  @override
  Widget build(BuildContext context) {
    return AdminShell(
      currentSection: section,
      title: title,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(48),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.construction,
                  size: 56, color: AppColors.textMuted),
              const SizedBox(height: 12),
              Text('Coming soon', style: AppTypography.h3),
              const SizedBox(height: 6),
              SizedBox(
                width: 360,
                child: Text(
                  tagline,
                  textAlign: TextAlign.center,
                  style: AppTypography.caption,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
