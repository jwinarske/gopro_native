// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
//
// command_queue.h — ready-gated command serialization for the BLE control
// plane.
//
// The camera cannot absorb arbitrary concurrent commands. It publishes "busy"
// and "encoding" statuses, and ordinary commands must wait until both are
// clear. The reference implementation models this with a single global lock
// that every non-fastpass message acquires.
//
// THE BUG THIS EXISTS TO AVOID
//
// BLE keep-alive is a write of 66 to the LED setting every 3 seconds; without
// it the camera drops the connection after roughly ten. In the reference
// implementation keep-alive is an ordinary setting write, so it acquires that
// same global lock -- which means it is blocked for exactly as long as the
// camera is busy or encoding. The keep-alive starves precisely when the
// session is doing something interesting, and the connection dies mid-capture.
//
// So priority is a first-class property here rather than an afterthought:
//
//   kQueued     waits for the ready gate, and serializes against other
//               kQueued commands. The default.
//   kFastpass   ignores the ready gate. For commands the camera accepts while
//               busy -- notably "stop shutter", which must not wait for the
//               encoding it is trying to stop.
//   kKeepAlive  ignores the ready gate AND the serialization, and jumps the
//               queue. Never blocked by anything except an outstanding
//               keep-alive of its own.
//
// This class is deliberately pure: no threads, no clock, no I/O. Time and
// transmission are injected, so every ordering property is testable
// deterministically. The owning transport drives it from its own thread.

#pragma once

#include <cstdint>
#include <deque>
#include <functional>
#include <span>
#include <string_view>
#include <vector>

namespace gp::ble {

/// Opaque correlation key. The caller derives it from whatever identifies a
/// response on the wire -- command id, query id, setting id, or a
/// (feature, action) protobuf pair. The queue only ever compares it.
using CorrelationId = uint64_t;

enum class Priority : uint8_t {
  kQueued = 0,
  kFastpass = 1,
  kKeepAlive = 2,
};

[[nodiscard]] std::string_view to_string(Priority p);

enum class Outcome : uint8_t {
  kResponded,  ///< a matching response arrived
  kTimedOut,   ///< no response within the write timeout
  kCanceled,   ///< cancel_all(), e.g. on disconnect
  kRejected,   ///< refused at submit time; never transmitted
};

[[nodiscard]] std::string_view to_string(Outcome o);

struct CommandQueueOptions {
  /// Milliseconds to wait for a response before giving up on a command.
  ///
  /// The reference implementation hardcodes 5 s and documents it as "not
  /// configurable"; there is no reason for that, and slow operations on a
  /// busy camera legitimately exceed it.
  uint32_t write_timeout_ms = 5000;
};

class CommandQueue {
 public:
  /// Called when a command is due for transmission. The transport fragments
  /// and writes it.
  using WriteFn = std::function<void(CorrelationId, std::span<const uint8_t>)>;

  /// Called exactly once per accepted submission.
  using CompletionFn =
      std::function<void(Outcome, std::span<const uint8_t> response)>;

  // Namespace scope rather than nested: a nested struct's default member
  // initializers are not yet parsed at the point a default argument in the
  // same class would need them.
  using Options = CommandQueueOptions;

  explicit CommandQueue(WriteFn write, Options opts = CommandQueueOptions{});

  /// Submits a command. Returns false and invokes `done` with kRejected if a
  /// command with the same correlation id is already in flight.
  ///
  /// Same-id rejection is not fussiness. Responses carry no sequence number,
  /// so two in-flight commands sharing an id cannot be told apart and the
  /// first response to arrive would resolve the wrong request.
  bool submit(CorrelationId id,
              std::vector<uint8_t> payload,
              Priority priority,
              CompletionFn done,
              uint64_t now_ms);

  /// Reports the camera's readiness, derived from the busy and encoding
  /// statuses. Releases queued work when it becomes true.
  void set_ready(bool ready, uint64_t now_ms);

  /// Routes an incoming response. Returns false if nothing was waiting on
  /// this id, in which case the caller should treat it as an asynchronous
  /// push notification rather than a reply.
  bool on_response(CorrelationId id,
                   std::span<const uint8_t> data,
                   uint64_t now_ms);

  /// Drives timeouts and releases newly-eligible work. Call periodically.
  void tick(uint64_t now_ms);

  /// Completes everything outstanding with kCanceled. Call on disconnect, so
  /// no caller is left awaiting a reply that can never arrive.
  void cancel_all();

  [[nodiscard]] bool ready() const { return ready_; }
  [[nodiscard]] size_t pending() const { return pending_.size(); }
  [[nodiscard]] size_t in_flight() const { return in_flight_.size(); }
  [[nodiscard]] bool is_in_flight(CorrelationId id) const;

 private:
  struct Entry {
    CorrelationId id{};
    std::vector<uint8_t> payload;
    Priority priority{Priority::kQueued};
    CompletionFn done;
    uint64_t sent_at_ms{0};
  };

  [[nodiscard]] bool can_send(const Entry& e) const;
  void pump(uint64_t now_ms);
  void send(Entry e, uint64_t now_ms);

  WriteFn write_;
  Options opts_;
  bool ready_{false};
  std::deque<Entry> pending_;
  std::vector<Entry> in_flight_;
};

}  // namespace gp::ble
