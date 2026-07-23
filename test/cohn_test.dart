// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
//
// COHN credential storage and certificate pinning.
//
// Both are things that appear to work when they are wrong. A credential file
// with the wrong mode reads back fine; a client with verification disabled
// connects to anything at all. So the tests here assert the properties that
// distinguish working from merely functioning.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gopro_native/src/cohn/cohn_http.dart';
import 'package:gopro_native/src/cohn/credentials.dart';
import 'package:test/test.dart';

const _credentials = CohnCredentials(
  username: 'gopro',
  password: 'hunter2',
  certificate:
      '-----BEGIN CERTIFICATE-----\nnot a real one\n'
      '-----END CERTIFICATE-----\n',
  ipAddress: '192.168.1.50',
  ssid: 'home',
  macAddress: 'aa:bb:cc:dd:ee:ff',
);

void main() {
  late Directory tmp;
  late FileCredentialStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('cohn_test');
    store = FileCredentialStore(directory: Directory('${tmp.path}/state'));
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  group('credentials', () {
    test('round trip', () async {
      await store.write('C123', _credentials);
      final got = await store.read('C123');
      expect(got, isNotNull);
      expect(got!.username, 'gopro');
      expect(got.password, 'hunter2');
      expect(got.certificate, _credentials.certificate);
      expect(got.ipAddress, '192.168.1.50');
      expect(got.ssid, 'home');
    });

    test('nothing stored reads as null rather than throwing', () async {
      expect(await store.read('never-seen'), isNull);
    });

    test('the file is 0600 and the directory 0700', () async {
      await store.write('C123', _credentials);

      final f = File('${store.directory.path}/C123.json');
      expect(f.existsSync(), isTrue);
      final fileMode = (await f.stat()).mode & 0x1FF;
      expect(
        fileMode,
        0x180, // 0600
        reason: 'file is ${fileMode.toRadixString(8)}, not 600',
      );

      final dirMode = (await store.directory.stat()).mode & 0x1FF;
      expect(
        dirMode,
        0x1C0, // 0700
        reason: 'directory is ${dirMode.toRadixString(8)}, not 700',
      );
    });

    test('a file that became readable by others is refused', () async {
      // Not hypothetical: an over-broad chmod on a parent, a restore from a
      // backup, a careless umask. Handing the credentials back anyway would
      // mean the protection silently stopped applying.
      await store.write('C123', _credentials);
      final f = File('${store.directory.path}/C123.json');
      await Process.run('chmod', ['644', f.path]);

      await expectLater(
        store.read('C123'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('644'), contains('beyond its owner')),
          ),
        ),
      );
    });

    test('a serial cannot escape the directory', () async {
      // The serial comes from the camera, so it is input. Writing
      // "../../../authorized_keys" must stay inside the state directory.
      await store.write('../../evil', _credentials);
      final escaped = File('${tmp.path}/evil.json');
      expect(escaped.existsSync(), isFalse);
      expect(store.directory.listSync().map((e) => e.path.split('/').last), [
        '______evil.json',
      ]);
    });

    test('a serial with nothing usable in it is rejected', () async {
      await expectLater(
        store.write('///', _credentials),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('delete removes it', () async {
      await store.write('C123', _credentials);
      await store.delete('C123');
      expect(await store.read('C123'), isNull);
      // Deleting what is not there is not an error.
      await store.delete('C123');
    });

    test('toString carries neither password nor certificate', () {
      // These reach logs and crash reports. The reference lets the Basic
      // token through its logging, which is the password base64'd.
      final s = _credentials.toString();
      expect(s, contains('gopro'));
      expect(s, isNot(contains('hunter2')));
      expect(s, isNot(contains('BEGIN CERTIFICATE')));
    });

    test('basicAuth is the documented encoding', () {
      expect(
        _credentials.basicAuth,
        'Basic ${base64Encode(utf8.encode('gopro:hunter2'))}',
      );
    });
  });

  group('pinning', () {
    test('a pinned client trusts nothing else', () async {
      // The whole point. `badCertificateCallback: (_, __, ___) => true` also
      // makes COHN work, and also accepts every other certificate on the
      // network.
      final camera = await _makeChain(tmp, name: 'camera');
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        SecurityContext()
          ..useCertificateChain(camera.chain)
          ..usePrivateKey(camera.key),
      );
      addTearDown(() => server.close(force: true));
      unawaited(
        server.forEach((r) {
          r.response.write('{"ok":true}');
          r.response.close();
        }),
      );

      final pem = await File(camera.ca).readAsString();
      final trusting = pinnedClient(pem);
      addTearDown(() => trusting.close(force: true));

      final uri = Uri.parse('https://127.0.0.1:${server.port}/');
      final ok = await (await trusting.getUrl(uri)).close();
      expect(ok.statusCode, 200);

      // A client pinned to a *different* certificate must refuse the same
      // server. If this passes, pinning is not doing anything.
      final other = await _makeChain(tmp, name: 'other');
      final wrong = pinnedClient(await File(other.ca).readAsString());
      addTearDown(() => wrong.close(force: true));

      // The handshake happens in getUrl, not in close. Awaiting it as an
      // argument to expectLater throws before the matcher ever sees it, so
      // the whole request has to be inside the closure.
      await expectLater(
        () async => (await wrong.getUrl(uri)).close(),
        throwsA(isA<HandshakeException>()),
      );
    });

    test(
      'a pinned client does not fall back to the system roots',
      () async {
        // withTrustedRoots: false. Otherwise a certificate from any public CA
        // would be accepted for the camera's address too.
        final chain = await _makeChain(tmp, name: 'roots');
        final c = pinnedClient(await File(chain.ca).readAsString());
        addTearDown(() => c.close(force: true));

        await expectLater(
          c
              .getUrl(Uri.parse('https://example.com/'))
              .then((r) => r.close())
              .timeout(const Duration(seconds: 10)),
          throwsA(anything),
        );
      },
      skip: 'needs outbound network access',
    );

    test('CohnHttp refuses to build without a host', () {
      const noAddress = CohnCredentials(
        username: 'u',
        password: 'p',
        certificate: 'x',
      );
      expect(() => CohnHttp(noAddress), throwsA(isA<ArgumentError>()));
    });
  });
}

/// Generates a throwaway root CA and a leaf signed by it.
///
/// COHN's shape: `RequestCOHNCert` returns a root CA certificate and the
/// camera presents a leaf under it. A self-signed leaf pinned as its own root
/// is a different and stricter case that OpenSSL rejects outright, so testing
/// that shape would prove the wrong thing.
Future<({String ca, String chain, String key})> _makeChain(
  Directory dir, {
  String name = 'test',
}) async {
  final d = '${dir.path}/$name';
  await Directory(d).create(recursive: true);

  final r = await Process.run('sh', [
    '-c',
    'set -e; cd "$d"; '
        'openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt '
        '  -days 1 -subj "/CN=$name-ca" 2>/dev/null; '
        'openssl req -newkey rsa:2048 -nodes -keyout leaf.key -out leaf.csr '
        '  -subj "/CN=127.0.0.1" 2>/dev/null; '
        'printf "subjectAltName=IP:127.0.0.1\\n" > ext.cnf; '
        'openssl x509 -req -in leaf.csr -CA ca.crt -CAkey ca.key '
        '  -CAcreateserial -out leaf.crt -days 1 -extfile ext.cnf 2>/dev/null',
  ]);
  if (r.exitCode != 0) {
    throw StateError('openssl failed: ${r.stderr}');
  }
  return (ca: '$d/ca.crt', chain: '$d/leaf.crt', key: '$d/leaf.key');
}
