// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
//
// webcam.dart — the camera as a USB webcam.
//
// Pure HTTP; the message table in #4 already carries the endpoints. What is
// here is the typing: resolution, field of view, protocol, status and error
// are enums upstream and were integers at the boundary until now.
//
// The camera sends video to the host as a UDP transport stream or over RTSP.
// Those packets never enter this process — a media pipeline consumes them
// directly from the socket. Starting and stopping is all that happens here.

import '../generated/streaming.dart';
import '../http/commands.dart';

/// What the camera said about a webcam request.
///
/// Every webcam endpoint answers with this shape, including the ones that
/// only report state.
class WebcamReply {
  const WebcamReply({this.status, this.error, this.raw = const {}});

  /// Null when the camera reported a status this build has no name for.
  /// Newer firmware introduces values, and an unrecognized one is not a
  /// reason to fail a call that otherwise succeeded.
  final WebcamStatus? status;
  final WebcamError? error;

  /// The undecoded document, so a caller is never blocked by this class not
  /// knowing about a field.
  final Map<String, Object?> raw;

  /// Whether the camera reported success. An absent error is treated as
  /// success, which is what the endpoints that only report state return.
  bool get ok => error == null || error == WebcamError.success;

  static WebcamReply fromJson(Map<String, Object?> json) => WebcamReply(
    status: json['status'] is int
        ? WebcamStatus.fromValue(json['status']! as int)
        : null,
    error: json['error'] is int
        ? WebcamError.fromValue(json['error']! as int)
        : null,
    raw: json,
  );

  @override
  String toString() =>
      'WebcamReply(${status?.name ?? 'status?'}, ${error?.name ?? 'error?'})';
}

/// A webcam request was refused by the camera.
class WebcamException implements Exception {
  const WebcamException(this.what, this.reply);

  final String what;
  final WebcamReply reply;

  @override
  String toString() => 'WebcamException($what: $reply)';
}

/// The camera's webcam mode.
class WebcamClient {
  WebcamClient(this.commands);

  final GoProCommands commands;

  /// The webcam protocol version the camera implements.
  Future<String> version() => commands.getWebcamVersion();

  Future<WebcamReply> status() async =>
      WebcamReply.fromJson(await commands.webcamStatus());

  /// Starts the webcam.
  ///
  /// [port] applies to the transport-stream protocol; RTSP uses its own.
  /// Omitted arguments leave the camera's current choice alone rather than
  /// imposing a default this package invented.
  Future<WebcamReply> start({
    WebcamResolution? resolution,
    WebcamFOV? fov,
    int? port,
    WebcamProtocol? protocol,
  }) => _do(
    'start',
    () => commands.webcamStart(
      resolution: resolution?.value,
      fov: fov?.value,
      port: port,
      protocol: protocol?.value,
    ),
  );

  /// Stops streaming but stays in webcam mode, so [start] is quick.
  Future<WebcamReply> stop() => _do('stop', commands.webcamStop);

  /// Leaves webcam mode entirely.
  Future<WebcamReply> exit() => _do('exit', commands.webcamExit);

  /// Starts the low-power preview.
  Future<WebcamReply> preview() => _do('preview', commands.webcamPreview);

  Future<WebcamReply> _do(
    String what,
    Future<Map<String, Object?>> Function() call,
  ) async {
    final reply = WebcamReply.fromJson(await call());
    if (!reply.ok) throw WebcamException(what, reply);
    return reply;
  }
}
