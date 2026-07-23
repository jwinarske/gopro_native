#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Joel Winarske
"""Enforce the standing review gates.

Three failure modes that do not announce themselves. A checklist would be
rediscovered rather than followed, so each one that can be checked mechanically
is checked here and runs in CI.

None of these fail loudly on their own. That is what makes them worth a gate:
a stripped assert is a library that works in debug and skips its error
handling in every shipped build; a logged passphrase looks like a log line;
and codec drift puts data in the wrong fields rather than raising.

Usage:
    tool/review_gates.py
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).parent.parent

# Generated sources are not ours to edit, and regeneration would revert any
# change made to satisfy a gate.
GENERATED = ("lib/src/generated/",)


class Failure:
    def __init__(self, gate: str, detail: str, where: str = ""):
        self.gate = gate
        self.detail = detail
        self.where = where

    def __str__(self) -> str:
        return f"  {self.where + ': ' if self.where else ''}{self.detail}"


def dart_sources(root: pathlib.Path, *, skip_generated: bool = True):
    for p in sorted(root.rglob("*.dart")):
        rel = p.relative_to(ROOT).as_posix()
        if skip_generated and rel.startswith(GENERATED):
            continue
        yield p, rel


# ---------------------------------------------------------------------------
# Gate 1 — assert is stripped in release and profile builds
# ---------------------------------------------------------------------------

# `assert` inside a const constructor's initializer list is a compile-time
# check, not control flow, and is not stripped in the sense that matters.
# Nothing in this package uses one yet; if that changes, this is where to
# carve it out deliberately rather than by accident.
ASSERT = re.compile(r"(?<![A-Za-z0-9_])assert\s*\(")


def gate_no_asserts() -> list[Failure]:
    """Dart strips assert in release AND profile.

    The reference uses assert for control flow in library code, including the
    result checks on COHN certificate creation and access point enablement.
    Translated directly, those become a library that silently proceeds on
    failure in every shipped build and works correctly only in debug -- the
    worst possible split, because it passes every test run.
    """
    out = []
    for path, rel in dart_sources(ROOT / "lib"):
        for i, line in enumerate(path.read_text().splitlines(), 1):
            if line.lstrip().startswith("//"):
                continue
            if ASSERT.search(line):
                out.append(Failure(
                    "assert", "assert is stripped in release and profile; "
                    "throw instead", f"{rel}:{i}",
                ))
    return out


# ---------------------------------------------------------------------------
# Gate 2 — nothing may log credentials
# ---------------------------------------------------------------------------

SECRET_NAMES = re.compile(
    r"\b(password|passphrase|secret|token|apikey|api_key)\b", re.I
)

# A declaration: `final String password;` or `String password = ...`, and the
# late/const spellings. Locals count as well as fields -- a local holding a
# passphrase as a String is the same leak with a shorter lifetime.
#
# The name must match as a whole word, so `passwordHint` and `tokenCount` are
# not swept in.
FIELD = re.compile(
    r"^\s*(?:late\s+)?(?:final\s+|const\s+|var\s+)?"
    r"([A-Za-z0-9_<>?.]+)\s+([A-Za-z0-9_]+)\s*[;=]"
)

# `final password = ...` -- no written type. Still worth flagging: whatever it
# infers, the binding holds the plaintext under a name that says so.
INFERRED = re.compile(r"^\s*(?:late\s+)?(?:final|const|var)\s+([A-Za-z0-9_]+)\s*=")


def gate_secrets_are_typed() -> list[Failure]:
    """Credential-bearing fields must be Secret, not String.

    A String cannot defend itself against interpolation. Nobody writes
    log(password) -- they write log('as $credentials') and the password comes
    with it, or attach an exception whose message was built from a command
    line. The reference has no redaction anywhere.
    """
    out = []
    for path, rel in dart_sources(ROOT / "lib"):
        for i, line in enumerate(path.read_text().splitlines(), 1):
            inferred = INFERRED.match(line)
            if inferred:
                name = inferred.group(1)
                if SECRET_NAMES.search(name):
                    out.append(Failure(
                        "secrets", f"`{name}` holds a credential under an "
                        "inferred type; wrap it in Secret at the point it is "
                        "produced, or do not bind it at all", f"{rel}:{i}",
                    ))
                continue

            m = FIELD.match(line)
            if not m:
                continue
            type_, name = m.group(1), m.group(2)
            if SECRET_NAMES.search(name) and type_ not in ("Secret", "Secret?"):
                out.append(Failure(
                    "secrets", f"`{name}` is {type_}; credential-bearing "
                    "declarations must be Secret so they cannot be "
                    "interpolated", f"{rel}:{i}",
                ))
    return out


# Any `.value` inside a string interpolation.
#
# Deliberately broader than "a name that looks like a secret". Matching on
# names only catches `${creds.password.value}` and misses `${p.value}`, which
# is the same leak with a shorter variable — and the shorter variable is what
# a helper function has. There are currently zero `.value` interpolations in
# lib/ or example/, so the broad rule costs nothing and the narrow one was
# demonstrably missing real cases.
#
# A false positive costs one line of restructuring. A miss costs a credential
# in a log.
INTERPOLATED_VALUE = re.compile(r"\$\{[^}]*\.value[^}]*\}")


def gate_no_interpolated_secrets() -> list[Failure]:
    """`.value` must not appear inside a string interpolation.

    Reading a secret is legitimate -- writing it into a string is where it
    escapes. Every real use (an argv element, an Authorization header, a JSON
    field written to a 0600 file) passes the value as a value.

    This does not know which `.value` belongs to a Secret, and does not try.
    Anything that needs one inside a string can build it from parts, which is
    what CohnCredentials.basicAuth does.
    """
    out = []
    for root in (ROOT / "lib", ROOT / "example"):
        for path, rel in dart_sources(root):
            for i, line in enumerate(path.read_text().splitlines(), 1):
                if INTERPOLATED_VALUE.search(line):
                    out.append(Failure(
                        "secrets", ".value inside a string interpolation; "
                        "pass it as a value rather than building a string",
                        f"{rel}:{i}",
                    ))
    return out


def gate_secret_redacts() -> list[Failure]:
    """Secret.toString must not return the value.

    The one line the whole type rests on.
    """
    src = (ROOT / "lib/src/secret.dart").read_text()
    if "String toString() => '<redacted>';" not in src:
        return [Failure(
            "secrets", "Secret.toString no longer returns a redacted "
            "placeholder", "lib/src/secret.dart",
        )]
    return []


# ---------------------------------------------------------------------------
# Gate 3 — glz::meta and codec.dart are one format in two places
# ---------------------------------------------------------------------------

def gate_codec_guards() -> list[Failure]:
    """Field order in glz::meta and codec.dart must move together.

    Drift is silent corruption, not a compile error: fields land in the wrong
    variables and a misread length prefix becomes an absurd allocation. Two
    guards stand between that and a shipped build, and both have to stay.

    The frozen vectors must be hand-encoded. Vectors captured from live output
    would drift along with the code they are meant to catch, which is worse
    than having none: they would report agreement between two things that had
    changed together.
    """
    out = []

    test = ROOT / "test/codec_test.dart"
    if not test.exists():
        return [Failure("codec", "test/codec_test.dart is gone; it is the "
                        "only guard against silent field-order drift")]
    text = test.read_text()
    # Hand-written byte vectors: a list of small integer literals.
    if not re.search(r"\[\s*(?:0x[0-9a-fA-F]+|\d+)\s*,", text):
        out.append(Failure(
            "codec", "no hand-encoded byte vectors found; frozen vectors are "
            "what catch drift, and captured ones drift with the code",
            "test/codec_test.dart",
        ))

    codec = ROOT / "lib/src/ffi/codec.dart"
    if not codec.exists():
        return out + [Failure("codec", "lib/src/ffi/codec.dart is gone")]
    ctext = codec.read_text()
    if "readString" not in ctext:
        out.append(Failure("codec", "_Reader.readString is gone",
                           "lib/src/ffi/codec.dart"))
    elif not re.search(r"(?s)readString.{0,1200}(throw|FormatException)", ctext):
        out.append(Failure(
            "codec", "readString no longer bounds-checks its length prefix; "
            "a misread prefix becomes an absurd allocation rather than a "
            "named error", "lib/src/ffi/codec.dart",
        ))
    return out


GATES = (
    ("assert is stripped in release and profile", gate_no_asserts),
    ("credential fields are typed", gate_secrets_are_typed),
    ("secrets are not interpolated", gate_no_interpolated_secrets),
    ("Secret redacts itself", gate_secret_redacts),
    ("codec drift guards are in place", gate_codec_guards),
)


def main() -> int:
    failures: list[Failure] = []
    for title, check in GATES:
        found = check()
        status = f"FAIL ({len(found)})" if found else "ok"
        print(f"  {status:<9} {title}")
        failures.extend(found)

    if failures:
        print("\nreview gates failed:", file=sys.stderr)
        for f in failures:
            print(str(f), file=sys.stderr)
        print("\nSee issue #7 for why each of these exists.", file=sys.stderr)
        return 1

    print(f"\nall {len(GATES)} review gates pass")
    return 0


if __name__ == "__main__":
    sys.exit(main())
