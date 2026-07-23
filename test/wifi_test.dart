// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
//
// Joining the camera's access point.
//
// The property worth pinning down is that no attacker-controlled string ever
// reaches a shell. An SSID is chosen by whoever runs the access point and a
// passphrase can contain anything, so the reference's approach — formatting
// both into a command string and running it with `shell=True` — is a command
// injection where the attacker supplies the network name.

import 'package:gopro_native/src/wifi/wifi_controller.dart';
import 'package:test/test.dart';

void main() {
  group('argv construction', () {
    const nmcli = NmcliWifiController();

    test('every value is its own argument', () {
      expect(
        nmcli.joinArgs(
          const ApCredentials(ssid: 'GP12345678', password: 'abc-def-ghi'),
        ),
        ['device', 'wifi', 'connect', 'GP12345678', 'password', 'abc-def-ghi'],
      );
    });

    test('shell metacharacters stay inside their argument', () {
      // Not hypothetical for an SSID: it is 32 arbitrary bytes chosen by
      // whoever runs the access point. As one argv element this is a network
      // name; interpolated into a shell string it is two commands.
      const hostile = ApCredentials(
        ssid: r'GP$(id > /tmp/pwned)',
        password: r"a'; rm -rf ~; echo '",
      );
      final args = nmcli.joinArgs(hostile);

      expect(args, contains(r'GP$(id > /tmp/pwned)'));
      expect(args, contains(r"a'; rm -rf ~; echo '"));
      // Nine words of shell syntax, still exactly six arguments.
      expect(args, hasLength(6));
      expect(args[3], hostile.ssid);
      expect(args[5], hostile.password);
    });

    test('a timeout is passed as two arguments, not one', () {
      final args = const NmcliWifiController(
        timeout: Duration(seconds: 30),
      ).joinArgs(const ApCredentials(ssid: 'GP1', password: 'p'));
      expect(args.take(2), ['--wait', '30']);
    });

    test('leaving names the connection', () {
      expect(nmcli.leaveArgs(const ApCredentials(ssid: 'GP1', password: 'p')), [
        'connection',
        'down',
        'GP1',
      ]);
    });

    test('a missing nmcli reports unavailable rather than throwing', () async {
      const missing = NmcliWifiController(executable: '/nonexistent/nmcli');
      expect(await missing.available, isFalse);
    });

    test('running a missing nmcli is a WifiJoinException', () async {
      const missing = NmcliWifiController(executable: '/nonexistent/nmcli');
      await expectLater(
        missing.join(const ApCredentials(ssid: 'GP1', password: 'p')),
        throwsA(isA<WifiJoinException>()),
      );
    });
  });

  group('manual controller', () {
    const creds = ApCredentials(ssid: 'GP12345678', password: 'secret-pass');

    test('throws with the instruction when nothing is configured', () async {
      await expectLater(
        const ManualWifiController().join(creds),
        throwsA(
          isA<WifiJoinException>().having(
            (e) => e.detail,
            'detail',
            contains('GP12345678'),
          ),
        ),
      );
    });

    test('reports rather than throwing when a callback is given', () async {
      String? said;
      await ManualWifiController(onInstruction: (m) => said = m).join(creds);
      expect(said, contains('GP12345678'));
    });

    test('the instruction does not contain the passphrase', () async {
      // It names where the passphrase is instead. Instructions get printed,
      // and a printed passphrase outlives the session it was needed for.
      String? said;
      await ManualWifiController(onInstruction: (m) => said = m).join(creds);
      expect(said, isNot(contains('secret-pass')));
    });

    test('reports itself unavailable', () async {
      expect(await const ManualWifiController().available, isFalse);
    });

    test('leaving is a no-op, not an error', () async {
      await const ManualWifiController().leave(creds);
    });
  });

  test('credentials do not print the passphrase', () {
    const creds = ApCredentials(ssid: 'GP12345678', password: 'secret-pass');
    expect(creds.toString(), contains('GP12345678'));
    expect(creds.toString(), isNot(contains('secret-pass')));
  });
}
