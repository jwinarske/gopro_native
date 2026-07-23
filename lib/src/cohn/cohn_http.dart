// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
//
// cohn_http.dart — the HTTPS client for a camera on the home network.
//
// COHN presents a self-signed certificate, which HttpClient rejects. The fix
// people reach for first is:
//
//     badCertificateCallback: (cert, host, port) => true
//
// That does not accept the camera's certificate. It accepts every
// certificate, from anything that answers on that address — which on a home
// network is precisely the threat model COHN's certificate exists to address.
// It also fails silently in the direction that looks like success.
//
// The certificate goes into the trust store instead, and nothing else is
// trusted for this client.

import 'dart:convert';
import 'dart:io';

import '../http/gopro_http.dart';
import 'credentials.dart';

/// Builds an [HttpClient] that trusts exactly one certificate.
///
/// [certificate] is the camera's self-signed root, PEM encoded, as returned
/// by `RequestCOHNCert`.
///
/// The returned client has no `badCertificateCallback`. If the camera
/// presents anything other than this certificate the connection fails, which
/// is the entire point: on a home network, the certificate is what
/// distinguishes the camera from whatever else has taken its address.
HttpClient pinnedClient(String certificate) {
  final context = SecurityContext(withTrustedRoots: false)
    ..setTrustedCertificatesBytes(utf8.encode(certificate));
  return HttpClient(context: context);
}

/// A [GoProHttp] pointed at a camera on the home network.
///
/// COHN is HTTPS on port 443 with HTTP Basic auth, unlike the plaintext port
/// 8080 used over USB and the camera's own access point. The command surface
/// above it is identical.
class CohnHttp extends GoProHttp {
  CohnHttp(
    this.credentials, {
    String? host,
    super.requestTimeout,
    super.stallTimeout,
  }) : super(
         // Evaluated before the client, so a missing host is reported as a
         // missing host rather than as whatever the TLS layer says about a
         // certificate it was never going to need.
         _baseUri(credentials, host),
         headers: {'Authorization': credentials.basicAuth.value},
         client: pinnedClient(credentials.certificate),
       );

  final CohnCredentials credentials;

  static Uri _baseUri(CohnCredentials credentials, String? host) {
    final h = host ?? credentials.ipAddress;
    if (h == null) {
      throw ArgumentError(
        'no host: the credentials carry no IP address, so one must be given',
      );
    }
    return Uri.parse('https://$h/');
  }
}
