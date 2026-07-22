// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
// types.dart — Dart mirrors of the native event records.

/// Where the serial number came from.
///
/// This is not merely diagnostic. `sysfs` means `libusb_open()` was denied,
/// which on the hotplug path is the *normal* outcome: logind applies the
/// uaccess ACL asynchronously and the open routinely loses that race even on
/// a correctly configured desktop. Observed on every MAX2 replug tested.
enum SerialSource { none, descriptor, sysfs }

/// How far a camera has progressed toward being usable.
///
/// A camera is not reachable when USB enumeration completes. Measured on a
/// MAX2 cold plug: netdev bound at +46 ms, camera answering at +754 ms. Only
/// [l3Ready] means "you can talk to it".
enum Readiness {
  absent,
  usbPresent,
  netdevBound,
  hostAddressed,
  l3Ready;

  /// True once the camera actually answers on its control port.
  bool get isReady => this == Readiness.l3Ready;
}

/// A GoPro camera attached over USB.
class GoProCamera {
  const GoProCamera({
    required this.vid,
    required this.pid,
    required this.bus,
    required this.address,
    required this.sysfsName,
    required this.serial,
    required this.serialSource,
    required this.ip,
    required this.netdev,
    required this.netdevFirstSeen,
    required this.netdevRenamed,
    required this.linkState,
    required this.hostIp,
    required this.readiness,
    required this.hasCdc,
    required this.elapsed,
  });

  final int vid;
  final int pid;
  final int bus;
  final int address;

  /// `/sys/bus/usb/devices` entry, e.g. `2-1`. Stable for the lifetime of the
  /// attachment and used as the identity key — [address] changes on replug.
  final String sysfsName;

  final String serial;
  final SerialSource serialSource;

  /// Control-plane address derived from the serial: `172.2X.1YZ.51`.
  final String ip;

  /// Kernel network interface, e.g. `enp17s0u1`.
  ///
  /// Do not persist this across events — see [netdevRenamed].
  final String netdev;

  /// First interface name ever seen for this device.
  final String netdevFirstSeen;

  /// True when the kernel-name → predictable-name rename was witnessed
  /// during this attachment (e.g. `eth0` → `enp17s0u1`).
  ///
  /// If a bug report shows this set, a stale cached interface name is the
  /// likely cause: the kernel registers the interface under a temporary name
  /// and udev renames it milliseconds later, so any name captured at arrival
  /// may already be obsolete. Install `udev/99-gopro.rules` to pin the name
  /// and remove the race entirely.
  final bool netdevRenamed;

  /// `operstate` of [netdev]. Informational only — USB network devices
  /// commonly report `unknown` while fully functional, so never gate on it.
  final String linkState;

  /// IPv4 the host holds on [netdev], leased by the camera's own DHCP server.
  /// Empty until the lease completes.
  final String hostIp;

  final Readiness readiness;
  final bool hasCdc;

  /// Time since this camera was first seen, for readiness timing.
  final Duration elapsed;

  bool get isReady => readiness.isReady;

  /// Base URL for the Open GoPro HTTP API. Null until [isReady].
  Uri? get baseUri =>
      isReady && ip.isNotEmpty ? Uri.parse('http://$ip:8080/') : null;

  @override
  String toString() =>
      'GoProCamera(${vid.toRadixString(16).padLeft(4, '0')}:'
      '${pid.toRadixString(16).padLeft(4, '0')} $sysfsName '
      'serial=$serial ip=$ip netdev=$netdev'
      '${netdevRenamed ? ' RENAMED-from=$netdevFirstSeen' : ''} '
      'host=$hostIp state=${readiness.name})';
}
