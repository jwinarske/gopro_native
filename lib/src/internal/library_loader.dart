// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
// library_loader.dart — DynamicLibrary.open() resolution for libgopro_nc.so.
//
// Search order (designed to work across the standard Flutter Linux embedder,
// plain `dart run` / `dart test`, and alternative embedders such as
// ivi-homescreen where `Platform.resolvedExecutable` points at a system
// binary like `/usr/bin/homescreen` and LD_LIBRARY_PATH is not honored):
//
//   1. `GOPRO_NC_LIB` environment variable override.
//   2. Bare `dlopen("libgopro_nc.so")` — uses the system loader, which
//      respects the embedder's RPATH/RUNPATH (the standard Flutter Linux
//      runner sets `$ORIGIN/lib`) and `/etc/ld.so.cache`.
//   3. Sibling-of-libapp lookup via `/proc/self/maps`. Flutter embedders
//      mmap the AOT snapshot `libapp.so` from the bundle's `lib/` dir; we
//      look for `libgopro_nc.so` next to it. Fixes ivi-homescreen.
//   4. Newest artifact under `.dart_tool/hooks_runner/shared/gopro_native/`
//      produced by `hook/build.dart`, so plain `dart run` / `dart test`
//      pick up the hook's build output automatically.
//   5. Bundle-relative paths derived from `Platform.script`.
//   6. Executable- and CWD-relative paths.
//   7. Each `LD_LIBRARY_PATH` directory, opened by absolute path.
//
// Patterned after
// https://github.com/meta-flutter/appstream_dart/blob/main/lib/src/bindings.dart

import 'dart:ffi';
import 'dart:io';

const _libName = 'libgopro_nc.so';

DynamicLibrary loadGoProNc() {
  // 1. Environment variable override.
  final envPath = Platform.environment['GOPRO_NC_LIB'];
  if (envPath != null && envPath.isNotEmpty) {
    return DynamicLibrary.open(envPath);
  }

  final errors = <String>[];

  // 2. System loader first.
  try {
    return DynamicLibrary.open(_libName);
  } catch (e) {
    errors.add('dlopen($_libName): $e');
  }

  // 3. Sibling-of-libapp.so via /proc/self/maps (fixes ivi-homescreen).
  final fromMaps = _findSiblingOfLoadedLib(_libName);
  if (fromMaps != null) {
    try {
      return DynamicLibrary.open(fromMaps);
    } catch (e) {
      errors.add('$fromMaps: $e');
    }
  }

  final candidates = <String>[];

  // 4. .dart_tool/hooks_runner artifact for `dart run` / `dart test`.
  final fromHook = _findInHooksRunner(_libName);
  if (fromHook != null) candidates.add(fromHook);

  // 5. Bundle-relative paths derived from Platform.script.
  try {
    final scriptDir = File(Platform.script.toFilePath()).parent.path;
    candidates.addAll([
      '$scriptDir/lib/$_libName',
      '$scriptDir/../lib/$_libName',
      '$scriptDir/../../lib/$_libName',
      '$scriptDir/../../../lib/$_libName',
    ]);
  } catch (_) {}

  // 6. Executable- and CWD-relative paths.
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  candidates.addAll([
    '$exeDir/lib/$_libName',
    '$exeDir/$_libName',
    '${Directory.current.path}/lib/$_libName',
    '${Directory.current.path}/build/$_libName',
    '${Directory.current.path}/native/build/$_libName',
  ]);

  // 7. LD_LIBRARY_PATH directories opened by absolute path.
  final ldPath = Platform.environment['LD_LIBRARY_PATH'] ?? '';
  for (final dir in ldPath.split(':')) {
    if (dir.isNotEmpty) candidates.add('$dir/$_libName');
  }

  for (final path in candidates) {
    final file = File(path);
    if (file.existsSync()) {
      try {
        return DynamicLibrary.open(file.absolute.path);
      } catch (e) {
        errors.add('${file.absolute.path}: $e');
      }
    }
  }

  throw StateError(
    'Failed to load $_libName. Searched:\n'
    '  dlopen($_libName) via system loader\n'
    '${candidates.map((p) => '  $p (${File(p).existsSync() ? "exists" : "not found"})').join('\n')}\n'
    'Errors:\n${errors.join('\n')}\n'
    'Platform.resolvedExecutable=${Platform.resolvedExecutable}\n'
    'Platform.script=${Platform.script}\n'
    'Directory.current=${Directory.current.path}\n'
    'LD_LIBRARY_PATH=${Platform.environment['LD_LIBRARY_PATH'] ?? '(not set)'}\n'
    'Set GOPRO_NC_LIB=/path/to/libgopro_nc.so to override.',
  );
}

/// Walk up from CWD looking for the newest shared library produced by the
/// `package:hooks` build runner, so plain `dart run` / `dart test` pick up
/// the artifact built by `hook/build.dart` automatically.
String? _findInHooksRunner(String libName) {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    final root = Directory(
      '${dir.path}/.dart_tool/hooks_runner/shared/gopro_native/build',
    );
    if (root.existsSync()) {
      File? newest;
      var newestTime = DateTime.fromMillisecondsSinceEpoch(0);
      for (final entity in root.listSync(recursive: true)) {
        if (entity is File && entity.path.endsWith('/$libName')) {
          final mtime = entity.statSync().modified;
          if (mtime.isAfter(newestTime)) {
            newest = entity;
            newestTime = mtime;
          }
        }
      }
      if (newest != null) return newest.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

/// Walk `/proc/self/maps` to find a directory that already has a
/// Flutter-bundled `.so` loaded (libapp.so, libflutter_*.so, or any library
/// mapped from a path ending in `/lib/`), and return `<dir>/<libName>` if
/// it exists. Fixes loading on embedders like ivi-homescreen where the
/// embedder binary lives outside the bundle and LD_LIBRARY_PATH is not
/// used to find bundled libraries.
String? _findSiblingOfLoadedLib(String libName) {
  try {
    final maps = File('/proc/self/maps');
    if (!maps.existsSync()) return null;

    final seen = <String>{};
    final preferred = <String>[];
    final fallback = <String>[];

    for (final line in maps.readAsLinesSync()) {
      final lastSpace = line.lastIndexOf(' ');
      if (lastSpace < 0) continue;
      final path = line.substring(lastSpace + 1);
      if (!path.startsWith('/')) continue;

      final slash = path.lastIndexOf('/');
      if (slash <= 0) continue;
      final dir = path.substring(0, slash);
      if (!seen.add(dir)) continue;

      final base = path.substring(slash + 1);
      if (dir.endsWith('/lib') ||
          base == 'libapp.so' ||
          base.startsWith('libflutter_')) {
        preferred.add(dir);
      } else {
        fallback.add(dir);
      }
    }

    for (final dir in [...preferred, ...fallback]) {
      final candidate = '$dir/$libName';
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  } catch (_) {
    return null;
  }
}
