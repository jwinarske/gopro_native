// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
// Guards the binary wire format against drift between
// glz::meta<gp::CameraRecord> (native/include/gopro_types.h) and the read
// order in lib/src/ffi/codec.dart.
//
// These vectors are hand-encoded rather than captured from the native side on
// purpose: if someone reorders the C++ meta fields, the native library and
// codec.dart drift *together* when tested against live output, and the bug
// only surfaces as garbage at runtime. A frozen vector catches it at test time.

import 'dart:convert';
import 'dart:typed_data';

import 'package:gopro_native/src/ffi/codec.dart';
import 'package:gopro_native/src/ffi/types.dart';
import 'package:test/test.dart';

/// Builds a payload in glz::meta declaration order.
Uint8List buildRecord({
  int kind = 0x01,
  int vid = 0x2672,
  int pid = 0x0059,
  int bus = 2,
  int address = 5,
  String sysfsName = '2-1',
  String serial = 'C3501234567123',
  int serialSource = 2, // sysfs
  String ip = '172.21.123.51',
  String netdev = 'enp17s0u1',
  String netdevFirstSeen = 'eth0',
  bool netdevRenamed = true,
  String linkState = 'up',
  String hostIp = '172.21.123.52',
  int readiness = 4, // l3Ready
  bool hasCdc = true,
  int elapsedMs = 754,
}) {
  final out = BytesBuilder();
  void u8(int v) => out.addByte(v);
  void u16(int v) {
    final b = ByteData(2)..setUint16(0, v, Endian.little);
    out.add(b.buffer.asUint8List());
  }

  void u32(int v) {
    final b = ByteData(4)..setUint32(0, v, Endian.little);
    out.add(b.buffer.asUint8List());
  }

  // uint32 length prefix -- matches encode_field(const std::string&) in
  // glaze_meta.h. Other implementations of this encoding use uint64; getting
  // the width wrong is exactly the drift these vectors exist to catch.
  void str(String s) {
    final bytes = utf8.encode(s);
    final b = ByteData(4)..setUint32(0, bytes.length, Endian.little);
    out.add(b.buffer.asUint8List());
    out.add(bytes);
  }

  u8(kind);
  u16(vid);
  u16(pid);
  u8(bus);
  u8(address);
  str(sysfsName);
  str(serial);
  u8(serialSource);
  str(ip);
  str(netdev);
  str(netdevFirstSeen);
  u8(netdevRenamed ? 1 : 0);
  str(linkState);
  str(hostIp);
  u8(readiness);
  u8(hasCdc ? 1 : 0);
  u32(elapsedMs);
  return out.toBytes();
}

void main() {
  test('decodes a full camera record in meta declaration order', () {
    final event = GlazeCodec.decodeEvent(buildRecord())!;
    expect(event.kind, EventKind.update);

    final c = event.camera!;
    expect(c.vid, 0x2672);
    expect(c.pid, 0x0059);
    expect(c.bus, 2);
    expect(c.address, 5);
    expect(c.sysfsName, '2-1');
    expect(c.serial, 'C3501234567123');
    expect(c.serialSource, SerialSource.sysfs);
    expect(c.ip, '172.21.123.51');
    expect(c.netdev, 'enp17s0u1');
    expect(c.netdevFirstSeen, 'eth0');
    expect(c.netdevRenamed, isTrue);
    expect(c.linkState, 'up');
    expect(c.hostIp, '172.21.123.52');
    expect(c.readiness, Readiness.l3Ready);
    expect(c.hasCdc, isTrue);
    expect(c.elapsed, const Duration(milliseconds: 754));
    expect(c.isReady, isTrue);
    expect(c.baseUri, Uri.parse('http://172.21.123.51:8080/'));
  });

  test('sentinel carries no payload', () {
    final event = GlazeCodec.decodeEvent(Uint8List.fromList([0x00]))!;
    expect(event.kind, EventKind.sentinel);
    expect(event.camera, isNull);
  });

  test('departure decodes the cached record', () {
    final event = GlazeCodec.decodeEvent(
      buildRecord(kind: 0x02, readiness: 0),
    )!;
    expect(event.kind, EventKind.left);
    expect(event.camera!.readiness, Readiness.absent);
    expect(event.camera!.isReady, isFalse);
    expect(event.camera!.baseUri, isNull);
  });

  test('empty strings round-trip', () {
    final event = GlazeCodec.decodeEvent(
      buildRecord(netdev: '', hostIp: '', linkState: '', netdevFirstSeen: ''),
    )!;
    expect(event.camera!.netdev, isEmpty);
    expect(event.camera!.hostIp, isEmpty);
  });

  test('unknown discriminator is ignored, not fatal', () {
    // A newer native library adding an event kind must degrade to "ignored"
    // rather than killing the event stream.
    expect(GlazeCodec.decodeEvent(Uint8List.fromList([0x7f, 1, 2, 3])), isNull);
    expect(GlazeCodec.decodeEvent(Uint8List(0)), isNull);
  });

  test('out-of-range string length is reported as drift, not an OOM', () {
    final bytes = buildRecord();
    // Corrupt the sysfsName length prefix. Offset 1 + 2+2+1+1 = 7.
    final view = ByteData.sublistView(bytes);
    view.setUint32(7, 0xFFFFFF, Endian.little);
    expect(
      () => GlazeCodec.decodeEvent(bytes),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('drifted'),
        ),
      ),
    );
  });

  test('unknown enum values clamp instead of throwing', () {
    final event = GlazeCodec.decodeEvent(
      buildRecord(serialSource: 99, readiness: 99),
    )!;
    expect(event.camera!.serialSource, SerialSource.none);
    expect(event.camera!.readiness, Readiness.absent);
  });
}
