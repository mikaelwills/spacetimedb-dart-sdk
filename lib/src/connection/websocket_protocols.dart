import 'package:spacetimedb_sdk/src/utils/sdk_logger.dart';

const String kV2WsProtocol = 'v2.bsatn.spacetimedb';
const String kV3WsProtocol = 'v3.bsatn.spacetimedb';

const List<String> kPreferredWsProtocols = [kV3WsProtocol, kV2WsProtocol];

enum NegotiatedWsProtocol { v2, v3 }

NegotiatedWsProtocol normalizeWsProtocol(String? protocol) {
  if (protocol == kV3WsProtocol) return NegotiatedWsProtocol.v3;
  if (protocol == null || protocol.isEmpty || protocol == kV2WsProtocol) {
    return NegotiatedWsProtocol.v2;
  }
  SdkLogger.w(
    'Unexpected negotiated WebSocket protocol "$protocol"; falling back to v2',
  );
  return NegotiatedWsProtocol.v2;
}
