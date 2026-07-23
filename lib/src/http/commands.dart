// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
//
// commands.dart — the typed Open GoPro HTTP command surface.
//
// One method per upstream message. The endpoints, path components and query
// argument names come from the generated table; what lives here is the
// mapping from a caller's arguments onto them.
//
// That mapping is hand-written on purpose. Upstream expresses it as a Python
// method body that rewrites **kwargs before dispatch, and fifteen of the forty
// messages have one. They range from renaming a parameter (`path` is sent as
// `p`) to spreading a datetime across four query arguments. Generating them
// would mean interpreting arbitrary Python; writing them means the transform
// is visible at the point it happens.

import 'dart:io';

import '../generated/constants.dart';
import '../generated/http_commands.dart';
import 'gopro_http.dart';
import 'http_message.dart';

/// Every HTTP command the camera accepts.
///
/// ```dart
/// final camera = GoProCommands(GoProHttp(discovered.baseUri!));
/// await camera.setShutter(Toggle.enable);
/// final state = await camera.getCameraState();
/// ```
class GoProCommands {
  GoProCommands(this.http);

  final GoProHttp http;

  void close() => http.close();

  HttpMessage _m(String name) {
    final m = kHttpMessages[name];
    if (m == null) {
      // Only reachable if the generated table and this file disagree, which
      // means one of them was edited without the other.
      throw StateError('no HTTP message named "$name"');
    }
    return m;
  }

  Future<Map<String, Object?>> _json(
    String name, [
    Map<String, Object?> values = const {},
  ]) => http.json(_m(name), values: values);

  Future<File> _binary(
    String name,
    Map<String, Object?> values,
    File destination,
    void Function(int, int?)? onProgress,
  ) => http.download(
    _m(name),
    destination,
    values: values,
    onProgress: onProgress,
  );

  // ── Camera ──────────────────────────────────────────────────────────────

  /// Every setting and status the camera exposes, in one document.
  Future<Map<String, Object?>> getCameraState() => _json('get_camera_state');

  /// Model, firmware, serial.
  Future<Map<String, Object?>> getCameraInfo() => _json('get_camera_info');

  /// The Open GoPro API version the camera implements, e.g. `2.0`.
  Future<String> getApiVersion() async {
    final r = await _json('get_open_gopro_api_version');
    return '${r['version']}';
  }

  Future<String> getCameraName() async {
    final r = await _json('get_camera_name');
    return '${r['value']}';
  }

  Future<void> setCameraName(String name) =>
      _json('set_camera_name', {'value': name});

  /// Keeps the connection from timing out. The camera drops an idle client.
  Future<void> keepAlive() => _json('set_keep_alive');

  /// Approximates a battery pull. The camera stops answering immediately, so
  /// this is expected to fail its response deadline rather than succeed.
  Future<void> reboot() => _json('reboot');

  Future<void> setThirdPartyClientInfo() =>
      _json('set_third_party_client_info');

  /// Hands control to the camera's own UI, or takes it back.
  Future<void> setCameraControl(CameraControl mode) =>
      _json('set_camera_control', {'p': mode.value});

  /// Enables the wired USB control channel.
  ///
  /// Disabling it is what allows another USB mode to take over; the camera
  /// refuses several operations while it is on.
  Future<void> setWiredUsbControl(Toggle control) =>
      _json('wired_usb_control', {'p': control.value});

  Future<void> setDigitalZoom(int percent) =>
      _json('set_digital_zoom', {'percent': percent});

  // ── Shutter ─────────────────────────────────────────────────────────────

  /// Starts or stops encoding.
  ///
  /// Stopping is the one command that must not wait for the camera to be
  /// idle: it is what makes the camera idle. Upstream marks the message
  /// fastpass conditionally on this argument, which is why the generated
  /// table records it as [HttpFastpass.conditional] rather than picking a
  /// constant that would be wrong in one direction or the other.
  Future<void> setShutter(Toggle shutter) => _json('set_shutter', {
    'mode': shutter == Toggle.enable ? 'start' : 'stop',
  });

  /// Whether [setShutter] with this argument bypasses the busy gate.
  static bool shutterIsFastpass(Toggle shutter) => shutter == Toggle.disable;

  // ── Date and time ───────────────────────────────────────────────────────

  /// Sets the camera clock.
  ///
  /// [tzOffset] is minutes from UTC. The camera has no notion of a timezone
  /// database, so the offset and the DST flag are both explicit and both have
  /// to come from the caller.
  Future<void> setDateTime(
    DateTime dateTime, {
    int tzOffset = 0,
    bool isDst = false,
  }) => _json('set_date_time', {
    'date': '${dateTime.year}_${dateTime.month}_${dateTime.day}',
    'time': '${dateTime.hour}_${dateTime.minute}_${dateTime.second}',
    'tzone': tzOffset,
    'dst': isDst ? 1 : 0,
  });

  /// The camera clock. Neither timezone nor DST aware, as upstream notes.
  Future<Map<String, Object?>> getDateTime() => _json('get_date_time');

  // ── Presets ─────────────────────────────────────────────────────────────

  /// Currently available presets and preset groups.
  Future<Map<String, Object?>> getPresetStatus({bool includeHidden = false}) =>
      _json('get_preset_status', {'include-hidden': includeHidden ? 1 : 0});

  Future<void> loadPreset(int preset) => _json('load_preset', {'id': preset});

  /// Loads the most recently used preset in [group], whose values come from
  /// the protobuf `EnumPresetGroup`.
  Future<void> loadPresetGroup(int group) =>
      _json('load_preset_group', {'id': group});

  Future<void> setPresetVisibility(int presetId, {required bool visible}) =>
      _json('set_preset_visibility', {
        'id': presetId,
        'visible': visible ? 1 : 0,
      });

  /// Renames or re-icons a custom preset. Omitted fields are left alone.
  Future<void> updateCustomPreset({
    int? iconId,
    Object? titleId,
    String? customName,
  }) => _json('update_custom_preset', {
    'icon_id': iconId,
    'title_id': titleId,
    'custom_name': customName,
  });

  // ── Media ───────────────────────────────────────────────────────────────

  /// Everything on the SD card.
  Future<Map<String, Object?>> getMediaList() => _json('get_media_list');

  /// Metadata for one file, e.g. `100GOPRO/GX010001.MP4`.
  Future<Map<String, Object?>> getMediaMetadata(String path) =>
      _json('get_media_metadata', {'path': path});

  Future<Map<String, Object?>> getLastCapturedMedia() =>
      _json('get_last_captured_media');

  Future<void> deleteFile(String path) => _json('delete_file', {'path': path});

  /// Deletes an entire group. Do not use on a file that is not a group.
  Future<void> deleteGroup(String firstFileInGroup) =>
      _json('delete_group', {'p': firstFileInGroup});

  Future<void> deleteAllMedia() => _json('delete_all_media');

  /// Marks a moment in a file. [offsetMs] is required for video and ignored
  /// for stills.
  Future<void> addHilight(String file, {int? offsetMs}) =>
      _json('add_file_hilight', {'path': file, 'ms': offsetMs});

  Future<void> removeHilight(String file, {required int offsetMs}) =>
      _json('remove_file_hilight', {'path': file, 'ms': offsetMs});

  /// Speeds up offload. Worth enabling around a batch of downloads and
  /// disabling afterwards — the camera restricts other operations while it
  /// is on.
  Future<void> setTurboTransfer(Toggle mode) =>
      _json('set_turbo_mode', {'p': mode.value});

  // ── Downloads ───────────────────────────────────────────────────────────

  /// Downloads a media file. [cameraFile] is a path like
  /// `100GOPRO/GX010001.MP4`.
  ///
  /// Streams to [destination]; the bytes never sit in memory. A transfer that
  /// stops delivering for [GoProHttp.stallTimeout] is abandoned and the
  /// partial file removed.
  Future<File> downloadFile(
    String cameraFile,
    File destination, {
    void Function(int received, int? total)? onProgress,
  }) => _binary('download_file', {'path': cameraFile}, destination, onProgress);

  Future<File> downloadThumbnail(
    String cameraFile,
    File destination, {
    void Function(int received, int? total)? onProgress,
  }) => _binary('get_thumbnail', {'path': cameraFile}, destination, onProgress);

  Future<File> downloadScreennail(
    String cameraFile,
    File destination, {
    void Function(int received, int? total)? onProgress,
  }) =>
      _binary('get_screennail', {'path': cameraFile}, destination, onProgress);

  /// The GPMF telemetry track embedded in a file.
  Future<File> downloadGpmf(
    String cameraFile,
    File destination, {
    void Function(int received, int? total)? onProgress,
  }) => _binary('get_gpmf_data', {'path': cameraFile}, destination, onProgress);

  Future<File> downloadTelemetry(
    String cameraFile,
    File destination, {
    void Function(int received, int? total)? onProgress,
  }) => _binary('get_telemetry', {'path': cameraFile}, destination, onProgress);

  // ── Streaming ───────────────────────────────────────────────────────────

  /// Starts or stops the preview stream. [port] applies when starting.
  Future<void> setPreviewStream(Toggle mode, {int? port}) => _json(
    'set_preview_stream',
    {'mode': mode == Toggle.enable ? 'start' : 'stop', 'port': port},
  );

  // ── Webcam ──────────────────────────────────────────────────────────────
  //
  // Resolution, FOV and protocol are integers here rather than enums: their
  // definitions live in an upstream module that is not vendored, and inventing
  // names for values this package cannot check against would be worse than
  // passing the value through. See the Open GoPro webcam specification.

  Future<Map<String, Object?>> webcamStart({
    int? resolution,
    int? fov,
    int? port,
    String? protocol,
  }) => _json('webcam_start', {
    'res': resolution,
    'fov': fov,
    'port': port,
    'protocol': protocol,
  });

  Future<Map<String, Object?>> webcamStop() => _json('webcam_stop');
  Future<Map<String, Object?>> webcamExit() => _json('webcam_exit');
  Future<Map<String, Object?>> webcamPreview() => _json('webcam_preview');
  Future<Map<String, Object?>> webcamStatus() => _json('webcam_status');

  Future<String> getWebcamVersion() async {
    final r = await _json('get_webcam_version');
    return '${r['version'] ?? r['value']}';
  }
}
