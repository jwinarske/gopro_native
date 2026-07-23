// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
//
// query_parser.h — decodes reassembled query responses and status pushes.
//
// Turns a completed frame from Reassembler into camera state. This is the
// piece that feeds CommandQueue::set_ready(), since readiness is derived from
// the BUSY and ENCODING statuses the camera reports here.
//
// WIRE FORMAT
//
// The framing header is already stripped by Reassembler::take(), so the
// payload starts at the command id:
//
//   [query_cmd_id] [status] [id, len, value] [id, len, value] ...
//
// Verified against a MAX2. A response to GET_STATUS_VAL for BUSY and
// ENCODING arrives as `08 13 00 08 01 00 0a 01 00`, where the leading 08 is
// the GENERAL framing header. After reassembly this parser sees:
//
//   13 00 08 01 00 0a 01 00
//    |  |  |  |  |  |  |  |
//    |  |  |  |  |  |  |  +- value 0
//    |  |  |  |  |  |  +---- len 1
//    |  |  |  |  |  +------- StatusId.encoding (10)
//    |  |  |  |  +---------- value 0
//    |  |  |  +------------- len 1
//    |  |  +---------------- StatusId.busy (8)
//    |  +------------------- status 0 (success)
//    +---------------------- QueryCmdId.getStatusVal (0x13)
//
// Values are big-endian.
//
// UNKNOWN IDS ARE SKIPPED, NOT FATAL
//
// Firmware introduces settings and statuses that any built-in table predates.
// An id this build does not recognize must advance by 2 + len and carry on;
// discarding the rest of the response because one entry was unfamiliar would
// make the whole camera unusable after a firmware update. Mapping ids to
// enums is the caller's job -- this parser reports raw ids and never rejects
// one.

#pragma once

#include <cstdint>
#include <optional>
#include <span>
#include <string_view>
#include <vector>

namespace gp::ble {

/// Query command ids that carry status values rather than setting values.
/// Everything else in a query response refers to settings.
inline constexpr uint8_t kGetStatusVal = 0x13;
inline constexpr uint8_t kRegStatusValUpdate = 0x53;
inline constexpr uint8_t kUnregStatusValUpdate = 0x73;
inline constexpr uint8_t kStatusValPush = 0x93;

/// Status ids the ready gate depends on.
inline constexpr uint8_t kStatusBusy = 8;
inline constexpr uint8_t kStatusEncoding = 10;

struct QueryEntry {
  uint8_t id{};

  /// Big-endian, and legitimately empty: a zero length means a push was
  /// registered for something that has no value yet.
  std::vector<uint8_t> value;

  /// Value as an unsigned integer, or nullopt when empty or wider than 8
  /// bytes.
  [[nodiscard]] std::optional<uint64_t> as_uint() const;

  [[nodiscard]] bool as_bool() const { return as_uint().value_or(0) != 0; }
};

struct QueryResponse {
  uint8_t query_cmd_id{};
  uint8_t status{};  ///< 0 is success; mirrors ErrorCode
  std::vector<QueryEntry> entries;

  /// True when `entries` are status ids; false when they are setting ids.
  [[nodiscard]] bool is_status() const;

  [[nodiscard]] bool ok() const { return status == 0; }

  /// Finds an entry by raw id.
  [[nodiscard]] const QueryEntry* find(uint8_t id) const;
};

enum class QueryParseResult {
  kOk,
  kTooShort,      ///< fewer than 2 bytes; no command id and status
  kTruncatedTlv,  ///< an entry's length ran past the end of the payload
};

[[nodiscard]] std::string_view to_string(QueryParseResult r);

/// Parses a reassembled payload. On kTruncatedTlv, `out` holds the entries
/// decoded before the bad one -- a truncated tail does not invalidate what
/// was already read.
[[nodiscard]] QueryParseResult parse_query(std::span<const uint8_t> payload,
                                           QueryResponse& out);

/// Tracks the camera readiness the command queue gates on.
///
/// Both statuses start unknown. Treating unknown as "not ready" is
/// deliberate: sending ordinary commands before the camera has reported its
/// state is how the reference implementation gets into trouble.
class ReadyState {
 public:
  /// Folds in any BUSY or ENCODING entries. Returns true if `ready()`
  /// changed, so the caller only touches the queue on a real transition.
  bool apply(const QueryResponse& response);

  [[nodiscard]] bool ready() const {
    return busy_.has_value() && !*busy_ && encoding_.has_value() && !*encoding_;
  }

  [[nodiscard]] std::optional<bool> busy() const { return busy_; }
  [[nodiscard]] std::optional<bool> encoding() const { return encoding_; }

  /// Clears both back to unknown. Call on disconnect: stale readiness after
  /// a reconnect would let commands through before the camera has spoken.
  void reset();

 private:
  std::optional<bool> busy_;
  std::optional<bool> encoding_;
};

}  // namespace gp::ble
