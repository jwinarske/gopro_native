# Examples

Each of these runs against a real camera. None of them changes anything on it
beyond what its name says.

| | |
|---|---|
| [`discover.dart`](discover.dart) | Watch for cameras on USB and report each one once it is actually reachable |
| [`http_probe.dart`](http_probe.dart) | Wait for a camera, then read version, info, state and media list over HTTP |
| [`ble_status.dart`](ble_status.dart) | Connect over BLE, read the busy and encoding statuses, watch the ready gate |
| [`wifi_ap.dart`](wifi_ap.dart) | Turn on the camera's access point and report how to join it |
| [`wifi_scan.dart`](wifi_scan.dart) | Scan for networks the camera can see, and optionally join one |
| [`livestream.dart`](livestream.dart) | Report what the camera can livestream, and optionally configure a stream |

```sh
dart run example/discover.dart
```

The native library is built automatically by the build hook. If you would
rather build it by hand:

```sh
cmake -S native -B build && cmake --build build
GOPRO_NC_LIB=$PWD/build/libgopro_nc.so dart run example/discover.dart
```

## A note on secrets

`wifi_scan.dart` takes a passphrase on stdin rather than as an argument:

```sh
read -rs PASS && echo "$PASS" | dart run example/wifi_scan.dart "SSID" -
```

Arguments are visible in the process list to every user on the machine, and
land in shell history. Joining a network the camera already has credentials
for needs no passphrase at all.
