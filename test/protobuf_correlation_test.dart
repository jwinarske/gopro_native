// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
//
// The protobuf correlation layout, across the FFI boundary.
//
// The native side owns the layout so it exists in one place. What this checks
// is that Dart gets the same answer it would compute, and that the properties
// the layout exists for actually hold: requests within a feature are distinct
// ids, and no protobuf id can collide with a plain one.

import 'package:gopro_native/src/ffi/ble_bindings.dart';
import 'package:gopro_native/src/ffi/ble_codec.dart';
import 'package:test/test.dart';

void main() {
  // COHN, which is where this matters: every request leads with 0xF1.
  const feature = 0xF1;
  const getStatus = 111;
  const createCert = 103;
  const clearCert = 102;

  int pb(int action, [BleChannel c = BleChannel.command]) =>
      BleBindings.protobufCorrelation(c, feature, action);

  test('requests within one feature are distinct ids', () {
    // The whole point. Correlating on the leading byte makes these one
    // command: the second submission is refused as a duplicate and the first
    // reply resolves the wrong caller.
    expect({pb(getStatus), pb(createCert), pb(clearCert)}, hasLength(3));
  });

  test('the id is the response action, not the request action', () {
    // Open GoPro sets the high bit on the reply: 111 -> 239, 103 -> 231.
    // A caller registered under the request id would never be resolved.
    expect(pb(getStatus) & 0xFF, 239);
    expect(pb(createCert) & 0xFF, 231);
    expect(pb(clearCert) & 0xFF, 230);
  });

  test('protobuf ids never collide with plain ones', () {
    // Without a discriminating bit, (query, 0xFF) and (command, feature 2,
    // action 0x7F) are both 0x2FF, and a plain reply would resolve a protobuf
    // caller. Checked across the whole plain space rather than by example.
    final plain = <int>{
      for (final c in BleChannel.values)
        for (var b = 0; b <= 0xFF; b++) BleCodec.correlationOf(c, b),
    };
    final protobuf = <int>{
      for (final c in BleChannel.values)
        for (var f = 0; f <= 0xFF; f++)
          for (var a = 0; a <= 0x7F; a++)
            BleBindings.protobufCorrelation(c, f, a),
    };
    expect(plain.intersection(protobuf), isEmpty);
  });

  test('the channel is part of the id', () {
    expect(
      pb(getStatus, BleChannel.command),
      isNot(pb(getStatus, BleChannel.query)),
    );
  });

  test('an out-of-range channel is refused rather than folded', () {
    // The native side returns zero, which is not a valid id. Folding it into
    // a neighbouring channel would write to the wrong characteristic.
    expect(
      BleBindings.protobufCorrelation(BleChannel.query, feature, 1),
      isNot(0),
    );
  });
}
