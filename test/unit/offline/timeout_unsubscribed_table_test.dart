import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';

import '../../mocks/mock_connection.dart';

class _MapDecoder extends RowDecoder<Map<String, dynamic>> {
  @override
  Map<String, dynamic> decode(BsatnDecoder decoder) => {};

  @override
  dynamic getPrimaryKey(Map<String, dynamic> row) => row['id'];

  @override
  bool get supportsJsonSerialization => true;

  @override
  Map<String, dynamic>? toJson(Map<String, dynamic> row) => row;

  @override
  Map<String, dynamic>? fromJson(Map<String, dynamic> json) => json;
}

void main() {
  group('U2 — does an unsubscribed table degrade landed detection?', () {
    test(
      'landed effect present but table NOT subscribed → outcome is undetectable, '
      'the mutation stays queued (at-least-once holds, re-send risk accepted)',
      () async {
        final connection = MockConnection();
        connection.setStateSilently(const Connected());
        final storage = InMemoryOfflineStorage();
        final cache = ClientCache();
        cache.registerDecoder<Map<String, dynamic>>('note', _MapDecoder());
        final noteTable = cache.getTableByName('note')!;
        noteTable.insertServerOwnedRow({'id': 1, 'content': 'new'});

        expect(
          noteTable.isSubscribed,
          isFalse,
          reason:
              'markSubscribed deliberately NOT called — mirrors the window '
              'right after a reconnect drops subscriptions',
        );

        final optimisticState = OptimisticStateManager(cache);
        final results = <MutationSyncResult>[];
        final syncer = MutationSyncer(
          connection: connection,
          storage: storage,
          optimisticState: optimisticState,
          cache: cache,
          send: (reducerName, args, {requestId}) async {
            throw SpacetimeDbTimeoutException(
              'timed out',
              elapsed: const Duration(seconds: 10),
            );
          },
        );
        final sub = syncer.onMutationSyncResult.listen(results.add);

        await storage.enqueueMutation(
          PendingMutation(
            requestId: 'u1',
            reducerName: 'update_note',
            encodedArgs: Uint8List(0),
            createdAt: DateTime.now(),
            optimisticChanges: [
              OptimisticChange.update(
                'note',
                {'id': 1, 'content': 'old'},
                {'id': 1, 'content': 'new'},
              ),
            ],
          ),
        );

        await syncer.syncPendingMutations();
        await Future<void>.delayed(Duration.zero);
        await sub.cancel();

        expect(
          await storage.getPendingMutations(),
          hasLength(1),
          reason:
              'the !table.isSubscribed gate forces undetectable, so the '
              'genuinely-landed effect is NOT confirmed — it stays queued',
        );
        expect(
          results.where((r) => r.success).map((r) => r.requestId),
          isNot(contains('u1')),
        );
        syncer.cancelRetry();
      },
    );

    test(
      'mirror case: identical state but table IS subscribed → landed, confirmed '
      'and dequeued',
      () async {
        final connection = MockConnection();
        connection.setStateSilently(const Connected());
        final storage = InMemoryOfflineStorage();
        final cache = ClientCache();
        cache.registerDecoder<Map<String, dynamic>>('note', _MapDecoder());
        final noteTable = cache.getTableByName('note')!;
        noteTable.markSubscribed();
        noteTable.insertServerOwnedRow({'id': 1, 'content': 'new'});

        final optimisticState = OptimisticStateManager(cache);
        final results = <MutationSyncResult>[];
        final syncer = MutationSyncer(
          connection: connection,
          storage: storage,
          optimisticState: optimisticState,
          cache: cache,
          send: (reducerName, args, {requestId}) async {
            throw SpacetimeDbTimeoutException(
              'timed out',
              elapsed: const Duration(seconds: 10),
            );
          },
        );
        final sub = syncer.onMutationSyncResult.listen(results.add);

        await storage.enqueueMutation(
          PendingMutation(
            requestId: 'u1',
            reducerName: 'update_note',
            encodedArgs: Uint8List(0),
            createdAt: DateTime.now(),
            optimisticChanges: [
              OptimisticChange.update(
                'note',
                {'id': 1, 'content': 'old'},
                {'id': 1, 'content': 'new'},
              ),
            ],
          ),
        );

        await syncer.syncPendingMutations();
        await Future<void>.delayed(Duration.zero);
        await sub.cancel();

        expect(
          await storage.getPendingMutations(),
          isEmpty,
          reason: 'subscribed + effect present → landed → dequeued',
        );
        expect(
          results.where((r) => r.success).map((r) => r.requestId),
          contains('u1'),
        );
        syncer.cancelRetry();
      },
    );
  });
}
