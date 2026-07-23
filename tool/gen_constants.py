#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Joel Winarske
"""Generate Dart constants from the Open GoPro Python SDK enum tables.

The upstream SDK carries ~477 setting values across 54 enums plus ~175 status
values. Transcribing that by hand is both tedious and a silent-error factory:
a single wrong integer produces a camera that misbehaves in one mode only.

Usage:
    tool/gen_constants.py [--upstream tool/upstream] [--out lib/src/generated]
    tool/gen_constants.py --check     # verify generated files are up to date

Do not hand-edit the generated files, including spelling sweeps: the
enumerator names mirror upstream exactly, and upstream is not internally
consistent (statuses.py has both CANCELLED and CANCELED). Rewriting one
produces an identifier that regeneration silently reverts.

The upstream .py files are vendored under tool/upstream/ so generation is
reproducible without a checkout of the SDK. They are MIT-licensed by GoPro,
Inc.; tool/upstream/LICENSE.gopro carries the notice, and every generated file
reproduces the copyright line as MIT requires for derived work.
"""

from __future__ import annotations

import argparse
import ast
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

GOPRO_COPYRIGHT = "Copyright © 2021-2024 GoPro, Inc."

# Enum base classes in the upstream SDK whose members are plain ints.
INT_ENUM_BASES = {"GoProIntEnum", "IntEnum"}


class GenError(Exception):
    pass


# ---------------------------------------------------------------------------
# Naming
# ---------------------------------------------------------------------------

def to_lower_camel(name: str) -> str:
    """SCREAMING_SNAKE -> lowerCamelCase, preserving digit groups.

    The upstream names are awkward on purpose: Python cannot start an
    identifier with a digit, so the generator upstream prefixes those with
    NUM_ (NUM_4K, NUM_1080). Dart has the same restriction, so the prefix has
    to survive in some form.

        NUM_4K            -> num4K
        ND_16             -> nd16
        FULL_FRAME_1_1_V2 -> fullFrame11V2
        MAX_LENS_2_5      -> maxLens25
    """
    parts = [p for p in name.split("_") if p]
    if not parts:
        raise GenError(f"empty identifier from {name!r}")
    out = parts[0].lower()
    for part in parts[1:]:
        if part[0].isdigit():
            # Digits first, then the letter tail title-cased. Upstream is not
            # self-consistent about where it puts underscores -- WirelessBand
            # is spelled NUM_2_4_GHZ as a status and NUM_2_4GHZ as a setting --
            # so normalizing the tail makes both land on num24Ghz instead of
            # producing two different Dart names for the same concept.
            digits = re.match(r"^\d+", part).group(0)
            tail = part[len(digits):]
            out += digits + (tail[0].upper() + tail[1:].lower() if tail else "")
        else:
            out += part[0].upper() + part[1:].lower()
    if not re.match(r"^[a-z_][A-Za-z0-9_]*$", out):
        raise GenError(f"{name!r} -> {out!r} is not a valid Dart identifier")
    return out


def to_upper_camel(name: str) -> str:
    """Normalize an upstream class name to Dart's UpperCamelCase.

    Most upstream names are already correct (VideoResolution). A handful are
    not, and Dart's linter flags them:

        LED_SPECIAL               -> LedSpecial
        Anti_Flicker              -> AntiFlicker
        AutomaticWi_FiAccessPoint -> AutomaticWiFiAccessPoint
    """
    parts = [p for p in name.split("_") if p]
    out = ""
    for part in parts:
        # An all-caps fragment is an acronym upstream wrote in shouting case;
        # title-case it. Anything else keeps its internal capitalization.
        out += part.capitalize() if part.isupper() else part[0].upper() + part[1:]
    if not re.match(r"^[A-Z][A-Za-z0-9]*$", out):
        raise GenError(f"class {name!r} -> {out!r} is not UpperCamelCase")
    return out


# Suffix applied to a class name when the same name is defined in more than
# one upstream module. WirelessBand is the current case: it exists as both a
# setting (id 178) and a status (id 76) with the same values but different
# member spellings, so neither can simply be dropped.
MODULE_SUFFIX = {
    "settings.py": "Setting",
    "statuses.py": "Status",
    "constants.py": "Constant",
}


DART_RESERVED = {
    "abstract", "as", "assert", "async", "await", "break", "case", "catch",
    "class", "const", "continue", "covariant", "default", "deferred", "do",
    "dynamic", "else", "enum", "export", "extends", "extension", "external",
    "factory", "false", "final", "finally", "for", "function", "get", "hide",
    "if", "implements", "import", "in", "interface", "is", "late", "library",
    "mixin", "new", "null", "on", "operator", "part", "required", "rethrow",
    "return", "set", "show", "static", "super", "switch", "sync", "this",
    "throw", "true", "try", "typedef", "var", "void", "while", "with", "yield",
    # Not reserved, but colliding with enum members Dart synthesises.
    "index", "values", "name", "hashCode", "runtimeType", "toString",
}


def safe_member(name: str) -> str:
    ident = to_lower_camel(name)
    return f"{ident}$" if ident in DART_RESERVED else ident


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

def as_int_literal(node: ast.expr) -> int | None:
    """Integer value of a literal, handling the unary-minus form.

    `UNKNOWN = -1` parses as UnaryOp(USub, Constant(1)), not Constant(-1);
    upstream uses it as a sentinel in several status enums.
    """
    if isinstance(node, ast.Constant) and isinstance(node.value, int):
        return node.value
    if (
        isinstance(node, ast.UnaryOp)
        and isinstance(node.op, ast.USub)
        and isinstance(node.operand, ast.Constant)
        and isinstance(node.operand.value, int)
    ):
        return -node.operand.value
    return None


class ParsedEnum:
    def __init__(self, name: str, doc: str | None):
        self.name = name
        self.dart_name = to_upper_camel(name)
        self.doc = doc
        self.members: list[tuple[str, int, str | None]] = []


def parse_module(path: pathlib.Path) -> list[ParsedEnum]:
    tree = ast.parse(path.read_text(), filename=str(path))
    enums: list[ParsedEnum] = []

    for node in tree.body:
        if not isinstance(node, ast.ClassDef):
            continue
        bases = {b.id for b in node.bases if isinstance(b, ast.Name)}
        if not (bases & INT_ENUM_BASES):
            continue

        enum = ParsedEnum(node.name, ast.get_docstring(node))
        body = node.body
        for i, stmt in enumerate(body):
            if not isinstance(stmt, ast.Assign) or len(stmt.targets) != 1:
                continue
            target = stmt.targets[0]
            if not isinstance(target, ast.Name):
                continue
            const = as_int_literal(stmt.value)
            if const is None:
                # Aliases and computed members are not representable as Dart
                # enum members; skipping silently would lose data, so refuse.
                raise GenError(
                    f"{path.name}:{stmt.lineno} {node.name}.{target.id} is not an "
                    f"integer literal ({ast.dump(stmt.value)[:60]})"
                )
            # A bare string immediately after the assignment is the member doc.
            doc = None
            if i + 1 < len(body):
                nxt = body[i + 1]
                if (
                    isinstance(nxt, ast.Expr)
                    and isinstance(nxt.value, ast.Constant)
                    and isinstance(nxt.value.value, str)
                ):
                    doc = nxt.value.value.strip()
            enum.members.append((target.id, const, doc))

        if enum.members:
            enums.append(enum)
    return enums


# ---------------------------------------------------------------------------
# Emission
# ---------------------------------------------------------------------------

def header(source: str) -> str:
    return f"""// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
//
// GENERATED FILE — DO NOT EDIT.
//
// Generated by tool/gen_constants.py from tool/upstream/{source}.
// Regenerate with:  tool/gen_constants.py
//
// Derived from the Open GoPro Python SDK, which is MIT licensed:
//   {GOPRO_COPYRIGHT}
// The full notice is in tool/upstream/LICENSE.gopro and must ship with any
// distribution of this package.

"""


def doc_comment(text: str | None, indent: str = "") -> str:
    if not text:
        return ""
    lines = [ln.rstrip() for ln in text.strip().splitlines()]
    return "".join(f"{indent}/// {ln}\n".rstrip() + "\n" for ln in lines)


def emit_enum(e: ParsedEnum) -> str:
    seen: dict[str, str] = {}
    seen_values: dict[int, str] = {}
    members = []
    for raw, value, doc in e.members:
        ident = safe_member(raw)
        if ident in seen:
            raise GenError(
                f"{e.name}: {raw!r} and {seen[ident]!r} both map to Dart "
                f"member {ident!r}"
            )
        seen[ident] = raw
        # Duplicate integers are legal in Python enums (they become aliases)
        # but would make fromValue ambiguous. Report rather than pick one.
        if value in seen_values:
            raise GenError(
                f"{e.name}: {raw!r} and {seen_values[value]!r} share value "
                f"{value}; fromValue would be ambiguous"
            )
        seen_values[value] = raw
        members.append((ident, raw, value, doc))

    out = [doc_comment(e.doc)]
    if e.dart_name != e.name:
        out.append(f"///\n/// Upstream name: `{e.name}`\n")
    out.append(f"enum {e.dart_name} {{\n")
    for i, (ident, raw, value, doc) in enumerate(members):
        if doc:
            out.append(doc_comment(doc, "  "))
        out.append(f"  /// Upstream name: `{raw}`\n" if not doc else "")
        term = ";" if i == len(members) - 1 else ","
        out.append(f"  {ident}({value}){term}\n")
    out.append(f"""
  const {e.dart_name}(this.value);

  /// Wire value written to / read from the camera.
  final int value;

  static final Map<int, {e.dart_name}> _byValue = {{
    for (final v in {e.dart_name}.values) v.value: v,
  }};

  /// Looks up a value received from the camera.
  ///
  /// Returns null for an unrecognized value rather than throwing — newer
  /// firmware can and does introduce values this table predates, and an
  /// unknown setting must not take down the connection.
  static {e.dart_name}? fromValue(int value) => _byValue[value];
}}
""")
    return "".join(out)


def emit_module(enums: list[ParsedEnum], source: str) -> str:
    return header(source) + "\n".join(emit_enum(e) for e in enums)


# ---------------------------------------------------------------------------

def dart_format(text: str) -> str:
    """Runs the emitted source through `dart format`.

    Without this the committed files are reformatted by `dart format` in CI
    and --check then reports drift forever, because the generator and the
    formatter disagree about the same content. Falls back to the raw text
    when the Dart SDK is unavailable.
    """
    dart = shutil.which("dart")
    if dart is None:
        raise GenError(
            "dart not found on PATH. The generated sources are formatted, so "
            "without it this would emit unformatted output and --check would "
            "compare against something that is never written."
        )
    with tempfile.TemporaryDirectory() as tmp:
        f = pathlib.Path(tmp) / "gen.dart"
        f.write_text(text)
        r = subprocess.run([dart, "format", str(f)],
                           capture_output=True, text=True)
        if r.returncode != 0:
            raise GenError(f"dart format failed: {r.stderr.strip()}")
        return f.read_text()


MODULES = {
    "settings.py": "settings.dart",
    "statuses.py": "statuses.dart",
    "constants.py": "constants.dart",
}


def main() -> int:
    ap = argparse.ArgumentParser()
    root = pathlib.Path(__file__).resolve().parent.parent
    ap.add_argument("--upstream", type=pathlib.Path, default=root / "tool/upstream")
    ap.add_argument("--out", type=pathlib.Path, default=root / "lib/src/generated")
    ap.add_argument(
        "--check",
        action="store_true",
        help="exit non-zero if the generated files differ from what would be "
        "written (for CI)",
    )
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    # Pass 1 — parse everything so cross-module name collisions are visible
    # before any file is written.
    parsed: dict[str, list[ParsedEnum]] = {}
    for src in MODULES:
        path = args.upstream / src
        if not path.exists():
            print(f"missing upstream source: {path}", file=sys.stderr)
            return 2
        try:
            parsed[src] = parse_module(path)
        except GenError as e:
            print(f"error: {e}", file=sys.stderr)
            return 1

    counts: dict[str, int] = {}
    for enums in parsed.values():
        for e in enums:
            counts[e.dart_name] = counts.get(e.dart_name, 0) + 1
    for src, enums in parsed.items():
        for e in enums:
            if counts[e.dart_name] > 1:
                renamed = e.dart_name + MODULE_SUFFIX[src]
                print(f"  disambiguating {e.dart_name} -> {renamed} (from {src})")
                e.dart_name = renamed

    # Pass 2 — emit.
    stale = []
    for src, dst in MODULES.items():
        enums = parsed[src]
        try:
            text = dart_format(emit_module(enums, src))
        except GenError as e:
            # Emission-time failures (name or value collisions) are as much a
            # user error as parse failures -- report them the same way rather
            # than as a traceback.
            print(f"error: {e}", file=sys.stderr)
            return 1
        target = args.out / dst
        if args.check:
            if not target.exists() or target.read_text() != text:
                stale.append(str(target))
        else:
            target.write_text(text)
            total = sum(len(e.members) for e in enums)
            print(f"{dst}: {len(enums)} enums, {total} members")

    if args.check:
        if stale:
            print("stale generated files: " + ", ".join(stale), file=sys.stderr)
            print("run tool/gen_constants.py", file=sys.stderr)
            return 1
        print("generated files up to date")
    return 0


if __name__ == "__main__":
    sys.exit(main())
