// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
//
// ble_codec.dart — decodes the events posted by the BLE bridge.
//
// Wire format is defined in native/include/ble_bridge.h. The first octet is a
// discriminator; multi-byte integers are little-endian.
//
//   0x10 write     [0x10][channel u8][bytes...]
//   0x11 response  [0x11][correlation u64][outcome u8][bytes...]
//   0x12 ready     [0x12][ready u8]
//   0x13 push      [0x13][channel u8][bytes...]
//   0x14 frame     [0x14][channel u8][FeedResult u8]
//
// DEBUG NOTE: this and the encoder in native/src/ble_bridge.cpp are one format
// written in two places. Drift is silent corruption, not a compile error, so
// test/ble_codec_test.dart freezes hand-encoded vectors rather than capturing
// them from live output. Vectors captured from the encoder would drift along
// with it and prove nothing.

import 'dart:typed_data';

/// The Control and Query characteristic pairs. Mirrors `gp::ble::Channel`.
enum BleChannel {
  command(0), // b5f90072 write, b5f90073 notify
  settings(1), // b5f90074 write, b5f90075 notify
  query(2); // b5f90076 write, b5f90077 notify

  const BleChannel(this.value);
  final int value;

  static BleChannel? fromByte(int b) {
    for (final c in BleChannel.values) {
      if (c.value == b) return c;
    }
    return null;
  }
}

/// Mirrors `gp::ble::Priority`.
enum BlePriority {
  /// Waits for the ready gate and serializes against other queued commands.
  queued(0),

  /// Ignores the ready gate. For commands the camera accepts while busy,
  /// above all stopping the shutter.
  fastpass(1),

  /// Ignores the gate and the serialization, and jumps the queue.
  keepAlive(2);

  const BlePriority(this.value);
  final int value;
}

/// Mirrors `gp::ble::Outcome`.
enum BleOutcome { responded, timedOut, canceled, rejected }

/// Mirrors `gp::ble::FeedResult`, minus the two success cases which never
/// reach Dart.
enum BleFrameError {
  needMore,
  complete,
  emptyPacket,
  truncatedHeader,
  reservedHeader,
  strayContinuation,
  overflow,
  zeroLength,
}

sealed class BleEvent {
  const BleEvent();
}

/// Write these bytes to [channel]'s write characteristic.
class BleWriteRequest extends BleEvent {
  const BleWriteRequest(this.channel, this.bytes);
  final BleChannel channel;
  final Uint8List bytes;
}

/// A submitted command completed.
class BleResponse extends BleEvent {
  const BleResponse(this.correlationId, this.outcome, this.payload);
  final int correlationId;
  final BleOutcome outcome;

  /// The reassembled response, empty unless [outcome] is
  /// [BleOutcome.responded].
  final Uint8List payload;
}

/// The ready gate opened or closed.
class BleReadyChanged extends BleEvent {
  const BleReadyChanged(this.ready);
  final bool ready;
}

/// A reassembled message nobody was waiting for: a registered status or
/// setting push.
class BlePush extends BleEvent {
  const BlePush(this.channel, this.message);
  final BleChannel channel;
  final Uint8List message;
}

/// A notification was rejected by the framing layer.
class BleFrameErrorEvent extends BleEvent {
  const BleFrameErrorEvent(this.channel, this.error);
  final BleChannel channel;
  final BleFrameError error;
}

class BleCodec {
  BleCodec._();

  static const int _write = 0x10;
  static const int _response = 0x11;
  static const int _ready = 0x12;
  static const int _push = 0x13;
  static const int _frameError = 0x14;

  /// Decodes one event, or null for an unrecognized discriminator or a
  /// truncated payload.
  ///
  /// Returning null rather than throwing means a newer native library adding
  /// an event kind degrades to "ignored" instead of killing the stream.
  static BleEvent? decode(Uint8List data) {
    if (data.isEmpty) return null;
    switch (data[0]) {
      case _write:
        if (data.length < 2) return null;
        final channel = BleChannel.fromByte(data[1]);
        if (channel == null) return null;
        return BleWriteRequest(channel, Uint8List.sublistView(data, 2));

      case _response:
        // discriminator + u64 + outcome
        if (data.length < 10) return null;
        final id = ByteData.sublistView(data).getUint64(1, Endian.little);
        final outcomeByte = data[9];
        if (outcomeByte >= BleOutcome.values.length) return null;
        return BleResponse(
          id,
          BleOutcome.values[outcomeByte],
          Uint8List.sublistView(data, 10),
        );

      case _ready:
        if (data.length < 2) return null;
        return BleReadyChanged(data[1] != 0);

      case _push:
        if (data.length < 2) return null;
        final channel = BleChannel.fromByte(data[1]);
        if (channel == null) return null;
        return BlePush(channel, Uint8List.sublistView(data, 2));

      case _frameError:
        if (data.length < 3) return null;
        final channel = BleChannel.fromByte(data[1]);
        if (channel == null || data[2] >= BleFrameError.values.length) {
          return null;
        }
        return BleFrameErrorEvent(channel, BleFrameError.values[data[2]]);

      default:
        return null;
    }
  }

  /// The correlation id the session will assign to a payload submitted on
  /// [channel]. Mirrors `gp::ble::correlation_of`.
  ///
  /// The leading byte is a command id, query command id, or setting id, and
  /// is only unique within a characteristic, so the channel forms the high
  /// bits.
  static int correlationOf(BleChannel channel, int leadingByte) =>
      (channel.value << 8) | leadingByte;
}
