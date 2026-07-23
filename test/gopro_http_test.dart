// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
//
// The HTTP transport, against a local server standing in for a camera.
//
// The behaviour worth pinning down is what happens when things go wrong:
// upstream applies a 5 second whole-request timeout to media downloads, which
// only works there because `requests` reads it per-read. Getting that wrong in
// Dart fails every video transfer, and getting the opposite wrong hangs
// forever on a camera that stopped talking.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:gopro_native/src/http/gopro_http.dart';
import 'package:gopro_native/src/http/http_message.dart';
import 'package:test/test.dart';

const _json = HttpMessage(
  name: 'probe',
  endpoint: 'gopro/probe',
  method: HttpMethod.get,
  response: HttpResponseKind.json,
);

const _put = HttpMessage(
  name: 'rename',
  endpoint: 'gopro/camera/name',
  method: HttpMethod.put,
  response: HttpResponseKind.json,
  bodyArguments: ['value'],
);

const _binary = HttpMessage(
  name: 'fetch',
  endpoint: 'videos/DCIM',
  method: HttpMethod.get,
  response: HttpResponseKind.binary,
  components: ['path'],
);

void main() {
  late HttpServer server;
  late Uri base;
  late Directory tmp;

  /// Set by each test to decide how the server answers.
  late Future<void> Function(HttpRequest) handler;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://127.0.0.1:${server.port}/');
    tmp = await Directory.systemTemp.createTemp('gopro_http_test');
    unawaited(
      server.forEach((r) async {
        await handler(r);
      }),
    );
  });

  tearDown(() async {
    await server.close(force: true);
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  group('json', () {
    test('decodes an object', () async {
      handler = (r) async {
        r.response.write('{"version":"2.0"}');
        await r.response.close();
      };
      final http = GoProHttp(base);
      addTearDown(http.close);
      expect(await http.json(_json), {'version': '2.0'});
    });

    test('an empty body is an empty map, not a crash', () async {
      // Several commands answer 200 with nothing at all.
      handler = (r) async => r.response.close();
      final http = GoProHttp(base);
      addTearDown(http.close);
      expect(await http.json(_json), isEmpty);
    });

    test('a bare JSON value is wrapped rather than rejected', () async {
      handler = (r) async {
        r.response.write('"H24.02"');
        await r.response.close();
      };
      final http = GoProHttp(base);
      addTearDown(http.close);
      expect(await http.json(_json), {'value': 'H24.02'});
    });

    test(
      'an error carries the body, which says which argument was wrong',
      () async {
        handler = (r) async {
          r.response.statusCode = 403;
          r.response.write('{"error":"invalid parameter"}');
          await r.response.close();
        };
        final http = GoProHttp(base);
        addTearDown(http.close);

        await expectLater(
          http.json(_json),
          throwsA(
            isA<GoProHttpException>()
                .having((e) => e.statusCode, 'statusCode', 403)
                .having((e) => e.body, 'body', contains('invalid parameter')),
          ),
        );
      },
    );

    test('a slow reply hits the request deadline', () async {
      handler = (r) async {
        await Future<void>.delayed(const Duration(seconds: 5));
        await r.response.close();
      };
      final http = GoProHttp(
        base,
        requestTimeout: const Duration(milliseconds: 200),
      );
      addTearDown(http.close);
      await expectLater(http.json(_json), throwsA(isA<TimeoutException>()));
    });

    test('a PUT sends only its declared body arguments', () async {
      Object? seen;
      handler = (r) async {
        seen = jsonDecode(await utf8.decoder.bind(r).join());
        await r.response.close();
      };
      final http = GoProHttp(base);
      addTearDown(http.close);

      await http.json(_put, values: {'value': 'Camera', 'extra': 'dropped'});
      expect(seen, {'value': 'Camera'});
    });

    test('asking a binary message for JSON is a programming error', () async {
      handler = (r) async => r.response.close();
      final http = GoProHttp(base);
      addTearDown(http.close);
      expect(() => http.json(_binary), throwsA(isA<ArgumentError>()));
    });
  });

  group('download', () {
    test('streams to disk', () async {
      final payload = List<int>.generate(64 * 1024, (i) => i % 256);
      handler = (r) async {
        r.response.add(payload);
        await r.response.close();
      };
      final http = GoProHttp(base);
      addTearDown(http.close);

      final out = File('${tmp.path}/GX010001.MP4');
      final progress = <int>[];
      await http.download(
        _binary,
        out,
        values: {'path': '100GOPRO/GX010001.MP4'},
        onProgress: (received, _) => progress.add(received),
      );

      expect(await out.length(), payload.length);
      expect(await out.readAsBytes(), payload);
      expect(progress, isNotEmpty);
      expect(progress.last, payload.length);
    });

    test(
      'a transfer longer than the request deadline still completes',
      () async {
        // The point of the separate policy. Upstream's 5 s applies to the whole
        // request, which no real video download would survive.
        handler = (r) async {
          for (var i = 0; i < 4; i++) {
            r.response.add(List<int>.filled(1024, 7));
            await r.response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          await r.response.close();
        };
        final http = GoProHttp(
          base,
          requestTimeout: const Duration(milliseconds: 50),
          stallTimeout: const Duration(seconds: 5),
        );
        addTearDown(http.close);

        final out = File('${tmp.path}/slow.bin');
        await http.download(_binary, out, values: {'path': 'a/b'});
        expect(await out.length(), 4096);
      },
    );

    test('a stream that stops delivering is abandoned', () async {
      // A camera that goes away mid-transfer holds the socket open and sends
      // nothing. Without a stall deadline this waits forever.
      handler = (r) async {
        r.response.add(List<int>.filled(256 * 1024, 1));
        await r.response.flush();
        // Then nothing, ever.
        await Completer<void>().future;
      };
      final http = GoProHttp(
        base,
        stallTimeout: const Duration(milliseconds: 300),
      );
      addTearDown(http.close);

      final out = File('${tmp.path}/stalled.bin');
      await expectLater(
        http.download(_binary, out, values: {'path': 'a/b'}),
        throwsA(isA<GoProStalledException>()),
      );
      // A partial file left behind looks like a finished download to whatever
      // finds it next.
      expect(out.existsSync(), isFalse);
    });

    test('a body shorter than its Content-Length leaves no file', () async {
      // dart:io usually notices this before the explicit length check does,
      // by way of the connection closing early. Either way the contract is
      // the same: it fails, and it does not leave a plausible-looking file.
      handler = (r) async {
        r.response.contentLength = 4096;
        r.response.add(List<int>.filled(1024, 1));
        await r.response.close().catchError((Object _) {});
      };
      final http = GoProHttp(base);
      addTearDown(http.close);

      final out = File('${tmp.path}/short.bin');
      await expectLater(
        http.download(_binary, out, values: {'path': 'a/b'}),
        throwsA(anything),
      );
      expect(out.existsSync(), isFalse);
    });

    test('an error status leaves no file behind', () async {
      handler = (r) async {
        r.response.statusCode = 404;
        r.response.write('not found');
        await r.response.close();
      };
      final http = GoProHttp(base);
      addTearDown(http.close);

      final out = File('${tmp.path}/missing.bin');
      await expectLater(
        http.download(_binary, out, values: {'path': 'a/b'}),
        throwsA(isA<GoProHttpException>()),
      );
      expect(out.existsSync(), isFalse);
    });

    test('the destination directory is created', () async {
      handler = (r) async {
        r.response.add([1, 2, 3]);
        await r.response.close();
      };
      final http = GoProHttp(base);
      addTearDown(http.close);

      final out = File('${tmp.path}/nested/deeper/x.bin');
      await http.download(_binary, out, values: {'path': 'a/b'});
      expect(await out.length(), 3);
    });

    test('asking a JSON message for binary is a programming error', () async {
      handler = (r) async => r.response.close();
      final http = GoProHttp(base);
      addTearDown(http.close);
      expect(
        () => http.download(_json, File('${tmp.path}/x')),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
