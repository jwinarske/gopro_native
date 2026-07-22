// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
//
// ble_link.h — BLE connection state machine.
//
// "Connected" is not "usable". Bringing up a GoPro's BLE control plane passes
// through several distinct stages, and every one of them can stall in a way
// that presents to the user as "it just doesn't work". This machine names the
// stages, detects the stalls, and says what to do next.
//
// It is the BLE counterpart of the USB readiness ladder in gopro_usb.h, and
// exists for the same reason: a single `connected` boolean cannot express
// which of several very different problems you actually have.
//
// STAGES
//
//   kAbsent            no LE candidate; nothing is advertising
//   kAdvertising       LE candidate seen, not connected
//   kConnected         link established
//   kServicesResolved  GATT attributes actually present AND the Control &
//                      Query characteristics found
//   kEncrypted         link encrypted -- proven by a successful StartNotify
//   kReady             every required characteristic is subscribed
//
// EACH RULE BELOW WAS PAID FOR. Observed on a MAX2, firmware H24.02.01.30.00:
//
// 1. A camera presents TWO device objects: BR-EDR (public address, Headset /
//    Handsfree / PnP profiles) and LE (random address, fea6). They share a
//    name. Selecting by name gets the wrong transport, and the Classic one can
//    never carry GATT.
//
// 2. The Classic link SUPPRESSES LE ADVERTISING. While it is up the camera
//    does not advertise, so a retry loop competes with the very bond blocking
//    it. Classic is treated as an adversary to disconnect, not a fallback.
//
// 3. BlueZ reported Connected=true AND ServicesResolved=true while exposing
//    ZERO GATT objects, for 30 s straight. Resolution is therefore judged by
//    counting attributes, never by the property.
//
// 4. Bonded=true does NOT imply the LE link is encrypted -- a Classic bond
//    sets that flag while doing nothing for GATT. Encryption is proven only by
//    a StartNotify that succeeds.
//
// 5. Unbonded LE enumerates services and reads Device Information happily, but
//    StartNotify fails "Not paired" and writes fail with an ATT error. So
//    discovery succeeding says nothing about whether control will work.
//
// This class is pure: no D-Bus, no threads, no clock. The caller supplies
// observations and a timestamp, so every transition and stall is testable
// deterministically.

#pragma once

#include <cstdint>
#include <string_view>

namespace gp::ble {

enum class LinkState : uint8_t {
  kAbsent,
  kAdvertising,
  kConnected,
  kServicesResolved,
  kEncrypted,
  kReady,
};

[[nodiscard]] std::string_view to_string(LinkState s);

/// What the caller should do next.
enum class LinkAction : uint8_t {
  kNone,               ///< nothing to do (ready, or waiting out a backoff)
  kScan,               ///< no candidate; scan for an LE advertisement
  kDisconnectClassic,  ///< a Classic link is blocking LE advertising
  kConnect,
  kWaitForServices,    ///< connected; attributes have not appeared yet
  kPair,               ///< resolved but unencrypted; needs an LE bond
  kSubscribe,          ///< encrypted; subscribe remaining characteristics
};

[[nodiscard]] std::string_view to_string(LinkAction a);

/// Why progress stopped. Distinct reasons because the user-facing fix differs
/// completely: "put the camera in pairing mode" versus "the camera is asleep".
enum class StallReason : uint8_t {
  kNone,
  kNoAdvertisement,     ///< nothing advertising -- camera asleep or off
  kClassicBlocking,     ///< Classic link up and LE not advertising
  kConnectFailed,       ///< connect attempts keep aborting
  kServicesNeverAppeared,  ///< connected, but no attributes were exposed
  kWrongDevice,         ///< attributes present but Control & Query missing
  kNotEncrypted,        ///< StartNotify refused; an LE bond is required
  kSubscribeFailed,
};

[[nodiscard]] std::string_view to_string(StallReason r);

/// A snapshot of what the transport can see. The BlueZ glue fills this in;
/// the machine never talks to D-Bus itself.
struct LinkObservation {
  /// An LE device object exists for this camera: random address (or public
  /// LE) AND advertising the Control & Query service. Selecting on both is
  /// what keeps the Classic object from being mistaken for it.
  bool le_candidate_present{false};

  /// A BR-EDR link to the same camera is up. Blocks LE advertising.
  bool classic_link_up{false};

  bool connected{false};

  /// BlueZ's Bonded flag. RECORDED BUT NEVER GATING: a Classic bond sets it
  /// without encrypting the LE link. Kept only so diagnostics can point out
  /// the discrepancy.
  bool bonded_flag{false};

  /// Number of GATT characteristics actually exposed. This -- not
  /// ServicesResolved -- is the truth about whether discovery completed.
  size_t attribute_count{0};

  /// Control & Query write/notify characteristics were all located.
  bool control_chars_found{false};

  /// A StartNotify has succeeded on this link, proving it is encrypted.
  bool notify_succeeded{false};

  size_t subscribed_count{0};
  size_t required_subscriptions{1};
};

struct LinkAdvice {
  LinkState state{LinkState::kAbsent};
  LinkAction action{LinkAction::kScan};
  StallReason stall{StallReason::kNone};

  /// Human-facing explanation of a stall. Empty when not stalled.
  std::string_view detail;

  /// Earliest time the caller should retry `action`. Zero means "now".
  uint64_t retry_at_ms{0};
};

struct LinkConfig {
  /// How long a stage may sit without progress before it is called stalled.
  uint32_t connect_timeout_ms = 10000;
  uint32_t services_timeout_ms = 15000;
  /// Generous: reaching an encrypted link needs a human to put the camera in
  /// pairing mode and confirm.
  uint32_t encrypt_timeout_ms = 60000;
  uint32_t subscribe_timeout_ms = 10000;

  uint32_t backoff_initial_ms = 1000;
  uint32_t backoff_max_ms = 30000;
};

class LinkMachine {
 public:
  explicit LinkMachine(LinkConfig cfg = LinkConfig{});

  /// Folds an observation in and returns what to do next.
  [[nodiscard]] LinkAdvice update(const LinkObservation& obs, uint64_t now_ms);

  [[nodiscard]] LinkState state() const { return state_; }

  /// Consecutive failed attempts at the current stage. Drives backoff and is
  /// reset by any forward progress.
  [[nodiscard]] uint32_t attempts() const { return attempts_; }

  /// Records that an attempted action failed, so backoff grows rather than
  /// hammering a camera that is asleep.
  void note_attempt_failed(uint64_t now_ms);

  void reset();

 private:
  [[nodiscard]] LinkState classify(const LinkObservation& obs) const;
  [[nodiscard]] uint32_t backoff_ms() const;

  LinkConfig cfg_;
  LinkState state_{LinkState::kAbsent};
  uint64_t state_since_ms_{0};
  uint64_t last_failure_ms_{0};
  uint32_t attempts_{0};
  bool seen_bonded_without_encryption_{false};
};

}  // namespace gp::ble
