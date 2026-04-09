library spacetimedb_dart_sdk;

// Re-export Int64 from fixnum for web-compatible 64-bit integers
export 'package:fixnum/fixnum.dart' show Int64;

// Core connection
export 'src/connection/spacetimedb_connection.dart';
export 'src/connection/connection_state.dart';
export 'src/connection/connection_quality.dart';
export 'src/connection/connection_config.dart';
export 'src/subscription/subscription_manager.dart';

// BSATN encoding/decoding
export 'src/codec/bsatn_encoder.dart';
export 'src/codec/bsatn_decoder.dart';

// Client cache
export 'src/cache/client_cache.dart';
export 'src/cache/table_cache.dart';
export 'src/cache/row_decoder.dart';

// Messages
export 'src/messages/server_messages.dart';
export 'src/messages/client_messages.dart';
export 'src/messages/shared_types.dart';
export 'src/messages/message_decoder.dart';
export 'src/messages/reducer_info.dart';
export 'src/messages/update_status.dart';

// Reducers
export 'src/reducers/reducer_caller.dart';
export 'src/reducers/reducer_def.dart';
export 'src/reducers/mutation_handler.dart';
export 'src/reducers/reducer_arg_decoder.dart';
export 'src/reducers/reducer_registry.dart';
export 'src/reducers/reducer_emitter.dart';
export 'src/reducers/transaction_result.dart';

// Events
export 'src/events/event.dart';
export 'src/events/event_context.dart';
export 'src/events/table_event.dart';

// Authentication
export 'src/auth/auth_token_store.dart';
export 'src/auth/in_memory_token_store.dart';
export 'src/auth/oidc_helper.dart';
export 'src/auth/identity.dart';

// Offline support
export 'src/offline/offline_storage.dart';
export 'src/offline/pending_mutation.dart';
export 'src/offline/sync_state.dart';
export 'src/offline/impl/json_file_storage.dart';
export 'src/offline/mutation_syncer.dart';
export 'src/offline/optimistic_state_manager.dart';

// Utils
export 'src/utils/sdk_logger.dart';
export 'src/utils/value_notifier.dart';
