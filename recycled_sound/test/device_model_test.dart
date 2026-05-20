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
      expect(d.type, 'RIC');
      expect(d.year, '2021');
      expect(d.batterySize, '312');
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
      expect(d.type, '');
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
    test('emits all 26 fields with sentinel server timestamps', () {
      const d = Device(
        id: 'x',
        brand: 'Oticon',
        model: 'More 1',
        type: 'BTE',
        batterySize: '13',
      );
      final map = d.toFirestore(createdBy: 'user-1');

      expect(map['brand'], 'Oticon');
      expect(map['model'], 'More 1');
      expect(map['type'], 'BTE');
      expect(map['batterySize'], '13');
      expect(map['accessories'], isEmpty);
      expect(map['photos'], isEmpty);
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
      final d = Device(
        id: 'x',
        brand: 'B',
        model: 'M',
        createdAt: created,
      );
      final map = d.toFirestore(createdBy: 'user-1');
      expect(map['createdAt'], isA<Timestamp>());
      expect(
        (map['createdAt'] as Timestamp).toDate().toUtc(),
        created,
      );
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
      expect(
        mocks.map((m) => m.brand).toSet(),
        {'Phonak', 'Oticon', 'Signia', 'GN Resound', 'Widex'},
      );
    });
  });

  group('DraftDevice.toDevice', () {
    test('promotes a draft to a Device, pinning the Firestore id', () {
      const draft = DraftDevice(
        brand: 'Oticon',
        model: 'More 1',
        type: 'BTE',
        batterySize: '13',
        qaStatus: QaStatus.pendingQa,
        status: DeviceStatus.donated,
        photos: ['gs://b/scan.jpg'],
      );

      final device = draft.toDevice(id: 'doc-123');

      expect(device.id, 'doc-123');
      expect(device.brand, 'Oticon');
      expect(device.model, 'More 1');
      expect(device.type, 'BTE');
      expect(device.batterySize, '13');
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
  });
}
