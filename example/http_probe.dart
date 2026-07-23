// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
// Wait for a camera on USB, then exercise the HTTP command surface.
//
//   dart run example/http_probe.dart
//
// Read-only apart from nothing: every command here reports state. Nothing
// starts the shutter, renames the camera, or deletes anything.

import 'dart:io';

import 'package:gopro_native/gopro_native.dart';

Future<void> main() async {
  final discovery = await GoProDiscovery.start();
  stdout.writeln('waiting for a camera on USB...');

  final camera =
      discovery.cameras.where((c) => c.isReady).firstOrNull ??
      await discovery.ready.first;
  stdout.writeln('${camera.serial} at ${camera.baseUri}');

  final gopro = GoProCommands(GoProHttp(camera.baseUri!));

  Future<void> show(String label, Future<Object?> Function() f) async {
    try {
      stdout.writeln('  $label: ${await f()}');
    } on GoProHttpException catch (e) {
      stdout.writeln('  $label: HTTP ${e.statusCode} ${e.body}');
    } catch (e) {
      stdout.writeln('  $label: $e');
    }
  }

  await show('api version', gopro.getApiVersion);
  await show('name', gopro.getCameraName);
  await show('info', gopro.getCameraInfo);
  await show('date/time', gopro.getDateTime);
  await show('last captured', gopro.getLastCapturedMedia);

  final state = await gopro.getCameraState();
  final status = state['status'] as Map<String, Object?>? ?? const {};
  final settings = state['settings'] as Map<String, Object?>? ?? const {};
  stdout.writeln(
    '  state: ${status.length} statuses, ${settings.length} settings',
  );
  // 8 is BUSY and 10 is ENCODING, the same pair the BLE ready gate uses.
  stdout.writeln('  busy=${status['8']} encoding=${status['10']}');

  final media = await gopro.getMediaList();
  final dirs = media['media'] as List<Object?>? ?? const [];
  var files = 0;
  for (final d in dirs) {
    files += ((d as Map<String, Object?>)['fs'] as List<Object?>? ?? []).length;
  }
  stdout.writeln('  media: ${dirs.length} directories, $files files');

  gopro.close();
  await discovery.close();
}
