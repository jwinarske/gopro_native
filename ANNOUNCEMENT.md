# gopro_native — Linux-first GoPro control for Dart

Hi all — sharing a package I've been building: **[gopro_native](https://github.com/jwinarske/gopro_native)**, a Dart/Flutter implementation of the Open GoPro API with Linux as the first-class target rather than an afterthought.

Apache 2.0-friendly MIT, and everything below is validated against real hardware — a MAX2 and a HERO13 Black.

## What it does

```dart
final discovery = await GoProDiscovery.start();
await for (final cam in discovery.ready) {
  print('${cam.serial} reachable at ${cam.baseUri}');
}
```

- **USB discovery** over libusb, with readiness staging and hotplug
- **BLE control plane** — bring-up, pairing, reconnection, the full command/settings/query protocol
- **40 HTTP commands** including streaming media download
- **Protobuf layer** for COHN, network management, presets, livestream
- **COHN** (camera on your home network) with credential storage and TLS pinning
- **Wi-Fi** — the camera's own access point, and joining it to your network
- **Livestream and webcam** control

## A few design decisions worth explaining

**Never claim the USB interface.** The camera enumerates as CDC-NCM, and `libusb_claim_interface()` would detach `cdc_ncm` and destroy the netdev the HTTP API rides on. Discovery is enumerate-only, and a CMake check fails the build if anyone reaches for it.

**No mDNS.** The control-plane address is derived from the USB serial descriptor, so there's no Zeroconf dependency and no first-responder-wins spoofing surface on the wired path.

**A camera isn't usable when enumeration completes.** Measured on a cold plug: netdev bound at +46 ms, camera answering at **+754 ms**. Only `Readiness.l3Ready` means "you can talk to it".

**Frames never cross into Dart.** For livestream and webcam, the camera streams straight to the RTMP server or the host socket. Dart brokers the configuration and stays out of the data path.

## The parts I'd have got wrong without hardware

Most of what took the longest wasn't in any spec.

**BlueZ can't complete pairing without a registered agent** — and nothing in the failure says so. `Device.Pair` returns, no bond forms, discovery still works, and `StartNotify` then returns success while `Notifying` stays false. It reads exactly like a camera that lost its bond.

**`Notifying` survives a disconnect as stale `true`**, and `StartNotify` on a characteristic BlueZ already thinks is notifying is a no-op — it returns success without writing the CCCD. On reconnect, writes went out and were acknowledged, and not one reply came back. `StopNotify` first, then `StartNotify`.

**Network management has its own characteristic pair.** Not the Control & Query command channel everything else uses. Sent there, every camera answers a bare `[feature][0x02]` whatever the action.

**The ready gate has to be opened.** It's derived from the BUSY and ENCODING statuses, both start unknown, and nothing opens it on its own — so every queued command waits behind a gate that never opens, then fails with a timeout that says nothing. That one presented as a camera refusing all commands while answering all queries.

## Security choices, and what they're reacting to

The reference implementation is a good spec but a poor security template, and porting it faithfully would have carried three problems across.

**Credentials aren't interpolatable.** The reference logs its full command line including the Wi-Fi passphrase, and the COHN Basic token goes through the same logger. Credential fields here are a `Secret` type that prints `<redacted>` and yields its contents only via `.value` — greppable in a way `$password` isn't. A CI gate rejects `.value` inside any string interpolation.

**Arguments are argv, never a shell string.** The reference formats the SSID and passphrase into a command run with `shell=True`. An SSID is 32 arbitrary bytes chosen by whoever runs the access point. It doesn't even take malice — a real camera reports `GoPro 24642729`, and that space alone splits into two arguments.

**TLS is pinned, not disabled.** COHN uses a self-signed cert, so `HttpClient` rejects it. The tempting fix — `badCertificateCallback: (_, __, ___) => true` — doesn't accept the camera's certificate; it accepts every certificate from anything answering on that address, on a home network, which is the exact threat the certificate exists for.

**And `assert` is stripped in Dart release *and* profile builds.** The reference uses it for control flow in library code, including the result checks on COHN provisioning. Ported directly that's a library which skips its error handling in every shipped build and works correctly only in debug — passing every test run on the way.

All four are enforced by `tool/review_gates.py` in CI rather than written down and rediscovered. Each gate is negative-tested: introducing the violation has to make it fail. Two of them didn't, when first written.

## Status

Feature-complete and hardware-validated. 144 tests plus native C++ suites, clang-tidy, ASAN/UBSan on the BlueZ layer, and generated sources checked against upstream on every build.

Built on **[bluez_native](https://github.com/jwinarske/bluez_native)** for BLE, which came out of the same work.

Feedback and bug reports very welcome — particularly from anyone with a different camera model, since a fair amount of what's above is "measured on the two cameras I have" rather than "documented anywhere".
