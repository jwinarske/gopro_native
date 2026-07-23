// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
#pragma once

// GoPro USB discovery — enumerate-only.
//
// The camera enumerates as a CDC-NCM (or RNDIS on older models) ethernet
// gadget. The kernel's cdc_ncm/rndis_host driver binds it and creates a
// netdev; the Open GoPro control API is plain HTTP over TCP on that
// interface. libusb is used here ONLY to identify the device and observe
// attach/detach.
//
// INVARIANT: this translation unit never calls libusb_claim_interface(),
// libusb_detach_kernel_driver(), or libusb_set_auto_detach_kernel_driver().
// Claiming would detach cdc_ncm and destroy the transport we are trying to
// find. libusb_open() is safe -- it does not disturb kernel drivers -- and is
// used solely to read the serial-number string descriptor. When open() is
// denied (no udev rule, not root) the serial is read from sysfs instead.

#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

struct libusb_context;
struct libusb_device;

namespace gp {

// GoPro, Inc. -- confirmed in usb.ids. PIDs are model-specific and
// undocumented, so discovery matches on vendor only.
inline constexpr uint16_t kGoProVid = 0x2672;

// Where the serial came from. Provenance matters, and not for the reason it
// first appears to.
//
// The obvious reading is "descriptor means the udev rule is installed". That
// is true at steady state and WRONG on the hotplug path: logind applies the
// uaccess ACL asynchronously, so libusb_open() at hotplug time routinely loses
// the race and returns EACCES even on a correctly configured desktop.
// Measured on a MAX2 replug: the settled device read (descriptor), the same
// device 48 ms after re-enumeration read (sysfs).
//
// The sysfs fallback is therefore load-bearing on the path that matters, not a
// convenience for misconfigured systems. Without it a replug yields no serial,
// hence no derived IP, hence total failure.
enum class SerialSource { kNone, kDescriptor, kSysfs };

// A camera is not usable the moment USB enumeration completes. Three distinct
// things must happen, and they are seconds apart:
//
//   kUsbPresent     device enumerated                        t = 0
//   kNetdevBound    cdc_ncm created the interface            +46 ms measured
//   kHostAddressed  DHCP lease from the camera's server      > 1 s measured
//   kL3Ready        camera answers on :8080
//
// Reporting a camera as available before kL3Ready produces intermittent
// connection failures that are painful to reproduce, because at steady state
// every stage completes within ~2 ms and the bug never shows.
enum class Readiness {
  kAbsent,
  kUsbPresent,
  kNetdevBound,
  kHostAddressed,
  kL3Ready,
};

[[nodiscard]] std::string_view to_string(Readiness r);

struct Camera {
  uint16_t vid{};
  uint16_t pid{};
  uint8_t bus{};
  uint8_t address{};
  std::vector<uint8_t> ports;  // libusb_get_port_numbers()

  std::string sysfs_name;  // "3-2.1" -- the /sys/bus/usb/devices entry
  std::string serial;      // full serial number, may be empty
  SerialSource serial_source{SerialSource::kNone};

  std::string ip;  // derived 172.2X.1YZ.51, empty if serial unusable

  // Current netdev name. NEVER CACHE THIS -- see the DEBUG NOTE on
  // resolve_netdev(). Re-resolve at point of use, or pin the name with the
  // udev rule so the question cannot arise.
  std::string netdev;

  // --- rename-race diagnostics (see DEBUG NOTE on resolve_netdev) ---------
  // First non-empty name ever observed for this device, and whether it has
  // changed since. netdev_renamed == true means this run witnessed the
  // kernel-name -> predictable-name rename, which is the signature to look
  // for when a cached interface name has gone stale.
  std::string netdev_first_seen;
  bool netdev_renamed{false};

  // Informational only, never gated on: USB network devices frequently report
  // "unknown" here even when perfectly usable, so treating it as a readiness
  // condition would hang forever on hardware that works.
  std::string link_state;

  // IPv4 the host holds on `netdev`, handed out by the camera's own DHCP
  // server. Empty until the lease completes.
  std::string host_ip;

  Readiness readiness{Readiness::kAbsent};

  // True when at least one interface reports a CDC communications or CDC
  // data class, i.e. this really is the network gadget and not some other
  // USB function the camera exposes. (MAX2 is a 3-interface composite: CDC
  // control, CDC data, and a PTP interface a desktop MTP daemon claims.)
  bool has_cdc_interface{false};

  [[nodiscard]] std::string describe() const;
};

// ---------------------------------------------------------------------------
// Pure helpers (no libusb, no filesystem) -- covered by --selftest.
// ---------------------------------------------------------------------------

// Open GoPro derives the wired IP from the last three digits of the serial:
//   172.2{X}.1{Y}{Z}.51
// Returns nullopt when the serial is shorter than 3 chars or its last three
// characters are not all ASCII digits.
[[nodiscard]] std::optional<std::string> derive_ip(std::string_view serial);

// Build the /sys/bus/usb/devices entry name: "<bus>-<port>[.<port>...]".
// A device directly on a root hub with no ports yields "usb<bus>".
[[nodiscard]] std::string sysfs_name(uint8_t bus,
                                     std::span<const uint8_t> ports);

// ---------------------------------------------------------------------------
// Filesystem helper
// ---------------------------------------------------------------------------

// Find the netdev bound to a USB device by scanning
//   /sys/bus/usb/devices/<sysfs_name>/<sysfs_name>:*/net/*
// Returns empty when no driver has bound an interface yet -- which is normal
// for a few tens of milliseconds after plug-in, and permanent if the kernel
// lacks cdc_ncm. `root` is overridable for testing against a fake sysfs tree.
//
// ===========================================================================
// DEBUG NOTE -- netdev rename race.  Read this before chasing a "wrong
// interface name" bug; it will save you an afternoon.
//
// The kernel registers a USB network interface under its own temporary name
// (eth0, eth1, ...) and udev renames it to the predictable name a few
// milliseconds later. Both events are visible in the kernel log:
//
//   cdc_ncm 2-1:1.0 eth0: register 'cdc_ncm' at usb-0000:11:00.0-1, CDC NCM
//   cdc_ncm 2-1:1.0 enp17s0u1: renamed from eth0
//
// A name sampled inside the hotplug callback lands in that window often
// enough to matter. Measured on a MAX2 replug: the callback fired 48 ms after
// enumeration and observed "eth0"; the interface was "enp17s0u1" moments
// later. The value was already stale when it was printed.
//
// Symptom to look for: a cached interface name that no longer exists, bind
// or route failures against a device that is plainly present, or a name that
// differs between two runs with no configuration change. Camera::netdev_renamed
// is set when this library witnesses the transition, and
// Camera::netdev_first_seen preserves the transient name -- so if a debug
// report shows renamed=true, the name captured at arrival is the culprit.
//
// Mitigations, in order of preference:
//   1. Install udev/99-gopro.rules, which pins the name to gopro0. The race
//      disappears because there is nothing to rename to.
//   2. Re-resolve at point of use rather than caching. This function is
//      cheap -- two directory reads -- so there is no reason to cache.
//   3. Wait for Readiness::kHostAddressed before reading the name at all;
//      by then udev has long since settled.
// ===========================================================================
[[nodiscard]] std::string find_netdev(
    std::string_view sysfs_name,
    std::string_view root = "/sys/bus/usb/devices");

// Re-resolve c.netdev from sysfs and maintain the rename diagnostics
// (netdev_first_seen / netdev_renamed). Idempotent and cheap; call it rather
// than trusting a previously stored name.
void resolve_netdev(Camera& c, std::string_view root = "/sys/bus/usb/devices");

// IPv4 address the host holds on `netdev`, or empty. This is the DHCP lease
// from the camera's own server, and its arrival is what actually gates
// reachability.
[[nodiscard]] std::string host_ipv4(std::string_view netdev);

// Contents of /sys/class/net/<netdev>/operstate. Informational only -- USB
// network devices commonly report "unknown" while fully functional.
[[nodiscard]] std::string link_state(std::string_view netdev);

// Re-sample every stage and update c.readiness, c.netdev, c.host_ip,
// c.link_state. Cheap enough to poll. `probe_port` of 0 stops at
// kHostAddressed without opening a socket.
Readiness advance_readiness(Camera& c,
                            uint16_t probe_port = 8080,
                            int probe_timeout_ms = 500);

// Poll advance_readiness() until kL3Ready or the deadline expires. Returns
// the stage actually reached, so a timeout still reports how far it got --
// "stopped at kNetdevBound" and "stopped at kHostAddressed" are very
// different failures.
//
// Do NOT call this from a libusb hotplug callback: it blocks for seconds and
// the callback runs on the event thread. Record the arrival, then settle it
// from your own loop.
Readiness wait_until_ready(Camera& c,
                           int timeout_ms,
                           int poll_ms = 50,
                           uint16_t probe_port = 8080);

// ---------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------

class Discovery {
 public:
  // arrived == false means the device left; on departure libusb can no longer
  // read descriptors, so only bus/address/ports/sysfs_name are populated and
  // the rest is filled from the arrival cache when available.
  using HotplugCallback = std::function<void(const Camera&, bool arrived)>;

  // vid is overridable so the spike can be exercised against whatever device
  // happens to be plugged in.
  static std::unique_ptr<Discovery> create(uint16_t vid = kGoProVid);
  ~Discovery();

  Discovery(const Discovery&) = delete;
  Discovery& operator=(const Discovery&) = delete;

  [[nodiscard]] std::vector<Camera> enumerate();

  // Static: libusb reports this per platform, not per context.
  [[nodiscard]] static bool hotplug_supported();

  // Registers for arrive/leave. Returns false if hotplug is unsupported on
  // this platform/libusb build.
  bool watch(HotplugCallback cb);

  // Drives libusb's event loop. Call in a loop; blocks up to timeout_ms.
  void pump(int timeout_ms);

 private:
  struct Impl;
  explicit Discovery(std::unique_ptr<Impl> impl);
  std::unique_ptr<Impl> impl_;
};

// TCP-connect probe against <ip>:8080 with a bounded timeout. This is what
// actually validates the whole premise -- that a serial read over USB yields
// an address the HTTP control API answers on. Returns true on connect.
[[nodiscard]] bool probe_tcp(std::string_view ip,
                             uint16_t port,
                             int timeout_ms);

}  // namespace gp
