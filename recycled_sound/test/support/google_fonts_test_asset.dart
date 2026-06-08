import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

/// Makes `GoogleFonts.inter()` resolve from the (mocked) asset bundle instead
/// of the network, so widgets that use it can render under `tester.runAsync`
/// without a live HTTP font fetch (which fails in CI / the sandbox).
///
/// google_fonts, when [GoogleFonts].config.allowRuntimeFetching is false, looks
/// for a bundled font whose asset path ends in `Inter-Regular.ttf` in the
/// `AssetManifest.bin`, then loads it via `rootBundle` (no checksum on the asset
/// path). We synthesise exactly that: a one-entry binary asset manifest plus the
/// font bytes, served through the test binding's asset message handler. The font
/// bytes are the Flutter SDK's own `Roboto-Regular.ttf` (any valid TTF satisfies
/// `FontLoader`); we resolve the SDK via `which flutter`.
///
/// Returns true if the mock was installed; false if the SDK font couldn't be
/// found — callers should then `skip` rather than hit the network.
bool installGoogleFontsAssetMock() {
  final fontBytes = _loadSdkRobotoBytes();
  if (fontBytes == null) return false;

  const assetKey = 'fonts/Inter-Regular.ttf';

  // Binary AssetManifest: Map<assetPath, List<{asset: assetPath}>>.
  final manifest = <String, Object>{
    assetKey: <Object>[
      <String, Object>{'asset': assetKey},
    ],
  };
  final ByteData manifestBin =
      const StandardMessageCodec().encodeMessage(manifest)!;

  GoogleFonts.config.allowRuntimeFetching = false;

  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  binding.defaultBinaryMessenger.setMockMessageHandler('flutter/assets',
      (ByteData? message) async {
    final key = utf8Decode(message);
    if (key == 'AssetManifest.bin') {
      return manifestBin;
    }
    if (key == assetKey) {
      return ByteData.view(fontBytes.buffer);
    }
    return null;
  });
  return true;
}

String utf8Decode(ByteData? message) {
  if (message == null) return '';
  final bytes = message.buffer.asUint8List(
    message.offsetInBytes,
    message.lengthInBytes,
  );
  return String.fromCharCodes(bytes);
}

/// Locates `Roboto-Regular.ttf` inside the active Flutter SDK and returns its
/// bytes, or null if it can't be found.
Uint8List? _loadSdkRobotoBytes() {
  final root = _flutterSdkRoot();
  if (root == null) return null;
  final fontFile = File(
    '$root/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
  );
  if (!fontFile.existsSync()) return null;
  return fontFile.readAsBytesSync();
}

/// Resolves the Flutter SDK root from `FLUTTER_ROOT` (set in CI) or by walking
/// up from the `flutter` executable on PATH.
String? _flutterSdkRoot() {
  final envRoot = Platform.environment['FLUTTER_ROOT'];
  if (envRoot != null && envRoot.isNotEmpty) return envRoot;

  try {
    final which = Platform.isWindows ? 'where' : 'which';
    final result = Process.runSync(which, <String>['flutter']);
    if (result.exitCode != 0) return null;
    final path = (result.stdout as String).trim().split('\n').first.trim();
    if (path.isEmpty) return null;
    // <root>/bin/flutter → <root>
    final binDir = File(path).parent;
    return binDir.parent.path;
  } catch (_) {
    return null;
  }
}
