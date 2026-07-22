// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
// discovery.dart — public Dart API over the native discovery bridge.

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'ffi/bindings.dart';
import 'ffi/codec.dart';
import 'ffi/types.dart';

/// Watches for GoPro cameras attached over USB.
///
/// Events arrive on a native worker thread via `Dart_PostCObject_DL` and are
/// delivered here without Dart pumping anything — see the note in
/// `native/include/gopro_bridge.h`.
///
/// ```dart
/// final d = await GoProDiscovery.start();
/// await for (final cam in d.ready) {
///   print('${cam.serial} reachable at ${cam.baseUri}');
/// }
/// ```
class GoProDiscovery {
  GoProDiscovery._(this._handle, this._port, this._sub);

  Pointer<Void> _handle;
  final ReceivePort _port;
  final StreamSubscription<dynamic> _sub;

  final _updates = StreamController<GoProCamera>.broadcast();
  final _departures = StreamController<GoProCamera>.broadcast();
  final _current = <String, GoProCamera>{};

  /// Every state change, including cameras that are not yet reachable. Use
  /// this to drive a UI that shows progress; use [ready] to actually connect.
  Stream<GoProCamera> get updates => _updates.stream;

  /// Cameras that have reached [Readiness.l3Ready] — reachable on
  /// [GoProCamera.baseUri]. A camera appears here at most once per
  /// attachment.
  Stream<GoProCamera> get ready =>
      _updates.stream.where((c) => c.isReady).distinct(
            (a, b) => a.sysfsName == b.sysfsName,
          );

  /// Cameras that have been unplugged.
  Stream<GoProCamera> get departures => _departures.stream;

  /// Snapshot of every camera currently attached, in any readiness state.
  List<GoProCamera> get cameras => List.unmodifiable(_current.values);

  /// Starts discovery. Completes once the native worker is running, so an
  /// empty [cameras] afterwards genuinely means "none attached" rather than
  /// "not looking yet".
  ///
  /// [vid] overrides the USB vendor filter for testing; 0 means GoPro
  /// (0x2672). [readinessTimeout] bounds how long a camera may sit settling
  /// before it is abandoned — it is still reported, with [GoProCamera
  /// .readiness] showing how far it got.
  ///
  /// Throws [StateError] if libusb cannot initialize or the platform lacks
  /// hotplug support.
  static Future<GoProDiscovery> start({
    int vid = 0,
    Duration readinessTimeout = const Duration(seconds: 10),
  }) async {
    GoProBindings.init();

    final port = ReceivePort();
    final handle = GoProBindings.create(port.sendPort.nativePort, vid);
    if (handle == nullptr) {
      port.close();
      throw StateError(
        'gopro_discovery_create failed: libusb could not initialize, or this '
        'platform has no hotplug support.',
      );
    }
    GoProBindings.setTimeout(handle, readinessTimeout.inMilliseconds);

    final started = Completer<void>();
    late final GoProDiscovery discovery;

    final sub = port.listen((message) {
      if (message is! Uint8List) return;
      final event = GlazeCodec.decodeEvent(message);
      if (event == null) return;

      switch (event.kind) {
        case EventKind.sentinel:
          if (!started.isCompleted) started.complete();
        case EventKind.update:
          discovery._onUpdate(event.camera!);
        case EventKind.left:
          discovery._onLeft(event.camera!);
      }
    });

    discovery = GoProDiscovery._(handle, port, sub);
    await started.future;
    return discovery;
  }

  void _onUpdate(GoProCamera c) {
    _current[c.sysfsName] = c;
    if (!_updates.isClosed) _updates.add(c);
  }

  void _onLeft(GoProCamera c) {
    _current.remove(c.sysfsName);
    if (!_departures.isClosed) _departures.add(c);
  }

  /// Waits for the first camera to become reachable, or null on timeout.
  Future<GoProCamera?> firstReady({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    for (final c in _current.values) {
      if (c.isReady) return c;
    }
    try {
      return await ready.first.timeout(timeout);
    } on TimeoutException {
      return null;
    }
  }

  /// Forces a re-scan. Rarely needed — devices already attached at [start]
  /// are reported automatically — but useful after suspend/resume.
  void rescan() {
    if (_handle != nullptr) GoProBindings.rescan(_handle);
  }

  /// Stops the native worker and releases resources. Idempotent.
  Future<void> close() async {
    if (_handle != nullptr) {
      // Joins the worker thread, so no further posts can race the port close.
      GoProBindings.destroy(_handle);
      _handle = nullptr;
    }
    await _sub.cancel();
    _port.close();
    await _updates.close();
    await _departures.close();
  }
}
