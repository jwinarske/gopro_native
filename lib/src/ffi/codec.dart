// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
// codec.dart — decodes event payloads posted by the native bridge.
//
// Wire format matches native/include/glaze_meta.h: fields in glz::meta<T>
// declaration order, little-endian, no type tags. Strings carry a uint32
// length prefix.
//
// DEBUG NOTE: the read order below must exactly mirror the field order in
// glz::meta<gp::CameraRecord> in native/include/gopro_types.h. Drift is
// silent corruption rather than a crash — fields land in the wrong variables
// and a misread length prefix turns into an absurd string allocation. If
// serials decode as garbage or a read throws RangeError, suspect drift here
// before anything else.

import 'dart:convert';
import 'dart:typed_data';

import 'types.dart';

/// Discriminator byte prefixed to every payload. Mirrors `gp::EventKind`.
enum EventKind {
  sentinel(0x00),
  update(0x01),
  left(0x02);

  const EventKind(this.value);
  final int value;

  static EventKind? fromByte(int b) {
    for (final k in EventKind.values) {
      if (k.value == b) return k;
    }
    return null;
  }
}

/// A decoded event from the native bridge.
class CameraEvent {
  const CameraEvent(this.kind, this.camera);
  final EventKind kind;

  /// Null only for [EventKind.sentinel].
  final GoProCamera? camera;
}

class GlazeCodec {
  GlazeCodec._();

  /// Decodes one payload. Returns null for an unrecognized
  /// discriminator rather than throwing, so a newer native library adding an
  /// event kind degrades to "ignored" instead of killing the stream.
  static CameraEvent? decodeEvent(Uint8List data) {
    if (data.isEmpty) return null;
    final kind = EventKind.fromByte(data[0]);
    if (kind == null) return null;
    if (kind == EventKind.sentinel) return const CameraEvent(EventKind.sentinel, null);
    return CameraEvent(kind, _readCamera(_Reader(data, 1)));
  }

  static GoProCamera _readCamera(_Reader r) => GoProCamera(
    vid: r.readUint16(),
    pid: r.readUint16(),
    bus: r.readUint8(),
    address: r.readUint8(),
    sysfsName: r.readString(),
    serial: r.readString(),
    serialSource: _serialSource(r.readUint8()),
    ip: r.readString(),
    netdev: r.readString(),
    netdevFirstSeen: r.readString(),
    netdevRenamed: r.readBool(),
    linkState: r.readString(),
    hostIp: r.readString(),
    readiness: _readiness(r.readUint8()),
    hasCdc: r.readBool(),
    elapsed: Duration(milliseconds: r.readUint32()),
  );

  static SerialSource _serialSource(int v) => v < SerialSource.values.length
      ? SerialSource.values[v]
      : SerialSource.none;

  static Readiness _readiness(int v) =>
      v < Readiness.values.length ? Readiness.values[v] : Readiness.absent;
}

class _Reader {
  _Reader(this._data, this._offset)
    : _view = ByteData.sublistView(_data);

  final Uint8List _data;
  final ByteData _view;
  int _offset;

  int readUint8() => _data[_offset++];

  bool readBool() => _data[_offset++] != 0;

  int readUint16() {
    final v = _view.getUint16(_offset, Endian.little);
    _offset += 2;
    return v;
  }

  int readUint32() {
    final v = _view.getUint32(_offset, Endian.little);
    _offset += 4;
    return v;
  }

  String readString() {
    // uint32, NOT uint64.
    //
    // glaze_meta.h writes a uint32 length prefix -- see
    // encode_field(const std::string&). Other implementations of this same
    // binary encoding use uint64, so if you port a codec in from elsewhere,
    // the prefix width is the thing to check first. Reading uint64 here
    // consumes the first four bytes of string *data* as the high half of the
    // length and yields an absurd value; the bounds check below turns that
    // into a named error instead of an exabyte allocation.
    final len = _view.getUint32(_offset, Endian.little);
    _offset += 4;
    if (len == 0) return '';
    // Guard the length prefix. An out-of-range value means the reader and the
    // native field order have drifted; failing loudly here is far easier to
    // diagnose than an OOM from a bogus allocation.
    if (_offset + len > _data.length) {
      throw StateError(
        'GlazeCodec: string length $len at offset ${_offset - 4} exceeds '
        'payload (${_data.length} bytes). The Dart read order in codec.dart '
        'and glz::meta<gp::CameraRecord> in gopro_types.h have drifted.',
      );
    }
    final s = utf8.decode(
      Uint8List.sublistView(_data, _offset, _offset + len),
      allowMalformed: true,
    );
    _offset += len;
    return s;
  }
}
