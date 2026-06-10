import 'package:flutter/material.dart';

import 'core/routing/app_router_web.dart';
import 'core/theme/app_theme.dart';

/// Web-target root widget. Uses [webRouter], which excludes scanner routes
/// (they pull in tflite_flutter / camera, neither web-compatible).
class RecycledSoundWebApp extends StatelessWidget {
  const RecycledSoundWebApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Recycled Sound — Admin',
      theme: AppTheme.light,
      routerConfig: webRouter,
      debugShowCheckedModeBanner: false,
    );
  }
}
