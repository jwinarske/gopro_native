// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
//
// ble_protocol.h — GoPro BLE packet fragmentation and reassembly.
//
// Every BLE message longer than one ATT payload is split across packets with a
// one-, two-, or three-byte header on the first fragment and a one-byte
// continuation header on each subsequent one:
//
//   bit 7    continuation flag
//   bits 6-5 header type, when continuation == 0
//
//   type 0b00  GENERAL  1-byte header, 5-bit length in bits 4-0
//   type 0b01  EXT_13   2-byte header, 13-bit length (bits 4-0 || byte 1)
//   type 0b10  EXT_16   3-byte header, 16-bit big-endian length in bytes 1-2
//   type 0b11  RESERVED
//   continuation  1-byte header (0x80), payload follows
//
// Lengths count payload bytes only, excluding every header.
//
// WHY THIS LIVES IN C++ RATHER THAN DART
//
// A NotifyPresetStatus response runs to several kilobytes. At the 20-byte ATT
// minimum that is ~150 fragments. Forwarding each one across the FFI boundary
// would cost ~150 Dart VM wake-ups (tens of microseconds each) plus an
// allocation and a GC finalizer per fragment, to deliver one logical message.
// Reassembling here collapses that to a single post.
//
// Getting this wrong does not crash — it silently truncates or corrupts long
// responses while short ones keep working, which is close to the worst
// possible failure mode. Hence the property tests in ble_protocol_test.cpp.

#pragma once

#include <cstddef>
#include <cstdint>
#include <span>
#include <string_view>
#include <vector>

namespace gp::ble {

inline constexpr uint8_t kContMask = 0b1000'0000;
inline constexpr uint8_t kHdrMask = 0b0110'0000;
inline constexpr uint8_t kGenLenMask = 0b0001'1111;
inline constexpr uint8_t kExt13Byte0Mask = 0b0001'1111;

enum class PacketHeader : uint8_t {
  kGeneral = 0b00,
  kExt13 = 0b01,
  kExt16 = 0b10,
  kReserved = 0b11,
};

/// Largest message the framing can express (16-bit length field).
inline constexpr size_t kMaxMessageLen = (1u << 16) - 2;

/// Minimum ATT payload: the BLE 4.0 default MTU of 23 less 3 bytes of ATT
/// overhead. A conservative floor only -- never assume it.
///
/// MEASURED: a GoPro MAX2 (firmware H24.02.01.30.00) negotiates an MTU of
/// **517** on every characteristic, giving a 514-byte payload. That is the
/// spec maximum, and 25x this floor. The reference implementation hardcodes
/// 20, so it pays ~26x the fragment count on large responses for no reason.
///
/// Read the real value from the transport -- BlueZ exposes it as the MTU
/// property on org.bluez.GattCharacteristic1 -- and pass payload = MTU - 3.
inline constexpr size_t kMinAttPayload = 20;

/// ATT header overhead. Usable payload is the negotiated MTU less this.
inline constexpr size_t kAttOverhead = 3;

// ---------------------------------------------------------------------------
// Transmit
// ---------------------------------------------------------------------------

/// Splits `data` into packets that each fit in `att_payload` bytes.
///
/// Matches the reference implementation's choice of header: EXT_13 when the
/// length fits in 13 bits, EXT_16 otherwise. GENERAL is never emitted on
/// transmit (though it is accepted on receive, since the camera does send it).
///
/// Returns an empty vector if `data` is empty or longer than kMaxMessageLen,
/// or if `att_payload` is too small to carry a header plus at least one byte.
[[nodiscard]] std::vector<std::vector<uint8_t>> fragment(
    std::span<const uint8_t> data, size_t att_payload = kMinAttPayload);

// ---------------------------------------------------------------------------
// Receive
// ---------------------------------------------------------------------------

enum class FeedResult {
  kNeedMore,       ///< accepted; message still incomplete
  kComplete,       ///< accepted; take() now yields the message
  kEmptyPacket,    ///< zero-length packet
  kTruncatedHdr,   ///< packet too short to contain its own header
  kReservedHdr,    ///< header type 0b11
  kStrayCont,      ///< continuation packet with no message in progress
  kOverflow,       ///< payload exceeded the declared length
  kZeroLength,     ///< header declared a zero-length message
};

[[nodiscard]] std::string_view to_string(FeedResult r);

/// Accumulates fragments into complete messages.
///
/// One instance per characteristic: responses on different characteristics
/// interleave, and sharing a reassembler across them would splice unrelated
/// messages together.
class Reassembler {
 public:
  /// Feeds one notification. On kComplete, call take().
  ///
  /// Any error result leaves the reassembler reset, so a corrupt packet costs
  /// one message rather than desynchronizing the stream permanently.
  [[nodiscard]] FeedResult feed(std::span<const uint8_t> packet);

  /// Moves out the completed message. Only valid immediately after feed()
  /// returned kComplete.
  [[nodiscard]] std::vector<uint8_t> take();

  /// Discards any partial message. Call on disconnect.
  ///
  /// This is the failure path that leaks in a malloc-based design: a message
  /// that never completes has no delivery event and therefore no finalizer to
  /// free it. Holding the partial in a member vector makes the cleanup
  /// automatic rather than something a teardown path must remember.
  void reset();

  [[nodiscard]] bool in_progress() const { return in_progress_; }

  /// Payload bytes still expected. Zero when idle.
  [[nodiscard]] size_t bytes_remaining() const { return remaining_; }

  /// Total payload declared by the current message's header.
  [[nodiscard]] size_t declared_len() const { return declared_; }

 private:
  std::vector<uint8_t> buf_;
  size_t remaining_{0};
  size_t declared_{0};
  bool in_progress_{false};
};

}  // namespace gp::ble
