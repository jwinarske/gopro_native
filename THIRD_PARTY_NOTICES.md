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
tool/upstream/streaming.py
tool/upstream/uuids.py
tool/upstream/LICENSE.gopro
```

Derived from those files by `tool/gen_constants.py`:

```
lib/src/generated/settings.dart
lib/src/generated/statuses.dart
lib/src/generated/constants.dart
lib/src/generated/streaming.dart
```

The generated Dart files are a derivative work: the enumerator names and
integer values are GoPro's. They reproduce the copyright notice in their
headers, as MIT requires, and the full notice is in `tool/upstream/LICENSE.gopro`.

The upstream sources are vendored rather than fetched so generation is
reproducible and the provenance of the generated files is auditable.

SPDX-License-Identifier: MIT
Copyright (c) 2021-2024 GoPro, Inc.

---

## Open GoPro — HTTP message definitions

Redistributed verbatim:

```
tool/upstream/http_commands.py
```

Derived from it by `tool/gen_http_commands.py`:

```
lib/src/generated/http_commands.dart
```

From the same Open GoPro Python SDK, under the same MIT grant recorded in
`tool/upstream/LICENSE.gopro`. The generated file reproduces the copyright
notice in its header.

SPDX-License-Identifier: MIT
Copyright (c) 2021-2024 GoPro, Inc.

---

## Open GoPro — protobuf definitions

Redistributed verbatim:

```
tool/upstream/proto/camera_control.proto
tool/upstream/proto/cohn.proto
tool/upstream/proto/live_streaming.proto
tool/upstream/proto/media.proto
tool/upstream/proto/network_management.proto
tool/upstream/proto/preset_status.proto
tool/upstream/proto/request_get_camera_capabilities.proto
tool/upstream/proto/request_get_preset_status.proto
tool/upstream/proto/response_generic.proto
tool/upstream/proto/set_camera_control_status.proto
tool/upstream/proto/turbo_transfer.proto
```

Derived from them by `tool/gen_proto.py`:

```
lib/src/generated/proto/*.dart      (33 files)
lib/proto/*.dart                    (6 feature libraries)
```

### Provenance

The `.proto` sources are taken from the `protobuf/` directory of the Open
GoPro repository, which is the canonical form. That directory carries no
LICENSE file of its own, so the grant was established by checking the
definitions against a distribution that does carry one.

All 11 files are byte-equivalent in structure to the descriptors GoPro ships
in `demos/python/sdk_wireless_camera_control/`, whose MIT LICENSE is vendored
here as `tool/upstream/LICENSE.gopro` and is the same grant covering the
camera constants above. The comparison was mechanical — every message, field
number, field type, label, enum and enum value, 459 declarations in total —
and each of the 11 matched exactly.

The same definitions also appear as `.proto` sources under
`demos/kotlin/kmp_sdk/protobuf/`, which does carry its own MIT LICENSE, but
that copy is an older snapshot: `preset_status.proto` alone differs by 42
lines. The canonical files were preferred over the more conveniently licensed
stale ones, and the grant established by the check above.

The generated Dart files are a derivative work: the message names, field
numbers and enum values are GoPro's. They reproduce the copyright notice in
their headers, as MIT requires.

SPDX-License-Identifier: MIT
Copyright (c) 2021-2024 GoPro, Inc.

---

## protobuf (Dart runtime)

`package:protobuf`, a runtime dependency of the generated code. Published by
the Dart protobuf authors under the BSD 3-Clause license. Not redistributed
here; resolved by `dart pub get` and carrying its own notice in the pub cache.

SPDX-License-Identifier: BSD-3-Clause

---

## Trademarks

GoPro, HERO, and MAX are trademarks of GoPro, Inc. This project is not
affiliated with, endorsed by, or sponsored by GoPro, Inc. The Open GoPro API is
published by GoPro, Inc. under the MIT license; the MIT grant covers copyright
only and conveys no trademark rights.
