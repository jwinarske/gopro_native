// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
// Scan for networks the camera can see, and optionally join one.
//
//   dart run example/wifi_scan.dart                     # scan only
//   dart run example/wifi_scan.dart "My Network"        # join a known one
//
// Joining a new network needs its passphrase. Pass it on stdin rather than
// as an argument: arguments are visible in the process list to every user on
// the machine, and land in shell history.
//
//   read -rs PASS && echo "$PASS" | dart run example/wifi_scan.dart "SSID" -

import 'dart:convert';
import 'dart:io';

import 'package:gopro_native/gopro_native.dart';

Future<void> main(List<String> args) async {
  final ssid = args.isNotEmpty ? args[0] : null;
  final fromStdin = args.length > 1 && args[1] == '-';

  final transport = await GoProBleTransport.start();
  if (transport.cameras.isEmpty) {
    stderr.writeln('no paired camera is advertising');
    await transport.close();
    exitCode = 1;
    return;
  }

  final camera = await transport.connect();
  final net = NetworkClient(camera);
  net.provisioningStates.listen((s) => stdout.writeln('  ${s.name}'));

  final scan = await net.scan();
  stdout.writeln('${scan.totalEntries} networks (scan ${scan.scanId})');
  final aps = await net.accessPoints(scan);
  for (final a in aps) {
    stdout.writeln('  $a');
  }

  if (ssid != null) {
    final known = aps.where((a) => a.ssid == ssid && a.isConfigured).isNotEmpty;
    if (known) {
      stdout.writeln('joining $ssid (already provisioned)...');
      await net.connect(ssid);
    } else if (fromStdin) {
      // Read once and do not echo, log, or keep it.
      final password =
          (stdin.transform(utf8.decoder).transform(const LineSplitter())).first;
      stdout.writeln('joining $ssid...');
      await net.connectNew(ssid, await password);
    } else {
      stderr.writeln(
        '$ssid is not provisioned on the camera. Re-run with "-" as the '
        'second argument and pipe the passphrase in on stdin.',
      );
      exitCode = 1;
    }
    if (exitCode == 0) stdout.writeln('joined');
  }

  await camera.close();
  await transport.close();
}
