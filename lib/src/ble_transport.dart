// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
//
// ble_transport.dart — moves bytes between BlueZ and the native session.
//
// This owns the GATT connection and nothing else. It reports what it can see,
// performs the writes the session asks for, and feeds notifications back in.
// Every decision about what those observations mean, and what to send, lives
// in the native components.

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:bluez_native/bluez_native.dart';

import 'ffi/ble_bindings.dart';
import 'ffi/ble_codec.dart';
import 'ffi/link_types.dart';

/// GoPro Control and Query service.
const _controlQueryService = '0000fea6-0000-1000-8000-00805f9b34fb';

String _gp(String short) => 'b5f9$short-aa8d-11e3-9046-0002a5d5c51b';

/// Write and notify characteristic for each channel.
final Map<BleChannel, ({String write, String notify})> _characteristics = {
  BleChannel.command: (write: _gp('0072'), notify: _gp('0073')),
  BleChannel.settings: (write: _gp('0074'), notify: _gp('0075')),
  BleChannel.query: (write: _gp('0076'), notify: _gp('0077')),
};

/// A camera reachable over BLE.
class GoProBleCamera {
  GoProBleCamera._(this._device, this._session, this._link);

  final BlueZDevice _device;
  final Pointer<Void> _session;
  final Pointer<Void> _link;

  final _writes = <BleChannel, BlueZGattCharacteristic>{};
  final _notifies = <BleChannel, BlueZGattCharacteristic>{};
  final _subs = <StreamSubscription<List<int>>>[];

  final _pushes = StreamController<BlePush>.broadcast();
  final _readyChanges = StreamController<bool>.broadcast();
  final _faults = StreamController<Object>.broadcast();
  final _pending = <int, Completer<BleResponse>>{};

  ReceivePort? _events;
  Timer? _ticker;
  Stopwatch? _clock;
  bool _closed = false;

  /// Messages the camera sent that nobody was waiting for: registered status
  /// and setting updates.
  Stream<BlePush> get pushes => _pushes.stream;

  /// The ready gate opening and closing, derived from the busy and encoding
  /// statuses.
  Stream<bool> get readyChanges => _readyChanges.stream;

  /// Trouble that does not belong to any one command: a GATT write that
  /// failed, a message the reassembler could not frame.
  ///
  /// Kept off [pushes] deliberately. Both of these resolve as an ordinary
  /// timeout for whoever was waiting, so nothing is lost by ignoring this
  /// stream — but the timeout says only that no reply came, and these say
  /// why. Listening is optional; not listening drops them.
  Stream<Object> get faults => _faults.stream;

  bool get ready => !_closed && BleBindings.ready(_session);

  String get address => _device.address;

  int get _now => _clock?.elapsedMilliseconds ?? 0;

  /// Sends a payload and waits for the camera's reply.
  ///
  /// Throws [StateError] if a command with the same correlation id is already
  /// outstanding. Correlation is the channel plus the leading payload byte,
  /// so two different commands on the same characteristic beginning with the
  /// same byte cannot be in flight together: their replies would be
  /// indistinguishable.
  ///
  /// [priority] defaults to [BlePriority.fastpass] on [BleChannel.query] and
  /// [BlePriority.queued] elsewhere. The ready gate is derived from the busy
  /// and encoding statuses, and both start unknown, so gating queries would
  /// leave the only thing that can open the gate waiting behind it. Queries
  /// are also the case the gate is not meant to protect: the camera answers
  /// them while it records.
  Future<BleResponse> send(
    BleChannel channel,
    List<int> payload, {
    BlePriority? priority,
  }) {
    if (_closed) throw StateError('camera is closed');
    if (payload.isEmpty) throw ArgumentError('payload is empty');

    priority ??= channel == BleChannel.query
        ? BlePriority.fastpass
        : BlePriority.queued;

    final id = BleCodec.correlationOf(channel, payload[0]);
    if (_pending.containsKey(id)) {
      throw StateError(
        'a command with correlation 0x${id.toRadixString(16)} is already '
        'outstanding on ${channel.name}',
      );
    }

    final completer = Completer<BleResponse>();
    _pending[id] = completer;

    if (!BleBindings.submit(_session, channel, payload, priority, _now)) {
      _pending.remove(id);
      throw StateError('submission refused for 0x${id.toRadixString(16)}');
    }
    return completer.future;
  }

  /// Asks the camera for the values of `statusIds`.
  Future<BleResponse> queryStatuses(List<int> statusIds) =>
      send(BleChannel.query, [0x13, ...statusIds]);

  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    _ticker?.cancel();
    // Cancels outstanding commands, so every pending future resolves rather
    // than hanging on a reply that can no longer arrive.
    BleBindings.disconnect(_session);

    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    for (final c in _notifies.values) {
      try {
        await c.stopNotify();
      } on BlueZException {
        // The link may already be gone; nothing left to unsubscribe from.
      }
    }

    // The cancellations above were posted to the port, not delivered. Give
    // the event loop a turn to drain them before the handle goes away, then
    // resolve whatever is still outstanding: a caller awaiting send() must
    // never be left holding a future that can no longer complete.
    await Future<void>.delayed(Duration.zero);
    for (final entry in _pending.entries) {
      entry.value.complete(
        BleResponse(entry.key, BleOutcome.canceled, Uint8List(0)),
      );
    }
    _pending.clear();

    BleBindings.destroy(_session);
    BleBindings.linkDestroy(_link);
    _events?.close();
    await _pushes.close();
    await _readyChanges.close();
    await _faults.close();
  }

  void _onEvent(dynamic message) {
    if (message is! Uint8List) return;
    final event = BleCodec.decode(message);
    if (event == null) return;

    switch (event) {
      case BleWriteRequest(:final channel, :final bytes):
        // Without response: the camera answers on the notify characteristic,
        // so waiting for a write acknowledgement adds a round trip that
        // carries no information.
        //
        // A failed write is not propagated to the caller here. The command it
        // belongs to will time out natively, which is the same outcome the
        // caller would see if the camera simply never answered. It goes to
        // [faults] so the cause is visible rather than inferred.
        _writes[channel]?.writeValue(bytes, withResponse: false).catchError((
          Object e,
        ) {
          if (!_faults.isClosed) _faults.add(e);
        });

      case BleResponse(:final correlationId):
        _pending.remove(correlationId)?.complete(event);

      case BleReadyChanged(:final ready):
        if (!_readyChanges.isClosed) _readyChanges.add(ready);

      case BlePush():
        if (!_pushes.isClosed) _pushes.add(event);

      case BleFrameErrorEvent(:final channel, :final error):
        // Framing errors reset the reassembler, so this costs one message
        // rather than desynchronizing the stream. Reported rather than
        // swallowed: a run of them means something is wrong with the link.
        if (!_faults.isClosed) {
          _faults.add(
            StateError('framing error on ${channel.name}: ${error.name}'),
          );
        }
    }
  }
}

/// Brings a camera up over BLE and reports which stage it stalls at.
class GoProBleTransport {
  GoProBleTransport._(this._client);

  final BlueZClient _client;

  static Future<GoProBleTransport> start() async {
    final client = BlueZClient();
    await client.connect();
    return GoProBleTransport._(client);
  }

  Future<void> close() async => _client.close();

  /// The LE object for a camera, or null.
  ///
  /// Requires both a random address type and the Control and Query service.
  /// A camera also presents a BR-EDR object with the same name, and that one
  /// can never carry GATT.
  BlueZDevice? _candidate() {
    for (final d in _client.devices) {
      if (d.addressType != 'random') continue;
      if (!d.uuids.any(
        (u) => u.toString().toLowerCase() == _controlQueryService,
      )) {
        continue;
      }
      return d;
    }
    return null;
  }

  /// A BR-EDR object for the same camera. While such a link is up the camera
  /// stops advertising over LE, so it has to be disconnected rather than
  /// waited out.
  BlueZDevice? _classicLink() {
    for (final d in _client.devices) {
      if (d.addressType == 'public' &&
          d.connected &&
          d.alias.startsWith('GoPro')) {
        return d;
      }
    }
    return null;
  }

  /// Walks the bring-up ladder until the camera is usable or `timeout`
  /// expires.
  ///
  /// On failure the [GoProBleException] names the stage that stalled and
  /// carries the machine's explanation, because "connect failed" and "needs
  /// an LE bond" call for completely different responses.
  Future<GoProBleCamera> connect({
    Duration timeout = const Duration(seconds: 60),
    Duration keepAlive = Duration.zero,
  }) async {
    final link = BleBindings.linkCreate();
    final clock = Stopwatch()..start();

    BlueZDevice? device;
    final writes = <BleChannel, BlueZGattCharacteristic>{};
    final notifies = <BleChannel, BlueZGattCharacteristic>{};
    var notifySucceeded = false;
    LinkAdvice? last;

    try {
      while (clock.elapsed < timeout) {
        device = _candidate();
        final classic = _classicLink();

        final chars = device == null
            ? const <BlueZGattCharacteristic>[]
            : device.gattCharacteristics.toList();
        // Re-scan until all six are found, not just until the first one is.
        // The objects appear on D-Bus a few at a time, so a scan that catches
        // a partial set has to be repeated or the rest are never picked up.
        if (device != null &&
            device.connected &&
            !_complete(writes, notifies)) {
          _locate(chars, writes, notifies);
        }

        final advice = BleBindings.linkUpdate(
          link,
          LinkObservation(
            candidatePresent: device != null,
            classicLinkUp: classic != null,
            connected: device?.connected ?? false,
            bondedFlag: device?.paired ?? false,
            // Count what is exposed. BlueZ has been observed reporting
            // ServicesResolved true while exposing nothing.
            attributeCount: chars.length,
            controlCharsFound: _complete(writes, notifies),
            notifySucceeded: notifySucceeded,
            // Count the characteristics actually notifying. Taking one
            // successful StartNotify as proof of all three would reach ready
            // with two channels deaf, and the camera's replies would simply
            // never arrive.
            subscribedCount: notifies.values.where((c) => c.notifying).length,
            requiredSubscriptions: _characteristics.length,
          ),
          clock.elapsedMilliseconds,
        );
        if (advice == null) {
          throw GoProBleException(
            LinkState.absent,
            StallReason.none,
            'native and Dart link enums have drifted',
          );
        }
        last = advice;

        if (advice.state.isReady) {
          return await _finish(
            device!,
            notifies,
            writes,
            link,
            clock,
            keepAlive,
          );
        }

        await _act(advice, device, classic, link, notifies, clock, (v) {
          notifySucceeded = v;
        });
      }

      throw GoProBleException(
        last?.state ?? LinkState.absent,
        last?.stall ?? StallReason.noAdvertisement,
        last?.detail.isNotEmpty == true
            ? last!.detail
            : 'timed out during bring-up',
      );
    } catch (_) {
      BleBindings.linkDestroy(link);
      rethrow;
    }
  }

  bool _complete(
    Map<BleChannel, BlueZGattCharacteristic> writes,
    Map<BleChannel, BlueZGattCharacteristic> notifies,
  ) =>
      writes.length == _characteristics.length &&
      notifies.length == _characteristics.length;

  void _locate(
    List<BlueZGattCharacteristic> chars,
    Map<BleChannel, BlueZGattCharacteristic> writes,
    Map<BleChannel, BlueZGattCharacteristic> notifies,
  ) {
    for (final entry in _characteristics.entries) {
      for (final c in chars) {
        final uuid = c.uuid.toString().toLowerCase();
        if (uuid == entry.value.write) writes[entry.key] = c;
        if (uuid == entry.value.notify) notifies[entry.key] = c;
      }
    }
  }

  Future<void> _act(
    LinkAdvice advice,
    BlueZDevice? device,
    BlueZDevice? classic,
    Pointer<Void> link,
    Map<BleChannel, BlueZGattCharacteristic> notifies,
    Stopwatch clock,
    void Function(bool) setNotifySucceeded,
  ) async {
    final waitMs = advice.retryAtMs - clock.elapsedMilliseconds;
    if (waitMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: waitMs));
    }

    try {
      switch (advice.action) {
        case LinkAction.scan:
          if (_client.adapters.isEmpty) {
            throw const GoProBleException(
              LinkState.absent,
              StallReason.noAdvertisement,
              'no Bluetooth adapter is present',
            );
          }
          final adapter = _client.adapters.first;
          if (!adapter.powered) await adapter.setPowered(true);
          if (!adapter.discovering) await adapter.startDiscovery();
          await Future<void>.delayed(const Duration(seconds: 2));

        case LinkAction.disconnectClassic:
          await classic?.disconnect();

        case LinkAction.connect:
          await device?.connect();

        case LinkAction.waitForServices:
          await Future<void>.delayed(const Duration(milliseconds: 500));

        case LinkAction.pair:
          // Discovery works unbonded but notifications are refused, so an LE
          // bond is required before any control traffic.
          if (device != null && !device.paired) await device.pair();
          // Proof of encryption is a StartNotify that succeeds, not a flag.
          if (notifies.isNotEmpty) {
            await notifies.values.first.startNotify();
            setNotifySucceeded(true);
          }

        case LinkAction.subscribe:
          for (final c in notifies.values) {
            if (!c.notifying) await c.startNotify();
          }

        case LinkAction.none:
          await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    } on BlueZException {
      BleBindings.linkNoteFailure(link, clock.elapsedMilliseconds);
    }
  }

  Future<GoProBleCamera> _finish(
    BlueZDevice device,
    Map<BleChannel, BlueZGattCharacteristic> notifies,
    Map<BleChannel, BlueZGattCharacteristic> writes,
    Pointer<Void> link,
    Stopwatch clock,
    Duration keepAlive,
  ) async {
    // The negotiated MTU less three bytes of ATT overhead. A MAX2 reports
    // 517, which is 25 times the floor the default assumes. Read before the
    // session exists so nothing between here and the constructor can throw
    // and strand a handle nobody holds a reference to.
    final mtu = notifies.values
        .map((c) => c.mtu)
        .fold<int>(0, (a, b) => a == 0 || b < a ? b : a);

    final events = ReceivePort();
    final session = BleBindings.create(
      events.sendPort.nativePort,
      keepAlive: keepAlive,
    );

    final camera = GoProBleCamera._(device, session, link)
      .._events = events
      .._clock = clock;
    camera._writes.addAll(writes);
    camera._notifies.addAll(notifies);
    events.listen(camera._onEvent);

    if (mtu > 3) BleBindings.setAttPayload(session, mtu - 3);

    for (final entry in notifies.entries) {
      camera._subs.add(
        entry.value.value.listen((bytes) {
          BleBindings.feed(session, entry.key, bytes, camera._now);
        }),
      );
    }

    // Dart drives the clock. A native timer would gain nothing: every write
    // has to be performed from this isolate anyway.
    camera._ticker = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => BleBindings.tick(session, camera._now),
    );

    return camera;
  }
}

/// Bring-up stopped before the camera became usable.
class GoProBleException implements Exception {
  const GoProBleException(this.state, this.reason, this.detail);

  /// The stage reached. `servicesResolved` means discovery worked but
  /// notifications were refused; `connected` means attributes never appeared.
  final LinkState state;
  final StallReason reason;

  /// What to do about it.
  final String detail;

  @override
  String toString() =>
      'GoProBleException(stalled at ${state.name}: ${reason.name})\n$detail';
}
