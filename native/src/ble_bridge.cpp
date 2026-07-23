// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
#include "ble_bridge.h"

#include <cstring>
#include <memory>
#include <vector>

#include "ble_session.h"

namespace {

using gp::ble::BleSession;
using gp::ble::Channel;
using gp::ble::CorrelationId;
using gp::ble::FeedResult;
using gp::ble::Outcome;
using gp::ble::Priority;
using gp::ble::QueryResponse;
using gp::ble::SessionConfig;

struct BleContext {
  Dart_Port_DL events_port{};
  std::unique_ptr<BleSession> session;
};

/// Posts one event. kTypedData copies rather than transferring a C-heap
/// pointer: these payloads are at most a few hundred bytes and arrive at
/// control-plane rates, so a malloc plus a GC finalizer per event would cost
/// more than the copy it avoids.
void post(Dart_Port_DL port, std::vector<uint8_t>& buf) {
  Dart_CObject obj;
  obj.type = Dart_CObject_kTypedData;
  obj.value.as_typed_data.type = Dart_TypedData_kUint8;
  obj.value.as_typed_data.length = static_cast<intptr_t>(buf.size());
  obj.value.as_typed_data.values = buf.data();
  Dart_PostCObject_DL(port, &obj);
}

void append_u64(std::vector<uint8_t>& buf, uint64_t v) {
  for (int i = 0; i < 8; ++i) {  // little-endian
    buf.push_back(static_cast<uint8_t>((v >> (i * 8)) & 0xFF));
  }
}

void wire_callbacks(BleContext* ctx) {
  const Dart_Port_DL port = ctx->events_port;

  ctx->session->on_response([port](CorrelationId id, Outcome outcome,
                                   std::span<const uint8_t> payload) {
    std::vector<uint8_t> buf;
    buf.reserve(10 + payload.size());
    buf.push_back(kGoProBleResponse);
    append_u64(buf, id);
    buf.push_back(static_cast<uint8_t>(outcome));
    buf.insert(buf.end(), payload.begin(), payload.end());
    post(port, buf);
  });

  ctx->session->on_ready([port](bool ready) {
    std::vector<uint8_t> buf{kGoProBleReady, static_cast<uint8_t>(ready)};
    post(port, buf);
  });

  ctx->session->on_push([port](Channel channel, const QueryResponse&,
                               std::span<const uint8_t> message) {
    std::vector<uint8_t> buf;
    buf.reserve(2 + message.size());
    buf.push_back(kGoProBlePush);
    buf.push_back(static_cast<uint8_t>(channel));
    buf.insert(buf.end(), message.begin(), message.end());
    post(port, buf);
  });

  ctx->session->on_frame_error([port](Channel channel, FeedResult result) {
    std::vector<uint8_t> buf{kGoProBleFrameError, static_cast<uint8_t>(channel),
                             static_cast<uint8_t>(result)};
    post(port, buf);
  });
}

}  // namespace

extern "C" {

void* gopro_ble_create(int64_t events_port,
                       uint32_t keep_alive_ms,
                       uint32_t write_timeout_ms,
                       uint32_t queue_timeout_ms) {
  auto ctx = std::make_unique<BleContext>();
  ctx->events_port = events_port;

  SessionConfig cfg;
  if (keep_alive_ms != 0) {
    cfg.keep_alive_interval_ms = keep_alive_ms;
  }
  if (write_timeout_ms != 0) {
    cfg.queue.write_timeout_ms = write_timeout_ms;
  }
  if (queue_timeout_ms != 0) {
    cfg.queue.queue_timeout_ms = queue_timeout_ms;
  }

  const Dart_Port_DL port = events_port;
  ctx->session = std::make_unique<BleSession>(
      [port](Channel channel, std::span<const uint8_t> packet) {
        std::vector<uint8_t> buf;
        buf.reserve(2 + packet.size());
        buf.push_back(kGoProBleWrite);
        buf.push_back(static_cast<uint8_t>(channel));
        buf.insert(buf.end(), packet.begin(), packet.end());
        post(port, buf);
      },
      cfg);

  wire_callbacks(ctx.get());
  return ctx.release();
}

void gopro_ble_destroy(void* handle) {
  if (handle == nullptr) {
    return;
  }
  auto* ctx = static_cast<BleContext*>(handle);
  // Cancel first: every outstanding command reports an outcome, so no Dart
  // future is left unresolved by teardown.
  ctx->session->on_disconnect();
  delete ctx;
}

void gopro_ble_feed(void* handle,
                    uint8_t channel,
                    const uint8_t* data,
                    int32_t len,
                    uint64_t now_ms) {
  if (handle == nullptr || len < 0 || (data == nullptr && len > 0)) {
    return;
  }
  if (channel >= gp::ble::kChannelCount) {
    return;
  }
  auto* ctx = static_cast<BleContext*>(handle);
  ctx->session->feed(static_cast<Channel>(channel),
                     std::span<const uint8_t>(data, static_cast<size_t>(len)),
                     now_ms);
}

int32_t gopro_ble_submit(void* handle,
                         uint8_t channel,
                         const uint8_t* payload,
                         int32_t len,
                         uint8_t priority,
                         uint64_t now_ms) {
  if (handle == nullptr || payload == nullptr || len <= 0) {
    return 0;
  }
  if (channel >= gp::ble::kChannelCount ||
      priority > static_cast<uint8_t>(Priority::kKeepAlive)) {
    return 0;
  }
  auto* ctx = static_cast<BleContext*>(handle);
  const bool accepted = ctx->session->submit(
      static_cast<Channel>(channel),
      std::span<const uint8_t>(payload, static_cast<size_t>(len)),
      static_cast<Priority>(priority), now_ms);
  return accepted ? 1 : 0;
}

int32_t gopro_ble_submit_protobuf(void* handle,
                                  uint8_t channel,
                                  uint8_t feature_id,
                                  uint8_t action_id,
                                  const uint8_t* message,
                                  int32_t len,
                                  uint8_t priority,
                                  uint64_t now_ms) {
  if (handle == nullptr || len < 0 || (message == nullptr && len > 0)) {
    return 0;
  }
  if (channel >= gp::ble::kChannelCount ||
      priority > static_cast<uint8_t>(Priority::kKeepAlive)) {
    return 0;
  }
  auto* ctx = static_cast<BleContext*>(handle);
  const bool accepted = ctx->session->submit_protobuf(
      static_cast<Channel>(channel), feature_id, action_id,
      std::span<const uint8_t>(message, static_cast<size_t>(len)),
      static_cast<Priority>(priority), now_ms);
  return accepted ? 1 : 0;
}

uint64_t gopro_ble_protobuf_correlation(uint8_t channel,
                                        uint8_t feature_id,
                                        uint8_t action_id) {
  if (channel >= gp::ble::kChannelCount) {
    return 0;
  }
  return gp::ble::correlation_of_protobuf(static_cast<Channel>(channel),
                                          feature_id, action_id);
}

void gopro_ble_tick(void* handle, uint64_t now_ms) {
  if (handle == nullptr) {
    return;
  }
  static_cast<BleContext*>(handle)->session->tick(now_ms);
}

void gopro_ble_set_att_payload(void* handle, uint32_t bytes) {
  if (handle == nullptr) {
    return;
  }
  static_cast<BleContext*>(handle)->session->set_att_payload(bytes);
}

void gopro_ble_disconnect(void* handle) {
  if (handle == nullptr) {
    return;
  }
  static_cast<BleContext*>(handle)->session->on_disconnect();
}

int32_t gopro_ble_ready(void* handle) {
  if (handle == nullptr) {
    return 0;
  }
  return static_cast<BleContext*>(handle)->session->ready() ? 1 : 0;
}

}  // extern "C"
