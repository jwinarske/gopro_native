## 0.2.0

Everything beyond USB discovery. 0.1.0 found cameras; this talks to them.

### BLE control plane

- Bring-up state machine with named stall reasons. "Connected" is not
  "usable", and a sleeping camera, a Classic link suppressing LE
  advertising, and a missing LE bond all present as "it does not work"
  while needing completely different responses.
- Reconnection after a dropped link, reusing one machine so backoff is an
  accumulated judgement rather than a fresh guess per attempt.
- A pairing agent. BlueZ cannot complete pairing without one: `Device.Pair`
  returns, no bond forms, discovery still works, and `StartNotify` then
  returns success while `Notifying` stays false. Nothing in that sequence
  mentions pairing.
- Fragmentation and reassembly at the negotiated MTU rather than the BLE 4.0
  floor — a ~26x reduction in fragment count on large responses.
- Ready-gated command queue where keep-alive can never be starved, and a
  deadline on commands waiting for a gate that may never open.

### HTTP command surface

- 40 typed commands over a table generated from the upstream SDK.
- Separate timeout policies: a whole-request deadline for JSON, and a
  stall deadline for downloads measured from the last byte. A 4 GB file may
  take as long as it takes; a stream delivering nothing for 30 s is stuck.
- Downloads stream to disk. A failed or stalled one deletes its partial
  file, because a truncated video looks like a finished one to whatever
  finds it next.

### Protobuf, COHN, Wi-Fi, streaming

- Generated protobuf split into per-feature libraries, so an application
  doing capture control does not ship the livestream descriptors.
- COHN provisioning with credentials in a `0600` file under
  `$XDG_STATE_HOME`, mode verified on read, and TLS pinned to the camera's
  certificate rather than verification disabled.
- The camera's access point, and joining the camera to an existing network.
- Livestream configuration and webcam control. Neither puts a video frame
  through this process.

### Standing review gates

`tool/review_gates.py` runs in CI: no `assert` in library code, credentials
typed so they cannot be interpolated, and the codec drift guards kept in
place.

## 0.1.0

- USB discovery over libusb with readiness staging and hotplug.
