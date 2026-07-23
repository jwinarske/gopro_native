// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
//
// gopro_http.dart — the Open GoPro HTTP transport.
//
// One dispatcher over the generated message table. Built on dart:io's
// HttpClient rather than package:http because downloads have to stream to
// disk and need a timeout that does not apply to the transfer as a whole.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'http_message.dart';

/// The camera answered, but not with success.
class GoProHttpException implements Exception {
  const GoProHttpException(this.message, this.uri, this.statusCode, this.body);

  final String message;
  final Uri uri;
  final int statusCode;

  /// The response body, truncated. Cameras return a JSON error document for
  /// most failures and it usually says which argument was wrong.
  final String body;

  @override
  String toString() =>
      'GoProHttpException($statusCode ${message.isEmpty ? '' : '$message '}'
      'for $uri)${body.isEmpty ? '' : '\n$body'}';
}

/// A transfer stopped making progress.
///
/// Distinct from a timeout on the request as a whole, which is not a useful
/// notion for a download: a 4 GB video legitimately takes minutes, while a
/// stream that has delivered nothing for 30 s is stuck no matter how long the
/// file is.
class GoProStalledException implements Exception {
  const GoProStalledException(this.uri, this.idle, this.received);

  final Uri uri;
  final Duration idle;
  final int received;

  @override
  String toString() =>
      'GoProStalledException(no data for ${idle.inSeconds}s after '
      '$received bytes from $uri)';
}

/// Speaks the Open GoPro HTTP API to one camera.
class GoProHttp {
  GoProHttp(
    this.base, {
    this.requestTimeout = const Duration(seconds: 5),
    this.stallTimeout = const Duration(seconds: 30),
    HttpClient? client,
  }) : _client = client ?? HttpClient() {
    // Applies to establishing the connection, not to the exchange. Downloads
    // must not inherit a deadline from it.
    _client.connectionTimeout = const Duration(seconds: 5);
  }

  /// Root of the camera's HTTP API, e.g. `http://172.21.123.51:8080/`.
  final Uri base;

  /// Deadline for a JSON exchange, start to finish.
  ///
  /// Upstream hardcodes 5 s and applies it to media downloads too. That only
  /// works there because `requests` reads it as a per-read timeout; a whole
  /// request deadline of 5 s would fail every video transfer. Downloads use
  /// [stallTimeout] instead.
  final Duration requestTimeout;

  /// How long a download may deliver nothing before it is abandoned.
  final Duration stallTimeout;

  final HttpClient _client;
  var _closed = false;

  void close() {
    if (_closed) return;
    _closed = true;
    _client.close(force: true);
  }

  /// Sends [message] and decodes the JSON reply.
  ///
  /// Returns an empty map when the camera answers with no body, which several
  /// commands do on success.
  Future<Map<String, Object?>> json(
    HttpMessage message, {
    Map<String, Object?> values = const {},
    Duration? timeout,
  }) async {
    if (message.response != HttpResponseKind.json) {
      throw ArgumentError('${message.name} does not return JSON');
    }
    final uri = message.url(base, values);

    final body = await _exchange(uri, message, values, timeout);
    if (body.isEmpty) return const {};

    final decoded = jsonDecode(body);
    if (decoded is Map<String, Object?>) return decoded;
    // A handful of endpoints answer with a bare value rather than an object.
    // Wrapping keeps one return type instead of pushing the distinction onto
    // every caller.
    return {'value': decoded};
  }

  Future<String> _exchange(
    Uri uri,
    HttpMessage message,
    Map<String, Object?> values,
    Duration? timeout,
  ) async {
    final deadline = timeout ?? requestTimeout;

    Future<String> run() async {
      final request = message.method == HttpMethod.put
          ? await _client.putUrl(uri)
          : await _client.getUrl(uri);

      if (message.method == HttpMethod.put) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(message.body(values)));
      }

      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw GoProHttpException(
          response.reasonPhrase,
          uri,
          response.statusCode,
          _truncate(text),
        );
      }
      return text;
    }

    return deadline == Duration.zero ? run() : run().timeout(deadline);
  }

  /// Streams a binary response to [destination] and returns it.
  ///
  /// The bytes go straight to disk. Buffering them would work for a thumbnail
  /// and fail for the video it belongs to.
  ///
  /// [onProgress] is called with the bytes received so far and the total when
  /// the camera declares one, which it does not always.
  Future<File> download(
    HttpMessage message,
    File destination, {
    Map<String, Object?> values = const {},
    void Function(int received, int? total)? onProgress,
  }) async {
    if (message.response != HttpResponseKind.binary) {
      throw ArgumentError('${message.name} does not return binary');
    }
    final uri = message.url(base, values);

    final request = await _client.getUrl(uri);
    final response = await request.close();

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final text = await response.transform(utf8.decoder).join();
      throw GoProHttpException(
        response.reasonPhrase,
        uri,
        response.statusCode,
        _truncate(text),
      );
    }

    final total = response.contentLength < 0 ? null : response.contentLength;
    await destination.parent.create(recursive: true);
    final sink = destination.openWrite();

    var received = 0;
    // Reset on every chunk, so the deadline is "nothing is arriving" rather
    // than "this is taking a while".
    Timer? stall;
    final stalled = Completer<void>();
    void arm() {
      stall?.cancel();
      if (stallTimeout == Duration.zero) return;
      stall = Timer(stallTimeout, () {
        if (!stalled.isCompleted) {
          stalled.completeError(
            GoProStalledException(uri, stallTimeout, received),
          );
        }
      });
    }

    arm();
    try {
      final pump = () async {
        await for (final chunk in response) {
          received += chunk.length;
          sink.add(chunk);
          arm();
          onProgress?.call(received, total);
        }
      }();
      await Future.any([pump, stalled.future]);
    } catch (_) {
      stall?.cancel();
      await sink.close();
      // A partial file is worse than none: it looks like a completed download
      // to anything that finds it later.
      if (await destination.exists()) await destination.delete();
      rethrow;
    }

    stall?.cancel();
    await sink.close();

    if (total != null && received != total) {
      if (await destination.exists()) await destination.delete();
      throw GoProHttpException(
        'truncated: $received of $total bytes',
        uri,
        response.statusCode,
        '',
      );
    }
    return destination;
  }

  static String _truncate(String s) =>
      s.length <= 512 ? s.trim() : '${s.substring(0, 512).trim()}…';
}
