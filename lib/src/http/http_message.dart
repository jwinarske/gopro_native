// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
//
// http_message.dart — the shape of one Open GoPro HTTP message.
//
// Upstream declares these as decorators on empty method bodies and builds the
// machinery by introspecting **kwargs at import time. Dart AOT has no runtime
// reflection, so the data comes across as a const table instead
// (lib/src/generated/http_commands.dart) and one dispatcher reads it.

enum HttpMethod { get, put }

/// Whether the camera accepts this message while it is busy.
enum HttpFastpass {
  /// Waits its turn.
  never,

  /// Always accepted while busy.
  always,

  /// Accepted or not depending on the arguments. `set_shutter` is the case:
  /// stopping must not wait for the encoding it is trying to stop, while
  /// starting has no reason to jump the queue.
  ///
  /// The generator refuses to flatten this to either constant, because both
  /// answers are wrong half the time. The typed wrapper decides.
  conditional,
}

/// What comes back. Binary responses stream to disk and never sit in memory:
/// a video can be gigabytes.
enum HttpResponseKind { json, binary }

/// One message: where it goes and what goes with it.
class HttpMessage {
  const HttpMessage({
    required this.name,
    required this.endpoint,
    required this.method,
    required this.response,
    this.components = const [],
    this.arguments = const [],
    this.bodyArguments = const [],
    this.fastpass = HttpFastpass.never,
  });

  /// The upstream method name, which is also this message's key in the table.
  final String name;

  /// Base path, with no leading slash normalization applied — a few upstream
  /// endpoints carry one and most do not, and [url] handles both.
  final String endpoint;

  final HttpMethod method;
  final HttpResponseKind response;

  /// Path segments appended in order: `endpoint/{component}`.
  final List<String> components;

  /// Query parameter names, in upstream's spelling. Several differ from the
  /// name the caller uses — `delete_group` takes a `path` and sends `p` —
  /// which is why the typed wrappers do the mapping rather than the table.
  final List<String> arguments;

  /// Names placed in the JSON body of a PUT.
  final List<String> bodyArguments;

  /// Whether the camera accepts this while busy.
  ///
  /// Carried here for the same reason the BLE queue has priorities: a command
  /// that must go out during an encode cannot wait for it. Stopping the
  /// shutter is the case that matters.
  final HttpFastpass fastpass;

  /// Builds the request URI against [base].
  ///
  /// [values] is keyed by upstream argument name. A null value is omitted
  /// rather than sent as the string "null", which matches upstream and is the
  /// difference between an optional parameter and a wrong one.
  ///
  /// Throws [ArgumentError] if a declared component is missing: a component is
  /// a path segment, so leaving it out silently would produce a URL that
  /// resolves to a different endpoint.
  Uri url(Uri base, [Map<String, Object?> values = const {}]) {
    final segments = <String>[
      ...endpoint.split('/').where((s) => s.isNotEmpty),
    ];
    for (final c in components) {
      final v = values[c];
      if (v == null) {
        throw ArgumentError('$name: missing path component "$c"');
      }
      segments.addAll(v.toString().split('/').where((s) => s.isNotEmpty));
    }

    final query = <String>[];
    for (final a in arguments) {
      final v = values[a];
      if (v != null) query.add('${_encodeQuery(a)}=${_encodeQuery(v)}');
    }

    return base.replace(
      pathSegments: segments,
      query: query.isEmpty ? null : query.join('&'),
    );
  }

  /// Percent-encodes a query argument, leaving `/` alone.
  ///
  /// Media paths are query arguments — `path=100GOPRO/GX010087.MP4` — and the
  /// camera will not accept the slash escaped. MEASURED on a HERO13 Black,
  /// firmware H24.01.02.10.00:
  ///
  ///     path=100GOPRO%2FGX010087.MP4   400 Bad Request, empty body
  ///     path=100GOPRO/GX010087.MP4     200
  ///
  /// RFC 3986 permits `/` in a query component; `Uri.queryParameters` escapes
  /// it anyway, which is why this cannot go through the normal path. Spaces
  /// become `%20` rather than `+`, since the camera parses the raw string
  /// rather than a form body.
  static String _encodeQuery(Object value) =>
      Uri.encodeComponent(value.toString()).replaceAll('%2F', '/');

  /// Builds the JSON body of a PUT, omitting anything not supplied.
  Map<String, Object?> body([Map<String, Object?> values = const {}]) => {
    for (final a in bodyArguments)
      if (values[a] != null) a: values[a],
  };

  @override
  String toString() => 'HttpMessage($name ${method.name} $endpoint)';
}
