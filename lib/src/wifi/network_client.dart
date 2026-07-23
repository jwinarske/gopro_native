// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
//
// network_client.dart — joining the camera to an existing network.
//
// The other direction from access_point.dart: there the host joins the
// camera, here the camera joins a network the host already knows about. This
// is what COHN needs before it can be provisioned, and what livestreaming
// needs before it has a route to a server.
//
// Scanning is asynchronous in a way the rest of the protocol is not. The
// request returns immediately with "scanning started" and the results arrive
// later as an unprompted notification carrying a scan id. Nothing correlates
// the two but the id, so the notification has to be watched for rather than
// awaited as a reply.

import 'dart:async';

import '../../proto/network.dart';
import '../ble_transport.dart';
import '../ffi/ble_codec.dart';
import '../generated/constants.dart';

/// A network request was refused, or provisioning failed.
class NetworkException implements Exception {
  const NetworkException(this.what, {this.result, this.provisioning});

  final String what;
  final EnumResultGeneric? result;

  /// The camera's provisioning verdict. The distinction matters: a wrong
  /// passphrase, an AP that would not associate, and a network with no
  /// internet are three different problems with three different fixes.
  final EnumProvisioning? provisioning;

  @override
  String toString() =>
      'NetworkException($what'
      '${result == null ? '' : ', ${result!.name}'}'
      '${provisioning == null ? '' : ', ${provisioning!.name}'})';
}

/// One access point the camera can see.
class AccessPoint {
  const AccessPoint({
    required this.ssid,
    required this.signalBars,
    required this.frequencyMhz,
    required this.flags,
  });

  final String ssid;

  /// 3 bars above -70 dBm, 2 above -85, 1 at or below.
  final int signalBars;
  final int frequencyMhz;

  /// Bitmask of [EnumScanEntryFlags].
  final int flags;

  bool get isOpen => flags & 0x01 == 0;

  /// The camera already holds credentials for this one, so [NetworkClient
  /// .connect] will work without a passphrase.
  bool get isConfigured => flags & 0x02 != 0;

  bool get isAssociated => flags & 0x08 != 0;
  bool get isUnsupported => flags & 0x10 != 0;

  @override
  String toString() =>
      'AccessPoint($ssid, ${signalBars}bar, ${frequencyMhz}MHz'
      '${isConfigured ? ', configured' : ''}'
      '${isAssociated ? ', associated' : ''})';
}

/// The result of a scan.
class ScanResult {
  const ScanResult({required this.scanId, required this.totalEntries});

  /// Identifies this batch of results. [NetworkClient.accessPoints] needs it;
  /// results from an older scan are not retrievable once a new one runs.
  final int scanId;
  final int totalEntries;
}

/// Puts the camera on a network.
class NetworkClient {
  NetworkClient(this.camera);

  final GoProBleCamera camera;

  /// Provisioning state as the camera reports it, unprompted.
  ///
  /// Connecting is not finished when the reply arrives — the reply says the
  /// attempt started. These notifications are how it ends.
  Stream<EnumProvisioning> get provisioningStates => camera.pushes
      .where(_isNotification(ActionId.notifProvisState))
      .map(
        (p) => NotifProvisioningState.fromBuffer(
          p.message.sublist(2),
        ).provisioningState,
      );

  /// Scans for access points and waits for the camera to finish.
  ///
  /// The reply to the request only says scanning began; completion arrives as
  /// a notification, so this listens for it before asking.
  Future<ScanResult> scan({
    Duration timeout = const Duration(seconds: 30),
  }) async {
    // Subscribe first. A fast scan can complete before the reply to the
    // request is even delivered, and a notification nobody is listening for
    // is simply gone.
    final done = camera.pushes
        .where(_isNotification(ActionId.notifStartScan))
        .map((p) => NotifStartScanning.fromBuffer(p.message.sublist(2)))
        .firstWhere((n) => n.scanningState == EnumScanning.SCANNING_SUCCESS)
        .timeout(
          timeout,
          onTimeout: () => throw const NetworkException(
            'timed out waiting for the scan to finish',
          ),
        );

    // If the request fails, `done` is still outstanding. Left alone it
    // completes later with an unhandled error -- the stream closes when the
    // camera does, and firstWhere on a closed stream throws.
    try {
      final reply = await _send(
        ActionId.scanWifiNetworks,
        RequestStartScan().writeToBuffer(),
        'start scan',
      );
      final started = ResponseStartScanning.fromBuffer(reply);
      if (started.result != EnumResultGeneric.RESULT_SUCCESS) {
        throw NetworkException('start scan', result: started.result);
      }
    } catch (_) {
      unawaited(done.catchError((Object _) => NotifStartScanning()));
      rethrow;
    }

    final n = await done;
    return ScanResult(
      scanId: n.hasScanId() ? n.scanId : 0,
      totalEntries: n.hasTotalEntries() ? n.totalEntries : 0,
    );
  }

  /// Retrieves the access points from a scan.
  ///
  /// Paged by the camera. [pageSize] bounds one request; the whole set is
  /// gathered unless [maxEntries] cuts it short.
  Future<List<AccessPoint>> accessPoints(
    ScanResult scan, {
    int pageSize = 20,
    int? maxEntries,
  }) async {
    final want = maxEntries == null
        ? scan.totalEntries
        : (maxEntries < scan.totalEntries ? maxEntries : scan.totalEntries);

    final out = <AccessPoint>[];
    while (out.length < want) {
      final remaining = want - out.length;
      final req = RequestGetApEntries()
        ..startIndex = out.length
        ..maxEntries = remaining < pageSize ? remaining : pageSize
        ..scanId = scan.scanId;

      final reply = await _send(
        ActionId.getApEntries,
        req.writeToBuffer(),
        'get access points',
      );
      final page = ResponseGetApEntries.fromBuffer(reply);
      if (page.result != EnumResultGeneric.RESULT_SUCCESS) {
        throw NetworkException('get access points', result: page.result);
      }
      if (page.entries.isEmpty) break; // The camera has no more to give.

      out.addAll(
        page.entries.map(
          (e) => AccessPoint(
            ssid: e.ssid,
            signalBars: e.signalStrengthBars,
            frequencyMhz: e.signalFrequencyMhz,
            flags: e.scanEntryFlags,
          ),
        ),
      );
    }
    return out;
  }

  /// Connects to a network the camera already has credentials for.
  Future<void> connect(
    String ssid, {
    Duration timeout = const Duration(seconds: 60),
  }) async {
    if (ssid.isEmpty) throw ArgumentError('ssid is empty');

    final settled = _awaitProvisioned(timeout);
    final reply = await _send(
      ActionId.requestWifiConnect,
      (RequestConnect()..ssid = ssid).writeToBuffer(),
      'connect',
    );
    final r = ResponseConnect.fromBuffer(reply);
    if (r.result != EnumResultGeneric.RESULT_SUCCESS) {
      throw NetworkException(
        'connect',
        result: r.result,
        provisioning: r.hasProvisioningState() ? r.provisioningState : null,
      );
    }
    await settled;
  }

  /// Connects to a network the camera has not seen before.
  ///
  /// [bypassEulaCheck] lets the camera accept a network with no route to the
  /// internet. Surfaced rather than hardcoded — the reference sets it to true
  /// unconditionally, which quietly changes what the camera will accept.
  ///
  /// [password] is not logged and does not appear in any exception thrown
  /// here.
  Future<void> connectNew(
    String ssid,
    String password, {
    bool bypassEulaCheck = false,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    if (ssid.isEmpty) throw ArgumentError('ssid is empty');

    final settled = _awaitProvisioned(timeout);
    final req = RequestConnectNew()
      ..ssid = ssid
      ..password = password
      ..bypassEulaCheck = bypassEulaCheck;

    final reply = await _send(
      ActionId.requestWifiConnectNew,
      req.writeToBuffer(),
      'connect to a new network',
    );
    final r = ResponseConnectNew.fromBuffer(reply);
    if (r.result != EnumResultGeneric.RESULT_SUCCESS) {
      throw NetworkException(
        'connect to a new network',
        result: r.result,
        provisioning: r.hasProvisioningState() ? r.provisioningState : null,
      );
    }
    await settled;
  }

  /// Disconnects the camera from its network.
  ///
  /// Note the feature: releasing lives under the command feature (action 120)
  /// rather than network management, unlike everything else here. Sending it
  /// on the network-management feature produces no reply at all.
  Future<void> release() async {
    final reply = await camera.sendProtobuf(
      FeatureId.command.value,
      ActionId.releaseNetwork.value,
      RequestReleaseNetwork().writeToBuffer(),
    );
    // Note the channel: releasing is a command-feature action and goes on the
    // command characteristic, unlike everything else here.
    if (reply.outcome != BleOutcome.responded) {
      throw NetworkException('release: ${reply.outcome.name}');
    }
    final r = ResponseGeneric.fromBuffer(reply.payload.sublist(2));
    if (r.result != EnumResultGeneric.RESULT_SUCCESS) {
      throw NetworkException('release', result: r.result);
    }
  }

  /// Waits for provisioning to reach a terminal state.
  ///
  /// Subscribed before the request goes out, because the camera can settle
  /// before the reply is delivered.
  Future<void> _awaitProvisioned(Duration timeout) {
    const succeeded = {
      EnumProvisioning.PROVISIONING_SUCCESS_NEW_AP,
      EnumProvisioning.PROVISIONING_SUCCESS_OLD_AP,
    };
    const pending = {
      EnumProvisioning.PROVISIONING_UNKNOWN,
      EnumProvisioning.PROVISIONING_NEVER_STARTED,
      EnumProvisioning.PROVISIONING_STARTED,
    };

    // Same shape as the scan: a caller that never awaits this must not be
    // left with an unhandled error when the stream closes.
    return provisioningStates
        .firstWhere((s) => !pending.contains(s))
        .timeout(
          timeout,
          onTimeout: () => throw const NetworkException(
            'timed out waiting for the camera to join',
          ),
        )
        .then((state) {
          if (!succeeded.contains(state)) {
            throw NetworkException(
              'the camera did not join',
              provisioning: state,
            );
          }
        });
  }

  /// Matches a notification by its action id.
  ///
  /// Notifications are not replies: they arrive with their own action id
  /// rather than a request's with the high bit set, so nothing is waiting on
  /// them and they surface as pushes.
  static bool Function(BlePush) _isNotification(ActionId action) =>
      (p) =>
          p.message.length >= 2 &&
          p.message[0] == FeatureId.networkManagement.value &&
          p.message[1] == action.value;

  Future<List<int>> _send(ActionId action, List<int> body, String what) async {
    final reply = await camera.sendProtobuf(
      FeatureId.networkManagement.value,
      action.value,
      body,
      // Camera Management, not the command characteristic. Sent there, every
      // camera tested answers a bare [feature][0x02] and nothing else,
      // whatever the action -- an error, not a reply, so the request simply
      // times out.
      channel: BleChannel.network,
    );
    if (reply.outcome != BleOutcome.responded) {
      throw NetworkException('$what: ${reply.outcome.name}');
    }
    return reply.payload.sublist(2);
  }
}
