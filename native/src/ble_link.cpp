// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
#include "ble_link.h"

#include <algorithm>

namespace gp::ble {

std::string_view to_string(LinkState s) {
  switch (s) {
    case LinkState::kAbsent: return "absent";
    case LinkState::kAdvertising: return "advertising";
    case LinkState::kConnected: return "connected";
    case LinkState::kServicesResolved: return "services-resolved";
    case LinkState::kEncrypted: return "encrypted";
    case LinkState::kReady: return "ready";
  }
  return "?";
}

std::string_view to_string(LinkAction a) {
  switch (a) {
    case LinkAction::kNone: return "none";
    case LinkAction::kScan: return "scan";
    case LinkAction::kDisconnectClassic: return "disconnect-classic";
    case LinkAction::kConnect: return "connect";
    case LinkAction::kWaitForServices: return "wait-for-services";
    case LinkAction::kPair: return "pair";
    case LinkAction::kSubscribe: return "subscribe";
  }
  return "?";
}

std::string_view to_string(StallReason r) {
  switch (r) {
    case StallReason::kNone: return "none";
    case StallReason::kNoAdvertisement: return "no-advertisement";
    case StallReason::kClassicBlocking: return "classic-blocking";
    case StallReason::kConnectFailed: return "connect-failed";
    case StallReason::kServicesNeverAppeared: return "services-never-appeared";
    case StallReason::kWrongDevice: return "wrong-device";
    case StallReason::kNotEncrypted: return "not-encrypted";
    case StallReason::kSubscribeFailed: return "subscribe-failed";
  }
  return "?";
}

LinkMachine::LinkMachine(LinkConfig cfg) : cfg_(cfg) {}

void LinkMachine::reset() {
  state_ = LinkState::kAbsent;
  state_since_ms_ = 0;
  last_failure_ms_ = 0;
  attempts_ = 0;
  seen_bonded_without_encryption_ = false;
}

uint32_t LinkMachine::backoff_ms() const {
  if (attempts_ == 0) return 0;
  // Exponential, capped. A camera that is asleep will not wake because we
  // asked faster.
  uint64_t ms = cfg_.backoff_initial_ms;
  for (uint32_t i = 1; i < attempts_ && ms < cfg_.backoff_max_ms; ++i) ms *= 2;
  return static_cast<uint32_t>(std::min<uint64_t>(ms, cfg_.backoff_max_ms));
}

void LinkMachine::note_attempt_failed(uint64_t now_ms) {
  ++attempts_;
  last_failure_ms_ = now_ms;
}

LinkState LinkMachine::classify(const LinkObservation& obs) const {
  if (!obs.connected) {
    return obs.le_candidate_present ? LinkState::kAdvertising
                                    : LinkState::kAbsent;
  }

  // Connected. Judge discovery by attributes actually exposed -- BlueZ has
  // been observed reporting ServicesResolved=true with none.
  if (obs.attribute_count == 0 || !obs.control_chars_found) {
    return LinkState::kConnected;
  }

  // Encryption is proven only by a StartNotify that worked. The Bonded flag is
  // not evidence: a BR-EDR bond sets it while leaving the LE link unencrypted,
  // and discovery succeeds unencrypted anyway.
  if (!obs.notify_succeeded) return LinkState::kServicesResolved;

  if (obs.subscribed_count < obs.required_subscriptions) {
    return LinkState::kEncrypted;
  }
  return LinkState::kReady;
}

LinkAdvice LinkMachine::update(const LinkObservation& obs, uint64_t now_ms) {
  const LinkState next = classify(obs);

  if (next != state_) {
    // Any change of stage counts as progress for backoff purposes, including
    // a regression -- a disconnect should retry promptly, not inherit the
    // backoff accumulated before it succeeded.
    state_ = next;
    state_since_ms_ = now_ms;
    attempts_ = 0;
    last_failure_ms_ = 0;
  }

  // Diagnostic only: remember if we ever saw the Bonded flag set while the
  // link was still unencrypted, so the stall message can name the trap.
  if (obs.bonded_flag && !obs.notify_succeeded &&
      state_ == LinkState::kServicesResolved) {
    seen_bonded_without_encryption_ = true;
  }

  LinkAdvice adv;
  adv.state = state_;

  const uint64_t in_state_ms = now_ms - state_since_ms_;
  const uint32_t wait = backoff_ms();
  adv.retry_at_ms = attempts_ > 0 ? last_failure_ms_ + wait : 0;

  switch (state_) {
    case LinkState::kAbsent:
      // Classic first: while that link is up the camera does not advertise, so
      // scanning harder will never find it.
      if (obs.classic_link_up) {
        adv.action = LinkAction::kDisconnectClassic;
        adv.stall = StallReason::kClassicBlocking;
        adv.detail =
            "A BR-EDR link to this camera is up. Classic suppresses LE "
            "advertising, so the LE transport cannot be found until it is "
            "disconnected. Removing the Classic bond stops it reconnecting.";
      } else {
        adv.action = LinkAction::kScan;
        if (in_state_ms >= cfg_.connect_timeout_ms) {
          adv.stall = StallReason::kNoAdvertisement;
          adv.detail =
              "Nothing advertising the Control & Query service. The camera is "
              "asleep, powered off, or has wireless disabled.";
        }
      }
      break;

    case LinkState::kAdvertising:
      adv.action = LinkAction::kConnect;
      if (attempts_ > 0 && in_state_ms >= cfg_.connect_timeout_ms) {
        adv.stall = StallReason::kConnectFailed;
        adv.detail =
            "The LE link is not establishing. Aborts during service discovery "
            "(le-connection-abort-by-local) are typical when the camera is "
            "dropping the link.";
      }
      break;

    case LinkState::kConnected:
      adv.action = LinkAction::kWaitForServices;
      if (in_state_ms >= cfg_.services_timeout_ms) {
        if (obs.attribute_count > 0 && !obs.control_chars_found) {
          adv.stall = StallReason::kWrongDevice;
          adv.detail =
              "Attributes are exposed but the Control & Query characteristics "
              "are absent. This is probably the BR-EDR object rather than the "
              "LE one -- check the address type.";
        } else {
          adv.stall = StallReason::kServicesNeverAppeared;
          adv.detail =
              "Connected but no GATT attributes appeared. Note that BlueZ may "
              "report ServicesResolved=true regardless; the attribute count is "
              "the reliable signal. A disconnect and reconnect usually clears "
              "it.";
        }
      }
      break;

    case LinkState::kServicesResolved:
      adv.action = LinkAction::kPair;
      if (in_state_ms >= cfg_.encrypt_timeout_ms) {
        adv.stall = StallReason::kNotEncrypted;
        adv.detail =
            seen_bonded_without_encryption_
                ? "Discovery works but StartNotify is refused. The Bonded flag "
                  "is set, which is misleading -- a BR-EDR bond does not "
                  "encrypt the LE link. An LE bond is required: put the camera "
                  "in pairing mode and pair the random-address device."
                : "Discovery works but StartNotify is refused (\"Not paired\"). "
                  "The Control & Query characteristics need an encrypted link. "
                  "Put the camera in pairing mode and pair over LE.";
      }
      break;

    case LinkState::kEncrypted:
      adv.action = LinkAction::kSubscribe;
      if (in_state_ms >= cfg_.subscribe_timeout_ms) {
        adv.stall = StallReason::kSubscribeFailed;
        adv.detail =
            "The link is encrypted but not every required characteristic is "
            "subscribed.";
      }
      break;

    case LinkState::kReady:
      adv.action = LinkAction::kNone;
      adv.retry_at_ms = 0;
      break;
  }

  return adv;
}

}  // namespace gp::ble
