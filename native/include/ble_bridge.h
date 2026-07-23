// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
//
// ble_bridge.h — C ABI exposing BleSession to Dart.
//
// The transport lives in Dart because bluez_native owns the D-Bus connection
// and delivers GATT notifications as a Dart stream. Dart pushes notification
// bytes in through gopro_ble_feed and performs the writes this side asks for.
//
// WHO DRIVES THE CLOCK
//
// Dart calls gopro_ble_tick on a timer. A native timer thread would buy
// nothing: every write this session produces has to be performed by
// bluez_native from the Dart isolate, so a keep-alive emitted natively would
// wait for that isolate anyway. The keep-alive interval is three seconds
// against a camera that drops the link after roughly ten, so event loop
// jitter has ample margin. What actually threatened the keep-alive was being
// queued behind the ready gate, and Priority::kKeepAlive is what solves that.
//
// EVENT ENCODING
//
// Events reach Dart as byte arrays whose first octet is a discriminator.
// Multi-byte integers are little-endian. lib/src/ffi/ble_codec.dart decodes
// this and test vectors are frozen on both sides, because a mismatch here is
// silent corruption rather than a compile error.
//
//   0x10 write     [0x10][channel u8][bytes...]
//                  Dart writes `bytes` to `channel`'s write characteristic.
//   0x11 response  [0x11][correlation u64][outcome u8][bytes...]
//   0x12 ready     [0x12][ready u8]
//   0x13 push      [0x13][channel u8][bytes...]
//   0x14 frame     [0x14][channel u8][FeedResult u8]

#pragma once

#include "dart_api_dl.h"

#include <cstdint>

#define GOPRO_EXPORT __attribute__((visibility("default")))

#ifdef __cplusplus
extern "C" {
#endif

/// Event discriminators. Mirrored by BleEventKind in ble_codec.dart.
enum GoProBleEvent {
  kGoProBleWrite = 0x10,
  kGoProBleResponse = 0x11,
  kGoProBleReady = 0x12,
  kGoProBlePush = 0x13,
  kGoProBleFrameError = 0x14,
};

/// Creates a session. `keep_alive_ms` and `write_timeout_ms` may be zero to
/// accept the defaults. Returns null only on allocation failure.
GOPRO_EXPORT void* gopro_ble_create(int64_t events_port,
                                    uint32_t keep_alive_ms,
                                    uint32_t write_timeout_ms);

GOPRO_EXPORT void gopro_ble_destroy(void* handle);

/// Feeds one GATT notification. `channel` is a gp::ble::Channel value.
GOPRO_EXPORT void gopro_ble_feed(void* handle,
                                 uint8_t channel,
                                 const uint8_t* data,
                                 int32_t len,
                                 uint64_t now_ms);

/// Submits a command. Returns 1 if accepted, 0 if a command with the same
/// correlation id is already outstanding.
GOPRO_EXPORT int32_t gopro_ble_submit(void* handle,
                                      uint8_t channel,
                                      const uint8_t* payload,
                                      int32_t len,
                                      uint8_t priority,
                                      uint64_t now_ms);

/// Drives command timeouts and the keep-alive.
GOPRO_EXPORT void gopro_ble_tick(void* handle, uint64_t now_ms);

/// Sets the usable ATT payload, which is the negotiated MTU less three bytes
/// of ATT overhead. Values below the BLE 4.0 floor are ignored.
GOPRO_EXPORT void gopro_ble_set_att_payload(void* handle, uint32_t bytes);

/// Clears partial frames, cancels outstanding commands, and forgets
/// readiness. Every cancelled command still reports an outcome, so no Dart
/// caller is left awaiting a reply that cannot arrive.
GOPRO_EXPORT void gopro_ble_disconnect(void* handle);

/// Non-zero when the ready gate is open. For diagnostics; Dart learns of
/// changes through the 0x12 event.
GOPRO_EXPORT int32_t gopro_ble_ready(void* handle);

#ifdef __cplusplus
}  // extern "C"
#endif
