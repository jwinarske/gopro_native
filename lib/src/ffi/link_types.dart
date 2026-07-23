// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
//
// link_types.dart — Dart mirrors of the BLE bring-up state machine.

/// How far bring-up has progressed. Mirrors `gp::ble::LinkState`.
///
/// Only [ready] means the control plane is usable. Each earlier stage can
/// stall for a different reason, which is why they are named separately
/// rather than collapsed into a connected flag.
enum LinkState {
  absent,
  advertising,
  connected,
  servicesResolved,
  encrypted,
  ready;

  bool get isReady => this == LinkState.ready;
}

/// What the transport should do next. Mirrors `gp::ble::LinkAction`.
enum LinkAction {
  none,
  scan,

  /// A BR-EDR link is up and suppressing LE advertising. Scanning harder
  /// will not find the camera; the Classic link has to go.
  disconnectClassic,

  connect,
  waitForServices,

  /// Discovery works but notifications are refused. The Control and Query
  /// characteristics need an encrypted link, which means an LE bond.
  pair,

  subscribe,
}

/// Why progress stopped. Mirrors `gp::ble::StallReason`.
///
/// These are distinct because the remedy differs completely: a sleeping
/// camera, a Classic link in the way, and a missing LE bond all present as
/// "it does not work".
enum StallReason {
  none,
  noAdvertisement,
  classicBlocking,
  connectFailed,
  servicesNeverAppeared,
  wrongDevice,
  notEncrypted,
  subscribeFailed;

  bool get isStalled => this != StallReason.none;
}

/// What the transport can currently see. Mirrors `gp::ble::LinkObservation`.
class LinkObservation {
  const LinkObservation({
    this.candidatePresent = false,
    this.classicLinkUp = false,
    this.connected = false,
    this.bondedFlag = false,
    this.controlCharsFound = false,
    this.notifySucceeded = false,
    this.attributeCount = 0,
    this.subscribedCount = 0,
    this.requiredSubscriptions = 1,
  });

  /// An LE device object advertising the Control and Query service.
  ///
  /// Require both a random address type **and** the `fea6` service. A camera
  /// also presents a BR-EDR object with the same name, and that one can
  /// never carry GATT.
  final bool candidatePresent;

  /// A BR-EDR link to the same camera is up. It suppresses LE advertising.
  final bool classicLinkUp;

  final bool connected;

  /// BlueZ's `Bonded` flag. Reported for diagnostics only and never gating:
  /// a BR-EDR bond sets it while leaving the LE link unencrypted, which is
  /// exactly the trap that makes this look connected when it is not usable.
  final bool bondedFlag;

  /// GATT characteristics actually exposed.
  ///
  /// Count them. BlueZ has been observed reporting `ServicesResolved: true`
  /// while exposing none, so the property is not evidence.
  final int attributeCount;

  final bool controlCharsFound;

  /// A `StartNotify` has succeeded. The only proof the link is encrypted.
  final bool notifySucceeded;

  final int subscribedCount;
  final int requiredSubscriptions;

  /// Packs the boolean half for the FFI call. Mirrors `GoProLinkFlags`.
  int get flags =>
      (candidatePresent ? 1 << 0 : 0) |
      (classicLinkUp ? 1 << 1 : 0) |
      (connected ? 1 << 2 : 0) |
      (bondedFlag ? 1 << 3 : 0) |
      (controlCharsFound ? 1 << 4 : 0) |
      (notifySucceeded ? 1 << 5 : 0);
}

/// The state machine's answer to an observation.
class LinkAdvice {
  const LinkAdvice({
    required this.state,
    required this.action,
    required this.stall,
    required this.detail,
    required this.retryAtMs,
  });

  final LinkState state;
  final LinkAction action;
  final StallReason stall;

  /// Explanation of the stall, empty when not stalled.
  final String detail;

  /// Earliest time to retry [action]; zero means now.
  final int retryAtMs;

  /// Unpacks `(state << 16) | (action << 8) | stall`. Returns null if any
  /// field is out of range, which would mean the native enums and these have
  /// drifted.
  static LinkAdvice? unpack(
    int packed, {
    required String detail,
    required int retryAtMs,
  }) {
    final s = (packed >> 16) & 0xFF;
    final a = (packed >> 8) & 0xFF;
    final r = packed & 0xFF;
    if (s >= LinkState.values.length ||
        a >= LinkAction.values.length ||
        r >= StallReason.values.length) {
      return null;
    }
    return LinkAdvice(
      state: LinkState.values[s],
      action: LinkAction.values[a],
      stall: StallReason.values[r],
      detail: detail,
      retryAtMs: retryAtMs,
    );
  }

  @override
  String toString() =>
      'LinkAdvice(${state.name} -> ${action.name}'
      '${stall.isStalled ? ", stalled: ${stall.name}" : ""})';
}
