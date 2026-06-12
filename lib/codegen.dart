library spacetimedb_sdk.codegen;

export 'spacetimedb_sdk.dart';

// BSATN encoding/decoding
export 'src/codec/bsatn_encoder.dart';
export 'src/codec/bsatn_decoder.dart';

// Cache internals needed by generated client
export 'src/cache/client_cache.dart';
export 'src/cache/row_decoder.dart';

// Subscription management
export 'src/subscription/subscription_manager.dart';

// Reducers
export 'src/reducers/reducer_caller.dart';
export 'src/reducers/reducer_def.dart';
export 'src/reducers/reducer_arg_decoder.dart';
export 'src/reducers/reducer_registry.dart';
export 'src/reducers/reducer_emitter.dart';
export 'src/reducers/mutation_handler.dart';

// Offline internals needed by generated client
export 'src/offline/mutation_syncer.dart';
export 'src/offline/pending_mutation.dart';
export 'src/offline/offline_queue_policy.dart';
export 'src/offline/optimistic_state_manager.dart';
