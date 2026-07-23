// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
#include "query_parser.h"

namespace gp::ble {

std::string_view to_string(QueryParseResult r) {
  switch (r) {
    case QueryParseResult::kOk:
      return "ok";
    case QueryParseResult::kTooShort:
      return "too-short";
    case QueryParseResult::kTruncatedTlv:
      return "truncated-tlv";
  }
  return "?";
}

std::optional<uint64_t> QueryEntry::as_uint() const {
  if (value.empty() || value.size() > sizeof(uint64_t))
    return std::nullopt;
  uint64_t v = 0;
  for (const uint8_t b : value) {  // big-endian
    v = (v << 8) | b;
  }
  return v;
}

bool QueryResponse::is_status() const {
  switch (query_cmd_id) {
    case kGetStatusVal:
    case kRegStatusValUpdate:
    case kUnregStatusValUpdate:
    case kStatusValPush:
      return true;
    default:
      return false;
  }
}

const QueryEntry* QueryResponse::find(uint8_t id) const {
  for (const auto& e : entries) {
    if (e.id == id)
      return &e;
  }
  return nullptr;
}

QueryParseResult parse_query(std::span<const uint8_t> payload,
                             QueryResponse& out) {
  out = QueryResponse{};
  if (payload.size() < 2)
    return QueryParseResult::kTooShort;

  out.query_cmd_id = payload[0];
  out.status = payload[1];

  size_t i = 2;
  // Each entry is [id][len][value...]. A trailing byte with no length cannot
  // be a complete entry, hence i + 1 < size.
  while (i + 1 < payload.size()) {
    const uint8_t id = payload[i];
    const size_t len = payload[i + 1];

    if (i + 2 + len > payload.size()) {
      // Keep what was decoded before the bad entry: a truncated tail says
      // nothing about the entries already read.
      return QueryParseResult::kTruncatedTlv;
    }

    QueryEntry e;
    e.id = id;
    e.value.assign(payload.begin() + static_cast<ptrdiff_t>(i + 2),
                   payload.begin() + static_cast<ptrdiff_t>(i + 2 + len));
    out.entries.push_back(std::move(e));

    i += 2 + len;
  }

  return QueryParseResult::kOk;
}

// ---------------------------------------------------------------------------
// ReadyState
// ---------------------------------------------------------------------------

void ReadyState::reset() {
  busy_.reset();
  encoding_.reset();
}

bool ReadyState::apply(const QueryResponse& response) {
  // Setting values share the id space with statuses, so a setting whose id
  // happens to be 8 or 10 would otherwise be read as BUSY or ENCODING.
  if (!response.is_status())
    return false;

  const bool was_ready = ready();

  if (const QueryEntry* e = response.find(kStatusBusy)) {
    // A registered push with no value yet carries no information; leaving the
    // previous state alone is better than guessing.
    if (!e->value.empty())
      busy_ = e->as_bool();
  }
  if (const QueryEntry* e = response.find(kStatusEncoding)) {
    if (!e->value.empty())
      encoding_ = e->as_bool();
  }

  return ready() != was_ready;
}

}  // namespace gp::ble
