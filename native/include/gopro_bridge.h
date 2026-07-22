// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
// gopro_bridge.h — C ABI exported to Dart FFI.
//
// The bridge owns ONE libusb context and ONE worker thread. That thread pumps
// libusb hotplug events and settles arrived cameras toward L3 readiness,
// posting encoded payloads to the Dart events port.
//
// Why a worker thread rather than letting Dart pump: reaching L3 readiness
// takes ~750 ms (DHCP from the camera's own server). Driving that from the
// Dart event loop would either block it or couple discovery latency to
// whatever else the isolate is doing -- an event arriving mid-frame-render
// waits for the render to finish, and a GC pause stalls discovery outright.
// Dart_PostCObject_DL is thread-safe and callable from any thread, so the
// worker posts directly and Dart never pumps anything.

#pragma once

#include "dart_api_dl.h"

#include <cstdint>

#define GOPRO_EXPORT __attribute__((visibility("default")))

#ifdef __cplusplus
extern "C" {
#endif

// Initialize Dart API dynamic linking. Call once at startup, before any
// _create call, passing NativeApi.initializeApiDLData.
GOPRO_EXPORT void gopro_bridge_init(void* dart_api_dl_data);

// Start discovery. `vid` is overridable for testing; pass 0 for the GoPro
// default (0x2672). Returns an opaque handle, or null if libusb failed to
// initialize or the platform lacks hotplug support.
//
// A kSentinel byte is posted once the worker is running, so Dart can await
// readiness of the bridge itself before trusting an empty camera list.
GOPRO_EXPORT void* gopro_discovery_create(int64_t events_port, uint16_t vid);

// Stops the worker thread and releases the libusb context. Safe on null.
GOPRO_EXPORT void gopro_discovery_destroy(void* handle);

// Force a re-scan, posting a kUpdate for every currently attached camera.
// Not normally needed -- LIBUSB_HOTPLUG_ENUMERATE reports devices already
// present at create time -- but useful after a suspend/resume cycle.
GOPRO_EXPORT void gopro_discovery_rescan(void* handle);

// Readiness budget in milliseconds before a settling camera is abandoned.
// Defaults to 10000. A camera that stalls is still reported, with its
// readiness field showing how far it got.
GOPRO_EXPORT void gopro_discovery_set_timeout(void* handle, int32_t timeout_ms);

#ifdef __cplusplus
}  // extern "C"
#endif
