// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
//
// Tests for the composed BLE control plane.
//
// The pieces are covered individually elsewhere. What matters here is that
// joining them preserves the guarantees each one provides: keep-alive still
// bypasses the ready gate, a status push still opens it, responses on
// different characteristics do not splice, and a disconnect leaves nothing
// stale behind.

#include "ble_session.h"

#include <cstdio>
#include <map>
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

/// Captures what the transport was asked to send.
struct Wire {
  struct Packet {
    Channel channel;
    std::vector<uint8_t> bytes;
  };
  std::vector<Packet> sent;

  BleSession::WriteFn fn() {
    return [this](Channel c, std::span<const uint8_t> b) {
      sent.push_back({c, std::vector<uint8_t>(b.begin(), b.end())});
    };
  }

  /// Reassembles what was sent on a channel back into logical messages, so a
  /// test can assert on payloads rather than fragments.
  [[nodiscard]] std::vector<std::vector<uint8_t>> messages(Channel c) const {
    std::vector<std::vector<uint8_t>> out;
    Reassembler r;
    for (const auto& p : sent) {
      if (p.channel != c)
        continue;
      if (r.feed(p.bytes) == FeedResult::kComplete)
        out.push_back(r.take());
    }
    return out;
  }

  void clear() { sent.clear(); }
};

/// Frames a payload the way the camera would, so it can be fed back in.
std::vector<std::vector<uint8_t>> frame(const std::vector<uint8_t>& payload,
                                        size_t mtu = 20) {
  return fragment(payload, mtu);
}

void feed_message(BleSession& s,
                  Channel c,
                  const std::vector<uint8_t>& payload,
                  uint64_t now_ms,
                  size_t mtu = 20) {
  for (const auto& packet : frame(payload, mtu)) {
    s.feed(c, packet, now_ms);
  }
}

// A status query response: GET_STATUS_VAL, success, BUSY and ENCODING.
std::vector<uint8_t> status(uint8_t busy, uint8_t encoding) {
  return {kGetStatusVal,   0x00, kStatusBusy, 1, busy,
          kStatusEncoding, 1,    encoding};
}

void test_ready_gate_from_a_push() {
  std::printf("status push opens the gate\n");
  Wire w;
  BleSession s(w.fn());
  bool ready_seen = false;
  s.on_ready([&](bool r) { ready_seen = r; });

  // Not ready: an ordinary command waits.
  check(s.submit(Channel::kCommand, std::vector<uint8_t>{0x01, 0x01},
                 Priority::kQueued, 0),
        "command accepted");
  check(w.messages(Channel::kCommand).empty(), "but not transmitted");
  check(s.pending() == 1, "it is pending");

  // A status push reporting idle should release it.
  feed_message(s, Channel::kQuery, status(0, 0), 100);
  check(s.ready(), "session is ready");
  check(ready_seen, "ready callback fired");
  check(w.messages(Channel::kCommand).size() == 1,
        "the queued command went out when the gate opened");
}

void test_keep_alive_bypasses_the_gate() {
  std::printf("keep-alive bypasses the ready gate\n");
  Wire w;
  SessionConfig cfg;
  cfg.keep_alive_interval_ms = 3000;
  BleSession s(w.fn(), cfg);

  // Camera busy, an ordinary command stuck behind the gate.
  feed_message(s, Channel::kQuery, status(1, 0), 0);
  check(!s.ready(), "not ready while busy");
  (void)s.submit(Channel::kCommand, std::vector<uint8_t>{0x01, 0x01},
                 Priority::kQueued, 0);
  check(w.messages(Channel::kCommand).empty(), "ordinary command blocked");

  s.tick(0);     // anchors the interval
  s.tick(3000);  // due
  const auto ka = w.messages(Channel::kSettings);
  check(ka.size() == 1, "keep-alive transmitted while the camera is busy");
  check(ka.empty() || (ka[0].size() == 3 && ka[0][0] == kLedSettingId &&
                       ka[0][2] == kKeepAliveValue),
        "keep-alive writes 66 to the LED setting");
  check(w.messages(Channel::kCommand).empty(),
        "the ordinary command is still blocked");
}

void test_keep_alive_interval() {
  std::printf("keep-alive cadence\n");
  Wire w;
  SessionConfig cfg;
  cfg.keep_alive_interval_ms = 3000;
  BleSession s(w.fn(), cfg);

  s.tick(1000);  // anchor
  s.tick(2000);
  check(w.messages(Channel::kSettings).empty(), "not due yet");
  s.tick(4000);
  check(w.messages(Channel::kSettings).size() == 1, "due at the interval");

  // The previous keep-alive is still outstanding, so the next is refused by
  // the single-flight rule rather than piling up.
  s.tick(7000);
  check(w.messages(Channel::kSettings).size() == 1,
        "no duplicate while one is in flight");

  // Once the camera answers, the next interval sends again.
  feed_message(s, Channel::kSettings, {kLedSettingId, 0x00}, 7100);
  s.tick(10100);
  check(w.messages(Channel::kSettings).size() == 2,
        "resumes after the response");
}

void test_channels_do_not_splice() {
  std::printf("interleaved channels\n");
  Wire w;
  BleSession s(w.fn());
  std::map<std::string, std::vector<uint8_t>> pushes;
  s.on_push([&](Channel c, const QueryResponse&, std::span<const uint8_t> m) {
    pushes[std::string(to_string(c))] =
        std::vector<uint8_t>(m.begin(), m.end());
  });

  // Two multi-fragment messages arriving interleaved on different
  // characteristics. One reassembler each is what keeps them apart.
  const std::vector<uint8_t> q(40, 0xAA);
  const std::vector<uint8_t> c(40, 0xBB);
  const auto qf = frame(q);
  const auto cf = frame(c);
  check(qf.size() > 1 && cf.size() > 1, "both messages fragment");

  for (size_t i = 0; i < qf.size() || i < cf.size(); ++i) {
    if (i < qf.size())
      s.feed(Channel::kQuery, qf[i], 0);
    if (i < cf.size())
      s.feed(Channel::kCommand, cf[i], 0);
  }

  check(pushes["query"] == q, "query message reassembled intact");
  check(pushes["command"] == c, "command message reassembled intact");
}

void test_correlation_is_per_channel() {
  std::printf("correlation is scoped to the characteristic\n");
  Wire w;
  BleSession s(w.fn());
  feed_message(s, Channel::kQuery, status(0, 0), 0);
  w.clear();

  // The same leading byte on two channels means two unrelated things, so
  // both submissions must be accepted.
  check(s.submit(Channel::kCommand, std::vector<uint8_t>{0x13, 0x01},
                 Priority::kQueued, 10),
        "command with leading byte 0x13 accepted");
  check(s.submit(Channel::kQuery, std::vector<uint8_t>{0x13, kStatusBusy},
                 Priority::kQueued, 10),
        "query with the same leading byte also accepted");
  check(correlation_of(Channel::kCommand, 0x13) !=
            correlation_of(Channel::kQuery, 0x13),
        "their correlation ids differ");

  // A duplicate on the same channel is refused: responses carry no sequence
  // number, so the first reply would resolve the wrong caller.
  check(!s.submit(Channel::kCommand, std::vector<uint8_t>{0x13, 0x02},
                  Priority::kQueued, 10),
        "duplicate on the same channel refused");
}

void test_response_resolves_the_submitter() {
  std::printf("responses resolve their submitter\n");
  Wire w;
  BleSession s(w.fn());
  feed_message(s, Channel::kQuery, status(0, 0), 0);

  std::vector<std::pair<CorrelationId, Outcome>> done;
  s.on_response([&](CorrelationId id, Outcome o, std::span<const uint8_t>) {
    done.emplace_back(id, o);
  });

  (void)s.submit(Channel::kCommand, std::vector<uint8_t>{0x01, 0x01},
                 Priority::kQueued, 10);
  feed_message(s, Channel::kCommand, {0x01, 0x00}, 20);

  check(done.size() == 1, "one completion");
  check(
      !done.empty() && done[0].first == correlation_of(Channel::kCommand, 0x01),
      "correct correlation id");
  check(!done.empty() && done[0].second == Outcome::kResponded, "responded");
}

void test_unmatched_is_a_push() {
  std::printf("unmatched messages are pushes\n");
  Wire w;
  BleSession s(w.fn());
  int pushes = 0;
  s.on_push([&](Channel, const QueryResponse&, std::span<const uint8_t>) {
    ++pushes;
  });
  int responses = 0;
  s.on_response(
      [&](CorrelationId, Outcome, std::span<const uint8_t>) { ++responses; });

  // Nothing was submitted, so this is a registered status update.
  feed_message(s, Channel::kQuery, status(0, 0), 0);
  check(pushes == 1, "reported as a push");
  check(responses == 0, "not reported as a response");
}

void test_mtu_changes_fragment_count() {
  std::printf("MTU affects fragmentation\n");
  Wire w;
  BleSession s(w.fn());
  feed_message(s, Channel::kQuery, status(0, 0), 0);
  w.clear();

  const std::vector<uint8_t> big(300, 0x5A);
  (void)s.submit(Channel::kCommand, big, Priority::kQueued, 10);
  const size_t at_floor = w.sent.size();
  check(at_floor > 15, "many fragments at the 20-byte floor");

  // A MAX2 negotiates 517, so the real payload is far larger.
  w.clear();
  s.set_att_payload(514);
  feed_message(s, Channel::kCommand, {0x5A, 0x00}, 20);  // clear the in-flight
  (void)s.submit(Channel::kCommand, big, Priority::kQueued, 30);
  check(w.sent.size() == 1, "a single fragment at the negotiated MTU");
  check(at_floor > w.sent.size() * 10, "an order of magnitude fewer");
}

void test_disconnect_clears_everything() {
  std::printf("disconnect\n");
  Wire w;
  BleSession s(w.fn());
  bool ready_now = true;
  s.on_ready([&](bool r) { ready_now = r; });
  std::vector<Outcome> outcomes;
  s.on_response([&](CorrelationId, Outcome o, std::span<const uint8_t>) {
    outcomes.push_back(o);
  });

  feed_message(s, Channel::kQuery, status(0, 0), 0);
  check(s.ready(), "ready");
  (void)s.submit(Channel::kCommand, std::vector<uint8_t>{0x01, 0x01},
                 Priority::kQueued, 10);
  (void)s.submit(Channel::kCommand, std::vector<uint8_t>{0x02, 0x01},
                 Priority::kQueued, 10);
  check(s.in_flight() == 1 && s.pending() == 1, "one in flight, one pending");

  // A half-received message must not survive either.
  const auto partial = frame(std::vector<uint8_t>(40, 0xCC));
  s.feed(Channel::kQuery, partial[0], 20);

  s.on_disconnect();

  check(!s.ready(), "readiness cleared");
  check(!ready_now, "ready callback reported false");
  check(s.in_flight() == 0 && s.pending() == 0, "queue drained");
  check(outcomes.size() == 2, "both submitters were told");
  check(outcomes.size() == 2 && outcomes[0] == Outcome::kCanceled &&
            outcomes[1] == Outcome::kCanceled,
        "cancelled rather than left hanging");

  // The partial is gone: a continuation from before the disconnect must not
  // attach to whatever arrives next.
  int errors = 0;
  s.on_frame_error([&](Channel, FeedResult) { ++errors; });
  s.feed(Channel::kQuery, partial[1], 30);
  check(errors == 1, "the stale continuation is rejected, not spliced");
}

void test_frame_errors_are_reported() {
  std::printf("frame errors\n");
  Wire w;
  BleSession s(w.fn());
  std::vector<FeedResult> errs;
  s.on_frame_error([&](Channel, FeedResult r) { errs.push_back(r); });

  s.feed(Channel::kQuery, std::vector<uint8_t>{kContMask, 0x01}, 0);
  check(errs.size() == 1 && errs[0] == FeedResult::kStrayCont,
        "stray continuation reported with its reason");

  // A reported error leaves the reassembler usable.
  errs.clear();
  feed_message(s, Channel::kQuery, status(0, 0), 10);
  check(errs.empty(), "the next message parses normally");
  check(s.ready(), "and takes effect");
}

}  // namespace

int main() {
  test_ready_gate_from_a_push();
  test_keep_alive_bypasses_the_gate();
  test_keep_alive_interval();
  test_channels_do_not_splice();
  test_correlation_is_per_channel();
  test_response_resolves_the_submitter();
  test_unmatched_is_a_push();
  test_mtu_changes_fragment_count();
  test_disconnect_clears_everything();
  test_frame_errors_are_reported();

  std::printf("\n%d checks, %d failed\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
