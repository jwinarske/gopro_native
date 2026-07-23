// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
//
// The generated protobuf layer.
//
// Not a test of protoc — that is not ours to verify. What this pins down is
// that the vendored definitions produce the wire format the camera expects,
// that the feature libraries export what their names promise, and that the
// proto2 semantics the camera relies on survived generation. `required`,
// explicit presence and defaults all differ from proto3, and a message that
// silently omits a required field is accepted by the encoder and rejected by
// the camera.

import 'package:gopro_native/proto/cohn.dart';
import 'package:gopro_native/proto/control.dart';
import 'package:gopro_native/proto/livestream.dart';
import 'package:gopro_native/proto/media.dart';
import 'package:gopro_native/proto/network.dart';
import 'package:gopro_native/proto/presets.dart';
import 'package:test/test.dart';

void main() {
  group('wire format', () {
    test('a required enum field encodes as tag 1, varint', () {
      final m = RequestSetCameraControlStatus()
        ..cameraControlStatus = EnumCameraControlStatus.CAMERA_EXTERNAL_CONTROL;

      // field 1, wire type 0 -> 0x08; value 2 -> external control.
      expect(m.writeToBuffer(), [0x08, 0x02]);
    });

    test('round trips through bytes', () {
      final sent = RequestSetCameraControlStatus()
        ..cameraControlStatus = EnumCameraControlStatus.CAMERA_IDLE;
      final got = RequestSetCameraControlStatus.fromBuffer(
        sent.writeToBuffer(),
      );
      expect(got.cameraControlStatus, EnumCameraControlStatus.CAMERA_IDLE);
    });

    test('proto2 explicit presence: an unset field is distinguishable', () {
      // proto3 would report the zero value and no presence. The camera reads
      // absence as "leave this alone", so the difference is load bearing.
      final m = RequestSetCOHNSetting();
      expect(m.hasCohnActive(), isFalse);
      expect(m.writeToBuffer(), isEmpty);

      m.cohnActive = false;
      expect(m.hasCohnActive(), isTrue);
      expect(m.writeToBuffer(), isNotEmpty);
    });

    test('a missing required field encodes as nothing at all', () {
      // The trap in this layer. The Dart runtime does not enforce proto2
      // `required` on serialization: writeToBuffer returns an empty buffer
      // rather than throwing, so an incomplete message is sent as zero bytes
      // and the failure surfaces as the camera ignoring a command.
      //
      // isInitialized() reports it and check() names the field. Anything
      // that puts a message on the wire has to call one of them.
      final m = RequestSetCameraControlStatus();
      expect(m.isInitialized(), isFalse);
      expect(m.writeToBuffer(), isEmpty);
      expect(
        m.check,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('cameraControlStatus'),
          ),
        ),
      );

      m.cameraControlStatus = EnumCameraControlStatus.CAMERA_IDLE;
      expect(m.isInitialized(), isTrue);
      expect(m.writeToBuffer(), isNotEmpty);
    });

    test('an unknown enum value does not throw on decode', () {
      // Firmware newer than these definitions will send values this build has
      // no name for. Losing the whole message over one field would be worse
      // than not knowing that field.
      final m = NotifyCOHNStatus.fromBuffer([0x08, 0x7F]);
      expect(m.hasStatus(), isFalse);
      expect(m.unknownFields.toString(), isNotEmpty);
    });
  });

  group('feature libraries', () {
    test('each exports its own messages', () {
      // Constructing one type per library is the whole assertion: it fails to
      // compile if the export is missing.
      expect(RequestGetCOHNStatus(), isNotNull);
      expect(RequestSetCameraName(), isNotNull);
      expect(RequestGetLiveStreamStatus(), isNotNull);
      expect(RequestSetTurboActive(), isNotNull);
      expect(RequestGetApEntries(), isNotNull);
      expect(RequestGetPresetStatus(), isNotNull);
    });

    test('the shared generic response comes with every one of them', () {
      // response_generic carries EnumResultGeneric, which appears in the
      // replies of most features. Making callers import a second library for
      // the type their own reply contains would be a poor trade for the
      // descriptors it saves.
      expect(EnumResultGeneric.RESULT_SUCCESS.value, 1);
      expect(ResponseGeneric(), isNotNull);
    });
  });
}
