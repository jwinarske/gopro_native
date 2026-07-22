// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
// Native assets build hook for gopro_native.
//
// Drives the project's CMake build to compile libgopro_nc.so, then declares
// the resulting shared library as a CodeAsset under the asset id
// `package:gopro_native/src/ffi/gopro_native_asset.dart`. Flutter apps bundle
// the .so automatically; `dart run` / `dart test` pick it up via the
// fallback loader in `lib/src/internal/library_loader.dart`.
//
// Patterned after https://github.com/meta-flutter/appstream_dart/blob/main/hook/build.dart

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    if (Platform.environment.containsKey('SKIP_NATIVE_BUILD')) {
      stderr.writeln('SKIP_NATIVE_BUILD set — skipping native build.');
      return;
    }

    final pkgRoot = input.packageRoot.toFilePath();
    final nativeRoot = '${pkgRoot}native';
    final buildDir = input.outputDirectory.resolve('cmake/').toFilePath();

    await Directory(buildDir).create(recursive: true);

    final hasNinja = await _which('ninja');

    // Reconfigure when the cache is missing OR older than CMakeLists.txt.
    //
    // bluez_native's hook only checks for the cache's existence. That leaves a
    // stale-cache hole: edit CMakeLists.txt and the hook rebuilds without ever
    // reconfiguring, so new sources or link options are silently ignored and
    // the failure looks like "my change did nothing".
    final cache = File('${buildDir}CMakeCache.txt');
    final cmakeLists = File('$nativeRoot/CMakeLists.txt');
    final needsConfigure =
        !cache.existsSync() ||
        (cmakeLists.existsSync() &&
            cmakeLists.lastModifiedSync().isAfter(cache.lastModifiedSync()));

    if (needsConfigure) {
      await _run('cmake', [
        '-S',
        nativeRoot,
        '-B',
        buildDir,
        '-DCMAKE_BUILD_TYPE=Release',
        '-DBUILD_TESTING=OFF',
        '-DGOPRO_HOOK_BUILD=ON',
        if (hasNinja) ...['-G', 'Ninja'],
      ]);
    }

    await _run('cmake', ['--build', buildDir, '--parallel']);

    final libFile = File('${buildDir}libgopro_nc.so');
    if (!libFile.existsSync()) {
      throw StateError('libgopro_nc.so not found at ${libFile.path}');
    }

    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'src/ffi/gopro_native_asset.dart',
        linkMode: DynamicLoadingBundled(),
        file: libFile.uri,
      ),
    );

    // Re-run the hook whenever any C/C++ source or CMake file changes.
    for (final dir in ['src', 'include']) {
      final d = Directory('$nativeRoot/$dir');
      if (!d.existsSync()) continue;
      for (final entity in d.listSync(recursive: true)) {
        if (entity is! File) continue;
        final p = entity.path;
        if (p.endsWith('.cpp') ||
            p.endsWith('.cc') ||
            p.endsWith('.c') ||
            p.endsWith('.hpp') ||
            p.endsWith('.h')) {
          output.dependencies.add(entity.uri);
        }
      }
    }
    output.dependencies.add(Uri.file('$nativeRoot/CMakeLists.txt'));
    output.dependencies.add(Uri.file('$nativeRoot/gopro_nc.map'));

    stderr.writeln('libgopro_nc built: ${libFile.path}');
  });
}

Future<void> _run(String exe, List<String> args) async {
  final p = await Process.start(exe, args, mode: ProcessStartMode.inheritStdio);
  final code = await p.exitCode;
  if (code != 0) {
    throw ProcessException(exe, args, 'exit code $code', code);
  }
}

Future<bool> _which(String exe) async {
  final r = await Process.run('which', [exe]);
  return r.exitCode == 0;
}
