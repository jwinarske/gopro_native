// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
#include "ble_session.h"

#include <utility>

namespace gp::ble {

std::string_view to_string(Channel c) {
  switch (c) {
    case Channel::kCommand:
      return "command";
    case Channel::kSettings:
      return "settings";
    case Channel::kQuery:
      return "query";
  }
  return "?";
}

namespace {

/// The correlation id of a reassembled response: its leading byte, scoped to
/// the channel it arrived on.
CorrelationId correlation_of_message(Channel channel,
                                     std::span<const uint8_t> message) {
  return message.empty() ? correlation_of(channel, 0)
                         : correlation_of(channel, message[0]);
}

/// Setting write: [setting id][length][value].
std::vector<uint8_t> keep_alive_payload() {
  return {kLedSettingId, 1, kKeepAliveValue};
}

}  // namespace

BleSession::BleSession(WriteFn write, SessionConfig cfg)
    : cfg_(cfg),
      write_(std::move(write)),
      queue_(
          // The queue does not know about channels, so recover the channel
          // from the correlation id it hands back.
          [this](CorrelationId id, std::span<const uint8_t> payload) {
            const auto channel = static_cast<Channel>((id >> 8) & 0xFF);
            for (const auto& packet : fragment(payload, cfg_.att_payload)) {
              if (write_) {
                write_(channel, packet);
              }
            }
          },
          cfg.queue) {}

void BleSession::set_att_payload(size_t bytes) {
  if (bytes >= kMinAttPayload) {
    cfg_.att_payload = bytes;
  }
}

void BleSession::feed(Channel channel,
                      std::span<const uint8_t> packet,
                      uint64_t now_ms) {
  const auto idx = static_cast<size_t>(channel);
  if (idx >= kChannelCount) {
    return;
  }

  const FeedResult result = rx_[idx].feed(packet);
  switch (result) {
    case FeedResult::kNeedMore:
      return;
    case FeedResult::kComplete:
      deliver(channel, rx_[idx].take(), now_ms);
      return;
    default:
      // Every error leaves the reassembler reset, so the next message starts
      // clean rather than inheriting a partial one.
      if (on_frame_error_) {
        on_frame_error_(channel, result);
      }
      return;
  }
}

void BleSession::deliver(Channel channel,
                         std::vector<uint8_t> message,
                         uint64_t now_ms) {
  const CorrelationId id = correlation_of_message(channel, message);

  // A reply to something outstanding resolves it. Anything else is a push.
  if (queue_.on_response(id, message, now_ms)) {
    // The queue invoked the caller's completion. Readiness still has to be
    // folded in: a status query is both a reply and a state update.
    QueryResponse parsed;
    if (parse_query(message, parsed) == QueryParseResult::kOk) {
      const bool was = ready_.ready();
      if (ready_.apply(parsed) && on_ready_) {
        on_ready_(ready_.ready());
      }
      if (ready_.ready() != was) {
        queue_.set_ready(ready_.ready(), now_ms);
      }
    }
    return;
  }

  QueryResponse parsed;
  const bool parsed_ok = parse_query(message, parsed) == QueryParseResult::kOk;

  if (parsed_ok) {
    const bool was = ready_.ready();
    if (ready_.apply(parsed)) {
      // Tell the queue before the caller: a push that opens the gate should
      // release queued work in the same turn.
      queue_.set_ready(ready_.ready(), now_ms);
      if (on_ready_) {
        on_ready_(ready_.ready());
      }
    } else if (ready_.ready() != was) {
      queue_.set_ready(ready_.ready(), now_ms);
    }
  }

  if (on_push_) {
    on_push_(channel, parsed, message);
  }
}

bool BleSession::submit(Channel channel,
                        std::span<const uint8_t> payload,
                        Priority priority,
                        uint64_t now_ms) {
  if (payload.empty()) {
    return false;
  }
  const CorrelationId id = correlation_of(channel, payload[0]);
  // The queue reports the outcome; forward it with the correlation id so a
  // caller can tell which submission finished. `this` outlives the queue,
  // which is a member.
  return queue_.submit(
      id, std::vector<uint8_t>(payload.begin(), payload.end()), priority,
      [this, id](Outcome outcome, std::span<const uint8_t> response) {
        if (on_response_) {
          on_response_(id, outcome, response);
        }
      },
      now_ms);
}

void BleSession::tick(uint64_t now_ms) {
  queue_.tick(now_ms);

  // Anchor the first interval to the first tick rather than to zero, so a
  // session created at a large timestamp does not fire immediately.
  if (!keep_alive_started_) {
    keep_alive_started_ = true;
    last_keep_alive_ms_ = now_ms;
    return;
  }

  if (now_ms - last_keep_alive_ms_ < cfg_.keep_alive_interval_ms) {
    return;
  }
  last_keep_alive_ms_ = now_ms;

  // kKeepAlive bypasses the ready gate. Queuing this behind a busy camera is
  // exactly how the link dies mid-capture.
  const auto payload = keep_alive_payload();
  (void)submit(Channel::kSettings, payload, Priority::kKeepAlive, now_ms);
}

void BleSession::on_disconnect() {
  for (auto& r : rx_) {
    r.reset();
  }
  queue_.cancel_all();

  const bool was = ready_.ready();
  ready_.reset();
  queue_.set_ready(false, 0);
  if (was && on_ready_) {
    on_ready_(false);
  }

  // Re-anchor so a reconnect does not fire a keep-alive for the elapsed gap.
  keep_alive_started_ = false;
}

}  // namespace gp::ble
