// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
//
// Livestream and webcam.
//
// Neither needs a camera to check what matters here: that the protobuf a
// livestream request produces is the one the camera expects, and that a
// webcam reply from firmware newer than these tables degrades to "I do not
// recognise that" rather than failing the call.

import 'package:gopro_native/proto/livestream.dart';
import 'package:gopro_native/src/generated/streaming.dart';
import 'package:gopro_native/src/streaming/webcam.dart';
import 'package:test/test.dart';

void main() {
  group('livestream request encoding', () {
    test('url and encode are the minimum', () {
      final m = RequestSetLiveStreamMode()
        ..url = 'rtmp://example.test/live/key'
        ..encode = false;
      expect(m.isInitialized(), isTrue);

      final back = RequestSetLiveStreamMode.fromBuffer(m.writeToBuffer());
      expect(back.url, 'rtmp://example.test/live/key');
      expect(back.encode, isFalse);
      // proto2 presence: the difference between "record while streaming: no"
      // and "leave that alone" is whether the field is there at all.
      expect(back.hasEncode(), isTrue);
    });

    test('omitted options stay out of the message', () {
      final m = RequestSetLiveStreamMode()..url = 'rtmp://x/y';
      final back = RequestSetLiveStreamMode.fromBuffer(m.writeToBuffer());
      expect(back.hasWindowSize(), isFalse);
      expect(back.hasLens(), isFalse);
      expect(back.hasMinimumBitrate(), isFalse);
      expect(back.hasCert(), isFalse);
    });

    test('window size and lens carry their wire values', () {
      final m = RequestSetLiveStreamMode()
        ..url = 'rtmp://x/y'
        ..windowSize = EnumWindowSize.WINDOW_SIZE_1080
        ..lens = EnumLens.LENS_LINEAR;
      final back = RequestSetLiveStreamMode.fromBuffer(m.writeToBuffer());
      expect(back.windowSize.value, 12);
      expect(back.lens.value, 4);
    });

    test('a status registration is a repeated field, not a flag', () {
      final m = RequestGetLiveStreamStatus()
        ..registerLiveStreamStatus.addAll([
          EnumRegisterLiveStreamStatus.REGISTER_LIVE_STREAM_STATUS_STATUS,
          EnumRegisterLiveStreamStatus.REGISTER_LIVE_STREAM_STATUS_ERROR,
        ]);
      final back = RequestGetLiveStreamStatus.fromBuffer(m.writeToBuffer());
      expect(back.registerLiveStreamStatus, hasLength(2));
      expect(back.unregisterLiveStreamStatus, isEmpty);
    });

    test('an empty status request is legal and registers nothing', () {
      // A one-shot read. Registering when the caller only wanted a value
      // would leave pushes arriving forever.
      final m = RequestGetLiveStreamStatus();
      expect(m.writeToBuffer(), isEmpty);
    });
  });

  group('webcam replies', () {
    test('status and error decode to their enums', () {
      final r = WebcamReply.fromJson({'status': 2, 'error': 0});
      expect(r.status, WebcamStatus.highPowerPreview);
      expect(r.error, WebcamError.success);
      expect(r.ok, isTrue);
    });

    test('a non-zero error is not ok', () {
      final r = WebcamReply.fromJson({'status': 1, 'error': 7});
      expect(r.error, WebcamError.unavailable);
      expect(r.ok, isFalse);
    });

    test('a missing error is success, not unknown', () {
      // The endpoints that only report state answer without one.
      final r = WebcamReply.fromJson({'status': 0});
      expect(r.error, isNull);
      expect(r.ok, isTrue);
    });

    test('an unrecognized value degrades rather than throwing', () {
      // Firmware newer than these tables will send values this build has no
      // name for. Losing the whole reply over one field would be worse than
      // not naming it.
      final r = WebcamReply.fromJson({'status': 99, 'error': 0});
      expect(r.status, isNull);
      expect(r.ok, isTrue);
      expect(r.raw['status'], 99);
    });

    test('the raw document survives decoding', () {
      final r = WebcamReply.fromJson({
        'status': 1,
        'error': 0,
        'something_new': 'kept',
      });
      expect(r.raw['something_new'], 'kept');
    });
  });

  group('generated streaming enums', () {
    test('webcam protocol is string valued', () {
      // The only string-valued enum upstream, and it goes on the wire as a
      // query argument rather than an integer.
      expect(WebcamProtocol.ts.value, 'TS');
      expect(WebcamProtocol.rtsp.value, 'RTSP');
      expect(WebcamProtocol.fromValue('RTSP'), WebcamProtocol.rtsp);
      expect(WebcamProtocol.fromValue('nope'), isNull);
    });

    test('resolutions carry the camera values, not their index', () {
      expect(WebcamResolution.res480.value, 4);
      expect(WebcamResolution.res720.value, 7);
      expect(WebcamResolution.res1080.value, 12);
      expect(WebcamResolution.notApplicable.value, 0);
    });

    test('field of view matches the lens numbering', () {
      expect(WebcamFOV.wide.value, 0);
      expect(WebcamFOV.narrow.value, 2);
      expect(WebcamFOV.superview.value, 3);
      expect(WebcamFOV.linear.value, 4);
    });
  });
}
