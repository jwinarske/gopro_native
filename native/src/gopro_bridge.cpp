// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
// gopro_bridge.cpp — C ABI wrapping USB discovery for Dart FFI.

#include "gopro_bridge.h"

#include <atomic>
#include <chrono>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

#include "gopro_types.h"
#include "gopro_usb.h"

namespace {

using clock = std::chrono::steady_clock;

struct Pending {
  gp::Camera cam;
  clock::time_point arrived;
  gp::Readiness last;
};

struct BridgeContext {
  std::unique_ptr<gp::Discovery> disco;
  Dart_Port_DL events_port{};
  std::thread worker;
  std::atomic<bool> stop{false};
  std::atomic<int> timeout_ms{10000};
  std::atomic<bool> rescan{false};

  std::mutex mu;
  std::vector<Pending> pending;
};

uint32_t ms_since(clock::time_point t) {
  return static_cast<uint32_t>(
      std::chrono::duration_cast<std::chrono::milliseconds>(clock::now() - t)
          .count());
}

gp::CameraRecord to_record(const gp::Camera& c, uint32_t elapsed_ms) {
  gp::CameraRecord r;
  r.vid = c.vid;
  r.pid = c.pid;
  r.bus = c.bus;
  r.address = c.address;
  r.sysfsName = c.sysfs_name;
  r.serial = c.serial;
  r.serialSource = static_cast<uint8_t>(c.serial_source);
  r.ip = c.ip;
  r.netdev = c.netdev;
  r.netdevFirstSeen = c.netdev_first_seen;
  r.netdevRenamed = c.netdev_renamed;
  r.linkState = c.link_state;
  r.hostIp = c.host_ip;
  r.readiness = static_cast<uint8_t>(c.readiness);
  r.hasCdc = c.has_cdc_interface;
  r.elapsedMs = elapsed_ms;
  return r;
}

// Post one event to Dart. Payload is a discriminator byte followed by the
// binary struct encoding.
//
// kTypedData (which copies) rather than kExternalTypedData (which transfers a
// C-heap pointer) is deliberate: these records are a few hundred bytes and
// arrive at human timescales, so a malloc plus a GC finalizer per event would
// cost more than the copy it avoids. Reassembled BLE frames in Phase 3 are
// the opposite case -- multi-kilobyte and frequent -- and should transfer
// rather than copy.
void post(Dart_Port_DL port, gp::EventKind kind, const gp::CameraRecord* rec) {
  std::vector<uint8_t> buf;
  buf.push_back(static_cast<uint8_t>(kind));
  if (rec != nullptr) {
    const auto payload = glz::encode(*rec);
    buf.insert(buf.end(), payload.begin(), payload.end());
  }

  Dart_CObject obj;
  obj.type = Dart_CObject_kTypedData;
  obj.value.as_typed_data.type = Dart_TypedData_kUint8;
  obj.value.as_typed_data.length = static_cast<intptr_t>(buf.size());
  obj.value.as_typed_data.values = buf.data();
  Dart_PostCObject_DL(port, &obj);
}

void worker_loop(BridgeContext* ctx) {
  post(ctx->events_port, gp::EventKind::kSentinel, nullptr);

  while (!ctx->stop.load(std::memory_order_relaxed)) {
    // Hotplug callbacks fire inside pump(), on this thread.
    ctx->disco->pump(50);

    if (ctx->rescan.exchange(false)) {
      for (auto& c : ctx->disco->enumerate()) {
        const auto rec = to_record(c, 0);
        post(ctx->events_port, gp::EventKind::kUpdate, &rec);
      }
    }

    const int budget = ctx->timeout_ms.load(std::memory_order_relaxed);
    const std::lock_guard lk(ctx->mu);
    for (auto it = ctx->pending.begin(); it != ctx->pending.end();) {
      const gp::Readiness before = it->last;
      const gp::Readiness after = gp::advance_readiness(it->cam);
      const uint32_t elapsed = ms_since(it->arrived);

      if (after != before) {
        it->last = after;
        const auto rec = to_record(it->cam, elapsed);
        post(ctx->events_port, gp::EventKind::kUpdate, &rec);
      }

      const bool done = after == gp::Readiness::kL3Ready ||
                        after == gp::Readiness::kAbsent ||
                        elapsed > static_cast<uint32_t>(budget);
      if (done) {
        // Emit a final record on timeout even if nothing changed, so Dart
        // always learns the terminal state rather than waiting forever.
        if (after == before && after != gp::Readiness::kL3Ready) {
          const auto rec = to_record(it->cam, elapsed);
          post(ctx->events_port, gp::EventKind::kUpdate, &rec);
        }
        it = ctx->pending.erase(it);
      } else {
        ++it;
      }
    }
  }
}

}  // namespace

extern "C" {

void gopro_bridge_init(void* dart_api_dl_data) {
  Dart_InitializeApiDL(dart_api_dl_data);
}

void* gopro_discovery_create(int64_t events_port, uint16_t vid) {
  auto ctx = std::make_unique<BridgeContext>();
  ctx->events_port = events_port;
  ctx->disco = gp::Discovery::create(vid == 0 ? gp::kGoProVid : vid);
  if (!ctx->disco)
    return nullptr;
  if (!gp::Discovery::hotplug_supported())
    return nullptr;

  BridgeContext* raw = ctx.get();
  const bool ok = raw->disco->watch([raw](const gp::Camera& c, bool arrived) {
    if (arrived) {
      // Do NOT settle here -- this runs on the worker's libusb event path and
      // reaching L3 takes ~750 ms. Record it; the loop drains it.
      const std::lock_guard lk(raw->mu);
      raw->pending.push_back({c, clock::now(), c.readiness});
      const auto rec = to_record(c, 0);
      post(raw->events_port, gp::EventKind::kUpdate, &rec);
    } else {
      {
        const std::lock_guard lk(raw->mu);
        std::erase_if(raw->pending, [&](const Pending& p) {
          return p.cam.sysfs_name == c.sysfs_name;
        });
      }
      const auto rec = to_record(c, 0);
      post(raw->events_port, gp::EventKind::kLeft, &rec);
    }
  });
  if (!ok)
    return nullptr;

  ctx->worker = std::thread(worker_loop, raw);
  return ctx.release();
}

void gopro_discovery_destroy(void* handle) {
  if (handle == nullptr)
    return;
  auto* ctx = static_cast<BridgeContext*>(handle);
  ctx->stop.store(true, std::memory_order_relaxed);
  if (ctx->worker.joinable())
    ctx->worker.join();
  delete ctx;
}

void gopro_discovery_rescan(void* handle) {
  if (handle == nullptr)
    return;
  static_cast<BridgeContext*>(handle)->rescan.store(true,
                                                    std::memory_order_relaxed);
}

void gopro_discovery_set_timeout(void* handle, int32_t timeout_ms) {
  if (handle == nullptr)
    return;
  static_cast<BridgeContext*>(handle)->timeout_ms.store(
      timeout_ms, std::memory_order_relaxed);
}

}  // extern "C"
