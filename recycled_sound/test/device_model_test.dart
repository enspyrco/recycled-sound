import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recycled_sound/features/devices/data/models/device.dart';

void main() {
  group('Device.fromFirestore', () {
    late FakeFirebaseFirestore firestore;

    setUp(() {
      firestore = FakeFirebaseFirestore();
    });

    test('parses full document with all fields populated', () async {
      await firestore.collection('incoming').doc('abc').set({
        'brand': 'Phonak',
        'model': 'Audéo P90',
        'type': 'RIC',
        'year': '2021',
        'serialLeft': 'L-001',
        'serialRight': 'R-001',
        'batterySize': '312',
        'domeType': 'Closed',
        'waxFilter': 'CeruShield',
        'receiver': 'M',
        'programmingInterface': 'Noahlink Wireless',
        'techLevel': 'Premium',
        'gainRange': '60dB',
        'fittingRange': '70dB',
        'remoteFT': true,
        'appCompatible': true,
        'auracast': false,
        'chargerType': 'Mini',
        'accessories': ['charger', 'dome kit'],
        'condition': 'Excellent',
        'qaStatus': 'passed',
        'status': 'ready',
        'servicingNotes': 'Cleaned',
        'servicingCost': 25.5,
        'donorId': 'donor-1',
        'scanId': 'scan-1',
        'photos': ['gs://b/p/0.jpg', 'gs://b/p/1.jpg'],
        'createdAt': Timestamp.fromDate(DateTime.utc(2026, 1, 1)),
        'updatedAt': Timestamp.fromDate(DateTime.utc(2026, 2, 1)),
      });

      final snap = await firestore.collection('incoming').doc('abc').get();
      final d = Device.fromFirestore(snap);

      expect(d.id, 'abc');
      expect(d.brand, 'Phonak');
      expect(d.model, 'Audéo P90');
      expect(d.type, Style.ric);
      expect(d.year, '2021');
      expect(d.batterySize, BatterySize.size312);
      expect(d.remoteFT, isTrue);
      expect(d.appCompatible, isTrue);
      expect(d.auracast, isFalse);
      expect(d.accessories, ['charger', 'dome kit']);
      expect(d.photos, hasLength(2));
      expect(d.servicingCost, closeTo(25.5, 1e-6));
      // Timestamp.toDate returns a local-zone DateTime — compare by epoch
      // milliseconds rather than assuming a specific zone.
      expect(d.createdAt!.toUtc(), DateTime.utc(2026, 1, 1));
      expect(d.updatedAt!.toUtc(), DateTime.utc(2026, 2, 1));
    });

    test('empty document fills sensible defaults', () async {
      await firestore.collection('incoming').doc('empty').set({});
      final snap = await firestore.collection('incoming').doc('empty').get();
      final d = Device.fromFirestore(snap);

      expect(d.id, 'empty');
      expect(d.brand, '');
      expect(d.model, '');
      expect(d.type, Style.unspecified);
      expect(d.batterySize, BatterySize.unspecified);
      expect(d.remoteFT, isFalse);
      expect(d.accessories, isEmpty);
      expect(d.photos, isEmpty);
      expect(d.qaStatus, QaStatus.pendingQa);
      expect(d.status, DeviceStatus.donated);
      expect(d.servicingCost, 0);
      expect(d.createdAt, isNull);
      expect(d.updatedAt, isNull);
    });

    test('integer servicingCost is coerced to double', () async {
      await firestore.collection('incoming').doc('cost').set({
        'brand': 'X',
        'servicingCost': 42, // int, not double
      });
      final snap = await firestore.collection('incoming').doc('cost').get();
      final d = Device.fromFirestore(snap);
      expect(d.servicingCost, 42.0);
    });
  });

  group('Device.toFirestore', () {
    test('emits the device fields with sentinel server timestamps', () {
      const d = Device(
        id: 'x',
        brand: 'Oticon',
        model: 'More 1',
        type: Style.bte,
        batterySize: BatterySize.size13,
        needsInputFields: [ClinicalField.tubing],
      );
      final map = d.toFirestore(createdBy: 'user-1');

      expect(map['brand'], 'Oticon');
      expect(map['model'], 'More 1');
      // Style/BatterySize serialize to their unchanged wire strings (#15).
      expect(map['type'], 'BTE');
      expect(map['batterySize'], '13');
      expect(map['accessories'], isEmpty);
      expect(map['photos'], isEmpty);
      expect(map['needsInputFields'], ['tubing']);
      // Enums serialized to their wire form
      expect(map['qaStatus'], 'pending_qa');
      expect(map['status'], 'donated');
      // Server sentinels for fresh writes
      expect(map['createdAt'], isA<FieldValue>());
      expect(map['updatedAt'], isA<FieldValue>());
      // createdBy required and present
      expect(map['createdBy'], 'user-1');
    });

    test('createdBy threads through to the payload', () {
      const d = Device(id: 'x', brand: 'Phonak', model: 'P90');
      final map = d.toFirestore(createdBy: 'user-123');
      expect(map['createdBy'], 'user-123');
    });

    test('createdAt preserved when device already has one', () {
      final created = DateTime.utc(2026, 3, 1);
      final d = Device(id: 'x', brand: 'B', model: 'M', createdAt: created);
      final map = d.toFirestore(createdBy: 'user-1');
      expect(map['createdAt'], isA<Timestamp>());
      expect((map['createdAt'] as Timestamp).toDate().toUtc(), created);
    });

    test('non-default qaStatus and status round-trip via enum', () {
      const d = Device(
        id: 'x',
        brand: 'B',
        model: 'M',
        qaStatus: QaStatus.passed,
        status: DeviceStatus.matched,
      );
      final map = d.toFirestore(createdBy: 'user-1');
      expect(map['qaStatus'], 'passed');
      expect(map['status'], 'matched');
    });

    test('QaStatus.fromWire treats unknown values as pendingQa', () {
      expect(QaStatus.fromWire('passed'), QaStatus.passed);
      expect(QaStatus.fromWire('failed'), QaStatus.failed);
      expect(QaStatus.fromWire(null), QaStatus.pendingQa);
      expect(QaStatus.fromWire('mystery_state'), QaStatus.pendingQa);
    });

    test('DeviceStatus.fromWire treats unknown values as donated', () {
      expect(DeviceStatus.fromWire('ready'), DeviceStatus.ready);
      expect(DeviceStatus.fromWire(null), DeviceStatus.donated);
      expect(DeviceStatus.fromWire('unknown_state'), DeviceStatus.donated);
    });
  });

  group('Device.mockDevices', () {
    test('returns the 5 register samples', () {
      final mocks = Device.mockDevices();
      expect(mocks, hasLength(5));
      expect(mocks.first.brand, 'Phonak');
      expect(mocks.last.brand, 'Widex');
      // Spot-check distinct brands
      expect(mocks.map((m) => m.brand).toSet(), {
        'Phonak',
        'Oticon',
        'Signia',
        'GN Resound',
        'Widex',
      });
    });
  });

  group('Device.unknownFieldCount', () {
    test('is zero when no fields were flagged', () {
      const d =
          Device(id: 'x', brand: 'Phonak', model: 'P90', type: Style.ric);
      expect(d.unknownFieldCount, 0);
    });

    test('reflects the persisted needsInputFields set', () {
      const d = Device(
        id: 'x',
        brand: 'Phonak',
        model: 'P90',
        needsInputFields: [ClinicalField.tubing, ClinicalField.colour],
      );
      expect(d.unknownFieldCount, 2);
    });

    test('does NOT flag AI-default "Unknown" values (collision guard)', () {
      // scan_fusion emits 'Unknown' for fields the AI couldn't read. Those are
      // NOT volunteer handoffs — only the persisted needsInputFields set is.
      // Since #15, Style/BatterySize absorb the 'Unknown' sentinel to
      // `unspecified` at parse time, so an unread field carries no value AND no
      // flag — unknownFieldCount stays 0.
      const d = Device(
        id: 'x',
        brand: 'Phonak',
        model: 'P90',
        type: Style.unspecified,
        batterySize: BatterySize.unspecified,
      );
      expect(
        d.unknownFieldCount,
        0,
        reason: 'an unspecified value must not be mistaken for a volunteer flag',
      );
    });
  });

  group('DraftDevice.toDevice', () {
    test('promotes a draft to a Device, pinning the Firestore id', () {
      const draft = DraftDevice(
        brand: 'Oticon',
        model: 'More 1',
        type: Style.bte,
        batterySize: BatterySize.size13,
        qaStatus: QaStatus.pendingQa,
        status: DeviceStatus.donated,
        photos: ['gs://b/scan.jpg'],
      );

      final device = draft.toDevice(id: 'doc-123');

      expect(device.id, 'doc-123');
      expect(device.brand, 'Oticon');
      expect(device.model, 'More 1');
      expect(device.type, Style.bte);
      expect(device.batterySize, BatterySize.size13);
      expect(device.qaStatus, QaStatus.pendingQa);
      expect(device.status, DeviceStatus.donated);
      // photos default to the draft's when not overridden
      expect(device.photos, ['gs://b/scan.jpg']);
    });

    test('overrides photos when given (post-upload URI merge)', () {
      const draft = DraftDevice(
        brand: 'Phonak',
        model: 'P90',
        photos: ['gs://b/scan.jpg'],
      );

      final device = draft.toDevice(
        id: 'x',
        photos: ['gs://b/scan.jpg', 'gs://b/incoming/x/photos/0.jpg'],
      );

      expect(device.photos, hasLength(2));
      expect(device.photos.last, endsWith('0.jpg'));
    });

    test('carries tubing/powerSource/colour/location through to Device', () {
      // Issue #751/#766: these four were previously dropped at the
      // DraftDevice→Device boundary. Confirm they survive promotion.
      const draft = DraftDevice(
        brand: 'Phonak',
        model: 'P90',
        tubing: Tubing.slim,
        powerSource: PowerSource.rechargeable,
        colour: 'Champagne',
        location: 'B07',
      );

      final device = draft.toDevice(id: 'x');

      expect(device.tubing, Tubing.slim);
      expect(device.powerSource, PowerSource.rechargeable);
      expect(device.colour, 'Champagne');
      expect(device.location, 'B07');
    });
  });

  group('clinical value + location fields (#751, #766)', () {
    late FakeFirebaseFirestore firestore;

    setUp(() => firestore = FakeFirebaseFirestore());

    test(
      'tubing/powerSource/colour/location survive a toFirestore→fromFirestore '
      'round-trip',
      () async {
        const d = Device(
          id: 'rt',
          brand: 'Phonak',
          model: 'P90',
          tubing: Tubing.standard,
          powerSource: PowerSource.battery,
          colour: 'Graphite',
          location: 'C10',
        );

        final map = d.toFirestore(createdBy: 'user-1');
        // The wire form carries each enum as its human-readable String — the
        // exact value already in Firestore, so existing docs round-trip (#15).
        expect(map['tubing'], 'Standard');
        expect(map['powerSource'], 'Battery');
        expect(map['colour'], 'Graphite');
        expect(map['location'], 'C10');

        await firestore.collection('incoming').doc('rt').set(map);
        final snap = await firestore.collection('incoming').doc('rt').get();
        final back = Device.fromFirestore(snap);

        expect(back.tubing, Tubing.standard);
        expect(back.powerSource, PowerSource.battery);
        expect(back.colour, 'Graphite');
        expect(back.location, 'C10');
      },
    );

    test(
      'needsInputFields with an unrecognised key is retained, blocks promotion, '
      'and round-trips losslessly (fail-closed; PR #86 cage-match)',
      () async {
        await firestore.collection('incoming').doc('mixed').set({
          'brand': 'Phonak',
          'model': 'P90',
          'needsInputFields': ['colour', 'make'], // one real, one garbage key
        });
        final snap = await firestore.collection('incoming').doc('mixed').get();
        final d = Device.fromFirestore(snap);

        // Recognised key is typed; the unknown one is RETAINED, not dropped.
        expect(d.needsInputFields, [ClinicalField.colour]);
        expect(d.unrecognisedNeedsInput, ['make']);
        expect(d.unknownFieldCount, 2);

        // The gate fails CLOSED — an un-nameable blocker still blocks.
        final verdict = d.reviewForPromotion();
        expect(verdict, isA<NeedsResolution>());
        expect((verdict as NeedsResolution).unrecognised, ['make']);

        // A tolerant read followed by a write must not silently destroy the
        // unknown blocker.
        expect(d.toFirestore(createdBy: 'u')['needsInputFields'],
            ['colour', 'make']);
      },
    );

    test('qaOverride round-trips through Firestore (audit record survives)',
        () async {
      final d = Device(
        id: 'ov',
        brand: 'Phonak',
        model: 'P90',
        needsInputFields: const [ClinicalField.brand],
        unrecognisedNeedsInput: const ['make'],
        qaOverride: QaOverride(
          overriddenBy: 'audiologist-7',
          overriddenAt: DateTime.utc(2026, 6, 16, 2, 30),
          fields: const [ClinicalField.brand],
          unrecognised: const ['make'],
        ),
      );
      await firestore
          .collection('devices')
          .doc('ov')
          .set(d.toFirestore(createdBy: 'audiologist-7'));
      final back = Device.fromFirestore(
          await firestore.collection('devices').doc('ov').get());

      expect(back.qaOverride, isNotNull);
      expect(back.qaOverride!.overriddenBy, 'audiologist-7');
      expect(back.qaOverride!.overriddenAt.toUtc(),
          DateTime.utc(2026, 6, 16, 2, 30));
      expect(back.qaOverride!.fields, [ClinicalField.brand]);
      expect(back.qaOverride!.unrecognised, ['make']);
    });

    test('a device with no override has a null qaOverride after round-trip',
        () async {
      const d = Device(id: 'plain', brand: 'Phonak', model: 'P90');
      await firestore
          .collection('devices')
          .doc('plain')
          .set(d.toFirestore(createdBy: 'u'));
      expect(
          Device.fromFirestore(
                  await firestore.collection('devices').doc('plain').get())
              .qaOverride,
          isNull);
    });

    test('enum fields default to unspecified when absent from the document',
        () async {
      await firestore.collection('incoming').doc('bare').set({'brand': 'X'});
      final snap = await firestore.collection('incoming').doc('bare').get();
      final d = Device.fromFirestore(snap);

      expect(d.tubing, Tubing.unspecified);
      expect(d.powerSource, PowerSource.unspecified);
      expect(d.colour, '');
      expect(d.location, '');
    });

    test('fromWire is tolerant: legacy/garbage/Unknown values → unspecified '
        'and never throw (#15)', () {
      // Existing docs, a future variant, an OCR misread, and the volunteer's
      // 'Unknown' provenance sentinel must all parse safely — the value is
      // never the "needs input" signal (that rides on needsInputFields).
      for (final junk in [null, '', 'Unknown', 'slim', 'BTE', '???']) {
        expect(Tubing.fromWire(junk), Tubing.unspecified,
            reason: 'tubing "$junk" must fall back, not throw');
        expect(PowerSource.fromWire(junk), PowerSource.unspecified,
            reason: 'powerSource "$junk" must fall back, not throw');
      }
      // The canonical wire strings parse to their variants and round-trip.
      expect(Tubing.fromWire('Slim'), Tubing.slim);
      expect(Tubing.fromWire('None'), Tubing.none);
      expect(PowerSource.fromWire('Rechargeable'), PowerSource.rechargeable);
      expect(Tubing.slim.wire, 'Slim');
      expect(PowerSource.rechargeable.wire, 'Rechargeable');
      expect(Tubing.unspecified.wire, '');
      expect(PowerSource.unspecified.wire, '');
    });

    test('Style.fromWire is tolerant: legacy/garbage/Unknown → unspecified, '
        'and round-trips its canonical wire (#15)', () {
      // Every closed-set value round-trips through its wire string.
      for (final s in Style.values) {
        expect(Style.fromWire(s.wire), s,
            reason: '${s.name} must round-trip through "${s.wire}"');
      }
      // The 'Unknown' provenance sentinel and any genuinely-garbage/empty value
      // fall back to unspecified — the value is never the "needs input" signal.
      for (final junk in [null, '', 'Unknown', 'BTE2', '???', '10']) {
        expect(Style.fromWire(junk), Style.unspecified,
            reason: 'Style "$junk" must fall back, not throw');
      }
      // Auto-healing: legacy mixed-case / padded variants recover to their
      // canonical enum rather than collapsing to unspecified and being blanked
      // on save (Kelvin, PR #90 cage-match).
      expect(Style.fromWire('ric'), Style.ric);
      expect(Style.fromWire('Ric'), Style.ric);
      expect(Style.fromWire(' BTE '), Style.bte);
      expect(Style.fromWire('cic'), Style.cic);
      // Spot-check the exact wire strings the Firestore rules read.
      expect(Style.bte.wire, 'BTE');
      expect(Style.iic.wire, 'IIC');
      expect(Style.unspecified.wire, '');
    });

    test('BatterySize.fromWire is tolerant: legacy/garbage/Unknown → '
        'unspecified, and round-trips its canonical wire (#15)', () {
      for (final b in BatterySize.values) {
        expect(BatterySize.fromWire(b.wire), b,
            reason: '${b.name} must round-trip through "${b.wire}"');
      }
      for (final junk in [null, '', 'Unknown', 'AAA', '11', 'BTE', '???']) {
        expect(BatterySize.fromWire(junk), BatterySize.unspecified,
            reason: 'BatterySize "$junk" must fall back, not throw');
      }
      // 'Rechargeable' overlaps PowerSource deliberately — it is a valid
      // battery-size value, not derived from the power field.
      expect(BatterySize.fromWire('Rechargeable'), BatterySize.rechargeable);
      // Auto-healing: legacy mixed-case / padded variants recover (Kelvin, #90).
      expect(BatterySize.fromWire('rechargeable'), BatterySize.rechargeable);
      expect(BatterySize.fromWire(' 312 '), BatterySize.size312);
      expect(BatterySize.size312.wire, '312');
      expect(BatterySize.unspecified.wire, '');
    });

    test("BatterySize.fromWire('N/A') maps to rechargeable so a rechargeable "
        "scan persists the canonical wire string (#90 cage-match)", () {
      // The confirm screen sets battery size to 'N/A' on the Power=Rechargeable
      // branch. That must translate to BatterySize.rechargeable (not blank), so
      // toFirestore emits 'Rechargeable' — the unchanged wire contract — rather
      // than silently emptying the field. (Carnot, PR #90.)
      expect(BatterySize.fromWire('N/A'), BatterySize.rechargeable);
      // The confirm screen parses the scanner's 'N/A' through fromWire when
      // building the DraftDevice; the resulting enum persists 'Rechargeable'.
      final d = Device(
        id: 'r',
        brand: 'GN Resound',
        model: 'ONE 9',
        powerSource: PowerSource.rechargeable,
        batterySize: BatterySize.fromWire('N/A'),
      );
      expect(d.batterySize, BatterySize.rechargeable);
      expect(d.toFirestore(createdBy: 'u')['batterySize'], 'Rechargeable');
    });

    test('Style/BatterySize.label shows the wire string, or "—" when '
        'unspecified (DRY display, #90 cage-match)', () {
      expect(Style.bte.label, 'BTE');
      expect(Style.unspecified.label, '—');
      expect(BatterySize.size13.label, '13');
      expect(BatterySize.rechargeable.label, 'Rechargeable');
      expect(BatterySize.unspecified.label, '—');
    });

    test('Style/BatterySize survive a toFirestore→fromFirestore round-trip '
        'and emit the unchanged wire strings (#15)', () async {
      const d = Device(
        id: 'sb',
        brand: 'Phonak',
        model: 'P90',
        type: Style.cic,
        batterySize: BatterySize.rechargeable,
      );
      final map = d.toFirestore(createdBy: 'u');
      // Wire format unchanged — what the devices/ rules' emptiness/sentinel
      // check reads.
      expect(map['type'], 'CIC');
      expect(map['batterySize'], 'Rechargeable');

      await firestore.collection('incoming').doc('sb').set(map);
      final back = Device.fromFirestore(
          await firestore.collection('incoming').doc('sb').get());
      expect(back.type, Style.cic);
      expect(back.batterySize, BatterySize.rechargeable);
    });

    test("a flagged type/batterySize:'Unknown' parses to unspecified (#15)",
        () async {
      // The volunteer flag sentinel persisted on the value field must read back
      // as unspecified — the review screen treats it as unresolved.
      await firestore.collection('incoming').doc('flagged').set({
        'brand': 'Phonak',
        'type': 'Unknown',
        'batterySize': 'Unknown',
        'needsInputFields': ['type', 'batterySize'],
      });
      final d = Device.fromFirestore(
          await firestore.collection('incoming').doc('flagged').get());
      expect(d.type, Style.unspecified);
      expect(d.batterySize, BatterySize.unspecified);
      // The flags ride on needsInputFields, not on the value.
      expect(d.needsInputFields,
          containsAll([ClinicalField.type, ClinicalField.batterySize]));
    });

    test('location is normalised (trim + uppercase) the way the confirm '
        'screen persists it', () {
      // The confirm screen does `text.trim().toUpperCase()` before building the
      // DraftDevice; assert that normalised value round-trips unchanged.
      const raw = '  b07 ';
      final normalised = raw.trim().toUpperCase();
      expect(normalised, 'B07');

      final d = Device(id: 'x', brand: 'B', model: 'M', location: normalised);
      final map = d.toFirestore(createdBy: 'u');
      expect(map['location'], 'B07');
    });
  });
}
