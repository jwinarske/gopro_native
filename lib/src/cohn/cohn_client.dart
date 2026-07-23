// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
//
// cohn_client.dart — Camera On the Home Network, over BLE.
//
// COHN lets the camera be reached over an existing network rather than its
// own access point. Provisioning is protobuf over BLE; using it afterwards is
// HTTPS with Basic auth and a pinned certificate (see cohn_http.dart).
//
// The camera has to already be on a network. COHN does not put it there —
// that is network management, a separate protobuf feature.

import 'dart:convert';

import '../../proto/cohn.dart';
import '../ble_transport.dart';
import '../ffi/ble_codec.dart';
import '../generated/constants.dart';
import 'credentials.dart';

/// A COHN request was refused by the camera.
class CohnException implements Exception {
  const CohnException(this.what, this.result);

  final String what;

  /// The camera's own verdict. Null when it never answered.
  final EnumResultGeneric? result;

  @override
  String toString() =>
      'CohnException($what${result == null ? '' : ': ${result!.name}'})';
}

/// Provisions and inspects COHN on one camera.
class CohnClient {
  CohnClient(this.camera);

  final GoProBleCamera camera;

  /// Reads the camera's COHN state.
  ///
  /// [register] asks the camera to keep sending updates as the state changes.
  /// Those arrive on [GoProBleCamera.pushes] framed the same way, and — like
  /// every registered subscription — do not survive a disconnect.
  Future<NotifyCOHNStatus> status({bool register = false}) async {
    final reply = await _query(
      ActionId.requestGetCohnStatus,
      (RequestGetCOHNStatus()..registerCohnStatus = register).writeToBuffer(),
      'get status',
    );
    return NotifyCOHNStatus.fromBuffer(reply);
  }

  /// Asks the camera to generate its self-signed certificate.
  ///
  /// [override] replaces an existing one, which invalidates any credentials
  /// already stored for this camera.
  ///
  /// [bypassEulaCheck] skips the camera's end-user agreement gate. The
  /// reference hardcodes this to true. It is surfaced here, and defaults to
  /// false, because silently accepting an agreement on someone's behalf is
  /// not a decision a library should be making for them.
  Future<void> createCertificate({
    bool override = false,
    bool bypassEulaCheck = false,
  }) async {
    final req = RequestCreateCOHNCert()..override = override;
    if (bypassEulaCheck) {
      // Not a field in the vendored definitions. Recorded rather than sent,
      // so the gap is visible instead of being silently ignored.
      throw UnimplementedError(
        'bypassEulaCheck is not in the vendored cohn.proto for this API '
        'version. Accept the agreement on the camera instead.',
      );
    }
    await _command(
      ActionId.requestCreateCohnCert,
      req.writeToBuffer(),
      'create certificate',
    );
  }

  /// Fetches the camera's root certificate, PEM encoded.
  Future<String> certificate() async {
    final reply = await _query(
      ActionId.requestGetCohnCert,
      RequestCOHNCert().writeToBuffer(),
      'get certificate',
    );
    final r = ResponseCOHNCert.fromBuffer(reply);
    if (r.hasResult() && r.result != EnumResultGeneric.RESULT_SUCCESS) {
      throw CohnException('get certificate', r.result);
    }
    if (!r.hasCert() || r.cert.isEmpty) {
      throw const CohnException('get certificate: empty', null);
    }
    return r.cert;
  }

  /// Discards the certificate and the credentials that go with it.
  Future<void> clearCertificate() => _command(
    ActionId.requestClearCohnCert,
    RequestClearCOHNCert().writeToBuffer(),
    'clear certificate',
  );

  /// Turns COHN on or off.
  Future<void> setEnabled({required bool enabled}) => _command(
    ActionId.requestCohnSetting,
    (RequestSetCOHNSetting()..cohnActive = enabled).writeToBuffer(),
    'set enabled',
  );

  /// Runs provisioning to completion and returns the credentials.
  ///
  /// The camera must already be connected to a network: COHN reports the
  /// address it has there, and without one there is nothing to hand back.
  /// Putting it on a network is network management, not this.
  ///
  /// Throws [CohnException] if the camera never reaches
  /// [EnumCOHNStatus.COHN_PROVISIONED] within [timeout].
  Future<CohnCredentials> provision({
    bool override = false,
    Duration timeout = const Duration(seconds: 60),
    Duration poll = const Duration(seconds: 2),
  }) async {
    final start = DateTime.now();

    await createCertificate(override: override);
    await setEnabled(enabled: true);

    // Provisioning is not instantaneous and the camera reports progress only
    // by way of its status, so this polls rather than pretending the create
    // call was the whole thing.
    while (DateTime.now().difference(start) < timeout) {
      final s = await status();
      if (s.hasStatus() && s.status == EnumCOHNStatus.COHN_PROVISIONED) {
        if (!s.hasUsername() || !s.hasPassword()) {
          throw const CohnException(
            'provisioned but the camera reported no credentials',
            null,
          );
        }
        return CohnCredentials(
          username: s.username,
          password: s.password,
          certificate: await certificate(),
          ipAddress: s.hasIpaddress() ? s.ipaddress : null,
          ssid: s.hasSsid() ? s.ssid : null,
          macAddress: s.hasMacaddress() ? s.macaddress : null,
        );
      }
      await Future<void>.delayed(poll);
    }
    throw const CohnException('timed out waiting to be provisioned', null);
  }

  // The "get" actions are query-feature and ride the query characteristic;
  // the rest are command-feature on the command characteristic. The channel
  // is not implied by the feature and getting it wrong produces no reply at
  // all rather than an error.
  Future<List<int>> _query(ActionId action, List<int> body, String what) =>
      _send(FeatureId.query, BleChannel.query, action, body, what);

  Future<void> _command(ActionId action, List<int> body, String what) async {
    final reply = await _send(
      FeatureId.command,
      BleChannel.command,
      action,
      body,
      what,
    );
    // Command replies are a bare ResponseGeneric.
    if (reply.isNotEmpty) {
      final r = ResponseGeneric.fromBuffer(reply);
      if (r.result != EnumResultGeneric.RESULT_SUCCESS) {
        throw CohnException(what, r.result);
      }
    }
  }

  Future<List<int>> _send(
    FeatureId feature,
    BleChannel channel,
    ActionId action,
    List<int> body,
    String what,
  ) async {
    final reply = await camera.sendProtobuf(
      feature.value,
      action.value,
      body,
      channel: channel,
    );
    if (reply.outcome != BleOutcome.responded) {
      throw CohnException('$what: ${reply.outcome.name}', null);
    }
    // Strip the [feature][action] header the reply carries.
    return reply.payload.sublist(2);
  }
}

/// Base64 of the Basic credentials, for callers building their own requests.
///
/// Exposed as a function rather than logged anywhere: this value is the
/// password with one reversible transformation applied.
String basicAuthHeader(String username, String password) =>
    'Basic ${base64Encode(utf8.encode('$username:$password'))}';
