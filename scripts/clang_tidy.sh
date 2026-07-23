#!/bin/bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Joel Winarske
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

BUILD_DIR="${1:-build}"

if [[ ! -f "${BUILD_DIR}/compile_commands.json" ]]; then
    echo "ERROR: compile_commands.json not found in ${BUILD_DIR}."
    echo "Build first with -DCMAKE_EXPORT_COMPILE_COMMANDS=ON."
    exit 1
fi

CLANG_TIDY="clang-tidy"
command -v "${CLANG_TIDY}" >/dev/null || { echo "ERROR: clang-tidy not found."; exit 1; }
echo "Using: $(command -v "${CLANG_TIDY}")"

# Restrict analysis to this project's own sources.
#
# The vendored Dart API headers and dart_api_dl.c are upstream artifacts that
# must stay byte-identical to the SDK they came from. Without an explicit
# filter, clang-tidy --fix rewrites them: reserved-identifier and
# redundant-void-arg fixes get applied to files that are not ours to change.
# glaze_meta.h is excluded because a binary codec is inherently full of
# pointer arithmetic that the bounds checks flag and cannot repair.
find "${ROOT_DIR}/native/src" "${ROOT_DIR}/native/include" \
    \( -name '*.cpp' -o -name '*.h' \) \
    ! -path '*/internal/*' \
    ! -name 'dart_api.h' \
    ! -name 'dart_api_dl.h' \
    ! -name 'dart_native_api.h' \
    ! -name 'dart_version.h' \
    ! -name 'glaze_meta.h' \
    -print | sort | \
    xargs "${CLANG_TIDY}" -p "${BUILD_DIR}" \
        --header-filter='native/include/(ble_link|ble_protocol|command_queue|query_parser|gopro_bridge|gopro_types|gopro_usb)\.h$' \
        --warnings-as-errors='*'

echo "clang-tidy passed."
