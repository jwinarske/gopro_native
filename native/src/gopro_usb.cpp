// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
#include "gopro_usb.h"

#include <libusb-1.0/libusb.h>

#include <arpa/inet.h>
#include <ifaddrs.h>
#include <netinet/in.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <filesystem>
#include <format>
#include <fstream>
#include <mutex>
#include <thread>
#include <unordered_map>

namespace fs = std::filesystem;

namespace gp {
namespace {

// Read a single-line sysfs attribute, trimming the trailing newline.
std::string read_sysfs_line(const fs::path& p) {
  std::ifstream in(p);
  if (!in)
    return {};
  std::string s;
  std::getline(in, s);
  while (!s.empty() && (s.back() == '\n' || s.back() == '\r'))
    s.pop_back();
  return s;
}

bool is_cdc_class(uint8_t cls) {
  // 0x02 CDC control, 0x0a CDC data, 0xef misc (RNDIS composite).
  return cls == LIBUSB_CLASS_COMM || cls == LIBUSB_CLASS_DATA || cls == 0xef;
}

}  // namespace

// ---------------------------------------------------------------------------
// Pure helpers
// ---------------------------------------------------------------------------

std::optional<std::string> derive_ip(std::string_view serial) {
  if (serial.size() < 3)
    return std::nullopt;
  const std::string_view tail = serial.substr(serial.size() - 3);
  for (const char c : tail) {
    if (std::isdigit(static_cast<unsigned char>(c)) == 0)
      return std::nullopt;
  }
  // Open GoPro: 172.2{X}.1{Y}{Z}.51
  return std::format("172.2{}.1{}{}.51", tail[0], tail[1], tail[2]);
}

std::string sysfs_name(uint8_t bus, std::span<const uint8_t> ports) {
  if (ports.empty())
    return std::format("usb{}", static_cast<int>(bus));
  std::string s = std::format("{}-{}", static_cast<int>(bus),
                              static_cast<int>(ports.front()));
  for (const uint8_t p : ports.subspan(1)) {
    s += std::format(".{}", static_cast<int>(p));
  }
  return s;
}

std::string_view to_string(Readiness r) {
  switch (r) {
    case Readiness::kAbsent:
      return "absent";
    case Readiness::kUsbPresent:
      return "usb-present";
    case Readiness::kNetdevBound:
      return "netdev-bound";
    case Readiness::kHostAddressed:
      return "host-addressed";
    case Readiness::kL3Ready:
      return "l3-ready";
  }
  return "?";
}

std::string Camera::describe() const {
  std::string s =
      std::format("{:04x}:{:04x} bus {} addr {} at {}", vid, pid,
                  static_cast<int>(bus), static_cast<int>(address), sysfs_name);
  s += std::format(
      "\n    serial : {}{}", serial.empty() ? "<unavailable>" : serial,
      serial_source == SerialSource::kSysfs        ? " (sysfs)"
      : serial_source == SerialSource::kDescriptor ? " (descriptor)"
                                                   : "");
  s += std::format("\n    ip     : {}", ip.empty() ? "<underivable>" : ip);
  s += std::format(
      "\n    netdev : {}{}", netdev.empty() ? "<not bound>" : netdev,
      netdev_renamed ? std::format("  (RENAMED from '{}' -- see DEBUG NOTE)",
                                   netdev_first_seen)
                     : "");
  s += std::format("\n    link   : {}", link_state.empty() ? "-" : link_state);
  s += std::format("\n    host ip: {}",
                   host_ip.empty() ? "<no lease>" : host_ip);
  s += std::format("\n    cdc    : {}", has_cdc_interface ? "yes" : "no");
  s += std::format("\n    state  : {}", to_string(readiness));
  return s;
}

// ---------------------------------------------------------------------------
// sysfs -> netdev
// ---------------------------------------------------------------------------

std::string find_netdev(std::string_view sysfs_name, std::string_view root) {
  std::error_code ec;
  const fs::path dev_dir = fs::path(root) / std::string(sysfs_name);
  if (!fs::is_directory(dev_dir, ec))
    return {};

  // Interface directories are named "<device>:<config>.<interface>". A device
  // has several -- CDC control and CDC data are separate interfaces -- and
  // only the one the network driver bound has a net/ subdirectory. Iteration
  // order is unspecified, so every interface must be examined.
  //
  // Each filesystem probe gets its own error_code. Sharing one across the
  // loop means a miss on interface N (the normal case: no net/ dir) leaves a
  // sticky error that aborts the scan before reaching interface N+1.
  const std::string prefix = std::string(sysfs_name) + ":";
  for (const auto& entry : fs::directory_iterator(dev_dir, ec)) {
    const std::string name = entry.path().filename().string();
    if (!name.starts_with(prefix))
      continue;

    std::error_code probe_ec;
    const fs::path net_dir = entry.path() / "net";
    if (!fs::is_directory(net_dir, probe_ec))
      continue;

    std::error_code iter_ec;
    for (const auto& n : fs::directory_iterator(net_dir, iter_ec)) {
      return n.path().filename().string();
    }
  }
  return {};
}

// ---------------------------------------------------------------------------
// Readiness
// ---------------------------------------------------------------------------

void resolve_netdev(Camera& c, std::string_view root) {
  const std::string now = find_netdev(c.sysfs_name, root);
  if (now.empty())
    return;  // not bound yet; keep whatever we had

  if (c.netdev_first_seen.empty()) {
    c.netdev_first_seen = now;
  } else if (c.netdev_first_seen != now) {
    // Witnessed the kernel-name -> predictable-name transition. See the
    // DEBUG NOTE in gopro_usb.h.
    c.netdev_renamed = true;
  }
  c.netdev = now;
}

std::string host_ipv4(std::string_view netdev) {
  if (netdev.empty())
    return {};

  ifaddrs* ifa = nullptr;
  if (::getifaddrs(&ifa) != 0)
    return {};

  std::string out;
  for (const ifaddrs* p = ifa; p != nullptr; p = p->ifa_next) {
    if (p->ifa_addr == nullptr || p->ifa_name == nullptr)
      continue;
    if (p->ifa_addr->sa_family != AF_INET)
      continue;
    if (netdev != p->ifa_name)
      continue;

    std::array<char, INET_ADDRSTRLEN> buf{};
    const auto* sin = reinterpret_cast<const sockaddr_in*>(p->ifa_addr);
    if (::inet_ntop(AF_INET, &sin->sin_addr, buf.data(), buf.size()) !=
        nullptr) {
      out.assign(buf.data());
    }
    break;
  }
  ::freeifaddrs(ifa);
  return out;
}

std::string link_state(std::string_view netdev) {
  if (netdev.empty())
    return {};
  return read_sysfs_line(fs::path("/sys/class/net") / std::string(netdev) /
                         "operstate");
}

Readiness advance_readiness(Camera& c,
                            uint16_t probe_port,
                            int probe_timeout_ms) {
  // Stage 1 -- is the USB device still there at all?
  std::error_code ec;
  if (!fs::exists(fs::path("/sys/bus/usb/devices") / c.sysfs_name, ec)) {
    c.readiness = Readiness::kAbsent;
    return c.readiness;
  }
  c.readiness = Readiness::kUsbPresent;

  // Stage 2 -- has cdc_ncm created the interface? Always re-resolve; the name
  // observed at hotplug time is frequently the transient kernel one.
  resolve_netdev(c);
  if (c.netdev.empty())
    return c.readiness;
  c.link_state = link_state(c.netdev);
  c.readiness = Readiness::kNetdevBound;

  // Stage 3 -- has DHCP handed us a lease? This is the slow one (> 1 s
  // measured), and skipping it is what makes connections fail intermittently.
  //
  // Deliberately NOT gated on link_state: USB network devices commonly report
  // "unknown" while fully functional, so requiring "up" would hang forever on
  // working hardware.
  c.host_ip = host_ipv4(c.netdev);
  if (c.host_ip.empty())
    return c.readiness;
  c.readiness = Readiness::kHostAddressed;

  // Stage 4 -- does the camera actually answer?
  if (probe_port == 0 || c.ip.empty())
    return c.readiness;
  if (probe_tcp(c.ip, probe_port, probe_timeout_ms)) {
    c.readiness = Readiness::kL3Ready;
  }
  return c.readiness;
}

Readiness wait_until_ready(Camera& c,
                           int timeout_ms,
                           int poll_ms,
                           uint16_t probe_port) {
  using clock = std::chrono::steady_clock;
  const auto deadline = clock::now() + std::chrono::milliseconds(timeout_ms);

  for (;;) {
    // Keep the per-attempt TCP timeout short so a refused/black-holed probe
    // does not eat the whole budget in one attempt.
    if (advance_readiness(c, probe_port, std::min(poll_ms * 4, 500)) ==
        Readiness::kL3Ready) {
      return c.readiness;
    }
    if (clock::now() >= deadline)
      return c.readiness;
    std::this_thread::sleep_for(std::chrono::milliseconds(poll_ms));
  }
}

// ---------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------

struct Discovery::Impl {
  libusb_context* ctx{nullptr};
  uint16_t vid{kGoProVid};

  libusb_hotplug_callback_handle handle{};
  bool watching{false};
  HotplugCallback cb;

  // Arrival cache, so a departure event can report the serial/ip the device
  // had while it was still readable.
  std::mutex cache_mu;
  std::unordered_map<std::string, Camera> cache;  // keyed by sysfs_name

  // Fills everything obtainable from a live libusb_device. Never claims.
  static Camera build(libusb_device* dev, bool readable);

  // libusb C callback. A member so it can see this private nested type.
  static int LIBUSB_CALL trampoline(libusb_context* ctx,
                                    libusb_device* dev,
                                    libusb_hotplug_event event,
                                    void* user_data);
};

namespace {

Camera build_identity(libusb_device* dev) {
  Camera c;
  libusb_device_descriptor desc{};
  if (libusb_get_device_descriptor(dev, &desc) == 0) {
    c.vid = desc.idVendor;
    c.pid = desc.idProduct;
  }
  c.bus = libusb_get_bus_number(dev);
  c.address = libusb_get_device_address(dev);

  std::array<uint8_t, 8> ports{};
  const int n = libusb_get_port_numbers(dev, ports.data(),
                                        static_cast<int>(ports.size()));
  if (n > 0)
    c.ports.assign(ports.begin(), ports.begin() + n);
  c.sysfs_name = sysfs_name(c.bus, c.ports);
  return c;
}

}  // namespace

Camera Discovery::Impl::build(libusb_device* dev, bool readable) {
  Camera c = build_identity(dev);

  if (!readable)
    return c;

  // --- interface classes (no claim, config descriptor only) --------------
  libusb_config_descriptor* cfg = nullptr;
  if (libusb_get_active_config_descriptor(dev, &cfg) == 0 && cfg != nullptr) {
    for (uint8_t i = 0; i < cfg->bNumInterfaces && !c.has_cdc_interface; ++i) {
      const libusb_interface& itf = cfg->interface[i];
      for (int a = 0; a < itf.num_altsetting; ++a) {
        if (is_cdc_class(itf.altsetting[a].bInterfaceClass)) {
          c.has_cdc_interface = true;
          break;
        }
      }
    }
    libusb_free_config_descriptor(cfg);
  }

  // --- serial: descriptor first, sysfs on permission failure -------------
  libusb_device_descriptor desc{};
  libusb_get_device_descriptor(dev, &desc);

  if (desc.iSerialNumber != 0) {
    libusb_device_handle* h = nullptr;
    // NOTE: open() only. No claim_interface, no detach_kernel_driver -- see
    // the invariant in gopro_usb.h.
    if (libusb_open(dev, &h) == 0 && h != nullptr) {
      std::array<unsigned char, 256> buf{};
      const int n = libusb_get_string_descriptor_ascii(
          h, desc.iSerialNumber, buf.data(), static_cast<int>(buf.size()));
      if (n > 0) {
        c.serial.assign(reinterpret_cast<char*>(buf.data()),
                        static_cast<size_t>(n));
        c.serial_source = SerialSource::kDescriptor;
      }
      libusb_close(h);
    }
  }

  if (c.serial.empty()) {
    const std::string s = read_sysfs_line(fs::path("/sys/bus/usb/devices") /
                                          c.sysfs_name / "serial");
    if (!s.empty()) {
      c.serial = s;
      c.serial_source = SerialSource::kSysfs;
    }
  }

  if (const auto ip = derive_ip(c.serial))
    c.ip = *ip;

  // Sample the remaining stages without opening a socket -- this runs inside
  // the hotplug callback, which must not block. The caller settles it.
  advance_readiness(c, /*probe_port=*/0);
  return c;
}

Discovery::Discovery(std::unique_ptr<Impl> impl) : impl_(std::move(impl)) {}

Discovery::~Discovery() {
  if (impl_ == nullptr)
    return;
  if (impl_->watching) {
    libusb_hotplug_deregister_callback(impl_->ctx, impl_->handle);
  }
  if (impl_->ctx != nullptr)
    libusb_exit(impl_->ctx);
}

std::unique_ptr<Discovery> Discovery::create(uint16_t vid) {
  auto impl = std::make_unique<Impl>();
  impl->vid = vid;
  if (const int r = libusb_init(&impl->ctx); r != 0) {
    return nullptr;
  }
  return std::unique_ptr<Discovery>(new Discovery(std::move(impl)));
}

std::vector<Camera> Discovery::enumerate() {
  std::vector<Camera> out;
  libusb_device** list = nullptr;
  const ssize_t n = libusb_get_device_list(impl_->ctx, &list);
  if (n < 0)
    return out;

  for (ssize_t i = 0; i < n; ++i) {
    libusb_device_descriptor desc{};
    if (libusb_get_device_descriptor(list[i], &desc) != 0)
      continue;
    if (desc.idVendor != impl_->vid)
      continue;
    Camera c = Impl::build(list[i], /*readable=*/true);
    {
      const std::lock_guard lk(impl_->cache_mu);
      impl_->cache[c.sysfs_name] = c;
    }
    out.push_back(std::move(c));
  }

  libusb_free_device_list(list, /*unref_devices=*/1);
  return out;
}

bool Discovery::hotplug_supported() {
  return libusb_has_capability(LIBUSB_CAP_HAS_HOTPLUG) != 0;
}

int LIBUSB_CALL Discovery::Impl::trampoline(libusb_context* /*ctx*/,
                                            libusb_device* dev,
                                            libusb_hotplug_event event,
                                            void* user_data) {
  auto* impl = static_cast<Discovery::Impl*>(user_data);
  const bool arrived = (event == LIBUSB_HOTPLUG_EVENT_DEVICE_ARRIVED);

  // On departure the device is gone: descriptors and open() are unavailable.
  Camera c = Impl::build(dev, /*readable=*/arrived);

  {
    const std::lock_guard lk(impl->cache_mu);
    if (arrived) {
      impl->cache[c.sysfs_name] = c;
    } else if (auto it = impl->cache.find(c.sysfs_name);
               it != impl->cache.end()) {
      // Recover what we knew while it was present.
      const Camera& prev = it->second;
      c.vid = prev.vid;
      c.pid = prev.pid;
      c.serial = prev.serial;
      c.serial_source = prev.serial_source;
      c.ip = prev.ip;
      c.netdev = prev.netdev;
      c.has_cdc_interface = prev.has_cdc_interface;
      impl->cache.erase(it);
    }
  }

  if (impl->cb)
    impl->cb(c, arrived);
  return 0;  // keep the callback registered
}

bool Discovery::watch(HotplugCallback cb) {
  if (!hotplug_supported())
    return false;
  impl_->cb = std::move(cb);

  const int r = libusb_hotplug_register_callback(
      impl_->ctx,
      static_cast<libusb_hotplug_event>(LIBUSB_HOTPLUG_EVENT_DEVICE_ARRIVED |
                                        LIBUSB_HOTPLUG_EVENT_DEVICE_LEFT),
      LIBUSB_HOTPLUG_ENUMERATE,  // fire for already-attached devices too
      impl_->vid, LIBUSB_HOTPLUG_MATCH_ANY, LIBUSB_HOTPLUG_MATCH_ANY,
      Impl::trampoline, impl_.get(), &impl_->handle);
  if (r != LIBUSB_SUCCESS)
    return false;

  impl_->watching = true;
  return true;
}

void Discovery::pump(int timeout_ms) {
  timeval tv{};
  tv.tv_sec = timeout_ms / 1000;
  tv.tv_usec = (timeout_ms % 1000) * 1000;
  libusb_handle_events_timeout_completed(impl_->ctx, &tv, nullptr);
}

// ---------------------------------------------------------------------------
// TCP probe
// ---------------------------------------------------------------------------

bool probe_tcp(std::string_view ip, uint16_t port, int timeout_ms) {
  const std::string host(ip);
  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_port = htons(port);
  if (inet_pton(AF_INET, host.c_str(), &addr.sin_addr) != 1)
    return false;

  const int fd = ::socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
  if (fd < 0)
    return false;

  bool ok = false;
  const int r = ::connect(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr));
  if (r == 0) {
    ok = true;
  } else if (errno == EINPROGRESS) {
    pollfd pfd{fd, POLLOUT, 0};
    if (::poll(&pfd, 1, timeout_ms) > 0) {
      int err = 0;
      socklen_t len = sizeof(err);
      if (::getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0 && err == 0) {
        ok = true;
      }
    }
  }
  ::close(fd);
  return ok;
}

}  // namespace gp
