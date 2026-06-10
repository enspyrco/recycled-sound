import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_web.dart';
import 'firebase_options.dart';

/// Web entry point. Distinct from `main.dart` because the mobile boot
/// pipeline (diagnostic boot screen, native device telemetry, scanner
/// pipeline) doesn't apply on the web — and the scanner's tflite_flutter
/// import would fail web compilation anyway.
///
/// Anonymous sign-in is preserved so unauthenticated visitors can browse
/// the public surface (currently: read-only device register); a future PR
/// adds router auth guards for role-gated routes.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  if (FirebaseAuth.instance.currentUser == null) {
    await FirebaseAuth.instance.signInAnonymously();
  }
  runApp(const ProviderScope(child: RecycledSoundWebApp()));
}
