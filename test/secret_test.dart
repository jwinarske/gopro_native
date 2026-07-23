// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
//
// The Secret type.
//
// Credentials leak through interpolation, not through decisions. Nobody
// writes `log(password)`; they write `log('as $credentials')`, or attach an
// exception whose message was built from a command line. So the property
// worth pinning down is what happens when someone does the accidental thing.

import 'package:gopro_native/src/secret.dart';
import 'package:test/test.dart';

void main() {
  test('interpolating a secret yields a placeholder', () {
    const s = Secret('hunter2');
    expect('$s', '<redacted>');
    expect('the password is $s', 'the password is <redacted>');
    expect(s.toString(), isNot(contains('hunter2')));
  });

  test('the value is available, but only by asking', () {
    // Every call site is a place a credential escapes, which is the point:
    // `.value` is greppable in a way `$password` is not.
    expect(const Secret('hunter2').value, 'hunter2');
  });

  test('a secret inside a collection still redacts', () {
    // Lists and maps print their elements with toString, so a secret in a
    // structure someone dumps is the common accident.
    const s = Secret('hunter2');
    expect([s].toString(), isNot(contains('hunter2')));
    expect({'password': s}.toString(), isNot(contains('hunter2')));
  });

  test('an exception carrying a secret does not print it', () {
    const s = Secret('hunter2');
    final e = StateError('failed with $s');
    expect(e.toString(), isNot(contains('hunter2')));
  });

  test('equality compares values', () {
    expect(const Secret('a') == const Secret('a'), isTrue);
    expect(const Secret('a') == const Secret('b'), isFalse);
    expect(const Secret('a') == const Secret('aa'), isFalse);
    expect(const Secret('') == const Secret(''), isTrue);
  });

  test('a secret is not equal to its own plaintext', () {
    // ignore: unrelated_type_equality_checks
    expect(const Secret('a') == 'a', isFalse);
  });

  test('the hash does not fingerprint the value', () {
    // A hash of the contents would put a recoverable fingerprint into any map
    // that ever held one, and into anything that prints a hash code. Two
    // different secrets of the same length collide on purpose.
    expect(const Secret('aaaa').hashCode, const Secret('bbbb').hashCode);
    expect(const Secret('hunter2').hashCode, isNot('hunter2'.hashCode));
  });

  test('length and emptiness are readable without the value', () {
    // Enough to validate input without handling the secret itself.
    expect(const Secret('hunter2').length, 7);
    expect(const Secret('').isEmpty, isTrue);
    expect(const Secret('x').isNotEmpty, isTrue);
  });
}
