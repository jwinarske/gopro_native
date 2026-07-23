// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
//
// Tests for query response parsing and readiness derivation.
//
// The case that matters most is negative: an unrecognized id must not
// discard the rest of the response. Firmware adds settings and statuses that
// any built-in table predates, so a parser that gives up on the first
// unfamiliar entry makes the camera unusable after an update.

#include "query_parser.h"

#include <cstdio>
#include <string>

namespace {

int g_failures = 0;
int g_checks = 0;

void check(bool ok, const std::string& what) {
  ++g_checks;
  if (!ok) {
    ++g_failures;
    std::printf("  [FAIL] %s\n", what.c_str());
  }
}

using namespace gp::ble;

QueryResponse parse(const std::vector<uint8_t>& bytes,
                    QueryParseResult* result = nullptr) {
  QueryResponse r;
  const auto res = parse_query(bytes, r);
  if (result != nullptr)
    *result = res;
  return r;
}

void test_real_capture() {
  std::printf("captured MAX2 response\n");
  // `08 13 00 08 01 00 0a 01 00` off the wire; 08 is the framing header that
  // Reassembler strips, so the parser sees the remainder.
  const std::vector<uint8_t> payload = {0x13, 0x00, 0x08, 0x01,
                                        0x00, 0x0a, 0x01, 0x00};
  QueryParseResult res{};
  const auto r = parse(payload, &res);

  check(res == QueryParseResult::kOk, "parses");
  check(r.query_cmd_id == kGetStatusVal, "command id is GET_STATUS_VAL");
  check(r.status == 0 && r.ok(), "status 0");
  check(r.is_status(), "entries are statuses");
  check(r.entries.size() == 2, "two entries");
  check(r.find(kStatusBusy) != nullptr && !r.find(kStatusBusy)->as_bool(),
        "BUSY = 0");
  check(
      r.find(kStatusEncoding) != nullptr && !r.find(kStatusEncoding)->as_bool(),
      "ENCODING = 0");
}

void test_unknown_ids_are_skipped() {
  std::printf("unknown ids\n");
  // An id this build has never seen sits between two it needs. Its length
  // must be used to step over it.
  const std::vector<uint8_t> payload = {
      0x13, 0x00, 0x08, 0x01, 0x01,        // BUSY = 1
      0xFE, 0x04, 0xDE, 0xAD, 0xBE, 0xEF,  // unknown, 4-byte value
      0x0a, 0x01, 0x01,                    // ENCODING = 1
  };
  QueryParseResult res{};
  const auto r = parse(payload, &res);

  check(res == QueryParseResult::kOk, "parses despite the unknown id");
  check(r.entries.size() == 3, "unknown entry is kept, not dropped");
  check(r.find(kStatusBusy) != nullptr && r.find(kStatusBusy)->as_bool(),
        "BUSY still decoded");
  check(
      r.find(kStatusEncoding) != nullptr && r.find(kStatusEncoding)->as_bool(),
      "ENCODING after the unknown entry still decoded");
  const QueryEntry* unknown = r.find(0xFE);
  check(unknown != nullptr && unknown->value.size() == 4,
        "unknown value preserved verbatim");
}

void test_zero_length_values() {
  std::printf("zero-length values\n");
  // Registering a push for something with no value yet is legal.
  const std::vector<uint8_t> payload = {0x13, 0x00, 0x08, 0x00,
                                        0x0a, 0x01, 0x01};
  QueryParseResult res{};
  const auto r = parse(payload, &res);

  check(res == QueryParseResult::kOk, "parses");
  check(r.entries.size() == 2, "both entries present");
  check(r.find(kStatusBusy)->value.empty(), "BUSY carries no value");
  check(!r.find(kStatusBusy)->as_uint().has_value(),
        "empty value has no integer reading");
  check(r.find(kStatusEncoding)->as_bool(), "ENCODING still decoded");
}

void test_malformed() {
  std::printf("malformed input\n");
  QueryParseResult res{};

  parse({}, &res);
  check(res == QueryParseResult::kTooShort, "empty payload");
  parse({0x13}, &res);
  check(res == QueryParseResult::kTooShort, "command id with no status");

  // A length that runs past the end must not read out of bounds.
  const auto r = parse({0x13, 0x00, 0x08, 0x01, 0x00, 0x0a, 0x7F, 0x01}, &res);
  check(res == QueryParseResult::kTruncatedTlv, "over-long length rejected");
  check(r.entries.size() == 1, "entries before the bad one are kept");
  check(r.find(kStatusBusy) != nullptr, "the good entry survived");

  // A trailing id with no length byte is not a complete entry.
  const auto t = parse({0x13, 0x00, 0x08, 0x01, 0x00, 0x0a}, &res);
  check(res == QueryParseResult::kOk, "dangling id is ignored, not an error");
  check(t.entries.size() == 1, "only the complete entry is reported");
}

void test_status_vs_setting() {
  std::printf("status ids vs setting ids\n");
  check(parse({kGetStatusVal, 0}).is_status(), "GET_STATUS_VAL");
  check(parse({kStatusValPush, 0}).is_status(), "STATUS_VAL_PUSH");
  check(parse({kRegStatusValUpdate, 0}).is_status(), "REG_STATUS_VAL_UPDATE");
  check(!parse({0x12, 0}).is_status(), "GET_SETTING_VAL is not a status query");
  check(!parse({0x92, 0}).is_status(),
        "SETTING_VAL_PUSH is not a status query");
}

void test_big_endian() {
  std::printf("value width and endianness\n");
  const auto r = parse({0x13, 0x00, 0x2A, 0x04, 0x12, 0x34, 0x56, 0x78});
  check(r.find(0x2A)->as_uint() == 0x12345678u, "4-byte value is big-endian");

  const auto w = parse({0x13, 0x00, 0x2B, 0x02, 0x01, 0x00});
  check(w.find(0x2B)->as_uint() == 256u, "2-byte value is big-endian");

  // Wider than uint64 has no integer reading, but the bytes are kept.
  const auto big = parse({0x13, 0x00, 0x2C, 0x09, 1, 2, 3, 4, 5, 6, 7, 8, 9});
  check(!big.find(0x2C)->as_uint().has_value(), "9-byte value has no uint");
  check(big.find(0x2C)->value.size() == 9, "9-byte value is still preserved");
}

void test_ready_state() {
  std::printf("readiness derivation\n");
  ReadyState s;
  check(!s.ready(), "unknown state is not ready");
  check(!s.busy().has_value() && !s.encoding().has_value(), "both unknown");

  // One status alone is not enough.
  check(!s.apply(parse({0x13, 0x00, 0x08, 0x01, 0x00})),
        "BUSY=0 alone does not flip ready");
  check(!s.ready(), "still not ready with ENCODING unknown");

  check(s.apply(parse({0x13, 0x00, 0x0a, 0x01, 0x00})),
        "ENCODING=0 completes the picture and reports a change");
  check(s.ready(), "ready once both are clear");

  // Going busy is a transition; staying busy is not.
  check(s.apply(parse({0x93, 0x00, 0x08, 0x01, 0x01})), "BUSY=1 flips ready");
  check(!s.ready(), "not ready while busy");
  check(!s.apply(parse({0x93, 0x00, 0x08, 0x01, 0x01})),
        "repeating BUSY=1 reports no change");

  check(s.apply(parse({0x93, 0x00, 0x08, 0x01, 0x00})), "BUSY=0 flips back");
  check(s.ready(), "ready again");
}

void test_ready_state_ignores_settings() {
  std::printf("readiness ignores setting queries\n");
  ReadyState s;
  (void)s.apply(parse({0x13, 0x00, 0x08, 0x01, 0x00, 0x0a, 0x01, 0x00}));
  check(s.ready(), "ready from a status query");

  // Setting id 8 is a different thing from status id 8. A setting response
  // must not be read as readiness.
  check(!s.apply(parse({0x12, 0x00, 0x08, 0x01, 0x01})),
        "setting query reports no change");
  check(s.ready(), "readiness unaffected by a setting with the same id");
}

void test_ready_state_reset() {
  std::printf("reset on disconnect\n");
  ReadyState s;
  (void)s.apply(parse({0x13, 0x00, 0x08, 0x01, 0x00, 0x0a, 0x01, 0x00}));
  check(s.ready(), "ready before reset");

  s.reset();
  // Carrying readiness across a reconnect would let commands through before
  // the camera has reported anything.
  check(!s.ready(), "not ready after reset");
  check(!s.busy().has_value(), "BUSY back to unknown");
}

void test_empty_value_does_not_clobber() {
  std::printf("zero-length push does not clobber known state\n");
  ReadyState s;
  (void)s.apply(parse({0x13, 0x00, 0x08, 0x01, 0x00, 0x0a, 0x01, 0x00}));
  check(s.ready(), "ready");

  // Registering a push yields an entry with no value. It carries no
  // information and must leave the previous reading alone.
  check(!s.apply(parse({0x53, 0x00, 0x08, 0x00, 0x0a, 0x00})),
        "valueless registration reports no change");
  check(s.ready(), "still ready");
}

}  // namespace

int main() {
  test_real_capture();
  test_unknown_ids_are_skipped();
  test_zero_length_values();
  test_malformed();
  test_status_vs_setting();
  test_big_endian();
  test_ready_state();
  test_ready_state_ignores_settings();
  test_ready_state_reset();
  test_empty_value_does_not_clobber();

  std::printf("\n%d checks, %d failed\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
