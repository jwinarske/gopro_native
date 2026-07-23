// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
// Report what the camera can livestream, and optionally configure a stream.
//
//   dart run example/livestream.dart                    # read only
//   dart run example/livestream.dart rtmp://host/app/key
//
// Configuring needs the camera already on a network with a route to the
// server; putting it there is network management. Nothing here starts the
// shutter — that is one call away and yours to make deliberately.

import 'dart:io';

import 'package:gopro_native/gopro_native.dart';
import 'package:gopro_native/proto/livestream.dart';

Future<void> main(List<String> args) async {
  final url = args.where((a) => a.startsWith('rtmp')).firstOrNull;

  final transport = await GoProBleTransport.start();
  if (transport.cameras.isEmpty) {
    stderr.writeln('no paired camera is advertising');
    await transport.close();
    exitCode = 1;
    return;
  }

  final camera = await transport.connect();
  final live = LivestreamClient(camera);

  final s = await live.status();
  stdout.writeln(
    'state:   ${s.hasLiveStreamStatus() ? s.liveStreamStatus.name : "?"}',
  );
  stdout.writeln(
    'bitrate: ${s.liveStreamMinimumStreamBitrate}'
    '..${s.liveStreamMaximumStreamBitrate} Kbps',
  );
  stdout.writeln(
    'sizes:   '
    '${s.liveStreamWindowSizeSupportedArray.map((w) => w.name).toList()}',
  );
  stdout.writeln(
    'lenses:  '
    '${s.liveStreamLensSupportedArray.map((l) => l.name).toList()}',
  );

  if (url != null) {
    // The URL usually embeds a stream key, so it is not echoed.
    stdout.writeln('configuring...');
    await live.configure(url: url, windowSize: EnumWindowSize.WINDOW_SIZE_1080);
    final ready = await live.waitUntilReady();
    stdout.writeln('ready: ${ready.liveStreamStatus.name}');
    stdout.writeln('call live.start() to begin streaming');
  }

  await camera.close();
  await transport.close();
}
