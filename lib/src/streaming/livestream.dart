// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
//
// livestream.dart — RTMP livestreaming, configured over BLE.
//
// Setup is protobuf on the command channel; status is a protobuf query the
// camera will also push unprompted once registered. The camera does the
// streaming itself, straight to the RTMP server: no frame ever reaches this
// process, and none should. Dart brokers the configuration and stays out of
// the data path entirely.
//
// The camera must already be on a network with a route to the server. Putting
// it there is network management, not this.

import '../../proto/livestream.dart';
import '../ble_transport.dart';
import '../ffi/ble_codec.dart';
import '../generated/constants.dart';

/// A livestream request was refused, or the camera reported an error state.
class LivestreamException implements Exception {
  const LivestreamException(this.what, {this.error, this.state});

  final String what;

  /// The camera's own error code, when it reported one.
  final EnumLiveStreamError? error;
  final EnumLiveStreamStatus? state;

  @override
  String toString() =>
      'LivestreamException($what'
      '${error == null ? '' : ', ${error!.name}'}'
      '${state == null ? '' : ', ${state!.name}'})';
}

/// Configures and observes the camera's livestream.
class LivestreamClient {
  LivestreamClient(this.camera);

  final GoProBleCamera camera;

  /// Reads the livestream status.
  ///
  /// [register] asks the camera to push updates as they change; those arrive
  /// on [GoProBleCamera.pushes] with the same framing and, like every
  /// registration, do not survive a disconnect.
  ///
  /// This is worth reading before [start]: it reports which resolutions and
  /// lenses the current camera and lens configuration actually support, and
  /// the bitrate bounds the camera will accept.
  Future<NotifyLiveStreamStatus> status({
    Set<EnumRegisterLiveStreamStatus> register = const {},
    Set<EnumRegisterLiveStreamStatus> unregister = const {},
  }) async {
    final req = RequestGetLiveStreamStatus()
      ..registerLiveStreamStatus.addAll(register)
      ..unregisterLiveStreamStatus.addAll(unregister);

    final reply = await camera.sendProtobuf(
      FeatureId.query.value,
      ActionId.getLivestreamStatus.value,
      req.writeToBuffer(),
      channel: BleChannel.query,
    );
    if (reply.outcome != BleOutcome.responded) {
      throw LivestreamException('get status: ${reply.outcome.name}');
    }
    return NotifyLiveStreamStatus.fromBuffer(reply.payload.sublist(2));
  }

  /// Configures the stream.
  ///
  /// [url] is the RTMP or RTMPS endpoint, and is a secret in practice: a
  /// stream key is usually embedded in it, and anyone holding it can publish
  /// as you. It is never logged here and does not appear in an exception.
  ///
  /// [certificate] is a PEM bundle for servers whose chain the camera does
  /// not already trust.
  ///
  /// [encode] also records to the SD card while streaming. The camera reports
  /// whether it supports that in
  /// [NotifyLiveStreamStatus.liveStreamEncodeSupported].
  Future<void> configure({
    required String url,
    bool encode = false,
    EnumWindowSize? windowSize,
    EnumLens? lens,
    int? minimumBitrate,
    int? maximumBitrate,
    int? startingBitrate,
    String? certificate,
  }) async {
    if (url.isEmpty) throw ArgumentError('url is empty');

    final req = RequestSetLiveStreamMode()
      ..url = url
      ..encode = encode;
    if (windowSize != null) req.windowSize = windowSize;
    if (lens != null) req.lens = lens;
    if (minimumBitrate != null) req.minimumBitrate = minimumBitrate;
    if (maximumBitrate != null) req.maximumBitrate = maximumBitrate;
    if (startingBitrate != null) req.startingBitrate = startingBitrate;
    if (certificate != null) req.cert = certificate.codeUnits;

    final reply = await camera.sendProtobuf(
      FeatureId.command.value,
      ActionId.setLivestreamMode.value,
      req.writeToBuffer(),
    );
    if (reply.outcome != BleOutcome.responded) {
      // Deliberately does not name the URL: it carries the stream key.
      throw LivestreamException('configure: ${reply.outcome.name}');
    }
  }

  /// Waits for the camera to finish configuring and report itself ready.
  ///
  /// Throws [LivestreamException] on a failure state, carrying the camera's
  /// own error — the difference between a bad URL, no internet, and an SSL
  /// handshake failure is the whole diagnosis.
  Future<NotifyLiveStreamStatus> waitUntilReady({
    Duration timeout = const Duration(seconds: 30),
    Duration poll = const Duration(seconds: 1),
  }) async {
    final start = DateTime.now();
    while (DateTime.now().difference(start) < timeout) {
      final s = await status();
      final state = s.hasLiveStreamStatus() ? s.liveStreamStatus : null;

      if (state == EnumLiveStreamStatus.LIVE_STREAM_STATE_READY ||
          state == EnumLiveStreamStatus.LIVE_STREAM_STATE_STREAMING) {
        return s;
      }
      if (state == EnumLiveStreamStatus.LIVE_STREAM_STATE_FAILED_STAY_ON) {
        throw LivestreamException(
          'the camera failed to configure the stream',
          error: s.hasLiveStreamError() ? s.liveStreamError : null,
          state: state,
        );
      }
      if (state == EnumLiveStreamStatus.LIVE_STREAM_STATE_UNAVAILABLE) {
        throw LivestreamException(
          'livestreaming is unavailable in this lens configuration',
          state: state,
        );
      }
      await Future<void>.delayed(poll);
    }
    throw const LivestreamException(
      'timed out waiting for the stream to be ready',
    );
  }

  /// Starts streaming. The camera must already be [waitUntilReady].
  ///
  /// This is the ordinary shutter command: once configured, streaming is
  /// what recording does.
  Future<void> start() => _shutter(true);

  /// Stops streaming.
  ///
  /// Fastpass, because stopping must not wait for the encoding it is stopping
  /// — the same reason the HTTP surface treats it that way.
  Future<void> stop() => _shutter(false);

  Future<void> _shutter(bool on) async {
    final reply = await camera.send(BleChannel.command, [
      CmdId.setShutter.value,
      1,
      on ? 1 : 0,
    ], priority: on ? BlePriority.queued : BlePriority.fastpass);
    if (reply.outcome != BleOutcome.responded) {
      throw LivestreamException(
        '${on ? 'start' : 'stop'}: ${reply.outcome.name}',
      );
    }
  }
}
