import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../devices/data/models/device.dart';
import '../../scanner/data/colour_classifier.dart';
import '../data/capture_ocr.dart';
import '../data/focus_control.dart';
import '../providers/capture_seed.dart';
import '../providers/upload_job.dart';
import 'capture_slot.dart';
import 'widgets/capture_guide_hand.dart';

/// Guided photo-capture flow — a peer to the scanner (`/scan`), built for the
/// volunteer photo day.
///
/// The unit of work is a **box containing a pair** of hearing aids. The flow
/// steps through [CaptureSlot.pairSequence] — every orientation of the LEFT
/// aid, then the RIGHT aid, 14 shots — and collects the handful of fields a
/// non-expert volunteer can actually read off the device (box number,
/// brand, model, colour). The clinical fields (style, tubing, battery size,
/// tech level, …) are deliberately NOT here: they are the audiologist's job,
/// resolved later in the review screen. On save the set is written to a new
/// device via [IncomingDeviceRepository.createIncoming], which uploads each
/// local file atomically to `captures/{uid}/{deviceId}/{side}_{slot}.jpg`. The
/// filename is the *photo identity* (side + orientation), not a position — so
/// skipping a slot can never shift another shot onto the wrong label.
///
/// After saving, the flow RESETS for the next box rather than navigating to the
/// (clinical, read-only) device screen — a volunteer photographing 300 devices
/// stays in the capture loop.
///
/// Camera lifecycle mirrors the scanner: a [WidgetsBindingObserver] tears the
/// controller down on background and rebuilds on resume, so the camera never
/// leaks. Unlike the scanner, there is no image stream — this flow only needs
/// preview + [CameraController.takePicture].
class CaptureScreen extends ConsumerStatefulWidget {
  const CaptureScreen({super.key});

  @override
  ConsumerState<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends ConsumerState<CaptureScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  bool _cameraReady = false;
  String? _cameraError;
  bool _isCapturing = false;
  bool _saving = false;
  bool _disposed = false;

  /// Camera lifecycle uses TWO guards that answer different questions:
  ///
  /// [_initGen] — a monotonic token answering "is my result still wanted?".
  /// Each init captures the value live at schedule time; a teardown bumps it.
  /// An init whose token is stale after an `await` disposes its half-built
  /// controller and bails, so it never publishes after a background.
  ///
  /// [_cameraOp] — a chained future answering "is the camera free to use?".
  /// Every init/teardown is appended to it, so they run strictly one at a
  /// time. Without this, a resume could call `initialize()` while a superseded
  /// init's `initialize()`/`dispose()` is still touching the native device —
  /// a transient camera-in-use error. The token alone can't prevent that; it
  /// only stops the stale result from being kept.
  int _initGen = 0;
  Future<void> _cameraOp = Future<void>.value();

  /// Index into [CaptureSlot.pairSequence] (0..13) — the step the volunteer is
  /// shooting.
  int _currentStep = 0;

  /// Captured local file paths, keyed by step index. Sparse: a step may be
  /// skipped, so we key by index rather than using a list.
  final Map<int, String> _captured = {};

  /// The volunteer enters only the box number (the link back to the physical
  /// box — it's on the box, not the device, so no camera can read it) and
  /// optionally the colour. Brand + model are read off the brand-label shots by
  /// OCR ([_ocr]); the audiologist confirms them later. Stored trimmed (box
  /// uppercased) to match the scan-confirm flow.
  String _location = '';
  String _colour = '';

  /// Brand/model as read by OCR from the medial (brand-label) shots — NOT typed
  /// by the volunteer. Blank until a brand-label photo is taken and matched.
  String _brand = '';
  String _model = '';

  /// True while OCR is running on a freshly-captured brand-label shot, so the
  /// details bar can show an "identifying…" hint.
  bool _detecting = false;

  /// Reads brand/model off captured stills. Off the live-camera hot path.
  final CaptureOcr _ocr = CaptureOcr();

  CaptureStep get _currentStepData => CaptureSlot.pairSequence[_currentStep];
  CaptureSlot get _currentSlot => _currentStepData.slot;
  AidSide get _currentSide => _currentStepData.side;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scheduleInit();
    // If the scanner routed here for a novel device, pre-fill the identity it
    // already read + the box number, so the volunteer just shoots. Consume the
    // seed (after this frame) so a later standalone capture starts blank.
    final seed = ref.read(captureSeedProvider);
    if (seed != null) {
      _brand = seed.brand;
      _model = seed.model;
      _location = seed.box;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.read(captureSeedProvider.notifier).state = null;
      });
    }
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _scheduleStop();
    _ocr.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _scheduleStop();
    } else if (state == AppLifecycleState.resumed) {
      _scheduleInit();
    }
  }

  /// Claim a fresh generation NOW (so any in-flight init is immediately stale)
  /// and append the init behind whatever camera op is already running.
  ///
  /// The trailing `catchError` is load-bearing: a bare `.then` chain stays
  /// permanently rejected if ANY queued op throws (e.g. a native `dispose()`
  /// failing mid-transition), and every later callback would then silently
  /// never run — the camera would be dead for good. Swallowing here keeps the
  /// queue self-healing; per-op errors are already surfaced via `_cameraError`.
  void _scheduleInit() {
    final gen = ++_initGen;
    _cameraOp = _cameraOp.then((_) => _initCamera(gen)).catchError((_) {});
  }

  /// Invalidate the current generation NOW, then append the teardown. The
  /// synchronous bump means an init already awaiting sees the staleness at its
  /// next checkpoint even before the chained teardown runs.
  void _scheduleStop() {
    _initGen++;
    _cameraOp = _cameraOp.then((_) => _stopCamera()).catchError((_) {});
  }

  Future<void> _initCamera(int gen) async {
    // Superseded before we even started, or a controller is already live.
    if (_disposed || gen != _initGen || _controller != null) return;

    CameraController? controller;
    try {
      final cameras = await availableCameras();
      if (_disposed || gen != _initGen) return;
      if (cameras.isEmpty) throw Exception('No cameras available');

      // Pick the rear ULTRA-WIDE lens preferentially: hearing aids are held
      // ~5–8 cm from the lens to fill the frame, which is well inside the
      // wide-angle camera's ~10 cm minimum focus distance. The ultra-wide
      // camera (iPhone 11+, all 12+ models) does macro down to ~2 cm — the
      // same lens iOS's own Camera app uses for "Macro mode". Falling back
      // through wide → first-back → first preserves behaviour on older non-Pro
      // iPhones that lack ultra-wide.
      //
      // Enumeration order is not a contract, so filter by `lensType` /
      // `lensDirection` rather than indexing. `firstOrNull` keeps the
      // priority cascade a flat null-coalesce chain — each predicate runs
      // at most once.
      final backCameras = cameras
          .where((c) => c.lensDirection == CameraLensDirection.back)
          .toList(growable: false);
      final desc = backCameras
              .where((c) => c.lensType == CameraLensType.ultraWide)
              .firstOrNull ??
          backCameras
              .where((c) => c.lensType == CameraLensType.wide)
              .firstOrNull ??
          backCameras.firstOrNull ??
          cameras.first;

      controller = CameraController(
        desc,
        // 1080p stills: these photos are the clinical/training record, and the
        // model number is printed tiny and sideways on the medial face, so 720p
        // (`.high`) is marginal as an archival still. `.veryHigh` (1920x1080,
        // ~1.3MB JPEGs) reads the label clearly while keeping the 14-shot save
        // fast enough for a 300-device photo day — `.max` (12MP, ~4MB) tripled
        // upload time for no legibility we need.
        ResolutionPreset.veryHigh,
        enableAudio: false,
        imageFormatGroup: defaultTargetPlatform == TargetPlatform.iOS
            ? ImageFormatGroup.bgra8888
            : ImageFormatGroup.yuv420,
      );
      await controller.initialize();
      if (_disposed || gen != _initGen) {
        await _safeDispose(controller);
        return;
      }

      // Prefer the native `.near` autofocus range restriction for these
      // small, close-held subjects. If it applies, we deliberately do NOT
      // also drive focus mode/point from Dart — both sides locking the shared
      // AVCaptureDevice could race. Fall back to centre AF only when the
      // native path is unavailable (Android, older iPhones, simulator).
      // On iOS the camera plugin reports `CameraDescription.name` as the
      // AVCaptureDevice uniqueID — pass it so `.near` is applied to the exact
      // lens we just opened, not a sibling lens guessed by the native side.
      // Use `defaultTargetPlatform` (not `dart:io` Platform) so this file
      // doesn't add yet another Web-incompatible reference; the channel
      // itself is iOS-only anyway and resolves to false elsewhere.
      final nearApplied = await FocusControl.setNearFocus(
        deviceUniqueId:
            defaultTargetPlatform == TargetPlatform.iOS ? desc.name : null,
      );
      if (_disposed || gen != _initGen) {
        await _safeDispose(controller);
        return;
      }
      if (!nearApplied) {
        try {
          await controller.setFocusMode(FocusMode.auto);
          await controller.setFocusPoint(const Offset(0.5, 0.5));
        } catch (_) {
          // Some devices/simulators reject focus config — non-fatal.
        }
        // These awaits are another background window — re-check before publish.
        if (_disposed || gen != _initGen) {
          await _safeDispose(controller);
          return;
        }
      }

      if (!mounted) {
        await _safeDispose(controller);
        return;
      }
      setState(() {
        _controller = controller;
        _cameraReady = true;
        _cameraError = null;
      });
    } catch (e) {
      // Dispose a controller we built but never published, then surface.
      if (controller != null && controller != _controller) {
        await _safeDispose(controller);
      }
      if (_disposed || gen != _initGen) return;
      if (mounted) setState(() => _cameraError = e.toString());
    }
  }

  Future<void> _stopCamera() async {
    // Generation was already bumped synchronously by _scheduleStop; this runs
    // serialized behind any in-flight init, so the device is free when we
    // dispose and the next scheduled init only starts after this returns.
    final c = _controller;
    if (c == null) return;
    _controller = null;
    _cameraReady = false;
    // Unmount CameraPreview BEFORE disposing the hardware, so the widget tree
    // never holds a disposed controller (an assertion crash on background).
    if (mounted) setState(() {});
    await _safeDispose(c);
  }

  /// Dispose a controller, swallowing any platform error. A failed dispose is
  /// best-effort cleanup; it must not escape and poison the [_cameraOp] queue
  /// or surface as a spurious capture error.
  Future<void> _safeDispose(CameraController controller) async {
    try {
      await controller.dispose();
    } catch (_) {
      // Best-effort — nothing actionable if the native release fails.
    }
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (_isCapturing || controller == null || !controller.value.isInitialized) {
      return;
    }
    setState(() => _isCapturing = true);
    try {
      final xFile = await controller.takePicture();
      if (!mounted || _disposed) return;
      HapticFeedback.lightImpact();
      final shotStep = _currentStep;
      setState(() {
        _captured[shotStep] = xFile.path;
        _currentStep = _nextUnshotStep();
      });
      // Read brand/model off whatever face carries the printed label — it is
      // NOT always the medial side, so OCR the shot we just took rather than
      // only the medial one. Fire-and-forget: OCR must never block or fail the
      // capture. Skip once both fields are known.
      if (_brand.isEmpty || _model.isEmpty) {
        unawaited(_runOcr(xFile.path));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Capture failed: $e'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isCapturing = false);
    }
  }

  void _selectStep(int index) => setState(() => _currentStep = index);

  /// The next step with no photo yet, scanning forward from the current step
  /// and wrapping. Returns the current index unchanged when every step is shot,
  /// so a full set leaves the user on the last-shot step rather than jumping
  /// back onto one already captured.
  int _nextUnshotStep() {
    final n = CaptureSlot.pairSequence.length;
    for (var step = 1; step <= n; step++) {
      final i = (_currentStep + step) % n;
      if (_captured[i] == null) return i;
    }
    return _currentStep;
  }

  void _retakeCurrent() => setState(() => _captured.remove(_currentStep));

  /// Captured local paths keyed by photo *identity* (`{side}_{slot}`), not
  /// position. The storage filename is derived from this key, so a skipped
  /// step can never shift another shot onto the wrong label.
  Map<String, String> get _capturedByKey => {
        for (var i = 0; i < CaptureSlot.pairSequence.length; i++)
          if (_captured[i] != null)
            '${CaptureSlot.pairSequence[i].side.name}_'
                    '${CaptureSlot.pairSequence[i].slot.name}':
                _captured[i]!,
      };

  /// Run OCR over a single captured shot and fill brand/model from whatever it
  /// reads. The printed label can be on ANY face (not just the medial side),
  /// so this fires on every captured shot — the first face whose text resolves
  /// a brand/model wins. Best-effort and off the camera thread: a failure
  /// leaves the fields blank for the audiologist, and a brand/model the
  /// volunteer already entered by hand is never overwritten.
  Future<void> _runOcr(String path) async {
    if (_brand.isNotEmpty && _model.isNotEmpty) return;
    setState(() => _detecting = true);
    final id = await _ocr.identify([path]);
    if (!mounted) return;
    setState(() {
      _detecting = false;
      if (id != null) {
        if (_brand.isEmpty && id.brand.isNotEmpty) _brand = id.brand;
        if (_model.isEmpty && id.model.isNotEmpty) _model = id.model;
      }
    });
  }

  /// Prompt for the volunteer-enterable details (box number + the easy
  /// identification fields). The dialog ([_DetailsDialog]) owns its own
  /// controllers and disposes them in *its* `State.dispose` — disposing right
  /// after `await showDialog` would touch a controller the `TextField` still
  /// rebuilds during the route's exit animation (a real crash).
  Future<void> _editDetails() async {
    final result = await showDialog<_DeviceDetails>(
      context: context,
      builder: (context) => _DetailsDialog(
        initial: _DeviceDetails(box: _location, colour: _colour),
      ),
    );
    if (result != null && mounted) {
      setState(() {
        _location = result.box.trim().toUpperCase();
        _colour = result.colour.trim();
      });
    }
  }

  Future<void> _save() async {
    final slotPhotos = _capturedByKey;
    if (slotPhotos.isEmpty || _saving) return;

    // Resolve context-bound handles up front — `_editDetails` awaits below, so
    // any `of(context)` lookup after it would cross an async gap.
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);

    // The box number is the link from this photo set back to the physical box
    // in the register — saving without it orphans the capture. Prompt for it,
    // and bail (with a clear nudge) if the volunteer still skips it.
    if (_location.isEmpty) {
      await _editDetails();
      if (_location.isEmpty) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Enter the box number before saving'),
            backgroundColor: AppColors.error,
          ),
        );
        return;
      }
    }

    setState(() => _saving = true);

    // No scan result, so clinical fields start blank; the volunteer fills the
    // easy identification fields and the audiologist resolves the rest later.
    final draft = DraftDevice(
      brand: _brand,
      model: _model,
      colour: _colour,
      location: _location,
    );

    // Hand the upload to the provider (NOT awaited here) so it survives this
    // screen disposing, then `go` to the progress screen — which observes the
    // job, shows per-photo bars, and routes to `/scan` for the next device on
    // success. Uploading 14 full-res stills inline would otherwise freeze this
    // screen for ~10s with no feedback (it reads as a crash to a volunteer).
    unawaited(
      ref.read(uploadJobProvider.notifier).start(
            draft: draft,
            namedPhotoPaths: slotPhotos,
            box: _location,
          ),
    );
    router.go('/capture/uploading');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: _cameraError != null
            ? _ErrorView(message: _cameraError!)
            : !_cameraReady || _controller == null
                ? const Center(child: CircularProgressIndicator())
                : _buildCamera(context),
      ),
    );
  }

  Widget _buildCamera(BuildContext context) {
    final capturedCount = _captured.length;
    final total = CaptureSlot.pairSequence.length;
    final hasCurrentShot = _captured[_currentStep] != null;

    return Stack(
      fit: StackFit.expand,
      children: [
        Center(child: CameraPreview(_controller!)),

        // Top region: close + progress, the device-details bar, then the
        // per-step guidance — stacked in one Column so they never overlap.
        Positioned(
          top: 8,
          left: 8,
          right: 8,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => context.go('/'),
                  ),
                  const Spacer(),
                  // Mode reminder: this flow only collects photos, it does not
                  // try to read the device. Naming that here prevents the "no
                  // info, unlike scanning" confusion from the entry point on.
                  Flexible(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        'Photo capture · no live ID',
                        style: AppTypography.caption
                            .copyWith(color: Colors.white70),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '$capturedCount / $total',
                      style: AppTypography.body.copyWith(color: Colors.white),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // Details bar — box number (required) + the easy identification
              // fields. Amber call-to-action until a box number is set.
              _DetailsBar(
                box: _location,
                colour: _colour,
                brand: _brand,
                model: _model,
                detecting: _detecting,
                onTap: _editDetails,
              ),
              const SizedBox(height: 12),

              // Per-step guidance — which aid (LEFT/RIGHT), the cartoony hand
              // coaching the orientation, and the plain-language what + why.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CaptureGuideHand(slot: _currentSlot),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Which physical aid + where we are in the set of 14.
                          _SideChip(side: _currentSide),
                          const SizedBox(height: 4),
                          Text(
                            'Photo ${_currentStep + 1} of $total · ${_currentSlot.title}',
                            style: AppTypography.label
                                .copyWith(color: Colors.white60),
                          ),
                          const SizedBox(height: 2),
                          // What to shoot — the action, in plain language.
                          Text(
                            _currentSlot.hint,
                            style:
                                AppTypography.h4.copyWith(color: Colors.white),
                          ),
                          const SizedBox(height: 6),
                          // Why it matters — keeps the step from feeling
                          // arbitrary to a non-expert volunteer.
                          Text(
                            'Why: ${_currentSlot.why}',
                            style: AppTypography.caption
                                .copyWith(color: Colors.white70),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        // Bottom controls: step strip + capture/retake + save.
        Positioned(
          bottom: 16,
          left: 0,
          right: 0,
          child: Column(
            children: [
              _StepStrip(
                captured: _captured,
                currentStep: _currentStep,
                onSelect: _selectStep,
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // Retake (only when current step already has a shot).
                  SizedBox(
                    width: 72,
                    child: hasCurrentShot
                        ? TextButton(
                            onPressed: _retakeCurrent,
                            child: const Text(
                              'Retake',
                              style: TextStyle(color: Colors.white),
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                  _ShutterButton(
                    busy: _isCapturing,
                    onTap: _capture,
                  ),
                  // Save (enabled once at least one photo exists).
                  SizedBox(
                    width: 72,
                    child: capturedCount > 0
                        ? TextButton(
                            onPressed: _saving ? null : _save,
                            child: _saving
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Text(
                                    'Save',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The volunteer-enterable device details, carried between the dialog and the
/// screen as one value. Brand + model are deliberately absent — those are read
/// by OCR off the brand-label shots, not typed.
class _DeviceDetails {
  const _DeviceDetails({required this.box, required this.colour});

  final String box;
  final String colour;
}

/// Modal for entering the device details a volunteer can actually provide: the
/// box number (required) and optionally the colour. A `StatefulWidget` so it
/// owns its controllers and disposes them in `State.dispose` — which runs only
/// after the route is fully gone, avoiding the use-after-dispose that disposing
/// in the caller (right after `await showDialog`) causes during the exit anim.
class _DetailsDialog extends StatefulWidget {
  const _DetailsDialog({required this.initial});

  final _DeviceDetails initial;

  @override
  State<_DetailsDialog> createState() => _DetailsDialogState();
}

class _DetailsDialogState extends State<_DetailsDialog> {
  late final TextEditingController _box =
      TextEditingController(text: widget.initial.box);

  // Colour is chosen from swatches, not typed: free-text produced inconsistent
  // names ("beige" vs "tan" vs "skin") that don't match the register. The
  // selected value is a palette NAME (or '' for none); it's matched
  // case-insensitively against whatever the initial colour was.
  late String _colour = widget.initial.colour;

  bool _isSelected(String name) => name.toLowerCase() == _colour.toLowerCase();

  @override
  void dispose() {
    _box.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Device details'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _box,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Box number *',
                hintText: 'e.g. B07, C10',
                helperText: 'Required — the label on the box',
              ),
            ),
            const SizedBox(height: 20),
            Text('Colour', style: AppTypography.label),
            const SizedBox(height: 2),
            Text(
              'Tap the closest match — brand & model are read from the photos',
              style: AppTypography.caption,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final entry in ColourClassifier.palette)
                  _ColourSwatch(
                    name: entry.name,
                    color: entry.color,
                    selected: _isSelected(entry.name),
                    // Tapping the selected swatch clears it (colour is optional).
                    onTap: () => setState(
                      () => _colour = _isSelected(entry.name) ? '' : entry.name,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(
            _DeviceDetails(box: _box.text, colour: _colour),
          ),
          child: const Text('OK'),
        ),
      ],
    );
  }
}

/// A single tappable colour swatch: a filled square with the colour name below.
/// Selected swatches gain a highlight ring and a check mark so the choice reads
/// clearly against any swatch colour (including the pale beiges).
class _ColourSwatch extends StatelessWidget {
  const _ColourSwatch({
    required this.name,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 64,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: selected ? AppColors.primary : AppColors.border,
                  width: selected ? 3 : 1,
                ),
              ),
              // Contrast the check against the swatch — a white tick vanishes
              // on the pale beiges, a black one on the espressos.
              child: selected
                  ? Icon(
                      Icons.check,
                      size: 22,
                      color: color.computeLuminance() > 0.5
                          ? Colors.black
                          : Colors.white,
                    )
                  : null,
            ),
            const SizedBox(height: 4),
            Text(
              name,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.caption.copyWith(
                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                color: selected ? AppColors.primary : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The device-details bar at the top of the capture flow. The top line is the
/// volunteer-entered part (box number, required, + optional colour): amber call
/// to action until a box number is set, solid once it is, tappable to edit. A
/// second line shows what OCR read off the brand-label shots (brand + model) —
/// not editable here, since the audiologist confirms it; this is just feedback
/// that the auto-identify worked.
class _DetailsBar extends StatelessWidget {
  const _DetailsBar({
    required this.box,
    required this.colour,
    required this.brand,
    required this.model,
    required this.detecting,
    required this.onTap,
  });

  final String box;
  final String colour;
  final String brand;
  final String model;
  final bool detecting;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isSet = box.isNotEmpty;
    final entered = [
      if (isSet) 'Box $box',
      if (colour.isNotEmpty) colour,
    ];
    final detected = [brand, model].where((s) => s.isNotEmpty).join(' ');

    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isSet
              ? Colors.black54
              : AppColors.warning.withValues(alpha: 0.22),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSet ? Colors.white24 : AppColors.warning,
            width: isSet ? 1 : 2,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isSet ? Icons.inventory_2 : Icons.label_important_outline,
                  color: isSet ? Colors.white : AppColors.warning,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    isSet
                        ? entered.join('  ·  ')
                        : 'Tap to add box number (required)',
                    style: AppTypography.body.copyWith(
                      color: Colors.white,
                      fontWeight: isSet ? FontWeight.bold : FontWeight.normal,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Icon(Icons.edit, color: Colors.white54, size: 16),
              ],
            ),
            // OCR feedback line — only once there's something to say.
            if (detecting || detected.isNotEmpty) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  const SizedBox(width: 30),
                  Icon(
                    detected.isNotEmpty ? Icons.auto_awesome : Icons.search,
                    color: AppColors.accent,
                    size: 14,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      detected.isNotEmpty
                          ? 'Read from photo: $detected'
                          : 'Reading brand & model…',
                      style: AppTypography.caption
                          .copyWith(color: Colors.white70),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Which-aid badge ("LEFT aid" / "RIGHT aid"), colour-coded so the volunteer
/// always knows which physical device of the pair they're shooting.
class _SideChip extends StatelessWidget {
  const _SideChip({required this.side});

  final AidSide side;

  @override
  Widget build(BuildContext context) {
    final colour =
        side == AidSide.left ? AppColors.accent : AppColors.success;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colour, width: 1.5),
      ),
      child: Text(
        '${side.label.toUpperCase()} AID',
        style: AppTypography.label.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

/// Horizontal strip of step chips — captured steps show a check, the active
/// step is ringed, and each carries an L/R badge so the two halves of the pair
/// are distinguishable at a glance. Tapping jumps to that step.
class _StepStrip extends StatelessWidget {
  const _StepStrip({
    required this.captured,
    required this.currentStep,
    required this.onSelect,
  });

  final Map<int, String> captured;
  final int currentStep;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 64,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: CaptureSlot.pairSequence.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final step = CaptureSlot.pairSequence[i];
          final shot = captured[i];
          final active = i == currentStep;
          final sideColour =
              step.side == AidSide.left ? AppColors.accent : AppColors.success;
          return GestureDetector(
            onTap: () => onSelect(i),
            child: Container(
              width: 56,
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: active ? AppColors.accent : Colors.white24,
                  width: active ? 2 : 1,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: sideColour.withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          step.side == AidSide.left ? 'L' : 'R',
                          style: AppTypography.caption.copyWith(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(width: 3),
                      Icon(
                        shot != null
                            ? Icons.check_circle
                            : Icons.circle_outlined,
                        color: shot != null
                            ? AppColors.success
                            : Colors.white54,
                        size: 16,
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    step.slot.title,
                    style: AppTypography.caption.copyWith(
                      color: Colors.white,
                      fontSize: 9,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ShutterButton extends StatelessWidget {
  const _ShutterButton({required this.busy, required this.onTap});

  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: busy ? null : onTap,
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white,
          border: Border.all(color: AppColors.accent, width: 4),
        ),
        child: busy
            ? const Padding(
                padding: EdgeInsets.all(20),
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: AppColors.accent,
                ),
              )
            : const Icon(Icons.camera_alt, color: AppColors.accent, size: 32),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography, color: Colors.white54, size: 48),
            const SizedBox(height: 16),
            Text(
              'Camera unavailable',
              style: AppTypography.h3.copyWith(color: Colors.white),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              style: AppTypography.caption.copyWith(color: Colors.white54),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () => context.go('/'),
              child: const Text('Back'),
            ),
          ],
        ),
      ),
    );
  }
}
