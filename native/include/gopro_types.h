// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
// gopro_types.h — event payload records and their glz::meta descriptions.
//
// Wire format is the compact binary encoding in glaze_meta.h: fields in
// declaration order, little-endian, no type tags, strings length-prefixed.
// lib/src/ffi/codec.dart decodes this byte-for-byte, so the field order here
// and the read order there MUST stay in lockstep.
//
// DEBUG NOTE: a mismatch between this declaration order and codec.dart is
// silent corruption, not a crash -- fields decode into the wrong variables and
// strings come out as garbage lengths. If Dart starts reporting nonsense
// serials or hangs allocating a huge string, suspect drift here first.

#pragma once

#include <cstdint>
#include <string>

#include "glaze_meta.h"

namespace gp {

// Discriminator byte prefixed to every posted payload.
enum class EventKind : uint8_t {
  kSentinel = 0x00,  // bridge initialized; no payload follows
  kUpdate = 0x01,    // arrival or readiness change; CameraRecord follows
  kLeft = 0x02,      // departure; CameraRecord follows (from arrival cache)
};

struct CameraRecord {
  uint16_t vid{};
  uint16_t pid{};
  uint8_t bus{};
  uint8_t address{};
  std::string sysfsName;
  std::string serial;
  uint8_t serialSource{};  // mirrors gp::SerialSource
  std::string ip;
  std::string netdev;
  std::string netdevFirstSeen;
  bool netdevRenamed{};
  std::string linkState;
  std::string hostIp;
  uint8_t readiness{};  // mirrors gp::Readiness
  bool hasCdc{};
  uint32_t elapsedMs{};  // since arrival, for readiness timing
};

}  // namespace gp

template <>
struct glz::meta<gp::CameraRecord> {
  static constexpr auto fields = std::make_tuple(
      glz::field("vid", &gp::CameraRecord::vid),
      glz::field("pid", &gp::CameraRecord::pid),
      glz::field("bus", &gp::CameraRecord::bus),
      glz::field("address", &gp::CameraRecord::address),
      glz::field("sysfsName", &gp::CameraRecord::sysfsName),
      glz::field("serial", &gp::CameraRecord::serial),
      glz::field("serialSource", &gp::CameraRecord::serialSource),
      glz::field("ip", &gp::CameraRecord::ip),
      glz::field("netdev", &gp::CameraRecord::netdev),
      glz::field("netdevFirstSeen", &gp::CameraRecord::netdevFirstSeen),
      glz::field("netdevRenamed", &gp::CameraRecord::netdevRenamed),
      glz::field("linkState", &gp::CameraRecord::linkState),
      glz::field("hostIp", &gp::CameraRecord::hostIp),
      glz::field("readiness", &gp::CameraRecord::readiness),
      glz::field("hasCdc", &gp::CameraRecord::hasCdc),
      glz::field("elapsedMs", &gp::CameraRecord::elapsedMs));
};
