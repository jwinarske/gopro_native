# Third-party notices

This project is MIT licensed (see `LICENSE`). It redistributes the components
below under their own terms. Each retains its original copyright notice in the
files themselves; those notices must not be removed.

---

## Dart SDK — Dart API DL headers and runtime

Redistributed verbatim, unmodified:

```
native/include/dart_api.h
native/include/dart_api_dl.h
native/include/dart_native_api.h
native/include/dart_version.h
native/include/internal/dart_api_dl_impl.h
native/src/dart_api_dl.c
```

These are required to call `Dart_PostCObject_DL` from native code. They carry
`Copyright (c) 2020, the Dart project authors` and are licensed BSD-3-Clause.

**Do not run formatters or linters with `--fix` over these files.** They are
upstream artifacts; local modifications make the vendored copy diverge from the
Dart SDK it must match.

SPDX-License-Identifier: BSD-3-Clause

```
Copyright 2012, the Dart project authors.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:
    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above
      copyright notice, this list of conditions and the following
      disclaimer in the documentation and/or other materials provided
      with the distribution.
    * Neither the name of Google LLC nor the names of its
      contributors may be used to endorse or promote products derived
      from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

---

## Open GoPro Python SDK — camera constants

Redistributed verbatim:

```
tool/upstream/settings.py
tool/upstream/statuses.py
tool/upstream/constants.py
tool/upstream/uuids.py
tool/upstream/LICENSE.gopro
```

Derived from those files by `tool/gen_constants.py`:

```
lib/src/generated/settings.dart
lib/src/generated/statuses.dart
lib/src/generated/constants.dart
```

The generated Dart files are a derivative work: the enumerator names and
integer values are GoPro's. They reproduce the copyright notice in their
headers, as MIT requires, and the full notice is in `tool/upstream/LICENSE.gopro`.

The upstream sources are vendored rather than fetched so generation is
reproducible and the provenance of the generated files is auditable.

SPDX-License-Identifier: MIT
Copyright (c) 2021-2024 GoPro, Inc.

---

## Trademarks

GoPro, HERO, and MAX are trademarks of GoPro, Inc. This project is not
affiliated with, endorsed by, or sponsored by GoPro, Inc. The Open GoPro API is
published by GoPro, Inc. under the MIT license; the MIT grant covers copyright
only and conveys no trademark rights.
