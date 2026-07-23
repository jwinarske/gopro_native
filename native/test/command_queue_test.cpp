// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
//
// Tests for the ready-gated command queue.
//
// The property that matters most is negative: keep-alive must never be
// blocked, by anything, ever. Every other guarantee here is about not
// resolving the wrong caller's future.

#include "command_queue.h"

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

using gp::ble::CommandQueue;
using gp::ble::Outcome;
using gp::ble::Priority;

// Records what reached the wire, in order.
struct Recorder {
  std::vector<uint64_t> sent;
  CommandQueue::WriteFn fn() {
    return
        [this](uint64_t id, std::span<const uint8_t>) { sent.push_back(id); };
  }
  bool sent_ids(const std::vector<uint64_t>& expect) const {
    return sent == expect;
  }
};

std::vector<uint8_t> body(uint8_t b = 0xAA) {
  return {b};
}

void test_ready_gate() {
  std::printf("ready gate\n");
  Recorder rec;
  CommandQueue q(rec.fn());

  // Not ready: ordinary commands queue rather than transmit.
  q.submit(1, body(), Priority::kQueued, nullptr, 0);
  q.submit(2, body(), Priority::kQueued, nullptr, 0);
  check(rec.sent.empty(), "ordinary commands wait while not ready");
  check(q.pending() == 2, "both are pending");

  // Becoming ready releases exactly one -- ordinary commands serialize.
  q.set_ready(true, 10);
  check(rec.sent_ids({1}), "one command released on ready");
  check(q.in_flight() == 1, "exactly one in flight");

  q.on_response(1, {}, 20);
  check(rec.sent_ids({1, 2}), "next released on response");
}

void test_keep_alive_is_never_blocked() {
  std::printf("keep-alive starvation (the bug)\n");
  Recorder rec;
  CommandQueue q(rec.fn());

  // Camera busy, an ordinary command already queued and stuck behind the gate.
  q.submit(100, body(), Priority::kQueued, nullptr, 0);
  check(rec.sent.empty(), "ordinary command is blocked");

  // Keep-alive must go out anyway. In the reference implementation it would
  // acquire the same lock and starve for as long as the camera stays busy,
  // and the connection dies after ~10 s.
  q.submit(66, body(), Priority::kKeepAlive, nullptr, 100);
  check(rec.sent_ids({66}), "keep-alive transmits while camera is busy");

  // And repeatedly, indefinitely, with the gate still shut.
  q.on_response(66, {}, 200);
  q.submit(66, body(), Priority::kKeepAlive, nullptr, 3100);
  q.on_response(66, {}, 3200);
  q.submit(66, body(), Priority::kKeepAlive, nullptr, 6100);
  check(rec.sent_ids({66, 66, 66}), "keep-alive is never starved");
  check(q.pending() == 1, "the ordinary command is still waiting");

  // Keep-alive also does not consume the ordinary serialization slot.
  q.set_ready(true, 7000);
  check(rec.sent_ids({66, 66, 66, 100}),
        "ordinary command runs once ready, unaffected by keep-alive traffic");
}

void test_keep_alive_jumps_the_queue() {
  std::printf("keep-alive ordering\n");
  Recorder rec;
  CommandQueue q(rec.fn());
  q.set_ready(true, 0);

  q.submit(1, body(), Priority::kQueued, nullptr, 0);  // goes out immediately
  q.submit(2, body(), Priority::kQueued, nullptr, 0);  // queued behind it
  q.submit(3, body(), Priority::kQueued, nullptr, 0);  // and behind that
  q.submit(66, body(), Priority::kKeepAlive, nullptr, 0);

  // Keep-alive overtakes the backlog rather than waiting its turn.
  check(rec.sent_ids({1, 66}), "keep-alive overtakes queued backlog");
}

void test_fastpass() {
  std::printf("fastpass\n");
  Recorder rec;
  CommandQueue q(rec.fn());

  // Not ready. Fastpass exists for commands the camera accepts while busy --
  // "stop shutter" above all, which must not wait for the encoding it is
  // trying to stop.
  q.submit(10, body(), Priority::kQueued, nullptr, 0);
  q.submit(11, body(), Priority::kFastpass, nullptr, 0);
  check(rec.sent_ids({11}), "fastpass ignores the ready gate");

  // Fastpass in flight does not block an ordinary command once ready.
  q.set_ready(true, 10);
  check(rec.sent_ids({11, 10}), "fastpass does not hold the ordinary slot");
}

void test_single_flight_per_id() {
  std::printf("single flight per correlation id\n");
  Recorder rec;
  CommandQueue q(rec.fn());
  q.set_ready(true, 0);

  Outcome first_outcome = Outcome::kCanceled;
  Outcome dup_outcome = Outcome::kCanceled;
  q.submit(
      7, body(), Priority::kQueued,
      [&](Outcome o, std::span<const uint8_t>) { first_outcome = o; }, 0);
  const bool accepted = q.submit(
      7, body(), Priority::kQueued,
      [&](Outcome o, std::span<const uint8_t>) { dup_outcome = o; }, 0);

  check(!accepted, "duplicate id is refused");
  check(dup_outcome == Outcome::kRejected, "duplicate completes as rejected");
  check(rec.sent_ids({7}), "duplicate never reaches the wire");

  // Responses carry no sequence number, so a second in-flight command with the
  // same id would have its response stolen by the first. Rejecting is the only
  // safe option.
  q.on_response(7, {}, 10);
  check(first_outcome == Outcome::kResponded, "original resolves normally");

  // Once complete, the id is reusable.
  check(q.submit(7, body(), Priority::kQueued, nullptr, 20),
        "id is reusable after completion");
}

void test_response_routing() {
  std::printf("response routing\n");
  Recorder rec;
  CommandQueue q(rec.fn());
  q.set_ready(true, 0);

  std::vector<uint8_t> got;
  q.submit(
      5, body(), Priority::kQueued,
      [&](Outcome o, std::span<const uint8_t> d) {
        if (o == Outcome::kResponded)
          got.assign(d.begin(), d.end());
      },
      0);

  const std::vector<uint8_t> payload = {0xDE, 0xAD, 0xBE, 0xEF};
  check(q.on_response(5, payload, 10), "matching response is consumed");
  check(got == payload, "payload reaches the caller intact");

  // An id nobody is waiting on is a push notification, not a reply. Reporting
  // it as unmatched lets the transport route it to listeners instead.
  check(!q.on_response(999, payload, 20),
        "unmatched response reported as unhandled");
}

void test_timeout() {
  std::printf("timeout\n");
  Recorder rec;
  CommandQueue q(rec.fn(), {.write_timeout_ms = 5000});
  q.set_ready(true, 0);

  Outcome outcome = Outcome::kResponded;
  q.submit(
      1, body(), Priority::kQueued,
      [&](Outcome o, std::span<const uint8_t>) { outcome = o; }, 0);
  q.submit(2, body(), Priority::kQueued, nullptr, 0);

  q.tick(4999);
  check(outcome == Outcome::kResponded, "not yet expired");
  check(q.in_flight() == 1, "still in flight just under the deadline");

  q.tick(5000);
  check(outcome == Outcome::kTimedOut, "expires at the deadline");
  // A timeout must free the serialization slot, or one lost response wedges
  // the queue permanently.
  check(rec.sent_ids({1, 2}), "timeout releases the next command");
}

void test_cancel_all() {
  std::printf("cancel_all\n");
  Recorder rec;
  CommandQueue q(rec.fn());
  q.set_ready(true, 0);

  int canceled = 0;
  const auto counter = [&](Outcome o, std::span<const uint8_t>) {
    if (o == Outcome::kCanceled)
      ++canceled;
  };
  q.submit(1, body(), Priority::kQueued, counter, 0);  // in flight
  q.submit(2, body(), Priority::kQueued, counter, 0);  // pending
  q.submit(3, body(), Priority::kQueued, counter, 0);  // pending

  q.cancel_all();
  // On disconnect nobody may be left awaiting a reply that can never arrive.
  check(canceled == 3, "in-flight and pending are all canceled");
  check(q.in_flight() == 0 && q.pending() == 0, "queue is empty after cancel");
}

void test_completion_can_resubmit() {
  std::printf("reentrancy\n");
  Recorder rec;
  CommandQueue q(rec.fn());
  q.set_ready(true, 0);

  // A completion handler that submits is the natural shape for a retry, and
  // it reenters the queue while it is mutating its own containers.
  int depth = 0;
  CommandQueue::CompletionFn retry;
  retry = [&](Outcome o, std::span<const uint8_t>) {
    if (o == Outcome::kTimedOut && depth < 3) {
      ++depth;
      q.submit(1, body(), Priority::kQueued, retry, 10000);
    }
  };
  q.submit(1, body(), Priority::kQueued, retry, 0);
  q.tick(5000);
  check(depth == 1, "completion handler may resubmit safely");
  check(q.in_flight() == 1, "resubmitted command is in flight");
}

}  // namespace

int main() {
  test_ready_gate();
  test_keep_alive_is_never_blocked();
  test_keep_alive_jumps_the_queue();
  test_fastpass();
  test_single_flight_per_id();
  test_response_routing();
  test_timeout();
  test_cancel_all();
  test_completion_can_resubmit();

  std::printf("\n%d checks, %d failed\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
