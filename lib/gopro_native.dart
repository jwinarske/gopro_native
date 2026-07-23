// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Joel Winarske
/// Linux-first GoPro camera discovery over USB via libusb.
///
/// Discovery is enumerate-only: the camera's CDC-NCM interface is never
/// claimed, because claiming would detach `cdc_ncm` and destroy the very
/// network transport the control API rides on.
library gopro_native;

export 'src/ble_transport.dart'
    show CameraLink, GoProBleCamera, GoProBleException, GoProBleTransport;
export 'src/cohn/cohn_client.dart' show CohnClient, CohnException;
export 'src/cohn/cohn_http.dart' show CohnHttp, pinnedClient;
export 'src/cohn/credentials.dart'
    show CohnCredentials, CohnCredentialStore, FileCredentialStore;
export 'src/discovery.dart' show GoProDiscovery;
export 'src/generated/streaming.dart';
export 'src/streaming/livestream.dart'
    show LivestreamClient, LivestreamException;
export 'src/streaming/webcam.dart'
    show WebcamClient, WebcamException, WebcamReply;
export 'src/wifi/access_point.dart' show GoProAccessPoint;
export 'src/wifi/wifi_controller.dart'
    show
        ApCredentials,
        ManualWifiController,
        NmcliWifiController,
        WifiController,
        WifiJoinException;
export 'src/ffi/ble_codec.dart'
    show
        BleChannel,
        BleFrameError,
        BleOutcome,
        BlePriority,
        BlePush,
        BleResponse;
export 'src/ffi/link_types.dart' show LinkAction, LinkState, StallReason;
export 'src/ffi/types.dart' show GoProCamera, Readiness, SerialSource;
export 'src/http/commands.dart' show GoProCommands;
export 'src/http/gopro_http.dart'
    show GoProHttp, GoProHttpException, GoProStalledException;
export 'src/http/http_message.dart'
    show HttpFastpass, HttpMessage, HttpMethod, HttpResponseKind;

// Generated from the Open GoPro Python SDK — see tool/gen_constants.py.
export 'src/generated/constants.dart';
export 'src/generated/settings.dart';
export 'src/generated/statuses.dart';
