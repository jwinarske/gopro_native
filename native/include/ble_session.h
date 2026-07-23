// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
//
// ble_session.h — the BLE control plane, composed.
//
// Joins the four protocol pieces into one object: Reassembler per
// characteristic, parse_query, ReadyState, and CommandQueue. The transport
// lives in Dart, which owns the GATT connection and moves bytes; this owns
// the protocol state and decides what to send.
//
//   notification bytes  ->  feed()  ->  reassemble  ->  parse  ->  ready gate
//   submit()            ->  queue   ->  WriteFn     ->  transport writes
//
// Pure logic: no D-Bus, no threads, no clock. Time arrives as a parameter and
// transmission goes out through a callback, so every ordering property is
// testable without hardware.
//
// CORRELATION
//
// Responses carry no sequence number. What identifies them is the first byte
// of the reassembled payload -- a command id, a query command id, or a
// setting id -- which is only unique within a characteristic. A settings
// response and a query response can both begin with 0x13 and mean unrelated
// things. Correlation ids therefore combine the characteristic with that
// byte, and CommandQueue's single-flight rule is what keeps two commands
// sharing one id from stealing each other's reply.
//
// KEEP-ALIVE
//
// The camera drops the link after roughly ten seconds of silence. tick()
// emits a keep-alive at a fixed interval, submitted at Priority::kKeepAlive
// so it bypasses the ready gate. Keeping the timer here rather than in the
// transport means the starvation behavior is testable: a keep-alive that
// queues behind a busy camera is the failure this design exists to prevent.

#pragma once

#include <cstdint>
#include <functional>
#include <span>
#include <string_view>
#include <vector>

#include "ble_protocol.h"
#include "command_queue.h"
#include "query_parser.h"

namespace gp::ble {

/// The characteristic pairs of the Control and Query service. Each write
/// characteristic has a matching notify characteristic; a response always
/// arrives on the partner of the one that carried the request.
enum class Channel : uint8_t {
  kCommand = 0,   ///< b5f90072 write, b5f90073 notify
  kSettings = 1,  ///< b5f90074 write, b5f90075 notify
  kQuery = 2,     ///< b5f90076 write, b5f90077 notify

  /// Camera Management, b5f90091 write and b5f90092 notify.
  ///
  /// A different service from the other three, and network management does
  /// not work anywhere else: sent on the command characteristic every camera
  /// tested answers a bare [feature][0x02] and nothing more, whatever the
  /// action. Optional, because a camera that does not expose the service is
  /// still fully usable for everything else.
  kNetwork = 3,
};

inline constexpr size_t kChannelCount = 4;

[[nodiscard]] std::string_view to_string(Channel c);

/// Builds a correlation id from a channel and the leading payload byte.
/// Exposed so callers can predict the id of a command they are about to
/// submit.
[[nodiscard]] constexpr CorrelationId correlation_of(Channel channel,
                                                     uint8_t leading_byte) {
  return (static_cast<CorrelationId>(channel) << 8) | leading_byte;
}

/// Set on a protobuf correlation id to keep it out of the one-byte space.
///
/// Without it (channel 2, byte 0xFF) and (channel 0, feature 2, action 0xFF)
/// are both 0x2FF, and a plain command's response would resolve a protobuf
/// caller.
inline constexpr CorrelationId kProtobufCorrelationBit = CorrelationId{1} << 24;

/// Turns a protobuf request action id into the response's.
///
/// Open GoPro sets the high bit: 101 -> 229, 110 -> 238, 5 -> 133. A protobuf
/// reply carries the response action id, so a caller waiting on a request has
/// to be registered under the reply's.
[[nodiscard]] constexpr uint8_t protobuf_response_action(uint8_t request) {
  return request | 0x80;
}

/// The channel a correlation id belongs to, for either width.
///
/// The queue does not know about channels, so the channel has to be
/// recoverable from the id it hands back. The two widths keep it in different
/// places, which is worth stating once here rather than open-coding a shift
/// at each use: reading a wide id as a narrow one yields the feature id,
/// which is a plausible-looking channel number and silently writes to the
/// wrong characteristic.
[[nodiscard]] constexpr Channel channel_of_correlation(CorrelationId id) {
  const auto shift = (id & kProtobufCorrelationBit) != 0 ? 16 : 8;
  return static_cast<Channel>((id >> shift) & 0xFF);
}

/// Correlation id for a protobuf message, which is framed as
/// `[feature id][action id][encoded message]`.
///
/// Two bytes wide because one is not enough to tell protobuf commands apart:
/// every COHN request leads with the same feature id, so correlating on the
/// leading byte alone makes them all one id. They would serialize against
/// each other for no reason, and — worse — a registered status notification
/// arriving on that feature would resolve whichever unrelated request
/// happened to be outstanding.
///
/// Pass the *request* action id; the mapping to the reply's is applied here.
[[nodiscard]] constexpr CorrelationId correlation_of_protobuf(
    Channel channel,
    uint8_t feature_id,
    uint8_t request_action_id) {
  return kProtobufCorrelationBit | (static_cast<CorrelationId>(channel) << 16) |
         (static_cast<CorrelationId>(feature_id) << 8) |
         protobuf_response_action(request_action_id);
}

/// Setting id 91, value 66: the write that keeps the link alive.
inline constexpr uint8_t kLedSettingId = 91;
inline constexpr uint8_t kKeepAliveValue = 66;

struct SessionConfig {
  /// The camera drops the link after roughly ten seconds without traffic.
  uint32_t keep_alive_interval_ms = 3000;

  /// Usable ATT payload. Read from the negotiated MTU less three bytes of
  /// ATT overhead; the default is the BLE 4.0 floor and is almost always
  /// wrong. A MAX2 negotiates 517.
  size_t att_payload = kMinAttPayload;

  CommandQueueOptions queue;
};

class BleSession {
 public:
  /// Emitted when a fragment is ready to go out on `channel`'s write
  /// characteristic. Called once per fragment, in order.
  using WriteFn = std::function<void(Channel, std::span<const uint8_t>)>;

  /// A submitted command completed. `payload` is the reassembled response,
  /// empty unless the outcome is kResponded.
  using ResponseFn =
      std::function<void(CorrelationId, Outcome, std::span<const uint8_t>)>;

  /// A reassembled message nobody was waiting for: a registered status or
  /// setting push.
  using PushFn = std::function<
      void(Channel, const QueryResponse&, std::span<const uint8_t>)>;

  /// The ready gate opened or closed.
  using ReadyFn = std::function<void(bool)>;

  /// A fed packet was rejected. Carries the reason so a caller can log which
  /// of the framing failures occurred rather than "something went wrong".
  using FrameErrorFn = std::function<void(Channel, FeedResult)>;

  explicit BleSession(WriteFn write, SessionConfig cfg = SessionConfig{});

  void on_response(ResponseFn fn) { on_response_ = std::move(fn); }
  void on_push(PushFn fn) { on_push_ = std::move(fn); }
  void on_ready(ReadyFn fn) { on_ready_ = std::move(fn); }
  void on_frame_error(FrameErrorFn fn) { on_frame_error_ = std::move(fn); }

  /// Feeds one notification from `channel`'s notify characteristic.
  void feed(Channel channel, std::span<const uint8_t> packet, uint64_t now_ms);

  /// Submits a command. The correlation id is derived from the channel and
  /// the first payload byte. Returns false if one with the same id is
  /// already outstanding.
  bool submit(Channel channel,
              std::span<const uint8_t> payload,
              Priority priority,
              uint64_t now_ms);

  /// Submits a protobuf command, framed as `[feature][action][payload]`.
  ///
  /// Correlated on both header bytes rather than the leading one, so requests
  /// sharing a feature id are distinct commands rather than one. `payload` is
  /// the encoded message alone; the two header bytes are prepended here.
  ///
  /// Returns false if a protobuf command with the same feature and action is
  /// already outstanding.
  bool submit_protobuf(Channel channel,
                       uint8_t feature_id,
                       uint8_t action_id,
                       std::span<const uint8_t> message,
                       Priority priority,
                       uint64_t now_ms);

  /// Drives command timeouts and the keep-alive. Call regularly; the
  /// interval only bounds keep-alive jitter, not correctness.
  void tick(uint64_t now_ms);

  /// Updates the usable ATT payload after MTU negotiation.
  void set_att_payload(size_t bytes);

  /// Clears every partial frame, cancels outstanding commands, and forgets
  /// readiness. Readiness must not survive a reconnect: commands would be
  /// released before the camera has reported its state.
  void on_disconnect();

  [[nodiscard]] bool ready() const { return ready_.ready(); }
  [[nodiscard]] size_t pending() const { return queue_.pending(); }
  [[nodiscard]] size_t in_flight() const { return queue_.in_flight(); }
  [[nodiscard]] size_t att_payload() const { return cfg_.att_payload; }

 private:
  void deliver(Channel channel, std::vector<uint8_t> message, uint64_t now_ms);

  /// Shared tail of both submit forms: hands the payload to the queue under
  /// `id` and wires the completion back to on_response_.
  bool enqueue(CorrelationId id,
               std::vector<uint8_t> payload,
               Priority priority,
               uint64_t now_ms);

  SessionConfig cfg_;
  WriteFn write_;
  ResponseFn on_response_;
  PushFn on_push_;
  ReadyFn on_ready_;
  FrameErrorFn on_frame_error_;

  // One reassembler per channel. Sharing one across characteristics would
  // splice interleaved messages together.
  Reassembler rx_[kChannelCount];

  CommandQueue queue_;
  ReadyState ready_;

  uint64_t last_keep_alive_ms_{0};
  bool keep_alive_started_{false};
};

}  // namespace gp::ble
