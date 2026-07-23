// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
#include "command_queue.h"

#include <algorithm>
#include <utility>

namespace gp::ble {

std::string_view to_string(Priority p) {
  switch (p) {
    case Priority::kQueued:
      return "queued";
    case Priority::kFastpass:
      return "fastpass";
    case Priority::kKeepAlive:
      return "keep-alive";
  }
  return "?";
}

std::string_view to_string(Outcome o) {
  switch (o) {
    case Outcome::kResponded:
      return "responded";
    case Outcome::kTimedOut:
      return "timed-out";
    case Outcome::kCanceled:
      return "canceled";
    case Outcome::kRejected:
      return "rejected";
  }
  return "?";
}

CommandQueue::CommandQueue(WriteFn write, Options opts)
    : write_(std::move(write)), opts_(opts) {}

bool CommandQueue::is_in_flight(CorrelationId id) const {
  return std::any_of(in_flight_.begin(), in_flight_.end(),
                     [id](const Entry& e) { return e.id == id; });
}

bool CommandQueue::can_send(const Entry& e) const {
  // Responses are matched by correlation id alone, so the same id may never be
  // outstanding twice -- regardless of priority.
  if (is_in_flight(e.id))
    return false;

  switch (e.priority) {
    case Priority::kKeepAlive:
      // Never gated. Starving this is what kills the connection.
      return true;
    case Priority::kFastpass:
      // Ignores readiness, but does not stampede: still one at a time.
      return true;
    case Priority::kQueued:
      if (!ready_)
        return false;
      // Serialize against other ordinary commands. Keep-alive and fastpass
      // traffic in flight does not block ordinary work, and vice versa.
      return std::none_of(
          in_flight_.begin(), in_flight_.end(),
          [](const Entry& f) { return f.priority == Priority::kQueued; });
  }
  return false;
}

void CommandQueue::send(Entry e, uint64_t now_ms) {
  e.sent_at_ms = now_ms;
  const CorrelationId id = e.id;
  const std::vector<uint8_t> payload = e.payload;
  in_flight_.push_back(std::move(e));
  // Write after the entry is recorded: a transport that completes
  // synchronously would otherwise deliver a response for a command the queue
  // does not yet know about.
  write_(id, payload);
}

void CommandQueue::pump(uint64_t now_ms) {
  // Repeat until a full pass sends nothing: dispatching one entry can unblock
  // another, and a keep-alive queued behind a blocked ordinary command must
  // still overtake it.
  bool progressed = true;
  while (progressed) {
    progressed = false;
    for (auto it = pending_.begin(); it != pending_.end(); ++it) {
      if (!can_send(*it))
        continue;
      Entry e = std::move(*it);
      pending_.erase(it);
      send(std::move(e), now_ms);
      progressed = true;
      break;  // iterators invalidated
    }
  }
}

bool CommandQueue::submit(CorrelationId id,
                          std::vector<uint8_t> payload,
                          Priority priority,
                          CompletionFn done,
                          uint64_t now_ms) {
  const bool duplicate =
      is_in_flight(id) ||
      std::any_of(pending_.begin(), pending_.end(),
                  [id](const Entry& e) { return e.id == id; });
  if (duplicate) {
    if (done)
      done(Outcome::kRejected, {});
    return false;
  }

  Entry e;
  e.id = id;
  e.payload = std::move(payload);
  e.priority = priority;
  e.done = std::move(done);

  // Keep-alive jumps the queue. Waiting behind ordinary commands that are
  // themselves waiting on the ready gate is exactly the starvation this class
  // exists to prevent.
  if (priority == Priority::kKeepAlive) {
    pending_.push_front(std::move(e));
  } else {
    pending_.push_back(std::move(e));
  }

  pump(now_ms);
  return true;
}

void CommandQueue::set_ready(bool ready, uint64_t now_ms) {
  ready_ = ready;
  if (ready_)
    pump(now_ms);
}

bool CommandQueue::on_response(CorrelationId id,
                               std::span<const uint8_t> data,
                               uint64_t now_ms) {
  const auto it = std::find_if(in_flight_.begin(), in_flight_.end(),
                               [id](const Entry& e) { return e.id == id; });
  if (it == in_flight_.end()) {
    // Nothing was waiting on this id. Almost always a push notification --
    // a registered status or setting update -- not a stray reply.
    return false;
  }

  CompletionFn done = std::move(it->done);
  in_flight_.erase(it);
  if (done)
    done(Outcome::kResponded, data);

  pump(now_ms);
  return true;
}

void CommandQueue::tick(uint64_t now_ms) {
  // Collect first, invoke after: a completion callback may submit, and
  // mutating in_flight_ while iterating it would be undefined.
  std::vector<CompletionFn> expired;
  for (auto it = in_flight_.begin(); it != in_flight_.end();) {
    if (now_ms - it->sent_at_ms >= opts_.write_timeout_ms) {
      expired.push_back(std::move(it->done));
      it = in_flight_.erase(it);
    } else {
      ++it;
    }
  }
  for (auto& done : expired) {
    if (done)
      done(Outcome::kTimedOut, {});
  }

  pump(now_ms);
}

void CommandQueue::cancel_all() {
  std::vector<CompletionFn> canceled;
  for (auto& e : in_flight_)
    canceled.push_back(std::move(e.done));
  for (auto& e : pending_)
    canceled.push_back(std::move(e.done));
  in_flight_.clear();
  pending_.clear();
  for (auto& done : canceled) {
    if (done)
      done(Outcome::kCanceled, {});
  }
}

}  // namespace gp::ble
