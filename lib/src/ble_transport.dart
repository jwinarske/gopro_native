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

/// What bring-up produced: the device and its six control characteristics.
typedef _Attached = ({
  BlueZDevice device,
  Map<BleChannel, BlueZGattCharacteristic> writes,
  Map<BleChannel, BlueZGattCharacteristic> notifies,
});

/// Whether the camera can be talked to.
///
/// Separate from the bring-up ladder in [LinkState], which describes how far
/// a single attempt has climbed. This is what a caller has to branch on.
enum CameraLink {
  /// Usable.
  up,

  /// The link dropped and bring-up is running again. [GoProBleCamera.send]
  /// throws while in this state rather than queueing against a camera that
  /// is not there.
  reconnecting,

  /// Given up. Either [GoProBleCamera.close] was called, or reconnection ran
  /// out of time. Terminal.
  down,
}

/// A camera reachable over BLE.
class GoProBleCamera {
  GoProBleCamera._(this._transport, this._device, this._session, this._link);

  final GoProBleTransport _transport;
  BlueZDevice _device;
  final Pointer<Void> _session;

  /// The bring-up state machine. Kept across reconnects rather than recreated
  /// so its backoff is one accumulated judgement, not a fresh guess per
  /// attempt.
  final Pointer<Void> _link;

  final _writes = <BleChannel, BlueZGattCharacteristic>{};
  final _notifies = <BleChannel, BlueZGattCharacteristic>{};
  final _subs = <StreamSubscription<void>>[];
  final _watch = <StreamSubscription<void>>[];

  final _pushes = StreamController<BlePush>.broadcast();
  final _readyChanges = StreamController<bool>.broadcast();
  final _faults = StreamController<Object>.broadcast();
  final _linkChanges = StreamController<CameraLink>.broadcast();
  final _pending = <int, Completer<BleResponse>>{};

  ReceivePort? _events;
  Timer? _ticker;
  Stopwatch? _clock;
  Duration _reconnectTimeout = Duration.zero;
  CameraLink _state = CameraLink.up;

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

  /// The connection coming and going.
  ///
  /// Worth listening to even when reconnection is automatic: registered
  /// status and setting subscriptions do not survive a camera-side
  /// disconnect, so a return to [CameraLink.up] is the caller's cue to send
  /// them again. Nothing else re-sends them.
  Stream<CameraLink> get linkChanges => _linkChanges.stream;

  CameraLink get link => _state;

  bool get ready => _state == CameraLink.up && BleBindings.ready(_session);

  String get address => _device.address;

  int get _now => _clock?.elapsedMilliseconds ?? 0;

  /// Sends a payload and waits for the camera's reply.
  ///
  /// Throws [StateError] if the link is not [CameraLink.up], or if a command
  /// with the same correlation id is already outstanding. Correlation is the
  /// channel plus the leading payload byte, so two different commands on the
  /// same characteristic beginning with the same byte cannot be in flight
  /// together: their replies would be indistinguishable.
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
    if (_state != CameraLink.up) {
      throw StateError('camera link is ${_state.name}');
    }
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

  /// Sends a protobuf command and waits for its reply.
  ///
  /// [message] is the encoded protobuf; the `[feature][action]` header is
  /// prepended natively. The reply's payload includes that header, so a
  /// caller decoding it must skip the first two bytes.
  ///
  /// Correlated on both header bytes rather than the leading one. Every
  /// request within a feature shares its feature id, so correlating on that
  /// alone would make them a single command — and would hand a registered
  /// notification to whichever request happened to be outstanding.
  ///
  /// Throws [StateError] if one with the same feature and action is already
  /// outstanding, or if the link is not up.
  Future<BleResponse> sendProtobuf(
    int featureId,
    int actionId,
    List<int> message, {
    BleChannel channel = BleChannel.command,
    BlePriority priority = BlePriority.queued,
  }) {
    if (_state != CameraLink.up) {
      throw StateError('camera link is ${_state.name}');
    }

    final id = BleBindings.protobufCorrelation(channel, featureId, actionId);
    if (_pending.containsKey(id)) {
      throw StateError(
        'a protobuf command for feature 0x${featureId.toRadixString(16)} '
        'action $actionId is already outstanding',
      );
    }

    final completer = Completer<BleResponse>();
    _pending[id] = completer;

    if (!BleBindings.submitProtobuf(
      _session,
      channel,
      featureId,
      actionId,
      message,
      priority,
      _now,
    )) {
      _pending.remove(id);
      throw StateError(
        'submission refused for feature 0x${featureId.toRadixString(16)} '
        'action $actionId',
      );
    }
    return completer.future;
  }

  Future<void> close() async {
    if (_state == CameraLink.down) return;
    _setState(CameraLink.down);

    _ticker?.cancel();
    for (final w in _watch) {
      await w.cancel();
    }
    _watch.clear();

    // Cancels outstanding commands, so every pending future resolves rather
    // than hanging on a reply that can no longer arrive.
    BleBindings.disconnect(_session);
    await _detach(stopNotify: true);

    // The cancellations above were posted to the port, not delivered. Give
    // the event loop a turn to drain them before the handle goes away, then
    // resolve whatever is still outstanding: a caller awaiting send() must
    // never be left holding a future that can no longer complete.
    await Future<void>.delayed(Duration.zero);
    _resolvePending();

    BleBindings.destroy(_session);
    BleBindings.linkDestroy(_link);
    _events?.close();
    await _pushes.close();
    await _readyChanges.close();
    await _faults.close();
    await _linkChanges.close();
  }

  void _setState(CameraLink next) {
    if (_state == next) return;
    _state = next;
    if (!_linkChanges.isClosed) _linkChanges.add(next);
  }

  /// Completes anything the native side did not, so no caller is left holding
  /// a future that can never resolve.
  void _resolvePending() {
    for (final entry in _pending.entries) {
      entry.value.complete(
        BleResponse(entry.key, BleOutcome.canceled, Uint8List(0)),
      );
    }
    _pending.clear();
  }

  /// Binds to a freshly brought-up link.
  Future<void> _attach(_Attached a) async {
    _device = a.device;
    _writes
      ..clear()
      ..addAll(a.writes);
    _notifies
      ..clear()
      ..addAll(a.notifies);

    // The negotiated MTU less three bytes of ATT overhead. A MAX2 reports
    // 517, which is 25 times the floor the default assumes. Re-read on every
    // attach: a reconnect renegotiates, and carrying the old value forward
    // would fragment against an MTU that no longer exists.
    final mtu = _notifies.values
        .map((c) => c.mtu)
        .fold<int>(0, (a, b) => a == 0 || b < a ? b : a);
    if (mtu > 3) BleBindings.setAttPayload(_session, mtu - 3);

    for (final entry in _notifies.entries) {
      _subs.add(
        entry.value.value.listen((bytes) {
          BleBindings.feed(_session, entry.key, bytes, _now);
        }),
      );
    }

    // Three ways to notice the link going away, because none of them is
    // sufficient alone. The property change is the fast path; the device
    // being removed from D-Bus closes that stream without a final event; and
    // the poll catches whatever both miss. Missing a drop is expensive --
    // every subsequent command times out with nothing saying why.
    _watch.add(
      a.device.propertiesChanged.listen((changed) {
        if (changed.contains('Connected') && !a.device.connected) {
          unawaited(_onDrop('BlueZ reported the device disconnected'));
        }
      }),
    );
    _watch.add(
      _transport._client.deviceRemoved.listen((d) {
        if (d.objectPath == a.device.objectPath) {
          unawaited(_onDrop('the device object was removed from BlueZ'));
        }
      }),
    );
  }

  /// Releases everything tied to the current link, keeping the session and
  /// the caller's streams alive.
  Future<void> _detach({required bool stopNotify}) async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();

    if (stopNotify) {
      for (final c in _notifies.values) {
        try {
          await c.stopNotify();
        } on BlueZException {
          // The link may already be gone; nothing left to unsubscribe from.
        }
      }
    }
    _writes.clear();
    _notifies.clear();
  }

  Future<void> _onDrop(String why) async {
    if (_state != CameraLink.up) return;

    if (_reconnectTimeout == Duration.zero) {
      _faults.add(StateError('link lost: $why'));
      await close();
      return;
    }

    _setState(CameraLink.reconnecting);
    _faults.add(StateError('link lost: $why; reconnecting'));

    // Resets the reassemblers and the ready gate as well as cancelling
    // in-flight work. Partial messages from before the drop must not be
    // reassembled against whatever arrives after it.
    BleBindings.disconnect(_session);

    // StopNotify would go to a device that is gone, and BlueZ tears the
    // session down on disconnect anyway.
    await _detach(stopNotify: false);
    _resolvePending();

    try {
      final a = await _transport._bringUp(
        link: _link,
        timeout: _reconnectTimeout,
      );
      await _attach(a);
      _setState(CameraLink.up);
    } on Object catch (e) {
      _faults.add(e);
      await close();
    }
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
  ///
  /// A link that drops afterwards is re-established automatically, within
  /// [reconnectTimeout] per attempt; the camera reports it on
  /// [GoProBleCamera.linkChanges]. Zero disables that, and a drop then closes
  /// the camera instead.
  Future<GoProBleCamera> connect({
    Duration timeout = const Duration(seconds: 60),
    Duration keepAlive = Duration.zero,
    Duration reconnectTimeout = const Duration(minutes: 5),
  }) async {
    final link = BleBindings.linkCreate();
    final clock = Stopwatch()..start();

    final _Attached attached;
    try {
      attached = await _bringUp(link: link, timeout: timeout);
    } catch (_) {
      BleBindings.linkDestroy(link);
      rethrow;
    }

    final events = ReceivePort();
    final session = BleBindings.create(
      events.sendPort.nativePort,
      keepAlive: keepAlive,
    );

    final camera = GoProBleCamera._(this, attached.device, session, link)
      .._events = events
      .._clock = clock
      .._reconnectTimeout = reconnectTimeout;
    events.listen(camera._onEvent);
    await camera._attach(attached);

    // Dart drives the clock. A native timer would gain nothing: every write
    // has to be performed from this isolate anyway. The same tick doubles as
    // the backstop that notices a link D-Bus did not tell us about.
    camera._ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      BleBindings.tick(session, camera._now);
      if (camera._state == CameraLink.up && !camera._device.connected) {
        unawaited(camera._onDrop('the device is no longer connected'));
      }
    });

    return camera;
  }

  /// One climb up the ladder, from wherever the camera currently is.
  ///
  /// Used for the first connection and for every reconnect after it, with the
  /// same [link] handle both times so backoff and attempt counts carry over.
  Future<_Attached> _bringUp({
    required Pointer<Void> link,
    required Duration timeout,
  }) async {
    final clock = Stopwatch()..start();

    BlueZDevice? device;
    final writes = <BleChannel, BlueZGattCharacteristic>{};
    final notifies = <BleChannel, BlueZGattCharacteristic>{};

    // Channels this climb has successfully subscribed, tracked here rather
    // than read back from BlueZ's Notifying property.
    //
    // That property survives a disconnect as stale true. Believing it makes
    // a reconnect skip StartNotify on channels that are no longer listening,
    // and the camera's replies then go nowhere -- the write succeeds, no
    // error is raised, and the command times out as though the camera had
    // ignored it. Count what this climb actually did.
    final subscribed = <BleChannel>{};
    LinkAdvice? last;

    while (clock.elapsed < timeout) {
      device = _candidate();
      final classic = _classicLink();

      final chars = device == null
          ? const <BlueZGattCharacteristic>[]
          : device.gattCharacteristics.toList();
      // Re-scan until all six are found, not just until the first one is.
      // The objects appear on D-Bus a few at a time, so a scan that catches
      // a partial set has to be repeated or the rest are never picked up.
      if (device != null && device.connected && !_complete(writes, notifies)) {
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
          // Encryption is proven by a StartNotify that worked, so the first
          // subscription is also the evidence for it.
          notifySucceeded: subscribed.isNotEmpty,
          // Every channel, not just the first. Taking one successful
          // StartNotify as proof of all three reaches ready with two
          // channels deaf.
          subscribedCount: subscribed.length,
          requiredSubscriptions: _characteristics.length,
        ),
        clock.elapsedMilliseconds,
      );
      if (advice == null) {
        throw const GoProBleException(
          LinkState.absent,
          StallReason.none,
          'native and Dart link enums have drifted',
        );
      }
      last = advice;

      if (advice.state.isReady) {
        return (device: device!, writes: writes, notifies: notifies);
      }

      await _act(advice, device, classic, link, notifies, subscribed, clock);
    }

    throw GoProBleException(
      last?.state ?? LinkState.absent,
      last?.stall ?? StallReason.noAdvertisement,
      last?.detail.isNotEmpty == true
          ? last!.detail
          : 'timed out during bring-up',
    );
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

  /// Subscribes channels not yet subscribed on this climb, recording only
  /// those whose `StartNotify` actually returned.
  ///
  /// `only` caps how many to attempt, which is what the pair stage wants: one
  /// success is all the evidence encryption needs, and the rest belong to the
  /// subscribe stage where a failure is diagnosed differently.
  Future<void> _subscribe(
    Map<BleChannel, BlueZGattCharacteristic> notifies,
    Set<BleChannel> subscribed, {
    int? only,
  }) async {
    var attempted = 0;
    for (final entry in notifies.entries) {
      if (subscribed.contains(entry.key)) continue;
      if (only != null && attempted >= only) return;
      attempted++;

      // Notifying survives a disconnect as stale true, and BlueZ treats
      // StartNotify on a characteristic it already considers notifying as a
      // no-op -- it returns success without writing the CCCD. The camera
      // cleared its side on disconnect, so the descriptor really does need
      // writing, and the subscription silently never happens.
      //
      // Measured on a MAX2 reconnect: writes went out and were acknowledged,
      // and not one reply came back on the affected channel.
      //
      // Reaching this line means the climb has not subscribed this channel,
      // so a true flag can only be left over. Clear it to force a real CCCD
      // write.
      if (entry.value.notifying) {
        try {
          await entry.value.stopNotify();
        } on BlueZException {
          // Best effort. If it will not stop, StartNotify below decides.
        }
      }

      await entry.value.startNotify();
      subscribed.add(entry.key);
    }
  }

  Future<void> _act(
    LinkAdvice advice,
    BlueZDevice? device,
    BlueZDevice? classic,
    Pointer<Void> link,
    Map<BleChannel, BlueZGattCharacteristic> notifies,
    Set<BleChannel> subscribed,
    Stopwatch clock,
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
          await _subscribe(notifies, subscribed, only: 1);

        case LinkAction.subscribe:
          await _subscribe(notifies, subscribed);

        case LinkAction.none:
          await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    } on BlueZException {
      BleBindings.linkNoteFailure(link, clock.elapsedMilliseconds);
    }
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
