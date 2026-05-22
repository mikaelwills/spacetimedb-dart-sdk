library spacetimedb_sdk;

export 'package:fixnum/fixnum.dart' show Int64;

// Exceptions
export 'src/exceptions.dart';

// Connection
export 'src/connection/spacetimedb_connection.dart' show SpacetimeDbConnection;
export 'src/connection/connection_state.dart';
export 'src/connection/connection_quality.dart';
export 'src/connection/connection_config.dart';
export 'src/connection/websocket_protocols.dart'
    show NegotiatedWsProtocol, kV2WsProtocol, kV3WsProtocol;

// Cache
export 'src/cache/table_cache.dart';

// Utilities
export 'src/utils/value_listenable_extensions.dart';

// Events
export 'src/events/event.dart';
export 'src/events/event_context.dart';
export 'src/events/table_event.dart';
export 'src/events/transaction_batch.dart';

// Reducers (consumer-facing)
export 'src/reducers/transaction_result.dart';
export 'src/messages/update_status.dart';

// Authentication
export 'src/auth/auth_token_store.dart';
export 'src/auth/in_memory_token_store.dart';
export 'src/auth/oidc_helper.dart';
export 'src/auth/identity.dart';

// Offline support (consumer-facing)
export 'src/offline/offline_storage.dart';
export 'src/offline/optimistic_change.dart';
export 'src/offline/sync_state.dart';
export 'src/offline/impl/json_file_storage.dart';
