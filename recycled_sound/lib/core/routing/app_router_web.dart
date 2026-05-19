import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';

import '../../features/admin/presentation/admin_shell.dart';
import '../../features/admin/presentation/device_register_screen.dart';
import '../../features/admin/presentation/incoming_queue_screen.dart';
import '../../features/admin/presentation/placeholder_admin_screen.dart';
import '../../features/auth/presentation/login_screen.dart';
import '../../features/auth/presentation/signup_screen.dart';

/// Web-target router.
///
/// Excludes scanner routes — the scanner depends on tflite_flutter
/// (`dart:ffi`) and ML Kit (camera), neither web-compatible. The web app is
/// admin-shaped: review the register, manage matching, surface impact.
///
/// Auth guard: anyone may visit /login and /signup; everything else
/// requires a signed-in user (anonymous OR authenticated). The Firestore
/// rules enforce role-based filtering on top, so an anonymous visitor
/// won't see other people's incoming docs — they'll see an empty list.
GoRouter buildWebRouter({String initialLocation = '/incoming'}) => GoRouter(
      initialLocation: initialLocation,
      redirect: (context, state) {
        final loc = state.matchedLocation;
        final isPublic = loc == '/login' || loc == '/signup';
        final signedIn = FirebaseAuth.instance.currentUser != null;
        if (!signedIn && !isPublic) return '/login';
        if (signedIn && isPublic) return '/incoming';
        return null;
      },
      routes: [
        GoRoute(path: '/', redirect: (_, _) => '/incoming'),
        GoRoute(
          path: '/incoming',
          builder: (context, state) => const IncomingQueueScreen(),
        ),
        GoRoute(
          path: '/devices',
          builder: (context, state) => const DeviceRegisterScreen(),
        ),
        GoRoute(
          path: '/matching',
          builder: (context, state) => const PlaceholderAdminScreen(
            section: AdminSection.matching,
            title: 'Matching',
            tagline:
                'Recipient applications matched to ready devices land here. Approve, message, ship.',
          ),
        ),
        GoRoute(
          path: '/users',
          builder: (context, state) => const PlaceholderAdminScreen(
            section: AdminSection.users,
            title: 'Users',
            tagline:
                'Donor, recipient, and audiologist accounts. Role grants happen here.',
          ),
        ),
        GoRoute(
          path: '/login',
          builder: (context, state) => const LoginScreen(),
        ),
        GoRoute(
          path: '/signup',
          builder: (context, state) => const SignupScreen(),
        ),
      ],
    );

final webRouter = buildWebRouter();
