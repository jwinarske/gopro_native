#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Joel Winarske
"""Generate the Open GoPro HTTP message table from the Python SDK.

Upstream declares each HTTP message as a decorator on an empty method body and
synthesizes the machinery from **kwargs introspection at import time. Dart AOT
has no runtime reflection, so that shape does not translate; what does
translate is the data inside the decorators, which is what this extracts.

The result is a table of endpoints, path components, query arguments and body
arguments. It deliberately does NOT try to reproduce the method bodies: about
a third of them rewrite kwargs before dispatch, in ways that range from
renaming a parameter to formatting a datetime across four query arguments.
Those live in hand-written Dart, where the transform is visible instead of
being inferred from a return statement. The table is the part that would
otherwise drift silently against upstream.

Usage:
    tool/gen_http_commands.py [--upstream tool/upstream] [--out lib/src/generated]
    tool/gen_http_commands.py --check     # verify the generated file is current

Do not hand-edit the generated file. The upstream .py is vendored under
tool/upstream/ so generation is reproducible without a checkout of the SDK. It
is MIT-licensed by GoPro, Inc.; tool/upstream/LICENSE.gopro carries the notice,
and the generated file reproduces the copyright line as MIT requires.
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

SOURCE = "http_commands.py"
TARGET = "http_commands.dart"

# The three decorators that declare an HTTP message, and the kind of response
# each produces.
DECORATORS = {
    "http_get_json_command": ("get", "json"),
    "http_put_json_command": ("put", "json"),
    "http_get_binary_command": ("get", "binary"),
}


class GenError(Exception):
    pass


def to_lower_camel(name: str) -> str:
    """snake_case -> lowerCamelCase."""
    parts = [p for p in name.split("_") if p]
    if not parts:
        raise GenError(f"empty identifier from {name!r}")
    out = parts[0].lower() + "".join(p[0].upper() + p[1:] for p in parts[1:])
    if not re.match(r"^[a-z][A-Za-z0-9]*$", out):
        raise GenError(f"{name!r} -> {out!r} is not a valid Dart identifier")
    return out


def string_list(node: ast.expr | None) -> list[str]:
    if node is None:
        return []
    if not isinstance(node, ast.List):
        raise GenError(f"expected a list literal, got {ast.dump(node)}")
    out = []
    for el in node.elts:
        if not isinstance(el, ast.Constant) or not isinstance(el.value, str):
            raise GenError(f"expected a string literal, got {ast.dump(el)}")
        out.append(el.value)
    return out


def string_value(node: ast.expr | None) -> str | None:
    if node is None:
        return None
    if not isinstance(node, ast.Constant) or not isinstance(node.value, str):
        raise GenError(f"expected a string literal, got {ast.dump(node)}")
    return node.value


# Every spelling upstream uses for "this message is always fastpass".
ALWAYS_FASTPASS = {"MessageRules.always_true", "lambda **_: True"}


def fastpass_of(node: ast.expr | None) -> str:
    """Reduces `rules=` to one of never, always, conditional.

    Upstream expresses this as MessageRules(fastpass_analyzer=...), sometimes
    as a constant and sometimes as a lambda over the run-time arguments. A
    lambda cannot be reduced here, and must not be flattened to either
    constant: calling it always would bypass the busy gate for commands that
    should respect it, and calling it never would make stopping the shutter
    wait for the encoding it is trying to stop.

    So conditional is carried through as its own value, and the typed wrapper
    that knows the argument decides. The table refuses to guess rather than
    picking the answer that is wrong half the time.
    """
    if node is None:
        return "never"
    if not isinstance(node, ast.Call):
        raise GenError(f"expected MessageRules(...), got {ast.dump(node)}")
    for kw in node.keywords:
        if kw.arg != "fastpass_analyzer":
            continue
        src = ast.unparse(kw.value)
        if src in ALWAYS_FASTPASS:
            return "always"
        if isinstance(kw.value, ast.Lambda):
            return "conditional"
        raise GenError(f"unrecognized fastpass analyzer {src!r}")
    return "never"


class Message:
    def __init__(self, name, method, response, endpoint, components,
                 arguments, body_args, identifier, fastpass, transforms):
        self.name = name
        self.method = method
        self.response = response
        self.endpoint = endpoint
        self.components = components
        self.arguments = arguments
        self.body_args = body_args
        self.identifier = identifier
        self.fastpass = fastpass
        # True when the upstream method body rewrites kwargs. Recorded so the
        # hand-written wrapper for it is a deliberate choice rather than an
        # omission nobody noticed.
        self.transforms = transforms

    @property
    def dart_name(self) -> str:
        return to_lower_camel(self.name)


def returns_a_dict(fn: ast.AsyncFunctionDef) -> bool:
    return any(
        isinstance(n, ast.Return) and isinstance(n.value, ast.Dict)
        for n in ast.walk(fn)
    )


def parse(path: pathlib.Path) -> list[Message]:
    tree = ast.parse(path.read_text(), filename=str(path))

    classes = [n for n in tree.body if isinstance(n, ast.ClassDef)]
    if not classes:
        raise GenError(f"{path.name}: no class definitions")

    out: list[Message] = []
    for cls in classes:
        for fn in cls.body:
            if not isinstance(fn, ast.AsyncFunctionDef):
                continue
            for dec in fn.decorator_list:
                if not isinstance(dec, ast.Call):
                    continue
                target = dec.func
                if not isinstance(target, ast.Name):
                    continue
                if target.id not in DECORATORS:
                    continue

                method, response = DECORATORS[target.id]
                kw = {k.arg: k.value for k in dec.keywords if k.arg}
                endpoint = string_value(kw.get("endpoint"))
                if endpoint is None:
                    raise GenError(f"{fn.name}: no endpoint")

                out.append(Message(
                    name=fn.name,
                    method=method,
                    response=response,
                    endpoint=endpoint,
                    components=string_list(kw.get("components")),
                    arguments=string_list(kw.get("arguments")),
                    body_args=string_list(kw.get("body_args")),
                    identifier=string_value(kw.get("identifier")),
                    fastpass=fastpass_of(kw.get("rules")),
                    transforms=returns_a_dict(fn),
                ))

    if not out:
        raise GenError(f"{path.name}: no HTTP messages found")

    names = [m.dart_name for m in out]
    dupes = {n for n in names if names.count(n) > 1}
    if dupes:
        raise GenError(f"duplicate message names: {sorted(dupes)}")
    return out


def dart_string(s: str) -> str:
    return "'" + s.replace("\\", "\\\\").replace("'", r"\'") + "'"


def dart_list(items: list[str]) -> str:
    # No `const` keyword: these sit inside a const map, where it is implied
    # and the analyzer flags it as redundant under --fatal-infos.
    return "[" + ", ".join(dart_string(i) for i in items) + "]"


def emit(messages: list[Message]) -> str:
    lines = [
        "// SPDX-License-Identifier: MIT",
        "// Copyright (c) 2026 Joel Winarske",
        "//",
        "// GENERATED FILE — DO NOT EDIT.",
        "//",
        f"// Generated by tool/gen_http_commands.py from tool/upstream/{SOURCE}.",
        "// Regenerate with:  tool/gen_http_commands.py",
        "//",
        "// Derived from the Open GoPro Python SDK, which is MIT licensed:",
        f"//   {GOPRO_COPYRIGHT}",
        "// The full notice is in tool/upstream/LICENSE.gopro and must ship with any",
        "// distribution of this package.",
        "",
        "import '../http/http_message.dart';",
        "",
        "/// Every Open GoPro HTTP message, keyed by its upstream method name.",
        "///",
        "/// The table is data only. Turning a caller's arguments into the",
        "/// `components` and `arguments` below is the job of the typed wrappers in",
        "/// `lib/src/http/commands.dart`, because roughly a third of the upstream",
        "/// methods rename or reshape their parameters on the way through and no",
        "/// table can express that.",
        "const Map<String, HttpMessage> kHttpMessages = {",
    ]

    for m in sorted(messages, key=lambda x: x.dart_name):
        lines.append(f"  {dart_string(m.name)}: HttpMessage(")
        lines.append(f"    name: {dart_string(m.name)},")
        lines.append(f"    endpoint: {dart_string(m.endpoint)},")
        lines.append(f"    method: HttpMethod.{m.method},")
        lines.append(f"    response: HttpResponseKind.{m.response},")
        if m.components:
            lines.append(f"    components: {dart_list(m.components)},")
        if m.arguments:
            lines.append(f"    arguments: {dart_list(m.arguments)},")
        if m.body_args:
            lines.append(f"    bodyArguments: {dart_list(m.body_args)},")
        if m.fastpass != "never":
            lines.append(f"    fastpass: HttpFastpass.{m.fastpass},")
        lines.append("  ),")

    lines.append("};")
    lines.append("")
    return "\n".join(lines)


def dart_format(text: str) -> str:
    """Runs the emitted source through `dart format`.

    Without this the committed file is reformatted by `dart format` in CI and
    --check then reports drift forever, because the generator and the formatter
    disagree about the same content.
    """
    dart = shutil.which("dart")
    if dart is None:
        raise GenError(
            "dart not found on PATH. The generated source is formatted, so "
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


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--upstream", type=pathlib.Path,
                    default=pathlib.Path(__file__).parent / "upstream")
    ap.add_argument("--out", type=pathlib.Path,
                    default=pathlib.Path(__file__).parent.parent
                    / "lib" / "src" / "generated")
    ap.add_argument("--check", action="store_true",
                    help="verify the generated file is up to date")
    args = ap.parse_args()

    path = args.upstream / SOURCE
    if not path.exists():
        print(f"missing upstream source: {path}", file=sys.stderr)
        return 2

    try:
        messages = parse(path)
        text = dart_format(emit(messages))
    except GenError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1

    target = args.out / TARGET
    if args.check:
        if not target.exists() or target.read_text() != text:
            print(f"stale generated file: {target}", file=sys.stderr)
            print("run tool/gen_http_commands.py", file=sys.stderr)
            return 1
        print("generated file up to date")
        return 0

    args.out.mkdir(parents=True, exist_ok=True)
    target.write_text(text)
    transforms = sum(1 for m in messages if m.transforms)
    fastpass = sum(1 for m in messages if m.fastpass != "never")
    print(f"{TARGET}: {len(messages)} messages "
          f"({fastpass} fastpass, {transforms} reshape their arguments)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
