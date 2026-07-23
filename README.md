# gopro_native

Linux-first GoPro camera discovery over USB for Dart and Flutter, built on
libusb with zero-copy FFI event delivery.

```dart
final discovery = await GoProDiscovery.start();
await for (final cam in discovery.ready) {
  print('${cam.serial} reachable at ${cam.baseUri}');
}
```

```
= ready: GoProCamera(2672:0059 2-1 serial=C3501234567123 ip=172.21.123.51
                     netdev=enp17s0u1 host=172.21.123.52 state=l3Ready)
  GET http://172.21.123.51:8080/gopro/version -> 200 {"version" : "2.0"}
```

No mDNS. The control-plane address is derived from the USB serial descriptor,
so there is no Zeroconf dependency and no first-responder-wins spoofing
surface on the wired path.

## Architecture

| Layer | |
|---|---|
| `native/src/gopro_usb.cpp` | libusb enumerate-only discovery + readiness staging |
| `native/src/gopro_bridge.cpp` | C ABI, worker thread, event posting |
| `hook/build.dart` | drives CMake, emits the `.so` as a `CodeAsset` |
| `lib/src/ffi/codec.dart` | binary payload decode |
| `lib/src/discovery.dart` | `Stream<GoProCamera>` public API |
| `native/src/ble_session.cpp` | BLE framing, correlation, ready gate |
| `native/src/ble_link.cpp` | BLE bring-up state machine |
| `lib/src/ble_transport.dart` | GATT over D-Bus, the only BlueZ-facing code |
| `lib/src/http/gopro_http.dart` | HTTP transport, streaming downloads |
| `lib/src/http/commands.dart` | 40 typed commands over the generated table |
| `lib/proto/*.dart` | protobuf, split per feature so descriptors tree shake |
| `lib/src/cohn/` | COHN provisioning, credential storage, pinned TLS |

Events are posted from a native worker thread via `Dart_PostCObject_DL`,
which is thread-safe and callable from any thread. Dart never pumps anything.
Reaching L3 readiness takes ~750 ms, so driving that from the Dart event loop
would couple discovery latency to whatever else the isolate is doing — an
event arriving mid-frame-render would wait for the render, and a GC pause
would stall discovery outright.

The ABI is restricted by a linker version script to five `gopro_*` entry
points plus the Dart API trampolines; `nm -D` shows nothing else.

## Two invariants worth knowing

**Never claim the interface.** The camera enumerates as CDC-NCM;
`libusb_claim_interface()` would detach `cdc_ncm` and destroy the netdev the
HTTP API rides on. `cmake/check_no_claim.cmake` fails the build if anyone
reaches for it, and is negative-tested.

**A camera is not usable when USB enumeration completes.** Measured on a MAX2
cold plug: netdev bound at +46 ms, camera answering at +754 ms. Only
`Readiness.l3Ready` means "you can talk to it" — `discovery.ready` fires
there, `discovery.updates` reports every intermediate stage.

## Build and run

```sh
dart pub get
dart test                       # hook builds the .so automatically
dart run example/discover.dart
```

Needs `libusb-1.0` dev headers, CMake ≥ 3.22, and a C++23 compiler. To build
the native library by hand:

```sh
cmake -S native -B build && cmake --build build
GOPRO_NC_LIB=$PWD/build/libgopro_nc.so dart run example/discover.dart
```

Install `udev/99-gopro.rules` to pin the interface name to `gopro0` and grant
`uaccess`. See the DEBUG NOTES below for why the naming rule matters.

## DEBUG NOTE — netdev rename race

The kernel registers a USB network interface under a temporary name and udev
renames it milliseconds later:

```
cdc_ncm 2-1:1.0 eth0: register 'cdc_ncm' at usb-0000:11:00.0-1, CDC NCM (NO ZLP)
cdc_ncm 2-1:1.0 enp17s0u1: renamed from eth0
```

A name sampled at hotplug time lands in that window often enough to matter —
observed on every MAX2 replug tested. **Do not persist `GoProCamera.netdev`
across events.**

`GoProCamera.netdevRenamed` is set when the library witnesses the transition,
and `netdevFirstSeen` preserves the transient name. If a bug report shows
`netdevRenamed: true`, a stale cached interface name is the likely cause.
Cross-check with `journalctl -k | grep 'renamed from'`.

Installing the udev rule removes the race entirely.

## DEBUG NOTE — wire format prefix is uint32, not uint64

`glaze_meta.h` writes a **uint32** length/count prefix for strings, vectors
and maps (see `encode_field(const std::string&)`). Other implementations of
this same binary encoding use **uint64**, so the width is the first thing to
check when porting a codec in or out.

Getting it wrong costs an afternoon: reading a uint64 prefix consumes the
first four bytes of string *data* as the high half of the length and yields an
absurd value — in testing, a length of 1022648283161427971 from a 106-byte
payload. `test/codec_test.dart` freezes hand-encoded vectors so the width
cannot regress, and `_Reader.readString` bounds-checks the prefix and reports
drift by name rather than attempting the allocation.

Field order in `glz::meta<gp::CameraRecord>` (`native/include/gopro_types.h`)
and the read order in `codec.dart` must stay in lockstep. Drift is silent
corruption, not a crash.

## DEBUG NOTE — serial provenance flips on hotplug

`GoProCamera.serialSource` reports `descriptor` or `sysfs`. The obvious
reading — "sysfs means the udev rule is missing" — is true at steady state
and **wrong on the hotplug path**: logind applies the uaccess ACL
asynchronously, so `libusb_open()` routinely loses that race even on a
correctly configured desktop. Every MAX2 replug tested read `sysfs` on
arrival and `descriptor` once settled.

The sysfs fallback is load-bearing, not a convenience. Without it a replug
yields no serial, hence no derived IP, hence total failure.

## BLE framing

`native/{include,src}/ble_protocol.*` implements GoPro's BLE packet framing —
fragmentation on transmit, reassembly on receive. It is pure logic with no
libusb, no BlueZ and no Dart, so it is testable without hardware:

```
cmake -S native -B build && cmake --build build && ctest --test-dir build
```

45 checks, including round-trip over every length from 1 to 600 bytes at eight
MTUs, both sides of the EXT_13 → EXT_16 header-width switch, and 2000 random
(length, MTU) pairs. Fragmentation bugs do not announce themselves — short
messages keep working while long ones truncate or splice — so the round-trip
property is checked exhaustively rather than by example.

Reassembly lives in C++ rather than Dart for a measured reason. A
multi-kilobyte preset response is **158 fragments at the BLE 4.0 minimum MTU
and 6 at 512** (the test prints this). Forwarding each fragment across the FFI
boundary would cost a Dart VM wake-up, an allocation and a GC finalizer per
fragment to deliver one logical message; reassembling natively collapses that
to a single post.

Two deliberate departures from the reference implementation:

- **The MTU is a parameter, not the constant 20.** The reference hardcodes the
  4.0 floor. Reading the negotiated value is a ~26× reduction in fragment
  count on large responses.
- **Over-long payloads are a hard error.** The reference logs *"received too
  much data. parsing is in unknown state"* and continues with a negative
  counter. A length that disagrees with the bytes on the wire means the stream
  is desynchronized, so continuing corrupts the next message too. Every error
  path leaves the reassembler reset, costing one message rather than
  permanently desynchronizing.

The partial-message-on-disconnect leak flagged during review is structurally
absent here: the partial lives in a member `std::vector`, so teardown is
automatic rather than something a cleanup path must remember.

## Command queue and the keep-alive gate

`native/{include,src}/command_queue.*` serializes the BLE control plane behind
the camera's busy/encoding readiness. Like the framing it is pure logic —
no threads, no clock, no I/O; time and transmission are injected — so every
ordering property is deterministic to test. 29 checks.

Priority is first-class rather than an afterthought, because of a specific
bug:

| | |
|---|---|
| `kQueued` | waits for the ready gate, serializes against other `kQueued`. The default. |
| `kFastpass` | ignores the ready gate. For commands the camera accepts while busy — above all "stop shutter", which must not wait for the encoding it is trying to stop. |
| `kKeepAlive` | ignores the gate *and* the serialization, and jumps the queue. |

**The bug.** BLE keep-alive is a write of 66 to the LED setting every 3 s;
without it the camera drops the connection after about ten. In the reference
implementation keep-alive is an ordinary setting write, so it acquires the
same global lock as everything else — meaning it is blocked for exactly as
long as the camera is busy or encoding. It starves precisely when the session
is doing something interesting, and the connection dies mid-capture. The
`keep-alive starvation` test pins the fix directly.

Two further guarantees worth knowing:

- **One command per correlation id at a time.** Responses carry no sequence
  number, so two in-flight commands sharing an id cannot be told apart and the
  first reply would resolve the wrong caller. Duplicates are refused at submit
  rather than transmitted.
- **A timeout frees the serialization slot.** Otherwise a single lost response
  wedges the queue permanently.

An unmatched response is reported as unhandled rather than dropped, so the
transport can route it to listeners — that is what a registered status or
setting push looks like.

## BLE link state machine

`native/{include,src}/ble_link.*` tracks connection bring-up. "Connected" is
not "usable", and every stage below can stall in a way that presents
identically as *"it just doesn't work"*:

```
kAbsent → kAdvertising → kConnected → kServicesResolved → kEncrypted → kReady
```

Each stall carries a distinct `StallReason` and a human-facing explanation,
because the fixes are completely different — "the camera is asleep" versus
"put it in pairing mode" versus "a Classic link is blocking LE". 39 checks,
pure logic, no D-Bus.

Every rule was paid for during MAX2 bring-up:

- **A camera presents two device objects.** BR-EDR (public address; Headset,
  Handsfree, PnP) and LE (random address; `fea6`). They share a name, so
  selecting by name gets the wrong transport — and the Classic one can never
  carry GATT.
- **The Classic link suppresses LE advertising.** While it is up the camera
  does not advertise, so retrying harder never helps. Classic is treated as
  something to disconnect, not a fallback.
- **BlueZ reported `Connected=true` and `ServicesResolved=true` while exposing
  zero GATT objects**, for 30 seconds. Resolution is judged by counting
  attributes; the property is not trusted.
- **`Bonded=true` does not imply the LE link is encrypted.** A BR-EDR bond
  sets that flag while doing nothing for GATT. Encryption is proven only by a
  `StartNotify` that succeeds, and the stall message calls the flag out by
  name because it is exactly what sends you down the wrong path.
- **Unbonded LE discovery works fine.** Full service enumeration and Device
  Information reads succeed; `StartNotify` then fails `Not paired` and writes
  fail with an ATT error. Discovery succeeding says nothing about whether
  control will work.

Backoff is exponential and capped, and any forward progress resets it — a
reconnect after a working session should not inherit the penalty accumulated
before it succeeded.

## BLE transport

`lib/src/ble_transport.dart` is the only part of the BLE stack that talks to
D-Bus. It owns the GATT connection and nothing else: it reports what it can
see, performs the writes the session asks for, and feeds notifications back
in. What those observations mean, and what to send, stays native.

```dart
final transport = await GoProBleTransport.start();
final camera = await transport.connect();

final busy = await camera.queryStatuses([8, 10]);
camera.readyChanges.listen((open) => print('ready gate ${open ? 'open' : 'shut'}'));
camera.pushes.listen(print);
camera.faults.listen(print);   // optional; why a command went unanswered
```

`connect()` walks the ladder above, and a failure throws a
`GoProBleException` naming the stage it stalled at with the machine's
explanation — "the camera is asleep" and "the LE link is not encrypted"
require completely different responses.

A link that drops afterwards is re-established automatically — the same
`LinkMachine` handle climbs the ladder again, so backoff and attempt counts
carry over rather than restarting from a fresh guess. `linkChanges` reports
`up` / `reconnecting` / `down`, and `send()` throws while reconnecting rather
than queueing against a camera that is not there. Registered status and
setting subscriptions do **not** survive a camera-side disconnect; a return
to `up` is the caller's cue to send them again, because nothing else will.

Measured on a MAX2: drop noticed 2.7 s after `bluetoothctl disconnect`, back
to `up` ~700 ms later, next query answered 15 ms after that.

Three rules the transport has to observe, each of which cost a debugging
session:

- **Count what you subscribed, not what BlueZ says is notifying.** Taking one
  successful `StartNotify` as proof of all three reaches ready with two
  channels deaf, and every reply then goes missing with no error anywhere.
- **`Notifying` survives a disconnect as stale `true`, and `StartNotify` on a
  characteristic BlueZ already considers notifying is a no-op** — it returns
  success without writing the CCCD. The camera cleared its side, so the
  descriptor really does need writing. On reconnect the writes went out and
  were acknowledged, and not one reply came back. `StopNotify` first, then
  `StartNotify`, to force a real descriptor write.
- **Queries are not gated.** The ready gate comes from the busy and encoding
  statuses, both of which start unknown, so gating queries leaves the only
  thing that can open the gate waiting behind it. `send()` therefore defaults
  to fastpass on the query channel. The camera answers queries while it
  records, which is the same reason stated from the camera's side.

## HTTP command surface

40 messages over USB or Wi-Fi, one typed method each.

```dart
final camera = GoProCommands(GoProHttp(discovered.baseUri!));

await camera.setShutter(Toggle.enable);
final state = await camera.getCameraState();
await camera.downloadFile('100GOPRO/GX010001.MP4', File('clip.mp4'),
    onProgress: (received, total) => print('$received / $total'));
```

Upstream declares each message as a decorator on an empty method body and
builds the machinery by introspecting `**kwargs` at import time. Dart AOT has
no runtime reflection, so the data comes across as a generated const table
(`tool/gen_http_commands.py` → `lib/src/generated/http_commands.dart`) that
one dispatcher reads.

The argument *mapping* stays hand-written. Fifteen of the forty upstream
methods rewrite their arguments before dispatch, from renaming a parameter —
`delete_group` takes a `path` and sends `p` — to spreading a `datetime`
across four query arguments. Generating those would mean interpreting
arbitrary Python; writing them puts the transform where it happens.

**Timeouts are not one policy.** Upstream hardcodes 5 seconds and applies it
to media downloads as well, which works there only because `requests` reads
it as a per-read timeout. A 5-second deadline on the whole request fails
every video transfer. So JSON exchanges get `requestTimeout` (5 s, whole
request) and downloads get `stallTimeout` (30 s since the last byte). A 4 GB
file may take as long as it takes; a stream that has delivered nothing for
30 seconds is stuck regardless of how large the file is.

Downloads stream straight to disk — upstream runs synchronous `requests`
inside an `async def`, blocking its event loop for the whole transfer. A
failed or stalled download deletes its partial file, because a truncated
video left on disk looks like a finished one to whatever finds it next.

`set_shutter` is the one message whose fastpass status depends on its
argument: stopping must not wait for the encoding it is trying to stop, while
starting has no reason to jump the queue. The generator refuses to flatten
that to a constant and records it as `HttpFastpass.conditional`; both
constants would be wrong half the time.

**A slash in a query argument must not be escaped.** Every media command
passes a path that way, and the camera rejects the escaped form:

```
path=100GOPRO%2FGX010087.MP4    400 Bad Request, empty body
path=100GOPRO/GX010087.MP4      200
```

RFC 3986 permits `/` in a query component; Dart's `Uri.queryParameters`
escapes it anyway, so the URL cannot be built that way. Getting this wrong
breaks every media command at once and the camera's 400 says nothing about
why.

## Protobuf layer

COHN, livestreaming, network management, preset status and camera control all
speak protobuf. The 11 `.proto` sources are vendored under
`tool/upstream/proto/` and generated by `tool/gen_proto.py`.

Output is split into per-feature libraries, because the `.pbjson.dart`
descriptors are reflective data and do not tree shake — an application doing
capture control should not ship the livestream and network-management tables:

```dart
import 'package:gopro_native/proto/control.dart';     // naming, control status, capabilities
import 'package:gopro_native/proto/cohn.dart';        // Camera On the Home Network
import 'package:gopro_native/proto/livestream.dart';
import 'package:gopro_native/proto/media.dart';       // high-res transfer, turbo
import 'package:gopro_native/proto/network.dart';     // access points, scanning
import 'package:gopro_native/proto/presets.dart';
```

`response_generic` is re-exported from every one of them: `EnumResultGeneric`
appears in most replies, and making callers import a second library for a type
their own reply contains would be a poor trade for the descriptors it saves.
Every `.proto` must be assigned to a group in the generator; one that is not
is an error rather than a file that quietly never gets exported.

### Sending one over BLE

A protobuf message is framed `[feature id][action id][encoded message]`, and
the reply carries the same header with the action id's high bit set — 111
becomes 239, 103 becomes 231.

```dart
final reply = await camera.sendProtobuf(
  FeatureId.query.value,              // 0xF5
  ActionId.getPresetStatus.value,     // 114, reply 242
  request.writeToBuffer(),
  channel: BleChannel.query,
);
final status = NotifyPresetStatus.fromBuffer(reply.payload.sublist(2));
```

**Correlation is two bytes wide for protobuf.** Every request within a
feature shares its leading byte, so correlating on that alone would make all
of COHN one command — they would serialize against each other for no reason,
and a registered notification arriving on that feature would resolve whatever
unrelated request happened to be outstanding. `sendProtobuf` correlates on
feature *and* action; the two id spaces are kept disjoint by a bit that no
one-byte id carries, checked exhaustively in `test/protobuf_correlation_test.dart`.

The channel matters and is not implied by the feature: query-feature messages
ride the query characteristic pair. Sent on the command pair, a MAX2 answers
nothing and emits a bare `f5 02` push instead.

**`required` is not enforced on serialization.** These are `proto2`, and the
Dart runtime does not check required fields when writing:

```dart
RequestSetCameraControlStatus().writeToBuffer()   // []  — not an error
```

An incomplete message is sent as zero bytes and shows up as the camera
ignoring a command. `isInitialized()` reports it and `check()` names the
missing field; anything putting a message on the wire has to call one of them.

## COHN

Camera On the Home Network: the camera reachable over an existing network
rather than its own access point. Provisioning is protobuf over BLE; using it
afterwards is HTTPS with Basic auth.

```dart
final cohn = CohnClient(camera);
final state = await cohn.status();          // NotifyCOHNStatus

final creds = await cohn.provision();       // camera must already be on Wi-Fi
await FileCredentialStore().write(serial, creds);

final gopro = GoProCommands(CohnHttp(creds));
```

**Credentials do not go in the working directory.** The reference writes the
username, password and certificate to `cohn_db.json` wherever the program
happened to start, pretty-printed and world-readable. `FileCredentialStore`
writes a `0600` file in a `0700` directory under `$XDG_STATE_HOME`, and
checks the mode on read — a file that has become group-readable since it was
written is refused rather than quietly used. The camera serial names the file
and is sanitized first, because it is input.

`CohnCredentials.toString` omits the password and the certificate. Those
reach logs and crash reports, and the Basic token is the password with one
reversible transformation applied. The `Authorization` header is held
privately by the HTTP client and never appears in an exception.

**Pinning, not disabling.** COHN presents a self-signed certificate, which
`HttpClient` rejects. The fix people reach for first is:

```dart
badCertificateCallback: (cert, host, port) => true   // do not do this
```

That does not accept the camera's certificate — it accepts every certificate
from anything answering on that address, which on a home network is precisely
what the certificate exists to prevent. The certificate goes into the trust
store instead, with `withTrustedRoots: false` so nothing else is trusted for
that client.

`bypassEulaCheck` is surfaced rather than hardcoded to true as the reference
does, and defaults to false: silently accepting an agreement on someone's
behalf is not a library's call. It is also not a field in the vendored
definitions for this API version, so asking for it raises rather than being
quietly dropped.

## Status

Validated end to end against a GoPro MAX2 (`2672:0059`): enumeration,
hotplug arrival and departure, readiness staging, the rename diagnostic,
event delivery into Dart, and an HTTP round-trip to the camera.

The BLE control plane is validated against the same camera: bring-up through
to ready, subscription to all three notify characteristics, fragmentation and
reassembly at the negotiated 517-byte MTU, correlation and response routing,
the ready gate deriving from a status query, teardown, and recovery from a
forced disconnect across repeated cycles.

The HTTP command surface is validated over USB against a HERO13 Black
(firmware `H24.01.02.10.00`): camera info, state (79 statuses, 120
settings), date and time, media list and metadata, last captured, thumbnail,
GPMF and telemetry, turbo transfer, and file download.

A 2.2 GB video transferred in 56 s at 37 MiB/s with resident memory flat at
215 MB throughout, through a client configured with a 100 ms JSON request
timeout — which is what the separate download policy buys. Upstream's 5 s
whole-request deadline would have abandoned that transfer at 4%.

Two endpoints in the Open GoPro specification are not implemented by that
camera and firmware: `gopro/camera/name` answers 404 *"Command is not
recognized"*, and `gopro/media/screennail` answers 400 for a video. Both
reproduce identically under `curl`, so they are the camera's answer rather
than a malformed request; the exceptions carry the camera's own message.

Generated sources cover 477 settings, 175 statuses, 100 protocol constants
(`tool/gen_constants.py`), 40 HTTP messages (`tool/gen_http_commands.py`) and
11 protobuf definitions (`tool/gen_proto.py`).

The protobuf layer is validated over BLE against a MAX2: a Get Preset Status
request returned 564 bytes across the reassembler, correctly correlated, and
decoded to 3 preset groups and 13 presets with mode and title enums
resolving.

COHN is not implemented by the MAX2. Get COHN Status times out with no reply
at all, on the same feature and characteristic where preset status answers,
so it is the camera and not the framing. A HERO13 Black answers it, reporting
`COHN_UNPROVISIONED` / `COHN_STATE_Idle` — the correct state before
provisioning.

Provisioning itself is not yet exercised end to end: it requires a camera
already joined to a network, which is network management and not built.

Not yet implemented: Wi-Fi.

## License

MIT — see [`LICENSE`](LICENSE). This matches the Open GoPro Python SDK, from
which the camera constants in `lib/src/generated/` are derived.

Third-party components are listed with their license texts in
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md):

- **Dart SDK** API DL headers and `dart_api_dl.c` (BSD-3-Clause), redistributed
  verbatim under `native/include/` and `native/src/`. Do not reformat or lint
  these with `--fix`; they must match upstream.
- **Open GoPro Python SDK** (MIT, GoPro, Inc.) — vendored under
  `tool/upstream/` and the source of the generated constants.

GoPro, HERO, and MAX are trademarks of GoPro, Inc. This project is not
affiliated with or endorsed by GoPro, Inc.
