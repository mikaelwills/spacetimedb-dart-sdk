import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';

import '../helpers/integration_test_helper.dart';
import '../generated/client.dart';

void main() {
  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);

  test(
    'a queuePolicy passed to the generated create() is actually threaded into '
    'the SubscriptionManager and enforced (not silently replaced by the default)',
    timeout: const Timeout(Duration(seconds: 60)),
    () async {
      final client = await SpacetimeDbClient.create(
        host: 'localhost:3000',
        database: 'notesdb',
        offlineStorage: InMemoryOfflineStorage(),
        queuePolicy: const OfflineQueuePolicy(
          maxQueueLength: 1,
          overflow: OverflowStrategy.rejectNew,
        ),
      );
      addTearDown(() async => client.disconnect());

      await client.reducers.createNote(title: 'a', content: 'a');

      expect(
        () => client.reducers.createNote(title: 'b', content: 'b'),
        throwsA(isA<SpacetimeDbQueueFullException>()),
        reason:
            'with maxQueueLength:1 the second offline enqueue must be rejected; '
            'if it succeeds the policy was dropped by create() and the default '
            'unbounded policy is in effect',
      );
    },
  );
}
