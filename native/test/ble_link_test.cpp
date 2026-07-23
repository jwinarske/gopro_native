// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
//
// Tests for the BLE connection state machine.
//
// Each case corresponds to a failure actually observed while bringing up a
// MAX2. The value of the machine is not that it connects -- it is that when it
// does not, it says which of these you are looking at, since they present
// identically as "it doesn't work".

#include "ble_link.h"

#include <cstdio>
#include <string>

namespace {

int g_failures = 0;
int g_checks = 0;

void check(bool ok, const std::string& what) {
  ++g_checks;
  if (!ok) {
    ++g_failures;
    std::printf("  [FAIL] %s\n", what.c_str());
  }
}

using namespace gp::ble;

/// A fully working camera; individual tests degrade one aspect.
LinkObservation good() {
  LinkObservation o;
  o.le_candidate_present = true;
  o.connected = true;
  o.attribute_count = 34;
  o.control_chars_found = true;
  o.notify_succeeded = true;
  o.subscribed_count = 1;
  o.required_subscriptions = 1;
  return o;
}

void test_happy_path() {
  std::printf("happy path\n");
  LinkMachine m;
  check(m.update(good(), 0).state == LinkState::kReady,
        "fully-up camera is ready");
  check(m.update(good(), 0).action == LinkAction::kNone,
        "ready needs no action");
}

void test_absent_and_asleep() {
  std::printf("absent / asleep\n");
  LinkMachine m;
  LinkObservation o;  // nothing at all

  auto a = m.update(o, 0);
  check(a.state == LinkState::kAbsent, "nothing seen -> absent");
  check(a.action == LinkAction::kScan, "absent -> scan");
  check(a.stall == StallReason::kNone, "not stalled immediately");

  // After the timeout with still nothing, name it: the camera is asleep.
  a = m.update(o, 10000);
  check(a.stall == StallReason::kNoAdvertisement,
        "prolonged silence -> asleep");
  check(!a.detail.empty(), "stall carries an explanation");
}

void test_classic_blocks_le() {
  std::printf("classic blocking LE (observed)\n");
  LinkMachine m;
  LinkObservation o;
  o.classic_link_up = true;        // BR-EDR bond auto-reconnected
  o.le_candidate_present = false;  // ...and LE advertising stopped

  const auto a = m.update(o, 0);
  check(a.state == LinkState::kAbsent, "classic-only -> absent on LE");
  // Scanning harder never helps here: the camera does not advertise while the
  // Classic link is up. The only useful move is to drop it.
  check(a.action == LinkAction::kDisconnectClassic,
        "classic up -> disconnect it, do not scan");
  check(a.stall == StallReason::kClassicBlocking, "named as classic blocking");
  check(a.detail.find("suppresses LE") != std::string_view::npos,
        "explains why scanning will not help");
}

void test_services_property_lies() {
  std::printf("BlueZ reports resolved with zero attributes (observed)\n");
  LinkMachine m;
  LinkObservation o;
  o.le_candidate_present = true;
  o.connected = true;
  o.attribute_count = 0;  // the property said resolved; reality said nothing

  auto a = m.update(o, 0);
  check(a.state == LinkState::kConnected, "connected but unresolved");
  check(a.action == LinkAction::kWaitForServices, "wait for attributes");

  a = m.update(o, 15000);
  check(a.stall == StallReason::kServicesNeverAppeared,
        "stall named after timeout");
  check(a.detail.find("ServicesResolved") != std::string_view::npos,
        "warns that the property is unreliable");
}

void test_wrong_transport() {
  std::printf("attributes present but not the camera's control service\n");
  LinkMachine m;
  LinkObservation o;
  o.le_candidate_present = true;
  o.connected = true;
  o.attribute_count = 12;         // a GATT DB exists...
  o.control_chars_found = false;  // ...but no Control & Query

  // Enter the state first; the timeout is measured from arrival, so a single
  // update at t=15000 has spent no time there.
  (void)m.update(o, 0);
  const auto a = m.update(o, 15000);
  check(a.state == LinkState::kConnected, "not resolved without control chars");
  check(a.stall == StallReason::kWrongDevice,
        "diagnosed as wrong device object");
  check(a.detail.find("address type") != std::string_view::npos,
        "points at the address type");
}

void test_unencrypted_needs_pairing() {
  std::printf("discovery works, StartNotify refused (observed)\n");
  LinkMachine m;
  LinkObservation o = good();
  o.notify_succeeded = false;  // "Not paired"
  o.subscribed_count = 0;

  auto a = m.update(o, 0);
  check(a.state == LinkState::kServicesResolved, "resolved but not encrypted");
  check(a.action == LinkAction::kPair, "next action is to pair");

  a = m.update(o, 60000);
  check(a.stall == StallReason::kNotEncrypted, "stall named as not encrypted");
  check(a.detail.find("pairing mode") != std::string_view::npos,
        "tells the user to use pairing mode");
}

void test_bonded_flag_does_not_imply_encrypted() {
  std::printf("Bonded=true with an unencrypted LE link (the trap)\n");
  LinkMachine m;
  LinkObservation o = good();
  o.notify_succeeded = false;
  o.subscribed_count = 0;
  o.bonded_flag = true;  // set by a BR-EDR bond -- means nothing for GATT

  auto a = m.update(o, 0);
  check(a.state == LinkState::kServicesResolved,
        "Bonded flag must not advance the state");

  a = m.update(o, 60000);
  check(a.stall == StallReason::kNotEncrypted,
        "still diagnosed as unencrypted");
  // The whole point: call out the misleading flag explicitly, because
  // "Bonded: yes" is exactly what sends someone down the wrong path.
  check(a.detail.find("BR-EDR bond does not") != std::string_view::npos,
        "explicitly warns that the Bonded flag is misleading");
}

void test_partial_subscription() {
  std::printf("encrypted but not fully subscribed\n");
  LinkMachine m;
  LinkObservation o = good();
  o.subscribed_count = 2;
  o.required_subscriptions = 4;

  auto a = m.update(o, 0);
  check(a.state == LinkState::kEncrypted, "not ready until all subscribed");
  check(a.action == LinkAction::kSubscribe, "subscribe the rest");

  a = m.update(o, 10000);
  check(a.stall == StallReason::kSubscribeFailed, "stall after timeout");

  o.subscribed_count = 4;
  check(m.update(o, 11000).state == LinkState::kReady,
        "ready once all subscribed");
}

void test_backoff() {
  std::printf("backoff\n");
  LinkConfig cfg;
  cfg.backoff_initial_ms = 1000;
  cfg.backoff_max_ms = 8000;
  LinkMachine m(cfg);

  LinkObservation o;
  o.le_candidate_present = true;  // advertising, connect keeps failing
  (void)m.update(o, 0);

  uint64_t t = 0;
  const uint32_t expect[] = {1000, 2000, 4000, 8000, 8000};
  bool ok = true;
  for (const uint32_t want : expect) {
    m.note_attempt_failed(t);
    const auto a = m.update(o, t);
    if (a.retry_at_ms != t + want) {
      ok = false;
      std::printf("  [FAIL] backoff: got %llu want %llu\n",
                  (unsigned long long)(a.retry_at_ms - t),
                  (unsigned long long)want);
      break;
    }
    t += 100;
  }
  check(ok, "backoff doubles and caps");
  check(m.attempts() == 5, "attempts counted");

  // Progress must clear the backoff: having finally connected, a later
  // disconnect should retry promptly rather than inherit the old penalty.
  LinkObservation up = good();
  (void)m.update(up, t);
  check(m.attempts() == 0, "progress resets attempts");
  const auto a = m.update(up, t);
  check(a.retry_at_ms == 0, "no backoff once progressing");
}

void test_regression_retries_promptly() {
  std::printf("disconnect after ready\n");
  LinkMachine m;
  (void)m.update(good(), 0);
  check(m.state() == LinkState::kReady, "ready first");

  LinkObservation gone;
  gone.le_candidate_present = true;  // still advertising, link dropped
  const auto a = m.update(gone, 1000);
  check(a.state == LinkState::kAdvertising, "regresses to advertising");
  check(a.action == LinkAction::kConnect, "reconnect");
  check(a.retry_at_ms == 0, "reconnects immediately, no inherited backoff");
}

void test_reset() {
  std::printf("reset\n");
  LinkMachine m;
  (void)m.update(good(), 0);
  m.note_attempt_failed(0);
  m.reset();
  check(m.state() == LinkState::kAbsent, "reset returns to absent");
  check(m.attempts() == 0, "reset clears attempts");
}

}  // namespace

int main() {
  test_happy_path();
  test_absent_and_asleep();
  test_classic_blocks_le();
  test_services_property_lies();
  test_wrong_transport();
  test_unencrypted_needs_pairing();
  test_bonded_flag_does_not_imply_encrypted();
  test_partial_subscription();
  test_backoff();
  test_regression_retries_promptly();
  test_reset();

  std::printf("\n%d checks, %d failed\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
