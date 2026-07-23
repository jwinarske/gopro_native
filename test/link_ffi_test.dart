// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
//
// Exercises the link state machine through the FFI boundary.
//
// The machine's behavior is covered in native/test/ble_link_test.cpp. What
// this checks is that the boundary preserves it: flags pack correctly, the
// packed advice unpacks to the right enums, and the detail string survives.
// A mismatch between the native enums and the Dart mirrors would otherwise be
// silent, since both sides are just small integers.

import 'package:gopro_native/src/ffi/ble_bindings.dart';
import 'package:gopro_native/src/ffi/link_types.dart';
import 'package:test/test.dart';

void main() {
  late final handle = BleBindings.linkCreate();

  LinkAdvice update(LinkObservation obs, int nowMs) {
    final a = BleBindings.linkUpdate(handle, obs, nowMs);
    expect(a, isNotNull, reason: 'packed advice out of range: enums drifted');
    return a!;
  }

  tearDownAll(() => BleBindings.linkDestroy(handle));

  setUp(() => BleBindings.linkReset(handle));

  test('nothing seen means scan', () {
    final a = update(const LinkObservation(), 0);
    expect(a.state, LinkState.absent);
    expect(a.action, LinkAction.scan);
    expect(a.stall, StallReason.none);
  });

  test('a Classic link is something to disconnect, not scan past', () {
    // While BR-EDR is up the camera does not advertise, so scanning harder
    // never finds it.
    final a = update(const LinkObservation(classicLinkUp: true), 0);
    expect(a.action, LinkAction.disconnectClassic);
    expect(a.stall, StallReason.classicBlocking);
    expect(a.detail, contains('suppresses LE'));
  });

  test('connected with no attributes waits, then names the stall', () {
    const obs = LinkObservation(
      candidatePresent: true,
      connected: true,
      attributeCount: 0,
    );
    expect(update(obs, 0).action, LinkAction.waitForServices);

    final stalled = update(obs, 20000);
    expect(stalled.stall, StallReason.servicesNeverAppeared);
    // The warning that BlueZ's property is unreliable has to survive the
    // boundary; it is the whole value of the message.
    expect(stalled.detail, contains('ServicesResolved'));
  });

  test('the bonded flag does not stand in for encryption', () {
    // A BR-EDR bond sets Bonded while leaving the LE link unencrypted. Only
    // a successful StartNotify proves otherwise.
    const obs = LinkObservation(
      candidatePresent: true,
      connected: true,
      bondedFlag: true,
      attributeCount: 34,
      controlCharsFound: true,
      notifySucceeded: false,
    );
    expect(update(obs, 0).state, LinkState.servicesResolved);

    final stalled = update(obs, 70000);
    expect(stalled.stall, StallReason.notEncrypted);
    expect(stalled.action, LinkAction.pair);
    expect(stalled.detail, contains('BR-EDR bond does not'));
  });

  test('reaching ready requires every subscription', () {
    const partial = LinkObservation(
      candidatePresent: true,
      connected: true,
      attributeCount: 34,
      controlCharsFound: true,
      notifySucceeded: true,
      subscribedCount: 2,
      requiredSubscriptions: 3,
    );
    expect(update(partial, 0).state, LinkState.encrypted);
    expect(update(partial, 0).action, LinkAction.subscribe);

    const full = LinkObservation(
      candidatePresent: true,
      connected: true,
      attributeCount: 34,
      controlCharsFound: true,
      notifySucceeded: true,
      subscribedCount: 3,
      requiredSubscriptions: 3,
    );
    final ready = update(full, 0);
    expect(ready.state, LinkState.ready);
    expect(ready.state.isReady, isTrue);
    expect(ready.action, LinkAction.none);
    expect(ready.stall.isStalled, isFalse);
  });

  test('backoff grows and progress clears it', () {
    const advertising = LinkObservation(candidatePresent: true);
    update(advertising, 0);

    BleBindings.linkNoteFailure(handle, 0);
    final first = update(advertising, 0);
    BleBindings.linkNoteFailure(handle, 0);
    final second = update(advertising, 0);
    expect(second.retryAtMs, greaterThan(first.retryAtMs));
    expect(BleBindings.linkAttempts(handle), 2);

    // Progress must clear the penalty, or a reconnect after a working
    // session inherits backoff it never earned.
    const connected = LinkObservation(
      candidatePresent: true,
      connected: true,
      attributeCount: 34,
      controlCharsFound: true,
      notifySucceeded: true,
      subscribedCount: 1,
    );
    update(connected, 100);
    expect(BleBindings.linkAttempts(handle), 0);
    expect(update(connected, 100).retryAtMs, 0);
  });

  test('flags pack in the order the native side unpacks them', () {
    expect(const LinkObservation(candidatePresent: true).flags, 1 << 0);
    expect(const LinkObservation(classicLinkUp: true).flags, 1 << 1);
    expect(const LinkObservation(connected: true).flags, 1 << 2);
    expect(const LinkObservation(bondedFlag: true).flags, 1 << 3);
    expect(const LinkObservation(controlCharsFound: true).flags, 1 << 4);
    expect(const LinkObservation(notifySucceeded: true).flags, 1 << 5);
  });

  test('out-of-range packed advice is reported rather than guessed', () {
    expect(LinkAdvice.unpack(0xFF0000, detail: '', retryAtMs: 0), isNull);
    expect(LinkAdvice.unpack(0x00FF00, detail: '', retryAtMs: 0), isNull);
    expect(LinkAdvice.unpack(0x0000FF, detail: '', retryAtMs: 0), isNull);
  });
}
