// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
//
// URL and body composition for the HTTP message table.
//
// These are the failures that do not announce themselves. A missing query
// argument, a path component pasted in as a query parameter, or a leading
// slash swallowed produces a URL the camera answers — with the wrong thing,
// or with a 404 that reads like the camera is broken rather than the request.

import 'package:gopro_native/src/generated/http_commands.dart';
import 'package:gopro_native/src/http/http_message.dart';
import 'package:test/test.dart';

void main() {
  final base = Uri.parse('http://172.21.123.51:8080/');

  HttpMessage m(String name) {
    final msg = kHttpMessages[name];
    expect(msg, isNotNull, reason: 'no message named $name');
    return msg!;
  }

  group('url', () {
    test('a bare endpoint', () {
      expect(
        m('get_camera_state').url(base).toString(),
        'http://172.21.123.51:8080/gopro/camera/state',
      );
    });

    test('a leading slash does not produce an empty segment', () {
      // Upstream is inconsistent: most endpoints have no leading slash and a
      // few do. Both have to land on the same shape, or the camera sees a
      // double slash and answers 404.
      final msg = m('delete_all_media');
      expect(msg.endpoint.startsWith('/'), isTrue, reason: 'test premise');
      expect(
        msg.url(base).toString(),
        'http://172.21.123.51:8080/gp/gpControl/command/storage/delete/all',
      );
    });

    test('query arguments use the upstream spelling, not the caller\'s', () {
      // delete_group takes a path and sends it as "p". Sending "path" would
      // be accepted by the camera and ignored.
      expect(
        m('delete_group').url(base, {'p': '100GOPRO/GX010001.MP4'}).query,
        'p=100GOPRO%2FGX010001.MP4',
      );
    });

    test('a hyphenated argument survives', () {
      expect(
        m('get_preset_status').url(base, {'include-hidden': 1}).query,
        'include-hidden=1',
      );
    });

    test('components become path segments', () {
      expect(
        m('set_shutter').url(base, {'mode': 'stop'}).toString(),
        'http://172.21.123.51:8080/gopro/camera/shutter/stop',
      );
    });

    test('a component containing slashes expands to several segments', () {
      // download_file's component is a camera path like 100GOPRO/GX010001.MP4.
      // Escaping the slash would ask for a single directory of that name.
      final uri = m(
        'download_file',
      ).url(base, {'path': '100GOPRO/GX010001.MP4'});
      expect(uri.pathSegments, ['videos', 'DCIM', '100GOPRO', 'GX010001.MP4']);
      expect(uri.toString(), contains('/videos/DCIM/100GOPRO/GX010001.MP4'));
    });

    test('components and arguments compose', () {
      final uri = m(
        'set_preview_stream',
      ).url(base, {'mode': 'start', 'port': 8554});
      expect(uri.path, '/gopro/camera/stream/start');
      expect(uri.query, 'port=8554');
    });

    test('a null argument is omitted rather than sent as "null"', () {
      // add_file_hilight's offset is optional for stills. "ms=null" is a
      // value, and the camera would reject it.
      final uri = m(
        'add_file_hilight',
      ).url(base, {'path': '100GOPRO/GOPR0001.JPG', 'ms': null});
      expect(uri.query, 'path=100GOPRO%2FGOPR0001.JPG');
      expect(uri.query, isNot(contains('ms')));
    });

    test('no arguments means no query string at all', () {
      expect(m('get_media_list').url(base).hasQuery, isFalse);
    });

    test('a missing component is refused, not silently dropped', () {
      // Dropping it would build /gopro/camera/shutter, a different endpoint
      // that the camera may well answer.
      expect(() => m('set_shutter').url(base), throwsA(isA<ArgumentError>()));
    });
  });

  group('body', () {
    test('only declared body arguments are sent', () {
      final body = m('update_custom_preset').body({
        'custom_name': 'Timelapse',
        'icon_id': 4,
        'not_a_field': 'ignored',
      });
      expect(body, {'custom_name': 'Timelapse', 'icon_id': 4});
    });

    test('omitted fields stay out, so the camera leaves them alone', () {
      expect(m('update_custom_preset').body({'icon_id': 4}), {'icon_id': 4});
    });

    test('a GET message has no body', () {
      expect(m('get_camera_state').body({'anything': 1}), isEmpty);
    });
  });

  group('table', () {
    test('every message is keyed by its own name', () {
      for (final entry in kHttpMessages.entries) {
        expect(entry.key, entry.value.name);
      }
    });

    test('binary messages are the download endpoints', () {
      final binary = kHttpMessages.values
          .where((m) => m.response == HttpResponseKind.binary)
          .map((m) => m.name)
          .toSet();
      expect(binary, {
        'download_file',
        'get_gpmf_data',
        'get_screennail',
        'get_telemetry',
        'get_thumbnail',
      });
    });

    test('set_shutter is the only conditionally fastpass message', () {
      // If upstream adds another, the wrapper for it has to decide too —
      // leaving it on the default would put it behind the busy gate.
      final conditional = kHttpMessages.values
          .where((m) => m.fastpass == HttpFastpass.conditional)
          .map((m) => m.name)
          .toList();
      expect(conditional, ['set_shutter']);
    });

    test('body arguments only appear on PUT messages', () {
      for (final m in kHttpMessages.values) {
        if (m.bodyArguments.isNotEmpty) {
          expect(m.method, HttpMethod.put, reason: m.name);
        }
      }
    });
  });
}
