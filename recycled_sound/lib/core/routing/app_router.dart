import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../features/home/presentation/home_screen.dart';
import '../../features/scanner/presentation/live_scanner_screen.dart';
import '../../features/scanner/presentation/analysing_screen.dart';
import '../../features/scanner/presentation/confirmation_screen.dart';
import '../../features/scanner/presentation/capture_3d_screen.dart';
import '../../features/scanner/presentation/results_screen.dart';
import '../../features/capture/presentation/capture_screen.dart';
import '../../features/devices/presentation/device_list_screen.dart';
import '../../features/devices/presentation/device_detail_screen.dart';
import '../../features/devices/presentation/photo_detail_screen.dart';
import '../../features/auth/presentation/login_screen.dart';
import '../../features/auth/presentation/signup_screen.dart';
import '../../features/boot/presentation/boot_screen.dart';
import '../../features/settings/presentation/settings_screen.dart';
import '../../features/settings/presentation/device_info_screen.dart';
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';

final _rootNavigatorKey = GlobalKey<NavigatorState>();
final _shellNavigatorKey = GlobalKey<NavigatorState>();

/// App-wide router using go_router with a ShellRoute for bottom tab navigation.
///
/// [initialLocation] defaults to `/boot` (the diagnostic splash). Widget tests
/// override to `/` to land directly on Home and avoid the boot screen's
/// periodic timers — `pumpAndSettle` would otherwise loop until timeout.
GoRouter createAppRouter({String initialLocation = '/boot'}) => GoRouter(
  navigatorKey: _rootNavigatorKey,
  initialLocation: initialLocation,
  routes: [
    // ── Boot / diagnostic splash ───────────────────────────────────────
    GoRoute(
      path: '/boot',
      parentNavigatorKey: _rootNavigatorKey,
      builder: (context, state) => const BootScreen(),
    ),

    // ── Shell route for bottom tabs ────────────────────────────────────
    ShellRoute(
      navigatorKey: _shellNavigatorKey,
      builder: (context, state, child) => _ScaffoldWithNavBar(child: child),
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => const HomeScreen(),
        ),
        GoRoute(
          path: '/devices',
          builder: (context, state) => const DeviceListScreen(),
        ),
        // Settings lives inside the shell so the bottom NavigationBar persists
        // while it (and its Device Info child) are shown. Entry point is the
        // gear icon in the Home AppBar — no dedicated bottom tab.
        GoRoute(
          path: '/settings',
          builder: (context, state) => const SettingsScreen(),
          routes: [
            GoRoute(
              path: 'device-info',
              builder: (context, state) => const DeviceInfoScreen(),
            ),
          ],
        ),
      ],
    ),

    // ── Full-screen routes (no bottom tabs) ────────────────────────────
    GoRoute(
      path: '/scan',
      parentNavigatorKey: _rootNavigatorKey,
      builder: (context, state) => const LiveScanScreen(),
    ),
    GoRoute(
      path: '/scan/analysing',
      parentNavigatorKey: _rootNavigatorKey,
      builder: (context, state) {
        final imagePath = state.extra as String? ?? '';
        return AnalysingScreen(imagePath: imagePath);
      },
    ),
    GoRoute(
      path: '/scan/results',
      parentNavigatorKey: _rootNavigatorKey,
      builder: (context, state) {
        final scanId = state.extra as String? ?? '';
        return ResultsScreen(scanId: scanId);
      },
    ),
    GoRoute(
      path: '/scan/3d',
      parentNavigatorKey: _rootNavigatorKey,
      builder: (context, state) {
        final deviceName = state.extra as String?;
        return Capture3dScreen(deviceName: deviceName);
      },
    ),
    GoRoute(
      path: '/scan/confirm',
      parentNavigatorKey: _rootNavigatorKey,
      builder: (context, state) => const ConfirmationScreen(),
    ),
    GoRoute(
      path: '/capture',
      parentNavigatorKey: _rootNavigatorKey,
      builder: (context, state) => const CaptureScreen(),
    ),
    GoRoute(
      path: '/devices/:id',
      parentNavigatorKey: _rootNavigatorKey,
      builder: (context, state) {
        final id = state.pathParameters['id']!;
        return DeviceDetailScreen(deviceId: id);
      },
    ),
    GoRoute(
      path: '/devices/:id/photo',
      parentNavigatorKey: _rootNavigatorKey,
      builder: (context, state) {
        final id = state.pathParameters['id']!;
        final photoRef = state.extra as String? ?? '';
        return PhotoDetailScreen(deviceId: id, photoRef: photoRef);
      },
    ),
    GoRoute(
      path: '/login',
      parentNavigatorKey: _rootNavigatorKey,
      builder: (context, state) => const LoginScreen(),
    ),
    GoRoute(
      path: '/signup',
      parentNavigatorKey: _rootNavigatorKey,
      builder: (context, state) => const SignupScreen(),
    ),
  ],
);

/// Default production router — lazily constructed on first use so test code
/// importing this file doesn't pay the boot-route construction cost.
final appRouter = createAppRouter();

/// Scaffold wrapper that provides the persistent bottom navigation bar.
class _ScaffoldWithNavBar extends StatelessWidget {
  const _ScaffoldWithNavBar({required this.child});

  final Widget child;

  int _currentIndex(BuildContext context) {
    final location = GoRouterState.of(context).uri.path;
    if (location.startsWith('/devices')) return 1;
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final index = _currentIndex(context);

    return Scaffold(
      body: child,
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.border, width: 0.5)),
        ),
        child: BottomNavigationBar(
          currentIndex: index,
          selectedLabelStyle: AppTypography.nav,
          unselectedLabelStyle: AppTypography.nav,
          onTap: (i) {
            switch (i) {
              case 0:
                context.go('/');
              case 1:
                context.go('/devices');
            }
          },
          items: const [
            BottomNavigationBarItem(icon: Icon(Icons.home_outlined), activeIcon: Icon(Icons.home), label: 'Home'),
            BottomNavigationBarItem(icon: Icon(Icons.devices_outlined), activeIcon: Icon(Icons.devices), label: 'Devices'),
          ],
        ),
      ),
    );
  }
}
