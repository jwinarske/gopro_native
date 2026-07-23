// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
//
// access_point.dart — the camera's own Wi-Fi access point, over BLE.
//
// The SSID and passphrase are plain readable GATT characteristics on the
// Wi-Fi Access Point service, not commands. Turning the radio on is a command
// on the control channel. Joining is the host's business — see
// wifi_controller.dart.

import 'dart:convert';

import '../ble_transport.dart';
import '../secret.dart';
import '../ffi/ble_codec.dart';
import '../generated/constants.dart';
import 'wifi_controller.dart';

String _gp(String short) => 'b5f9$short-aa8d-11e3-9046-0002a5d5c51b';

/// Wi-Fi AP SSID.
final String kWifiApSsidUuid = _gp('0002');

/// Wi-Fi AP passphrase.
final String kWifiApPasswordUuid = _gp('0003');

/// The camera's access point.
class GoProAccessPoint {
  GoProAccessPoint(
    this.camera, {
    this.controller = const ManualWifiController(),
  });

  final GoProBleCamera camera;

  /// How the host joins. Defaults to reporting what needs doing rather than
  /// reconfiguring the host's network on its own initiative.
  final WifiController controller;

  /// Reads the SSID and passphrase.
  ///
  /// Both are readable without the access point being on, so this can be
  /// called before [enable].
  Future<ApCredentials> credentials() async {
    // The passphrase goes straight into a Secret without being bound to a
    // name first. A local holding it as plain bytes is one more place it can
    // be picked up from, and naming it invites exactly that.
    return ApCredentials(
      ssid: _text(await camera.readCharacteristic(kWifiApSsidUuid), 'SSID'),
      password: Secret(
        _text(
          await camera.readCharacteristic(kWifiApPasswordUuid),
          'passphrase',
        ),
      ),
    );
  }

  /// Turns the access point on or off.
  ///
  /// The camera drops any existing Wi-Fi connection when this changes, COHN
  /// included: the radio serves one role at a time.
  Future<void> setEnabled({required bool enabled}) async {
    final r = await camera.send(BleChannel.command, [
      CmdId.setWifi.value,
      1,
      enabled ? 1 : 0,
    ]);
    if (r.outcome != BleOutcome.responded) {
      throw WifiJoinException('AP control: ${r.outcome.name}');
    }
    // [command id][status], status 0 is success.
    if (r.payload.length >= 2 && r.payload[1] != 0) {
      throw WifiJoinException(
        'the camera refused AP control',
        detail: 'status ${r.payload[1]}',
      );
    }
  }

  /// Turns the access point on, reads its credentials, and joins.
  ///
  /// With the default [ManualWifiController] this stops short of joining and
  /// throws with the instruction, which is deliberate: the credentials are
  /// still returned by [credentials] for a caller that wants to act on them
  /// itself.
  Future<ApCredentials> connect() async {
    await setEnabled(enabled: true);
    final creds = await credentials();
    await controller.join(creds);
    return creds;
  }

  static String _text(List<int> bytes, String what) {
    if (bytes.isEmpty) {
      throw WifiJoinException('the camera reported an empty $what');
    }
    // The camera writes plain ASCII. Decoded leniently so one unexpected byte
    // reports as a mangled name rather than an exception with no value in it.
    return utf8.decode(bytes, allowMalformed: true).trim();
  }
}
