// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
//
// ble_bindings.dart — lookupFunction wrappers for native/include/ble_bridge.h
// and native/include/link_bridge.h.

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../internal/library_loader.dart';
import 'ble_codec.dart';
import 'link_types.dart';

class BleBindings {
  BleBindings._();

  static final DynamicLibrary _lib = loadGoProNc();

  // ── Session ───────────────────────────────────────────────────────────

  static final _create = _lib
      .lookupFunction<
        Pointer<Void> Function(Int64, Uint32, Uint32, Uint32),
        Pointer<Void> Function(int, int, int, int)
      >('gopro_ble_create');

  static final _destroy = _lib
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('gopro_ble_destroy');

  static final _feed = _lib
      .lookupFunction<
        Void Function(Pointer<Void>, Uint8, Pointer<Uint8>, Int32, Uint64),
        void Function(Pointer<Void>, int, Pointer<Uint8>, int, int)
      >('gopro_ble_feed');

  static final _submit = _lib
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Uint8,
          Pointer<Uint8>,
          Int32,
          Uint8,
          Uint64,
        ),
        int Function(Pointer<Void>, int, Pointer<Uint8>, int, int, int)
      >('gopro_ble_submit');

  static final _tick = _lib
      .lookupFunction<
        Void Function(Pointer<Void>, Uint64),
        void Function(Pointer<Void>, int)
      >('gopro_ble_tick');

  static final _setAttPayload = _lib
      .lookupFunction<
        Void Function(Pointer<Void>, Uint32),
        void Function(Pointer<Void>, int)
      >('gopro_ble_set_att_payload');

  static final _disconnect = _lib
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('gopro_ble_disconnect');

  static final _ready = _lib
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('gopro_ble_ready');

  /// Every duration may be zero to accept the native default. [writeTimeout]
  /// bounds the wait for a response; [queueTimeout] bounds the wait before
  /// that, while a command is held behind the ready gate.
  static Pointer<Void> create(
    int eventsPort, {
    Duration keepAlive = Duration.zero,
    Duration writeTimeout = Duration.zero,
    Duration queueTimeout = Duration.zero,
  }) {
    return _create(
      eventsPort,
      keepAlive.inMilliseconds,
      writeTimeout.inMilliseconds,
      queueTimeout.inMilliseconds,
    );
  }

  static void destroy(Pointer<Void> h) => _destroy(h);
  static void tick(Pointer<Void> h, int nowMs) => _tick(h, nowMs);
  static void setAttPayload(Pointer<Void> h, int bytes) =>
      _setAttPayload(h, bytes);
  static void disconnect(Pointer<Void> h) => _disconnect(h);
  static bool ready(Pointer<Void> h) => _ready(h) != 0;

  /// Copies `bytes` into native memory for the duration of the call. The
  /// session copies anything it retains, so the buffer is freed immediately.
  static void feed(
    Pointer<Void> h,
    BleChannel channel,
    List<int> bytes,
    int nowMs,
  ) {
    if (bytes.isEmpty) return;
    final buf = calloc<Uint8>(bytes.length);
    try {
      buf.asTypedList(bytes.length).setAll(0, bytes);
      _feed(h, channel.value, buf, bytes.length, nowMs);
    } finally {
      calloc.free(buf);
    }
  }

  /// Returns false if a command with the same correlation id is already
  /// outstanding.
  static bool submit(
    Pointer<Void> h,
    BleChannel channel,
    List<int> payload,
    BlePriority priority,
    int nowMs,
  ) {
    if (payload.isEmpty) return false;
    final buf = calloc<Uint8>(payload.length);
    try {
      buf.asTypedList(payload.length).setAll(0, payload);
      return _submit(
            h,
            channel.value,
            buf,
            payload.length,
            priority.value,
            nowMs,
          ) !=
          0;
    } finally {
      calloc.free(buf);
    }
  }

  // ── Link state machine ────────────────────────────────────────────────

  static final _linkCreate = _lib
      .lookupFunction<
        Pointer<Void> Function(Uint32, Uint32, Uint32, Uint32, Uint32, Uint32),
        Pointer<Void> Function(int, int, int, int, int, int)
      >('gopro_link_create');

  static final _linkDestroy = _lib
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('gopro_link_destroy');

  static final _linkUpdate = _lib
      .lookupFunction<
        Uint32 Function(Pointer<Void>, Uint32, Uint32, Uint32, Uint32, Uint64),
        int Function(Pointer<Void>, int, int, int, int, int)
      >('gopro_link_update');

  static final _linkRetryAt = _lib
      .lookupFunction<
        Uint64 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('gopro_link_retry_at');

  static final _linkDetail = _lib
      .lookupFunction<
        Pointer<Utf8> Function(Pointer<Void>),
        Pointer<Utf8> Function(Pointer<Void>)
      >('gopro_link_detail');

  static final _linkNoteFailure = _lib
      .lookupFunction<
        Void Function(Pointer<Void>, Uint64),
        void Function(Pointer<Void>, int)
      >('gopro_link_note_failure');

  static final _linkAttempts = _lib
      .lookupFunction<
        Uint32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('gopro_link_attempts');

  static final _linkReset = _lib
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('gopro_link_reset');

  /// Zero for any duration keeps the native default.
  static Pointer<Void> linkCreate({
    Duration connectTimeout = Duration.zero,
    Duration servicesTimeout = Duration.zero,
    Duration encryptTimeout = Duration.zero,
    Duration subscribeTimeout = Duration.zero,
    Duration backoffInitial = Duration.zero,
    Duration backoffMax = Duration.zero,
  }) => _linkCreate(
    connectTimeout.inMilliseconds,
    servicesTimeout.inMilliseconds,
    encryptTimeout.inMilliseconds,
    subscribeTimeout.inMilliseconds,
    backoffInitial.inMilliseconds,
    backoffMax.inMilliseconds,
  );

  static void linkDestroy(Pointer<Void> h) => _linkDestroy(h);
  static void linkNoteFailure(Pointer<Void> h, int nowMs) =>
      _linkNoteFailure(h, nowMs);
  static int linkAttempts(Pointer<Void> h) => _linkAttempts(h);
  static void linkReset(Pointer<Void> h) => _linkReset(h);

  /// Returns null only if the packed advice is out of range, which would
  /// mean the native enums and the Dart mirrors have drifted.
  static LinkAdvice? linkUpdate(
    Pointer<Void> h,
    LinkObservation obs,
    int nowMs,
  ) {
    final packed = _linkUpdate(
      h,
      obs.flags,
      obs.attributeCount,
      obs.subscribedCount,
      obs.requiredSubscriptions,
      nowMs,
    );
    return LinkAdvice.unpack(
      packed,
      detail: _linkDetail(h).toDartString(),
      retryAtMs: _linkRetryAt(h),
    );
  }
}
