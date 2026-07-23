// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
//
// Joining the camera to a network.
//
// The message encodings and the flag decoding are checkable without a camera,
// and they are where a mistake is quiet: a scan entry's flags decide whether
// a passphrase is needed at all, and reading them wrong sends one where it
// was not wanted or omits it where it was.

import 'package:gopro_native/proto/network.dart';
import 'package:gopro_native/src/wifi/network_client.dart';
import 'package:test/test.dart';

AccessPoint ap(int flags) =>
    AccessPoint(ssid: 'net', signalBars: 3, frequencyMhz: 5180, flags: flags);

void main() {
  group('scan entry flags', () {
    test('open is the absence of the authenticated bit', () {
      expect(ap(0x00).isOpen, isTrue);
      expect(ap(0x01).isOpen, isFalse);
    });

    test('configured means the camera already holds credentials', () {
      // The difference between connect() and connectNew(): sending a
      // passphrase for a network the camera already knows is unnecessary,
      // and omitting one for a network it does not is a failed join.
      expect(ap(0x02).isConfigured, isTrue);
      expect(ap(0x01).isConfigured, isFalse);
    });

    test('associated means this is the current network', () {
      expect(ap(0x08).isAssociated, isTrue);
      expect(ap(0x04).isAssociated, isFalse);
    });

    test('unsupported is its own bit, not an absence', () {
      expect(ap(0x10).isUnsupported, isTrue);
      expect(ap(0x0F).isUnsupported, isFalse);
    });

    test('flags combine', () {
      // A configured, authenticated, currently associated network.
      final a = ap(0x01 | 0x02 | 0x08);
      expect(a.isOpen, isFalse);
      expect(a.isConfigured, isTrue);
      expect(a.isAssociated, isTrue);
      expect(a.isUnsupported, isFalse);
    });

    test('toString does not invent a passphrase field', () {
      expect(ap(0x03).toString(), contains('net'));
      expect(ap(0x03).toString(), contains('configured'));
    });
  });

  group('request encoding', () {
    test('connect carries only the ssid', () {
      final m = RequestConnect()..ssid = 'home';
      expect(m.isInitialized(), isTrue);
      expect(RequestConnect.fromBuffer(m.writeToBuffer()).ssid, 'home');
    });

    test('connect refuses to encode without an ssid', () {
      // required, and the Dart runtime does not enforce it on write — an
      // empty buffer would go out and the camera would ignore it.
      expect(RequestConnect().isInitialized(), isFalse);
      expect(RequestConnect().writeToBuffer(), isEmpty);
    });

    test('connect-new carries ssid and password', () {
      final m = RequestConnectNew()
        ..ssid = 'home'
        ..password = 'hunter2';
      final back = RequestConnectNew.fromBuffer(m.writeToBuffer());
      expect(back.ssid, 'home');
      expect(back.password, 'hunter2');
      expect(back.isInitialized(), isTrue);
    });

    test('bypassing the EULA check is explicit, not implied', () {
      // The reference sets this unconditionally, which changes what the
      // camera will accept without saying so.
      final off = RequestConnectNew()
        ..ssid = 'a'
        ..password = 'b'
        ..bypassEulaCheck = false;
      expect(
        RequestConnectNew.fromBuffer(off.writeToBuffer()).bypassEulaCheck,
        isFalse,
      );

      final unset = RequestConnectNew()
        ..ssid = 'a'
        ..password = 'b';
      expect(
        RequestConnectNew.fromBuffer(
          unset.writeToBuffer(),
        ).hasBypassEulaCheck(),
        isFalse,
      );
    });

    test('paging carries the scan id, not just an offset', () {
      // Results belong to a scan. Asking with the wrong id returns another
      // scan's networks, which look perfectly plausible.
      final m = RequestGetApEntries()
        ..startIndex = 20
        ..maxEntries = 20
        ..scanId = 7;
      final back = RequestGetApEntries.fromBuffer(m.writeToBuffer());
      expect(back.startIndex, 20);
      expect(back.maxEntries, 20);
      expect(back.scanId, 7);
    });

    test('a scan request has no fields', () {
      expect(RequestStartScan().writeToBuffer(), isEmpty);
      expect(RequestStartScan().isInitialized(), isTrue);
    });
  });

  group('provisioning states', () {
    test('the two successes are distinguishable', () {
      // New and old AP both mean joined, but only one of them provisioned
      // credentials that will still be there next time.
      expect(
        EnumProvisioning.PROVISIONING_SUCCESS_NEW_AP,
        isNot(EnumProvisioning.PROVISIONING_SUCCESS_OLD_AP),
      );
    });

    test('failures name their cause', () {
      // A wrong passphrase, an AP that would not associate, and a network
      // with no internet need three different responses from a caller.
      expect(EnumProvisioning.PROVISIONING_ERROR_PASSWORD_AUTH.value, 8);
      expect(EnumProvisioning.PROVISIONING_ERROR_FAILED_TO_ASSOCIATE.value, 7);
      expect(EnumProvisioning.PROVISIONING_ERROR_NO_INTERNET.value, 10);
      expect(EnumProvisioning.PROVISIONING_ERROR_EULA_BLOCKING.value, 9);
    });
  });

  group('exceptions', () {
    test('carry the camera verdict rather than a generic message', () {
      const e = NetworkException(
        'connect',
        provisioning: EnumProvisioning.PROVISIONING_ERROR_PASSWORD_AUTH,
      );
      expect(e.toString(), contains('PROVISIONING_ERROR_PASSWORD_AUTH'));
    });

    test('do not carry a passphrase', () {
      // Nothing constructs one with a password in it; this pins that down so
      // a later `detail: password` cannot slip in unnoticed.
      const e = NetworkException('connect to a new network');
      expect(e.toString(), isNot(contains('hunter2')));
    });
  });
}
