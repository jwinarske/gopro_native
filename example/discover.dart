// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
// Watch for GoPro cameras and report each one once it is actually reachable.
//
//   dart run example/discover.dart
//
// If the library is not found, build it and point GOPRO_NC_LIB at the result:
//   cmake -S native -B build && cmake --build build
//   GOPRO_NC_LIB=$PWD/build/libgopro_nc.so dart run example/discover.dart

import 'dart:async';
import 'dart:io';

import 'package:gopro_native/gopro_native.dart';

Future<void> main(List<String> args) async {
  final discovery = await GoProDiscovery.start();
  stdout.writeln('discovery started; ctrl-c to stop');

  final attached = discovery.cameras;
  if (attached.isEmpty) {
    stdout.writeln('no cameras attached yet — plug one in');
  }

  discovery.updates.listen((c) {
    stdout.writeln(
      '  [${c.elapsed.inMilliseconds.toString().padLeft(5)} ms] '
      '${c.sysfsName} ${c.readiness.name}'
      '${c.netdev.isEmpty ? '' : ' netdev=${c.netdev}'}'
      '${c.netdevRenamed ? ' (RENAMED from ${c.netdevFirstSeen})' : ''}',
    );
  });

  discovery.ready.listen((c) async {
    stdout.writeln('= ready: $c');
    stdout.writeln('  serial from ${c.serialSource.name}');
    if (c.netdevRenamed) {
      stdout.writeln(
        '  NOTE: interface was renamed from ${c.netdevFirstSeen} to '
        '${c.netdev} during bring-up. Any name cached at arrival is stale — '
        'see the DEBUG NOTE in the README.',
      );
    }
    await _probe(c);
  });

  discovery.departures.listen((c) {
    stdout.writeln('- left: ${c.sysfsName} (${c.serial})');
  });

  ProcessSignal.sigint.watch().listen((_) async {
    stdout.writeln('\nstopping');
    await discovery.close();
    exit(0);
  });

  await Completer<void>().future;
}

Future<void> _probe(GoProCamera c) async {
  final uri = c.baseUri?.resolve('gopro/version');
  if (uri == null) return;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final req = await client.getUrl(uri);
    final res = await req.close();
    final body = await res.transform(const SystemEncoding().decoder).join();
    stdout.writeln('  GET $uri -> ${res.statusCode} ${body.trim()}');
  } catch (e) {
    stdout.writeln('  GET $uri failed: $e');
  } finally {
    client.close(force: true);
  }
}
