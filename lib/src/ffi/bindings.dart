// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
// bindings.dart — lookupFunction wrappers for native/include/gopro_bridge.h.

import 'dart:ffi';

import '../internal/library_loader.dart';

class GoProBindings {
  GoProBindings._();

  static final DynamicLibrary _lib = loadGoProNc();

  static final _init = _lib
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('gopro_bridge_init');

  static final _create = _lib
      .lookupFunction<
        Pointer<Void> Function(Int64, Uint16),
        Pointer<Void> Function(int, int)
      >('gopro_discovery_create');

  static final _destroy = _lib
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('gopro_discovery_destroy');

  static final _rescan = _lib
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('gopro_discovery_rescan');

  static final _setTimeout = _lib
      .lookupFunction<
        Void Function(Pointer<Void>, Int32),
        void Function(Pointer<Void>, int)
      >('gopro_discovery_set_timeout');

  static bool _initialized = false;

  /// Idempotent — the native side tolerates repeat calls, but there is no
  /// reason to pay for them.
  static void init() {
    if (_initialized) return;
    _init(NativeApi.initializeApiDLData);
    _initialized = true;
  }

  static Pointer<Void> create(int eventsPort, int vid) =>
      _create(eventsPort, vid);
  static void destroy(Pointer<Void> h) => _destroy(h);
  static void rescan(Pointer<Void> h) => _rescan(h);
  static void setTimeout(Pointer<Void> h, int ms) => _setTimeout(h, ms);
}
