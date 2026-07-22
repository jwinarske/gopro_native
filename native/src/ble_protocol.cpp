// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
#include "ble_protocol.h"

namespace gp::ble {

std::string_view to_string(FeedResult r) {
  switch (r) {
    case FeedResult::kNeedMore: return "need-more";
    case FeedResult::kComplete: return "complete";
    case FeedResult::kEmptyPacket: return "empty-packet";
    case FeedResult::kTruncatedHdr: return "truncated-header";
    case FeedResult::kReservedHdr: return "reserved-header";
    case FeedResult::kStrayCont: return "stray-continuation";
    case FeedResult::kOverflow: return "overflow";
    case FeedResult::kZeroLength: return "zero-length";
  }
  return "?";
}

// ---------------------------------------------------------------------------
// Transmit
// ---------------------------------------------------------------------------

std::vector<std::vector<uint8_t>> fragment(std::span<const uint8_t> data,
                                           size_t att_payload) {
  std::vector<std::vector<uint8_t>> out;
  if (data.empty() || data.size() > kMaxMessageLen) return out;

  const size_t len = data.size();

  // Build the first-fragment header. EXT_13 up to 2^13-2, EXT_16 beyond --
  // matching the reference implementation, which never emits GENERAL on
  // transmit even though the camera does on receive.
  std::vector<uint8_t> first_hdr;
  if (len < (1u << 13) - 1) {
    first_hdr = {
        static_cast<uint8_t>((static_cast<uint8_t>(PacketHeader::kExt13) << 5) |
                             ((len >> 8) & kExt13Byte0Mask)),
        static_cast<uint8_t>(len & 0xFF),
    };
  } else {
    first_hdr = {
        static_cast<uint8_t>(static_cast<uint8_t>(PacketHeader::kExt16) << 5),
        static_cast<uint8_t>((len >> 8) & 0xFF),
        static_cast<uint8_t>(len & 0xFF),
    };
  }

  // Every fragment must carry at least one payload byte, or fragmentation
  // never terminates. The continuation header is one byte, so the binding
  // constraint is the larger first header.
  if (att_payload <= first_hdr.size()) return out;

  size_t offset = 0;
  bool first = true;
  while (offset < len) {
    std::vector<uint8_t> packet;
    if (first) {
      packet = first_hdr;
      first = false;
    } else {
      packet.push_back(kContMask);
    }

    const size_t room = att_payload - packet.size();
    const size_t take = std::min(room, len - offset);
    packet.insert(packet.end(), data.begin() + static_cast<ptrdiff_t>(offset),
                  data.begin() + static_cast<ptrdiff_t>(offset + take));
    offset += take;
    out.push_back(std::move(packet));
  }
  return out;
}

// ---------------------------------------------------------------------------
// Receive
// ---------------------------------------------------------------------------

void Reassembler::reset() {
  buf_.clear();
  remaining_ = 0;
  declared_ = 0;
  in_progress_ = false;
}

FeedResult Reassembler::feed(std::span<const uint8_t> packet) {
  if (packet.empty()) {
    reset();
    return FeedResult::kEmptyPacket;
  }

  size_t payload_start = 0;

  if ((packet[0] & kContMask) != 0) {
    // A continuation with nothing in flight means we joined mid-message or
    // dropped the start. Accepting it would splice unrelated bytes into the
    // next message, so drop it and stay reset.
    if (!in_progress_) {
      reset();
      return FeedResult::kStrayCont;
    }
    payload_start = 1;
  } else {
    // New message. Discard any partial one -- the camera has moved on.
    buf_.clear();

    const auto hdr = static_cast<PacketHeader>((packet[0] & kHdrMask) >> 5);
    switch (hdr) {
      case PacketHeader::kGeneral:
        declared_ = packet[0] & kGenLenMask;
        payload_start = 1;
        break;
      case PacketHeader::kExt13:
        if (packet.size() < 2) {
          reset();
          return FeedResult::kTruncatedHdr;
        }
        declared_ = (static_cast<size_t>(packet[0] & kExt13Byte0Mask) << 8) |
                    packet[1];
        payload_start = 2;
        break;
      case PacketHeader::kExt16:
        if (packet.size() < 3) {
          reset();
          return FeedResult::kTruncatedHdr;
        }
        declared_ = (static_cast<size_t>(packet[1]) << 8) | packet[2];
        payload_start = 3;
        break;
      case PacketHeader::kReserved:
        reset();
        return FeedResult::kReservedHdr;
    }

    if (declared_ == 0) {
      reset();
      return FeedResult::kZeroLength;
    }

    remaining_ = declared_;
    in_progress_ = true;
    buf_.reserve(declared_);
  }

  const size_t payload_len = packet.size() - payload_start;

  // The reference implementation logs "received too much data. parsing is in
  // unknown state" and carries on with a negative counter. Treat it as a hard
  // error instead: a length that disagrees with the bytes on the wire means
  // the stream is desynchronized, and continuing corrupts the next message
  // too.
  if (payload_len > remaining_) {
    reset();
    return FeedResult::kOverflow;
  }

  buf_.insert(buf_.end(), packet.begin() + static_cast<ptrdiff_t>(payload_start),
              packet.end());
  remaining_ -= payload_len;

  if (remaining_ == 0) {
    in_progress_ = false;
    return FeedResult::kComplete;
  }
  return FeedResult::kNeedMore;
}

std::vector<uint8_t> Reassembler::take() {
  std::vector<uint8_t> out = std::move(buf_);
  buf_.clear();
  remaining_ = 0;
  declared_ = 0;
  in_progress_ = false;
  return out;
}

}  // namespace gp::ble
