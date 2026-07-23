// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
#include "link_bridge.h"

#include <string>

#include "ble_link.h"

namespace {

struct LinkContext {
  gp::ble::LinkMachine machine;
  // The advice holds a string_view into a literal; keeping the last one lets
  // gopro_link_detail hand back a stable pointer without allocating.
  std::string detail;
  uint64_t retry_at_ms{0};

  explicit LinkContext(gp::ble::LinkConfig cfg) : machine(cfg) {}
};

}  // namespace

extern "C" {

void* gopro_link_create(uint32_t connect_timeout_ms,
                        uint32_t services_timeout_ms,
                        uint32_t encrypt_timeout_ms,
                        uint32_t subscribe_timeout_ms,
                        uint32_t backoff_initial_ms,
                        uint32_t backoff_max_ms) {
  gp::ble::LinkConfig cfg;
  // Zero means "keep the default", so a caller can override one timeout
  // without having to restate the rest.
  if (connect_timeout_ms != 0) {
    cfg.connect_timeout_ms = connect_timeout_ms;
  }
  if (services_timeout_ms != 0) {
    cfg.services_timeout_ms = services_timeout_ms;
  }
  if (encrypt_timeout_ms != 0) {
    cfg.encrypt_timeout_ms = encrypt_timeout_ms;
  }
  if (subscribe_timeout_ms != 0) {
    cfg.subscribe_timeout_ms = subscribe_timeout_ms;
  }
  if (backoff_initial_ms != 0) {
    cfg.backoff_initial_ms = backoff_initial_ms;
  }
  if (backoff_max_ms != 0) {
    cfg.backoff_max_ms = backoff_max_ms;
  }
  return new LinkContext(cfg);
}

void gopro_link_destroy(void* handle) {
  delete static_cast<LinkContext*>(handle);
}

uint32_t gopro_link_update(void* handle,
                           uint32_t flags,
                           uint32_t attribute_count,
                           uint32_t subscribed_count,
                           uint32_t required_subscriptions,
                           uint64_t now_ms) {
  if (handle == nullptr) {
    return 0;
  }
  auto* ctx = static_cast<LinkContext*>(handle);

  gp::ble::LinkObservation obs;
  obs.le_candidate_present = (flags & kGoProLinkCandidatePresent) != 0;
  obs.classic_link_up = (flags & kGoProLinkClassicUp) != 0;
  obs.connected = (flags & kGoProLinkConnected) != 0;
  obs.bonded_flag = (flags & kGoProLinkBonded) != 0;
  obs.control_chars_found = (flags & kGoProLinkControlCharsFound) != 0;
  obs.notify_succeeded = (flags & kGoProLinkNotifySucceeded) != 0;
  obs.attribute_count = attribute_count;
  obs.subscribed_count = subscribed_count;
  // Zero required subscriptions would make kReady unreachable; the machine
  // defaults to one and a caller passing zero almost certainly means that.
  obs.required_subscriptions =
      required_subscriptions == 0 ? 1 : required_subscriptions;

  const gp::ble::LinkAdvice advice = ctx->machine.update(obs, now_ms);
  ctx->detail.assign(advice.detail);
  ctx->retry_at_ms = advice.retry_at_ms;

  return (static_cast<uint32_t>(advice.state) << 16) |
         (static_cast<uint32_t>(advice.action) << 8) |
         static_cast<uint32_t>(advice.stall);
}

uint64_t gopro_link_retry_at(void* handle) {
  if (handle == nullptr) {
    return 0;
  }
  return static_cast<LinkContext*>(handle)->retry_at_ms;
}

const char* gopro_link_detail(void* handle) {
  if (handle == nullptr) {
    return "";
  }
  return static_cast<LinkContext*>(handle)->detail.c_str();
}

void gopro_link_note_failure(void* handle, uint64_t now_ms) {
  if (handle == nullptr) {
    return;
  }
  static_cast<LinkContext*>(handle)->machine.note_attempt_failed(now_ms);
}

uint32_t gopro_link_attempts(void* handle) {
  if (handle == nullptr) {
    return 0;
  }
  return static_cast<LinkContext*>(handle)->machine.attempts();
}

void gopro_link_reset(void* handle) {
  if (handle == nullptr) {
    return;
  }
  auto* ctx = static_cast<LinkContext*>(handle);
  ctx->machine.reset();
  ctx->detail.clear();
  ctx->retry_at_ms = 0;
}

}  // extern "C"
