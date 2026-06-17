import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:firebase_storage_mocks/firebase_storage_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:recycled_sound/features/admin/presentation/incoming_review_detail_screen.dart';
import 'package:recycled_sound/features/devices/data/incoming_device_repository.dart';
import 'package:recycled_sound/features/devices/data/models/device.dart';
import 'package:recycled_sound/features/devices/providers/device_providers.dart';
import 'package:recycled_sound/features/scanner/data/models/scan_result.dart'
    show kUnknownValue;

/// Repository double that records the review-flow calls without touching a real
/// backend. Extends the real repo (constructed with the standard Firebase
/// mocks), matching the test-double style in `device_detail_screen_test.dart`.
class _RecordingRepository extends IncomingDeviceRepository {
  _RecordingRepository()
      : super(
          firestore: FakeFirebaseFirestore(),
          storage: MockFirebaseStorage(),
          auth: MockFirebaseAuth(),
        );

  int promoteCalls = 0;
  int updateCalls = 0;
  final List<QaStatus?> updateQaStatuses = [];
  // Captured edits from the last updateIncoming call.
  String? lastBrand;
  String? lastModel;
  Style? lastType;
  BatterySize? lastBatterySize;
  Tubing? lastTubing;
  PowerSource? lastPowerSource;
  String? lastColour;
  double? lastServicingCost;
  List<ClinicalField>? lastNeedsInputFields;
  // Captured args from the last promoteToDevice call.
  ReviewEdits? lastEdits;
  bool lastAllowOverride = false;

  @override
  Future<void> updateIncoming(
    String id, {
    required String brand,
    required String model,
    required Style type,
    required BatterySize batterySize,
    required Tubing tubing,
    required PowerSource powerSource,
    required String colour,
    required String location,
    required String servicingNotes,
    required double servicingCost,
    QaStatus? qaStatus,
    List<ClinicalField>? needsInputFields,
    List<String> unrecognisedNeedsInput = const [],
  }) async {
    updateCalls++;
    updateQaStatuses.add(qaStatus);
    lastBrand = brand;
    lastModel = model;
    lastType = type;
    lastBatterySize = batterySize;
    lastTubing = tubing;
    lastPowerSource = powerSource;
    lastColour = colour;
    lastServicingCost = servicingCost;
    lastNeedsInputFields = needsInputFields;
  }

  @override
  Future<void> promoteToDevice(
    String incomingId, {
    ReviewEdits? edits,
    bool allowOverride = false,
  }) async {
    promoteCalls++;
    lastEdits = edits;
    lastAllowOverride = allowOverride;
  }
}

const _id = 'dev1';

// Hint texts are the stable handle for each TextField now that the form carries
// eight of them (brand/model/type/battery/colour/location/notes/cost) — a
// positional `.first`/`.last` would silently target the wrong field.
const _brandHint = 'e.g. Oticon, Phonak';
const _colourHint = 'e.g. Charcoal, Beige';

Finder _fieldByHint(String hint) => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == hint,
    );

Device _device({
  String brand = 'Oticon',
  Style type = Style.bte,
  BatterySize batterySize = BatterySize.size13,
  Tubing tubing = Tubing.unspecified,
  PowerSource powerSource = PowerSource.unspecified,
  String colour = '',
  List<ClinicalField> needsInputFields = const [],
  QaStatus qaStatus = QaStatus.pendingQa,
}) =>
    Device(
      id: _id,
      brand: brand,
      model: 'More 1',
      type: type,
      year: '2022',
      batterySize: batterySize,
      tubing: tubing,
      powerSource: powerSource,
      colour: colour,
      needsInputFields: needsInputFields,
      qaStatus: qaStatus,
    );

Future<_RecordingRepository> _pump(
  WidgetTester tester, {
  required Device device,
}) async {
  final repo = _RecordingRepository();
  final router = GoRouter(
    initialLocation: '/incoming/$_id/review',
    routes: [
      GoRoute(
        path: '/incoming',
        builder: (_, _) => const Scaffold(body: Text('QUEUE')),
      ),
      GoRoute(
        path: '/incoming/:id/review',
        builder: (_, state) => IncomingReviewDetailScreen(
          deviceId: state.pathParameters['id']!,
        ),
      ),
    ],
  );
  await tester.pumpWidget(ProviderScope(
    overrides: [
      incomingDeviceByIdProvider(_id).overrideWith((_) => Stream.value(device)),
      incomingDeviceRepositoryProvider.overrideWithValue(repo),
    ],
    child: MaterialApp.router(routerConfig: router),
  ));
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  testWidgets('renders device fields and the needsInputFields banner',
      (tester) async {
    await _pump(tester,
        device: _device(
            needsInputFields: [ClinicalField.tubing, ClinicalField.colour]));

    expect(find.text('Oticon More 1'), findsOneWidget);
    expect(find.text('Identification'), findsOneWidget);
    expect(find.text('Audiologist review'), findsOneWidget);
    // Banner surfaces the flagged fields by friendly label (sorted).
    expect(find.textContaining('Needs your input (2)'), findsOneWidget);
    expect(find.textContaining('Colour, Tubing'), findsOneWidget);
  });

  testWidgets('no banner when nothing was flagged', (tester) async {
    await _pump(tester, device: _device());
    expect(find.textContaining('Needs your input'), findsNothing);
    expect(find.textContaining('All flagged fields resolved'), findsNothing);
  });

  testWidgets('real scan keys map to their audiologist labels in the banner',
      (tester) async {
    // 'type' is the scan model's Style field; it must render as "Style", not
    // the raw key. Leave the Style picker unspecified so the flag stays
    // unresolved and the banner this test inspects is present.
    await _pump(tester,
        device: _device(
            type: Style.unspecified,
            needsInputFields: [ClinicalField.type]));
    expect(find.textContaining('Style'), findsWidgets);
    expect(find.textContaining('type'), findsNothing);
  });

  testWidgets(
      'a flagged identity field (brand) is editable and resolves on input (#783)',
      (tester) async {
    // A volunteer-flagged brand arrives as the `'Unknown'` sentinel; the screen
    // normalizes it to an empty, editable field that starts UNRESOLVED.
    await _pump(tester,
        device: _device(
            brand: kUnknownValue, needsInputFields: [ClinicalField.brand]));
    // Sentinel normalized away — the field shows blank, not "Unknown".
    expect(find.text('Unknown'), findsNothing);
    expect(find.textContaining('Needs your input (1)'), findsOneWidget);
    expect(find.textContaining('Make'), findsWidgets);
    expect(find.textContaining('All flagged fields resolved'), findsNothing);

    // Correcting the brand resolves the flag — the real resolution path #783
    // adds (previously override was the only way past an identity flag).
    await tester.enterText(_fieldByHint(_brandHint), 'Oticon');
    await tester.pumpAndSettle();
    expect(find.textContaining('Needs your input'), findsNothing);
    expect(find.textContaining('All flagged fields resolved'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Pass QA'), findsOneWidget);
  });

  testWidgets('Pass QA persists edits then promotes, navigating to the queue',
      (tester) async {
    final repo = await _pump(tester,
        device: _device(needsInputFields: [ClinicalField.colour]));

    // Resolve the flagged colour field.
    await tester.enterText(_fieldByHint(_colourHint), 'Charcoal');
    await tester.pumpAndSettle();

    final pass = find.widgetWithText(FilledButton, 'Pass QA');
    await tester.ensureVisible(pass);
    await tester.tap(pass);
    await tester.pumpAndSettle();

    // Pass is now a SINGLE transactional promote (edits merged + gated + written
    // atomically) — no separate updateIncoming on this path.
    expect(repo.updateCalls, 0);
    expect(repo.promoteCalls, 1);
    expect(repo.lastEdits, isNotNull);
    expect(repo.lastEdits!.colour, 'Charcoal');
    // Resolved → clean pass: not an override, and the shrunk flag set (colour
    // resolved) is empty.
    expect(repo.lastAllowOverride, isFalse);
    expect(repo.lastEdits!.needsInputFields, isEmpty);
    // Navigated back to the queue.
    expect(find.text('QUEUE'), findsOneWidget);
  });

  testWidgets(
      'correcting a flagged brand promotes CLEAN, carrying the edit (#783)',
      (tester) async {
    final repo = await _pump(tester,
        device: _device(
            brand: kUnknownValue, needsInputFields: [ClinicalField.brand]));

    await tester.enterText(_fieldByHint(_brandHint), 'Oticon');
    await tester.pumpAndSettle();

    final pass = find.widgetWithText(FilledButton, 'Pass QA');
    await tester.ensureVisible(pass);
    await tester.tap(pass);
    await tester.pumpAndSettle();

    expect(repo.promoteCalls, 1);
    // Clean promotion — NOT an override — because the brand flag was resolved by
    // editing, and the corrected value rides in the edits + the flag set shrank
    // to empty so the gate sees it Promotable.
    expect(repo.lastAllowOverride, isFalse);
    expect(repo.lastEdits!.brand, 'Oticon');
    expect(repo.lastEdits!.needsInputFields, isEmpty);
    expect(find.text('QUEUE'), findsOneWidget);
  });

  testWidgets(
      'an identity flag left uncorrected makes Pass an explicit "Override & pass"',
      (tester) async {
    await _pump(tester,
        device: _device(
            brand: kUnknownValue, needsInputFields: [ClinicalField.brand]));
    // brand normalizes to empty and the audiologist leaves it — so it stays
    // unresolved and the action is an override, not a clean pass.
    expect(find.widgetWithText(FilledButton, 'Pass QA'), findsNothing);
    expect(find.textContaining('Override & pass (1 unresolved)'),
        findsOneWidget);
  });

  testWidgets('Override & pass records the still-unresolved fields as override',
      (tester) async {
    final repo = await _pump(tester,
        device: _device(
            brand: kUnknownValue, needsInputFields: [ClinicalField.brand]));

    final btn = find.textContaining('Override & pass');
    await tester.ensureVisible(btn);
    await tester.tap(btn);
    await tester.pumpAndSettle();

    expect(repo.promoteCalls, 1);
    // The UI authorises the override; the uncorrected brand flag rides in the
    // edits so the gate stamps it from the verdict. The brand value carried is
    // the de-sentineled empty string (provenance lives in the flag, not the
    // value — feedback_provenance_not_value).
    expect(repo.lastAllowOverride, isTrue);
    expect(repo.lastEdits!.needsInputFields, [ClinicalField.brand]);
    expect(repo.lastEdits!.brand, '');
    expect(find.text('QUEUE'), findsOneWidget);
  });

  testWidgets('resolving the last clinical flag flips Override back to Pass QA',
      (tester) async {
    await _pump(tester,
        device: _device(needsInputFields: [ClinicalField.colour]));
    // Colour starts empty → unresolved → override label.
    expect(find.textContaining('Override & pass'), findsOneWidget);

    await tester.enterText(_fieldByHint(_colourHint), 'Charcoal');
    await tester.pumpAndSettle();

    // Now resolved → clean pass.
    expect(find.textContaining('Override & pass'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Pass QA'), findsOneWidget);
  });

  testWidgets('Fail QA sets failed without promoting and stays put',
      (tester) async {
    final repo = await _pump(tester, device: _device());

    final fail = find.widgetWithText(OutlinedButton, 'Fail QA');
    await tester.ensureVisible(fail);
    await tester.tap(fail);
    await tester.pumpAndSettle();

    expect(repo.updateCalls, 1);
    expect(repo.updateQaStatuses.single, QaStatus.failed);
    expect(repo.promoteCalls, 0);
    // No nav — still on the review screen.
    expect(find.text('QUEUE'), findsNothing);
    expect(find.text('Audiologist review'), findsOneWidget);
  });

  testWidgets('editing a segmented field is captured on save', (tester) async {
    final repo = await _pump(tester, device: _device());

    // Pick "Slim" tubing and "Battery" power source. "Battery" also appears as
    // the Identification spec-row label, so scope the tap to the power-source
    // segmented control.
    final slim = find.text('Slim');
    await tester.ensureVisible(slim);
    await tester.tap(slim);
    final battery = find.descendant(
      of: find.byType(SegmentedButton<PowerSource>),
      matching: find.text('Battery'),
    );
    await tester.ensureVisible(battery);
    await tester.tap(battery);
    await tester.pumpAndSettle();

    final fail = find.widgetWithText(OutlinedButton, 'Fail QA');
    await tester.ensureVisible(fail);
    await tester.tap(fail);
    await tester.pumpAndSettle();

    expect(repo.lastTubing, Tubing.slim);
    expect(repo.lastPowerSource, PowerSource.battery);
  });

  testWidgets(
      'a flagged Style resolves by picking a dropdown value, and is captured '
      '(#15)', (tester) async {
    // Style is a closed-set dropdown now (not a free-text field). A flagged
    // Style starts unspecified → unresolved; selecting a real value resolves it.
    final repo = await _pump(tester,
        device: _device(
            type: Style.unspecified,
            needsInputFields: [ClinicalField.type]));
    expect(find.textContaining('Override & pass'), findsOneWidget);

    // Open the Style dropdown and pick RIC. (The Type dropdown is the first
    // DropdownButtonFormField on the screen.)
    await tester.tap(find.byType(DropdownButtonFormField<Style>));
    await tester.pumpAndSettle();
    // The selected-item 'RIC' may also paint behind the menu, so tap the menu
    // entry (the last 'RIC' in the overlay).
    await tester.tap(find.text('RIC').last);
    await tester.pumpAndSettle();

    // Flag resolved → clean Pass QA.
    expect(find.textContaining('Override & pass'), findsNothing);
    final pass = find.widgetWithText(FilledButton, 'Pass QA');
    await tester.ensureVisible(pass);
    await tester.tap(pass);
    await tester.pumpAndSettle();

    expect(repo.promoteCalls, 1);
    expect(repo.lastAllowOverride, isFalse);
    expect(repo.lastEdits!.type, Style.ric);
    expect(repo.lastEdits!.needsInputFields, isEmpty);
  });

  testWidgets('a picked BatterySize is captured on save (#15)', (tester) async {
    final repo = await _pump(tester, device: _device());

    await tester.tap(find.byType(DropdownButtonFormField<BatterySize>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('675').last);
    await tester.pumpAndSettle();

    final fail = find.widgetWithText(OutlinedButton, 'Fail QA');
    await tester.ensureVisible(fail);
    await tester.tap(fail);
    await tester.pumpAndSettle();

    expect(repo.lastBatterySize, BatterySize.size675);
  });

  testWidgets('permission-denied shows the lock UI, not a crash',
      (tester) async {
    final router = GoRouter(
      initialLocation: '/incoming/$_id/review',
      routes: [
        GoRoute(
          path: '/incoming/:id/review',
          builder: (_, state) => IncomingReviewDetailScreen(
            deviceId: state.pathParameters['id']!,
          ),
        ),
      ],
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        incomingDeviceByIdProvider(_id).overrideWith(
          (_) => Stream.error(Exception('permission-denied')),
        ),
      ],
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('audiologist or admin role'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
  });

  testWidgets('servicing cost left as a trailing-dot "5." persists 5.0, not 0',
      (tester) async {
    // Cage-match (Carnot) residual: double.tryParse("5.") returns null, so a
    // value left mid-typing would silently save 0 on a money field. _parsedCost
    // normalises the trailing dot before parsing.
    final repo = await _pump(tester, device: _device());

    // Cost is the last TextField (colour, location, notes, cost).
    final costField = find.byType(TextField).last;
    await tester.ensureVisible(costField);
    await tester.enterText(costField, '5.');
    await tester.pumpAndSettle();

    final fail = find.widgetWithText(OutlinedButton, 'Fail QA');
    await tester.ensureVisible(fail);
    await tester.tap(fail);
    await tester.pumpAndSettle();

    expect(repo.lastServicingCost, 5.0);
  });
}
