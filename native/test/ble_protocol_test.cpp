// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
//
// Property and edge-case tests for BLE fragmentation / reassembly.
//
// Fragmentation bugs do not announce themselves: short messages keep working
// while long ones truncate or splice, so the damage shows up as "the camera
// sometimes returns nonsense" much later and far from the cause. The core
// property here is round-trip over the whole interesting size range at every
// plausible MTU, which is cheap to check exhaustively and catches off-by-ones
// that hand-picked examples miss.
//
// Deliberately dependency-free: no gtest, so this runs anywhere the library
// builds.

#include "ble_protocol.h"

#include <cstdio>
#include <cstdlib>
#include <numeric>
#include <random>
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

std::vector<uint8_t> pattern(size_t n, uint32_t seed = 1) {
  // A counter pattern would mask byte-order errors within a fragment; a PRNG
  // sequence makes any transposition visible.
  std::vector<uint8_t> v(n);
  std::mt19937 rng(seed);
  for (auto& b : v) b = static_cast<uint8_t>(rng() & 0xFF);
  return v;
}

// Fragment then reassemble, returning the recovered message.
std::vector<uint8_t> round_trip(const std::vector<uint8_t>& msg, size_t mtu,
                                bool* completed) {
  auto packets = gp::ble::fragment(msg, mtu);
  gp::ble::Reassembler r;
  *completed = false;
  for (size_t i = 0; i < packets.size(); ++i) {
    const auto res = r.feed(packets[i]);
    if (res == gp::ble::FeedResult::kComplete) {
      *completed = (i + 1 == packets.size());  // must complete on the last one
      return r.take();
    }
    if (res != gp::ble::FeedResult::kNeedMore) return {};
  }
  return {};
}

void test_round_trip_exhaustive() {
  std::printf("round-trip across sizes x MTUs\n");
  // MTUs worth covering: the 4.0 floor, a few odd values that land headers on
  // awkward boundaries, and larger negotiated sizes.
  const size_t mtus[] = {4, 5, 20, 23, 64, 185, 244, 512};
  bool all_ok = true;

  for (const size_t mtu : mtus) {
    // Sizes bracketing every header-width and fragment-count boundary.
    for (size_t n = 1; n <= 600; ++n) {
      bool completed = false;
      const auto msg = pattern(n, static_cast<uint32_t>(n * 31 + mtu));
      const auto got = round_trip(msg, mtu, &completed);
      if (got != msg || !completed) {
        all_ok = false;
        std::printf("  [FAIL] mtu=%zu len=%zu (got %zu bytes, completed=%d)\n",
                    mtu, n, got.size(), static_cast<int>(completed));
        break;
      }
    }
  }
  check(all_ok, "round-trip holds for 1..600 bytes at 8 MTUs");
}

void test_header_width_boundaries() {
  std::printf("header width boundaries\n");
  // EXT_13 covers < 2^13-1; EXT_16 takes over at that point. Both sides of the
  // switch must round-trip.
  const size_t sizes[] = {
      8190, 8191, 8192, 8193,       // around 2^13-1
      (1u << 14), (1u << 15) + 7,   // solidly EXT_16
      gp::ble::kMaxMessageLen,      // largest expressible
  };
  for (const size_t n : sizes) {
    bool completed = false;
    const auto msg = pattern(n, static_cast<uint32_t>(n));
    const auto got = round_trip(msg, 20, &completed);
    check(got == msg && completed,
          "round-trip at length " + std::to_string(n));
  }

  // One byte past what the 16-bit length can express must be refused, not
  // silently truncated to a wrong length.
  const auto too_long = std::vector<uint8_t>(gp::ble::kMaxMessageLen + 1, 0xAB);
  check(gp::ble::fragment(too_long, 20).empty(),
        "oversized message is refused");
}

void test_fragment_shape() {
  std::printf("fragment shape\n");
  // 100 bytes at MTU 20: first packet has a 2-byte EXT_13 header (18 payload),
  // the rest have a 1-byte continuation header (19 payload each).
  const auto packets = gp::ble::fragment(pattern(100), 20);
  check(!packets.empty(), "100 bytes fragments");
  size_t payload = 0;
  bool sizes_ok = true;
  for (size_t i = 0; i < packets.size(); ++i) {
    if (packets[i].size() > 20) sizes_ok = false;
    if (i == 0) {
      check((packets[i][0] & gp::ble::kContMask) == 0, "first packet is not a continuation");
      check(((packets[i][0] & gp::ble::kHdrMask) >> 5) ==
                static_cast<uint8_t>(gp::ble::PacketHeader::kExt13),
            "first packet uses EXT_13");
      payload += packets[i].size() - 2;
    } else {
      check(packets[i][0] == gp::ble::kContMask,
            "packet " + std::to_string(i) + " is a continuation");
      payload += packets[i].size() - 1;
    }
  }
  check(sizes_ok, "no packet exceeds the MTU");
  check(payload == 100, "payload bytes sum to the message length");
  check(packets.size() == 1 + (100 - 18 + 18) / 19, "expected fragment count");

  // A single short message still fits in one packet with its header.
  const auto one = gp::ble::fragment(pattern(5), 20);
  check(one.size() == 1, "5 bytes is a single packet");
  check(one[0].size() == 7, "5 bytes + 2-byte EXT_13 header");
}

void test_receive_general_header() {
  std::printf("GENERAL header on receive\n");
  // fragment() never emits GENERAL, but the camera does for short responses,
  // so the receiver must accept it. Hand-build one: 3-byte payload.
  gp::ble::Reassembler r;
  const std::vector<uint8_t> pkt = {0x03, 0xAA, 0xBB, 0xCC};
  check(r.feed(pkt) == gp::ble::FeedResult::kComplete, "GENERAL completes");
  const auto got = r.take();
  check(got == std::vector<uint8_t>({0xAA, 0xBB, 0xCC}), "GENERAL payload");
}

void test_error_paths() {
  std::printf("error paths\n");
  using gp::ble::FeedResult;

  {  // Continuation with nothing in flight.
    gp::ble::Reassembler r;
    const std::vector<uint8_t> cont = {gp::ble::kContMask, 0x01, 0x02};
    check(r.feed(cont) == FeedResult::kStrayCont, "stray continuation rejected");
    check(!r.in_progress(), "stray continuation leaves reassembler idle");
  }
  {  // Empty packet.
    gp::ble::Reassembler r;
    check(r.feed({}) == FeedResult::kEmptyPacket, "empty packet rejected");
  }
  {  // EXT_13 header claiming a second byte that is not there.
    gp::ble::Reassembler r;
    const std::vector<uint8_t> pkt = {0x20};
    check(r.feed(pkt) == FeedResult::kTruncatedHdr, "truncated EXT_13 rejected");
  }
  {  // EXT_16 header missing its length bytes.
    gp::ble::Reassembler r;
    const std::vector<uint8_t> pkt = {0x40, 0x00};
    check(r.feed(pkt) == FeedResult::kTruncatedHdr, "truncated EXT_16 rejected");
  }
  {  // Reserved header type.
    gp::ble::Reassembler r;
    const std::vector<uint8_t> pkt = {0x60, 0x01};
    check(r.feed(pkt) == FeedResult::kReservedHdr, "reserved header rejected");
  }
  {  // Header declaring zero payload.
    gp::ble::Reassembler r;
    const std::vector<uint8_t> pkt = {0x00};
    check(r.feed(pkt) == FeedResult::kZeroLength, "zero-length rejected");
  }
  {  // More payload than the header declared.
    gp::ble::Reassembler r;
    const std::vector<uint8_t> pkt = {0x02, 0xAA, 0xBB, 0xCC};  // says 2, has 3
    check(r.feed(pkt) == FeedResult::kOverflow, "overflow rejected");
    check(!r.in_progress(), "overflow leaves reassembler idle");
  }
}

void test_recovery_after_error() {
  std::printf("recovery\n");
  gp::ble::Reassembler r;

  // Start a long message, then interrupt it with a fresh one. The partial must
  // be discarded, not spliced onto the new message -- this is the failure that
  // produces plausible-looking garbage rather than an obvious error.
  const auto big = pattern(200, 7);
  const auto packets = gp::ble::fragment(big, 20);
  (void)r.feed(packets[0]);
  (void)r.feed(packets[1]);
  check(r.in_progress(), "partial message is in progress");

  const auto small = pattern(10, 9);
  bool completed = false;
  const auto recovered = round_trip(small, 20, &completed);
  check(recovered == small && completed, "unrelated message round-trips");

  // A stray continuation must not resurrect the abandoned partial.
  gp::ble::Reassembler r2;
  (void)r2.feed(packets[0]);
  r2.reset();
  check(!r2.in_progress(), "reset clears the partial");
  const std::vector<uint8_t> cont = {gp::ble::kContMask, 0xFF};
  check(r2.feed(cont) == gp::ble::FeedResult::kStrayCont,
        "continuation after reset is rejected");
}

void test_mtu_scaling() {
  std::printf("MTU scaling\n");
  // The headline reason to negotiate a larger MTU: a multi-kilobyte preset
  // response costs ~150 fragments at the 4.0 floor and a handful at 512.
  const auto msg = pattern(3000);
  const auto at20 = gp::ble::fragment(msg, 20);
  const auto at512 = gp::ble::fragment(msg, 512);
  check(at20.size() > 150, "3 KB needs >150 fragments at MTU 20");
  check(at512.size() < 10, "3 KB needs <10 fragments at MTU 512");
  std::printf("  (3000 bytes: %zu fragments at 20, %zu at 512 — %.0fx fewer)\n",
              at20.size(), at512.size(),
              static_cast<double>(at20.size()) /
                  static_cast<double>(at512.size()));

  // An MTU too small to hold the first header plus one payload byte must be
  // refused rather than looping forever emitting header-only packets.
  //
  // The threshold depends on message length, because the header width does:
  // a 3 KB message uses a 2-byte EXT_13 header and so survives an MTU of 3,
  // while a message large enough to need the 3-byte EXT_16 header does not.
  // Pinning both sides catches a guard written against the wrong header.
  check(gp::ble::fragment(msg, 2).empty(), "EXT_13 message: MTU 2 refused");
  check(!gp::ble::fragment(msg, 3).empty(), "EXT_13 message: MTU 3 accepted");
  {
    bool completed = false;
    const auto got = round_trip(msg, 3, &completed);
    check(got == msg && completed, "EXT_13 message round-trips at MTU 3");
  }

  const auto huge = pattern(9000);  // > 2^13-1, so EXT_16
  check(gp::ble::fragment(huge, 3).empty(), "EXT_16 message: MTU 3 refused");
  check(!gp::ble::fragment(huge, 4).empty(), "EXT_16 message: MTU 4 accepted");
}

void test_randomised_round_trip() {
  std::printf("randomised round-trip\n");
  std::mt19937 rng(20260722);
  std::uniform_int_distribution<size_t> len_dist(1, 9000);
  std::uniform_int_distribution<size_t> mtu_dist(4, 517);
  bool all_ok = true;
  for (int i = 0; i < 2000; ++i) {
    const size_t n = len_dist(rng);
    const size_t mtu = mtu_dist(rng);
    const auto msg = pattern(n, static_cast<uint32_t>(rng()));
    bool completed = false;
    const auto got = round_trip(msg, mtu, &completed);
    if (got != msg || !completed) {
      all_ok = false;
      std::printf("  [FAIL] len=%zu mtu=%zu\n", n, mtu);
      break;
    }
  }
  check(all_ok, "2000 random (length, MTU) pairs round-trip");
}

}  // namespace

int main() {
  test_round_trip_exhaustive();
  test_header_width_boundaries();
  test_fragment_shape();
  test_receive_general_header();
  test_error_paths();
  test_recovery_after_error();
  test_mtu_scaling();
  test_randomised_round_trip();

  std::printf("\n%d checks, %d failed\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
