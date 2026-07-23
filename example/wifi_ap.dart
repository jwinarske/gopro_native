// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
// Turn on the camera's Wi-Fi access point and report how to join it.
//
//   dart run example/wifi_ap.dart [BLE-address]
//
// Joining is left to the host. Pass --nmcli to have NetworkManager do it.

import 'dart:io';

import 'package:gopro_native/gopro_native.dart';

Future<void> main(List<String> args) async {
  final useNmcli = args.contains('--nmcli');
  final address = args.where((a) => !a.startsWith('--')).firstOrNull;

  final transport = await GoProBleTransport.start();
  if (transport.cameras.isEmpty) {
    stderr.writeln('no paired camera is advertising');
    await transport.close();
    exitCode = 1;
    return;
  }
  stdout.writeln('cameras: ${transport.cameras}');

  final camera = await transport.connect(address: address);
  stdout.writeln('connected to ${camera.address}');

  final ap = GoProAccessPoint(
    camera,
    controller: useNmcli
        ? const NmcliWifiController(timeout: Duration(seconds: 30))
        : ManualWifiController(onInstruction: stdout.writeln),
  );

  await ap.setEnabled(enabled: true);
  final creds = await ap.credentials();
  stdout.writeln('access point up: $creds');

  // The passphrase is not printed. It is on `creds` for a caller that needs
  // it, and the point of the manual controller is that a human already has
  // the camera in hand.
  await ap.controller.join(creds);

  stdout.writeln('ctrl-c to leave the access point on, or wait 30 s');
  await Future<void>.delayed(const Duration(seconds: 30));

  await ap.controller.leave(creds);
  await ap.setEnabled(enabled: false);
  stdout.writeln('access point off');

  await camera.close();
  await transport.close();
}
