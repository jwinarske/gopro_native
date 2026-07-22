// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
// Spot-checks on the generated constants.
//
// The generator is mechanical, so exhaustive assertions would just restate it.
// What is worth pinning is the handful of values this project already depends
// on, the naming transforms that are easy to get subtly wrong, and the
// unknown-value behavior — a camera on newer firmware must not take down the
// connection by sending a value this table predates.
//
// `tool/gen_constants.py --check` guards the files against being stale
// relative to tool/upstream/.

import 'package:gopro_native/gopro_native.dart';
import 'package:test/test.dart';

void main() {
  group('SettingId', () {
    test('carries the MAX2 settings this project relies on', () {
      // Added by upstream's MAX2 support (Python SDK 0.22.0). cameraMode is
      // the 360-vs-flat switch and must be set before loading a preset.
      expect(SettingId.cameraMode.value, 194);
      expect(SettingId.num360PhotoFilesExtension.value, 196);
      expect(SettingId.automaticWiFiAccessPoint.value, 236);
    });

    test('beepVolume is 216 — upstream renamed it from CAMERA_VOLUME', () {
      // A breaking rename in 0.22.0. Pinned so a regeneration against an older
      // vendored copy is caught rather than silently reverting the name.
      expect(SettingId.beepVolume.value, 216);
    });

    test('led is 91 — the keep-alive setting', () {
      // BLE keep-alive is a write of 66 to this setting every 3 s. Phase 3
      // depends on it; if this id moves, keep-alive silently stops working
      // and the camera drops the connection after ~10 s.
      expect(SettingId.led.value, 91);
    });
  });

  group('naming transforms', () {
    test('digit-leading fragments keep their case', () {
      expect(VideoResolution.num4K.value, 1);
      expect(VideoResolution.num1080.value, 9);
    });

    test('all-caps upstream class names become UpperCamelCase', () {
      // LED_SPECIAL -> LedSpecial, Anti_Flicker -> AntiFlicker.
      expect(LedSpecial.values, isNotEmpty);
      expect(AntiFlicker.values, isNotEmpty);
      expect(AutomaticWiFiAccessPoint.values, isNotEmpty);
    });

    test('cross-module collisions are disambiguated, not dropped', () {
      // WirelessBand exists upstream as both a setting (178) and a status
      // (76). Same values, different member spellings — neither can be
      // dropped, so both survive with a module suffix.
      expect(WirelessBandSetting.values.length, 2);
      expect(WirelessBandStatus.values.length, 2);
      expect(WirelessBandSetting.num24Ghz.value, 0);
      expect(WirelessBandStatus.num24Ghz.value, 0);
    });
  });

  group('StatusId', () {
    test('carries the statuses the ready-gate depends on', () {
      expect(StatusId.busy.value, 8);
      expect(StatusId.encoding.value, 10);
      // Added by upstream's MAX2 support.
      expect(StatusId.cameraName.value, 122);
    });
  });

  group('fromValue', () {
    test('round-trips every generated member', () {
      for (final s in SettingId.values) {
        expect(SettingId.fromValue(s.value), same(s));
      }
      for (final s in StatusId.values) {
        expect(StatusId.fromValue(s.value), same(s));
      }
      for (final r in VideoResolution.values) {
        expect(VideoResolution.fromValue(r.value), same(r));
      }
    });

    test('returns null for unknown values instead of throwing', () {
      // Newer firmware introduces values this table predates. An unknown
      // setting must degrade to null, never take down the connection.
      expect(SettingId.fromValue(0xFFFF), isNull);
      expect(StatusId.fromValue(0xFFFF), isNull);
      expect(VideoResolution.fromValue(0xFFFF), isNull);
    });

    test('handles the negative sentinel upstream uses', () {
      // Several status enums use UNKNOWN = -1, which parses as a unary-minus
      // expression rather than a literal. Its survival is worth pinning.
      expect(PrimaryStorage.fromValue(-1), isNotNull);
      expect(PrimaryStorage.fromValue(-1)!.value, -1);
    });
  });
}
