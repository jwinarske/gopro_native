// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
// Connect to a camera over BLE and read its busy and encoding statuses.
//
//   dart run example/ble_status.dart
//
// The camera has to be in pairing mode the first time, and the LE bond has to
// be to this host. A Classic link to the same camera suppresses LE
// advertising, so the transport disconnects one if it finds it.

import 'dart:async';
import 'dart:io';

import 'package:gopro_native/gopro_native.dart';

Future<void> main(List<String> args) async {
  final transport = await GoProBleTransport.start();

  final GoProBleCamera camera;
  try {
    stdout.writeln('bringing up the link...');
    camera = await transport.connect();
  } on GoProBleException catch (e) {
    stderr.writeln(e);
    await transport.close();
    exitCode = 1;
    return;
  }

  stdout.writeln('ready: ${camera.address}');

  camera.readyChanges.listen(
    (r) => stdout.writeln('  ready gate ${r ? 'open' : 'closed'}'),
  );
  camera.pushes.listen(
    (p) => stdout.writeln('  push on ${p.channel.name}: ${_hex(p.message)}'),
  );
  camera.faults.listen((f) => stderr.writeln('  fault: $f'));
  camera.linkChanges.listen((l) async {
    stdout.writeln('  link ${l.name}');
    // Registered subscriptions do not survive a camera-side disconnect.
    // Nothing re-sends them, so a return to up is the cue to do it here.
    if (l == CameraLink.up) {
      final again = await camera.send(BleChannel.query, [0x53, 8, 10]);
      stdout.writeln('  re-registered ${again.outcome.name}');
    }
  });

  // 8 is BUSY and 10 is ENCODING. Together they are the ready gate the
  // session applies to every queued command.
  final response = await camera.queryStatuses([8, 10]);
  stdout.writeln('query ${response.outcome.name}: ${_hex(response.payload)}');

  // Register for updates to the same two, so the gate tracks the camera
  // rather than being polled.
  final registered = await camera.send(BleChannel.query, [0x53, 8, 10]);
  stdout.writeln('register ${registered.outcome.name}');

  stdout.writeln('watching for 30 s; ctrl-c to stop early');
  await Future<void>.delayed(const Duration(seconds: 30));

  await camera.close();
  await transport.close();
}

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join(' ');
