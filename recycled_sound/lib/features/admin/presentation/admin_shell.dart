import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';

/// Identifies the currently-active admin section so the nav rail highlights
/// the right entry. Sealed via enum so adding a new section is a compile
/// error in every screen until handled.
enum AdminSection { incoming, devices, matching, users }

/// Persistent web admin chrome — sidebar nav on the left, branded app bar
/// on top, scrollable content slot on the right.
class AdminShell extends StatelessWidget {
  const AdminShell({
    super.key,
    required this.currentSection,
    required this.title,
    required this.child,
    this.actions = const [],
  });

  final AdminSection currentSection;
  final String title;
  final Widget child;
  final List<Widget> actions;

  static const _destinations = <(AdminSection, IconData, String, String)>[
    (AdminSection.incoming, Icons.inbox_outlined, 'Incoming', '/incoming'),
    (AdminSection.devices, Icons.devices_outlined, 'Devices', '/devices'),
    (AdminSection.matching, Icons.compare_arrows, 'Matching', '/matching'),
    (AdminSection.users, Icons.people_outline, 'Users', '/users'),
  ];

  @override
  Widget build(BuildContext context) {
    final selectedIndex = _destinations
        .indexWhere((d) => d.$1 == currentSection)
        .clamp(0, _destinations.length - 1);

    return Scaffold(
      body: Row(
        children: [
          // ── Sidebar ───────────────────────────────────────────────
          Container(
            width: 220,
            color: AppColors.primaryLight,
            child: SafeArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
                    child: Row(
                      children: [
                        Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: AppColors.primary,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(Icons.hearing,
                              size: 18, color: Colors.white),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Recycled Sound',
                            style: AppTypography.h4
                                .copyWith(color: AppColors.primary),
                          ),
                        ),
                      ],
                    ),
                  ),
                  for (var i = 0; i < _destinations.length; i++)
                    _NavTile(
                      icon: _destinations[i].$2,
                      label: _destinations[i].$3,
                      selected: i == selectedIndex,
                      onTap: () => context.go(_destinations[i].$4),
                    ),
                  const Spacer(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                    child: Text(
                      'Admin v0.4',
                      style: AppTypography.caption
                          .copyWith(color: AppColors.textMuted),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // ── Main pane ──────────────────────────────────────────────
          Expanded(
            child: Column(
              children: [
                Container(
                  height: 64,
                  decoration: const BoxDecoration(
                    border: Border(
                      bottom:
                          BorderSide(color: AppColors.border, width: 0.5),
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Row(
                    children: [
                      Expanded(child: Text(title, style: AppTypography.h2)),
                      ...actions,
                    ],
                  ),
                ),
                Expanded(child: child),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: selected ? AppColors.primary : Colors.transparent,
              width: 3,
            ),
          ),
          color: selected ? Colors.white : Colors.transparent,
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 18,
              color: selected ? AppColors.primary : AppColors.textMuted,
            ),
            const SizedBox(width: 12),
            Text(
              label,
              style: AppTypography.body.copyWith(
                color: selected ? AppColors.primary : AppColors.textMuted,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
