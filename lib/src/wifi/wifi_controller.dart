// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
//
// wifi_controller.dart — joining the camera's access point.
//
// Turning the access point on is protocol work and belongs to this package.
// Joining it is not: it is whatever the host's network stack does, and there
// is no portable answer. The reference spends roughly 1500 lines shelling out
// to nmcli, networksetup, netsh and a system_profiler pipeline to cover that
// ground.
//
// So joining is an interface with a default that does nothing but say what
// needs doing. An application that already manages connectivity implements
// it; one that does not gets an honest instruction instead of a dependency on
// whatever happens to be installed.

import 'dart:io';

/// The camera's access point, as advertised over BLE.
class ApCredentials {
  const ApCredentials({required this.ssid, required this.password});

  /// Typically `GP` followed by the last digits of the serial.
  final String ssid;
  final String password;

  /// Omits the passphrase. It reaches logs otherwise.
  @override
  String toString() => 'ApCredentials($ssid)';
}

/// Joining the camera's access point failed.
class WifiJoinException implements Exception {
  const WifiJoinException(this.message, {this.detail = ''});

  final String message;
  final String detail;

  @override
  String toString() =>
      'WifiJoinException($message)${detail.isEmpty ? '' : '\n$detail'}';
}

/// How the host joins and leaves a network.
abstract class WifiController {
  /// Whether this controller can actually do anything, so a caller can pick
  /// one without catching an exception to find out.
  Future<bool> get available;

  /// Joins [credentials.ssid]. Returns when the host is associated.
  Future<void> join(ApCredentials credentials);

  /// Returns the host to whatever it was on before, if that is meaningful.
  Future<void> leave(ApCredentials credentials);
}

/// Reports what needs doing and does none of it.
///
/// The default, and the right choice for anything already managing its own
/// connectivity: silently reconfiguring the host's network is not a library's
/// call to make.
class ManualWifiController implements WifiController {
  const ManualWifiController({this.onInstruction});

  /// Called with a human-readable instruction instead of joining.
  final void Function(String)? onInstruction;

  @override
  Future<bool> get available async => false;

  @override
  Future<void> join(ApCredentials credentials) async {
    final message =
        'Join the camera access point "${credentials.ssid}" on this host, '
        'then retry. Its passphrase came from the camera over BLE and is on '
        'the ApCredentials passed here.';
    if (onInstruction != null) {
      onInstruction!(message);
      return;
    }
    throw WifiJoinException(
      'no Wi-Fi controller is configured',
      detail: message,
    );
  }

  @override
  Future<void> leave(ApCredentials credentials) async {}
}

/// Joins through NetworkManager's command line client.
///
/// Every argument is passed as its own element of an argv list, never
/// interpolated into a string handed to a shell. The reference builds these
/// commands by formatting the SSID and passphrase into a string and running
/// it with `shell=True`; an SSID is chosen by whoever runs the access point,
/// and a passphrase can contain anything at all, so that is a command
/// injection with the attacker supplying the network name.
///
/// [Process.run] with a list never involves a shell, so quoting is not a
/// concern here — but the argv form is the reason it is not, and it is worth
/// not losing that by accident.
class NmcliWifiController implements WifiController {
  const NmcliWifiController({this.executable = 'nmcli', this.timeout});

  final String executable;

  /// Passed to nmcli as `--wait`. Null leaves nmcli's own default.
  final Duration? timeout;

  @override
  Future<bool> get available async {
    try {
      final r = await Process.run(executable, ['--version']);
      return r.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  /// The argv for joining. Separated out so the shape is testable without a
  /// NetworkManager to run it against.
  List<String> joinArgs(ApCredentials credentials) => [
    if (timeout != null) ...['--wait', '${timeout!.inSeconds}'],
    'device',
    'wifi',
    'connect',
    credentials.ssid,
    'password',
    credentials.password,
  ];

  List<String> leaveArgs(ApCredentials credentials) => [
    'connection',
    'down',
    credentials.ssid,
  ];

  @override
  Future<void> join(ApCredentials credentials) async {
    final r = await _run(joinArgs(credentials));
    if (r.exitCode != 0) {
      throw WifiJoinException(
        'nmcli could not join "${credentials.ssid}"',
        // nmcli echoes the arguments it was given on some errors, so the
        // output is scrubbed before it goes anywhere a human might paste it.
        detail: _redact(r, credentials.password),
      );
    }
  }

  @override
  Future<void> leave(ApCredentials credentials) async {
    // Failing to leave is not worth an exception: the camera's access point
    // has no internet, so the host will usually have moved on already.
    await _run(leaveArgs(credentials));
  }

  Future<ProcessResult> _run(List<String> args) async {
    try {
      return await Process.run(executable, args);
    } on ProcessException catch (e) {
      throw WifiJoinException('cannot run $executable', detail: e.message);
    }
  }

  static String _redact(ProcessResult r, String secret) {
    final text = '${r.stdout}${r.stderr}'.trim();
    return secret.isEmpty ? text : text.replaceAll(secret, '<passphrase>');
  }
}
