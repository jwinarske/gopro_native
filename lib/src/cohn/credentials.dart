// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
//
// credentials.dart — where COHN credentials live at rest.
//
// COHN hands out an HTTP Basic username and password plus a self-signed
// certificate. Together they are everything needed to reach the camera on the
// home network, so where they are written matters as much as that they are.
//
// The reference implementation writes all three to `cohn_db.json` in the
// current working directory, pretty-printed. That is world-readable, ends up
// in whatever directory the program happened to start in, and is very easy to
// commit by accident.

import 'dart:convert';
import 'dart:io';

/// Everything needed to reach a camera over COHN.
class CohnCredentials {
  const CohnCredentials({
    required this.username,
    required this.password,
    required this.certificate,
    this.ipAddress,
    this.ssid,
    this.macAddress,
  });

  final String username;
  final String password;

  /// The camera's self-signed root certificate, PEM encoded.
  ///
  /// Not a secret, but stored alongside the ones that are: without it the
  /// credentials cannot be used, since the connection will not verify.
  final String certificate;

  final String? ipAddress;
  final String? ssid;
  final String? macAddress;

  /// The `Authorization` header value.
  String get basicAuth =>
      'Basic ${base64Encode(utf8.encode('$username:$password'))}';

  Map<String, Object?> toJson() => {
    'username': username,
    'password': password,
    'certificate': certificate,
    if (ipAddress != null) 'ipAddress': ipAddress,
    if (ssid != null) 'ssid': ssid,
    if (macAddress != null) 'macAddress': macAddress,
  };

  static CohnCredentials fromJson(Map<String, Object?> json) => CohnCredentials(
    username: json['username']! as String,
    password: json['password']! as String,
    certificate: json['certificate']! as String,
    ipAddress: json['ipAddress'] as String?,
    ssid: json['ssid'] as String?,
    macAddress: json['macAddress'] as String?,
  );

  /// Deliberately omits the password and the certificate.
  ///
  /// These end up in logs and exception messages. The reference lets the
  /// Basic token through its logging, which puts the password in plaintext
  /// wherever those logs go.
  @override
  String toString() =>
      'CohnCredentials($username, ${ssid ?? "?"}, ${ipAddress ?? "?"})';
}

/// Where credentials are kept between runs.
abstract class CohnCredentialStore {
  /// Credentials for `serial`, or null if none are stored.
  Future<CohnCredentials?> read(String serial);

  Future<void> write(String serial, CohnCredentials credentials);

  Future<void> delete(String serial);
}

/// A `0600` file under `$XDG_STATE_HOME`.
///
/// The fallback for headless and embedded targets, which have no keyring
/// daemon and no session bus to reach one over. Not as good as a keyring —
/// the bytes are on disk in the clear — but it is private to the user, it is
/// in a defined location rather than the working directory, and the mode is
/// verified on read rather than assumed.
class FileCredentialStore implements CohnCredentialStore {
  FileCredentialStore({Directory? directory})
    : _dir = directory ?? _defaultDirectory();

  final Directory _dir;

  Directory get directory => _dir;

  static Directory _defaultDirectory() {
    final env = Platform.environment;
    // XDG says state goes in XDG_STATE_HOME, defaulting to ~/.local/state.
    // Not XDG_CONFIG_HOME: these are machine-generated and not something a
    // user edits or syncs between hosts.
    final base =
        env['XDG_STATE_HOME'] ??
        (env['HOME'] == null ? null : '${env['HOME']}/.local/state');
    if (base == null) {
      throw StateError(
        'neither XDG_STATE_HOME nor HOME is set, so there is nowhere '
        'private to write credentials',
      );
    }
    return Directory('$base/gopro_native');
  }

  File _fileFor(String serial) {
    // The serial reaches this from a camera, so it is not trusted to be a
    // safe filename. A serial of "../../authorized_keys" must not escape.
    final safe = serial.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    if (safe.isEmpty || safe.replaceAll('_', '').isEmpty) {
      throw ArgumentError('serial "$serial" has no usable characters');
    }
    return File('${_dir.path}/$safe.json');
  }

  @override
  Future<CohnCredentials?> read(String serial) async {
    final f = _fileFor(serial);
    if (!await f.exists()) return null;

    // A file that has become group- or world-readable since it was written
    // is a different situation from one that was never written. Report it
    // rather than handing back credentials that others can also read.
    final mode = (await f.stat()).mode & 0x1FF;
    if (mode & 0x03F != 0) {
      throw StateError(
        '${f.path} is mode ${mode.toRadixString(8).padLeft(3, '0')}, which is '
        'readable beyond its owner. Refusing to use it; delete it and '
        'provision again.',
      );
    }

    return CohnCredentials.fromJson(
      jsonDecode(await f.readAsString()) as Map<String, Object?>,
    );
  }

  @override
  Future<void> write(String serial, CohnCredentials credentials) async {
    await _dir.create(recursive: true);
    // 0700 on the directory too: a 0600 file inside a traversable directory
    // still leaks its name, and the name is the camera serial.
    await Process.run('chmod', ['700', _dir.path]);

    final f = _fileFor(serial);
    // Create the file before writing so the mode is never briefly permissive
    // with the secret already in it.
    if (!await f.exists()) {
      await f.create();
    }
    await Process.run('chmod', ['600', f.path]);
    await f.writeAsString(jsonEncode(credentials.toJson()), flush: true);
  }

  @override
  Future<void> delete(String serial) async {
    final f = _fileFor(serial);
    if (await f.exists()) await f.delete();
  }
}
