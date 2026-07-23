// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
//
// link_bridge.h — C ABI exposing LinkMachine to Dart.
//
// Bring-up runs in Dart, because that is where the transport lives: scanning,
// connecting, pairing and subscribing all go through bluez_native. What Dart
// lacks is the judgement about what those observations mean, which is what
// LinkMachine holds.
//
// So Dart reports what it can see and receives back a stage, an action, and
// a stall reason. The rules that make the observations meaningful --
// selecting on address type as well as service UUID, counting attributes
// rather than trusting ServicesResolved, refusing to treat a bond flag as
// evidence of encryption -- stay in one tested place instead of being
// reimplemented against whatever the transport happens to expose.
//
// The advice is returned packed rather than posted to a port. It is a direct
// answer to a call the caller just made, so a round trip through the event
// loop would only add latency and reordering risk.

#pragma once

#include <cstdint>

#define GOPRO_EXPORT __attribute__((visibility("default")))

#ifdef __cplusplus
extern "C" {
#endif

/// Bit flags for the boolean half of gp::ble::LinkObservation.
enum GoProLinkFlags {
  /// An LE device object advertising the Control and Query service. The
  /// caller must require BOTH a random address type AND the fea6 service; a
  /// camera also presents a BR-EDR object with the same name that can never
  /// carry GATT.
  kGoProLinkCandidatePresent = 1u << 0,

  /// A BR-EDR link to the same camera is up. It suppresses LE advertising,
  /// so it has to be disconnected rather than waited out.
  kGoProLinkClassicUp = 1u << 1,

  kGoProLinkConnected = 1u << 2,

  /// BlueZ's Bonded flag. Reported for diagnostics and never gating: a
  /// BR-EDR bond sets it while leaving the LE link unencrypted.
  kGoProLinkBonded = 1u << 3,

  /// The Control and Query characteristics were all located.
  kGoProLinkControlCharsFound = 1u << 4,

  /// A StartNotify has succeeded, which is the only proof the link is
  /// encrypted.
  kGoProLinkNotifySucceeded = 1u << 5,
};

GOPRO_EXPORT void* gopro_link_create(uint32_t connect_timeout_ms,
                                     uint32_t services_timeout_ms,
                                     uint32_t encrypt_timeout_ms,
                                     uint32_t subscribe_timeout_ms,
                                     uint32_t backoff_initial_ms,
                                     uint32_t backoff_max_ms);

GOPRO_EXPORT void gopro_link_destroy(void* handle);

/// Folds an observation in and returns the advice packed as
/// (state << 16) | (action << 8) | stall, matching gp::ble::LinkState,
/// LinkAction and StallReason.
///
/// `attribute_count` must be the number of GATT characteristics actually
/// exposed. BlueZ has been observed reporting ServicesResolved=true while
/// exposing none, so the count is the reliable signal.
GOPRO_EXPORT uint32_t gopro_link_update(void* handle,
                                        uint32_t flags,
                                        uint32_t attribute_count,
                                        uint32_t subscribed_count,
                                        uint32_t required_subscriptions,
                                        uint64_t now_ms);

/// Earliest time the caller should retry the advised action, or zero for
/// now. Valid until the next gopro_link_update.
GOPRO_EXPORT uint64_t gopro_link_retry_at(void* handle);

/// Human-readable explanation of the current stall, or an empty string when
/// not stalled. Points at a string literal with static lifetime.
GOPRO_EXPORT const char* gopro_link_detail(void* handle);

/// Records that the advised action failed, so backoff grows rather than
/// hammering a camera that is asleep.
GOPRO_EXPORT void gopro_link_note_failure(void* handle, uint64_t now_ms);

/// Consecutive failures at the current stage. Reset by any forward progress.
GOPRO_EXPORT uint32_t gopro_link_attempts(void* handle);

GOPRO_EXPORT void gopro_link_reset(void* handle);

#ifdef __cplusplus
}  // extern "C"
#endif
