// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
//
// secret.dart — a string that does not print itself.
//
// Credentials leak through interpolation, not through decisions. Nobody
// writes `log(password)`; they write `log('connecting as $credentials')` and
// the password comes along, or they attach an exception to a crash reporter
// and the command line that built it goes too. The reference implementation
// has no redaction anywhere: its `cmd()` logs the full command line
// including the Wi-Fi passphrase, and the COHN Basic token flows through the
// same logger.
//
// A String cannot defend itself. This can: interpolating it yields
// `<redacted>`, and reading the real value takes saying [value], which is
// greppable and reviewable in a way `$password` is not.

/// A value that must not reach a log, an exception, or a crash report.
///
/// Deliberately not `implements Comparable`, not `toJson`, and with no
/// implicit conversion. Every route out is explicit.
class Secret {
  const Secret(this._value);

  final String _value;

  /// The real value. Every call site is a place a credential escapes, so
  /// this is meant to be easy to search for.
  String get value => _value;

  bool get isEmpty => _value.isEmpty;
  bool get isNotEmpty => _value.isNotEmpty;
  int get length => _value.length;

  /// Redacted. This is the whole point of the type.
  @override
  String toString() => '<redacted>';

  /// Constant-time within the bounds Dart offers.
  ///
  /// Not a security guarantee — Dart strings are not fixed-layout and the
  /// VM may short-circuit. It costs nothing and removes the most obvious
  /// timing signal, which is comparing lengths first and bailing.
  @override
  bool operator ==(Object other) {
    if (other is! Secret) return false;
    final a = _value.codeUnits;
    final b = other._value.codeUnits;
    var diff = a.length ^ b.length;
    for (var i = 0; i < a.length && i < b.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  /// Derived from the length alone.
  ///
  /// A hash of the value would put a recoverable fingerprint of the secret
  /// into any map that ever held one, and into anything that prints a hash.
  @override
  int get hashCode => _value.length.hashCode;
}
