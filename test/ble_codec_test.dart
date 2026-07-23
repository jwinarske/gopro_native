// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
//
// Guards the BLE event wire format against drift between the encoder in
// native/src/ble_bridge.cpp and the decoder in lib/src/ffi/ble_codec.dart.
//
// The vectors are hand-encoded on purpose. Captured from the encoder they
// would drift along with it and prove nothing; written by hand they fail the
// moment either side changes alone.

import 'dart:typed_data';

import 'package:gopro_native/src/ffi/ble_codec.dart';
import 'package:test/test.dart';

Uint8List bytes(List<int> v) => Uint8List.fromList(v);

/// [0x11][correlation u64 little-endian][outcome][payload...]
Uint8List response(int id, int outcome, List<int> payload) {
  final b = BytesBuilder();
  b.addByte(0x11);
  final u64 = ByteData(8)..setUint64(0, id, Endian.little);
  b.add(u64.buffer.asUint8List());
  b.addByte(outcome);
  b.add(payload);
  return b.toBytes();
}

void main() {
  group('write request', () {
    test('decodes channel and bytes', () {
      final e = BleCodec.decode(bytes([0x10, 2, 0x20, 0x03, 0x13]));
      expect(e, isA<BleWriteRequest>());
      final w = e! as BleWriteRequest;
      expect(w.channel, BleChannel.query);
      expect(w.bytes, [0x20, 0x03, 0x13]);
    });

    test('an unknown channel is ignored rather than guessed', () {
      expect(BleCodec.decode(bytes([0x10, 99, 0x01])), isNull);
    });
  });

  group('response', () {
    test('decodes a 64-bit correlation id little-endian', () {
      // Channel query (2), leading byte 0x13 -> 0x213.
      final e = BleCodec.decode(response(0x213, 0, [0x13, 0x00, 0x08]));
      expect(e, isA<BleResponse>());
      final r = e! as BleResponse;
      expect(r.correlationId, 0x213);
      expect(r.outcome, BleOutcome.responded);
      expect(r.payload, [0x13, 0x00, 0x08]);
    });

    test('carries an empty payload for non-responded outcomes', () {
      for (final (byte, outcome) in [
        (1, BleOutcome.timedOut),
        (2, BleOutcome.canceled),
        (3, BleOutcome.rejected),
      ]) {
        final r = BleCodec.decode(response(0x101, byte, []))! as BleResponse;
        expect(r.outcome, outcome);
        expect(r.payload, isEmpty);
      }
    });

    test('a truncated header is rejected, not read past', () {
      // Nine bytes is one short of discriminator + u64 + outcome.
      expect(BleCodec.decode(bytes(List.filled(9, 0)..[0] = 0x11)), isNull);
    });

    test('an unknown outcome is ignored', () {
      expect(BleCodec.decode(response(1, 99, [])), isNull);
    });
  });

  test('ready', () {
    expect((BleCodec.decode(bytes([0x12, 1]))! as BleReadyChanged).ready, true);
    expect(
      (BleCodec.decode(bytes([0x12, 0]))! as BleReadyChanged).ready,
      false,
    );
  });

  test('push', () {
    final p =
        BleCodec.decode(bytes([0x13, 2, 0x13, 0x00, 0x08, 0x01, 0x00]))!
            as BlePush;
    expect(p.channel, BleChannel.query);
    expect(p.message, [0x13, 0x00, 0x08, 0x01, 0x00]);
  });

  test('frame error carries the reason', () {
    final f = BleCodec.decode(bytes([0x14, 0, 5]))! as BleFrameErrorEvent;
    expect(f.channel, BleChannel.command);
    // Distinguishing which framing failure occurred is the point; a single
    // "bad packet" would not tell a reader whether the stream desynchronized
    // or a stray continuation arrived.
    expect(f.error, BleFrameError.strayContinuation);
  });

  group('malformed input', () {
    test('empty and unknown discriminators are ignored', () {
      expect(BleCodec.decode(Uint8List(0)), isNull);
      // A newer native library adding an event kind must degrade to
      // "ignored" rather than killing the stream.
      expect(BleCodec.decode(bytes([0x7F, 1, 2, 3])), isNull);
    });

    test('every event kind rejects a truncated payload', () {
      for (final d in [0x10, 0x12, 0x13]) {
        expect(BleCodec.decode(bytes([d])), isNull, reason: 'kind $d');
      }
      expect(BleCodec.decode(bytes([0x14, 0])), isNull);
    });
  });

  group('correlation', () {
    test('is scoped to the characteristic', () {
      // The same leading byte on two channels denotes unrelated things.
      expect(
        BleCodec.correlationOf(BleChannel.command, 0x13),
        isNot(BleCodec.correlationOf(BleChannel.query, 0x13)),
      );
      expect(BleCodec.correlationOf(BleChannel.command, 0x13), 0x013);
      expect(BleCodec.correlationOf(BleChannel.settings, 0x13), 0x113);
      expect(BleCodec.correlationOf(BleChannel.query, 0x13), 0x213);
    });

    test('matches the id the native side reports', () {
      final r =
          BleCodec.decode(
                response(
                  BleCodec.correlationOf(BleChannel.settings, 91),
                  0,
                  [],
                ),
              )!
              as BleResponse;
      expect(r.correlationId, BleCodec.correlationOf(BleChannel.settings, 91));
    });
  });

  test('enum values mirror the native side', () {
    // These cross the FFI boundary as raw integers.
    expect(BleChannel.command.value, 0);
    expect(BleChannel.settings.value, 1);
    expect(BleChannel.query.value, 2);
    expect(BlePriority.queued.value, 0);
    expect(BlePriority.fastpass.value, 1);
    expect(BlePriority.keepAlive.value, 2);
    expect(BleOutcome.values.indexOf(BleOutcome.responded), 0);
    expect(BleOutcome.values.indexOf(BleOutcome.canceled), 2);
  });
}
