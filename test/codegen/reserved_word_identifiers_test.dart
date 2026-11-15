import 'dart:async';
import 'dart:typed_data';

import 'package:spacetimedb_sdk/codegen.dart';
import 'package:test/test.dart';

import '../generated/reducer_args.dart';
import '../generated/reducers.dart';
import '../generated/stage.dart';
import '../mocks/mock_connection.dart';

void main() {
  group('Generated code for Dart reserved-word names', () {
    test('a row whose column is `class` round-trips through BSATN', () {
      final stage = Stage(id: 7, class_: 'lab');

      final encoder = BsatnEncoder();
      stage.encodeBsatn(encoder);
      final decoded = Stage.decodeBsatn(BsatnDecoder(encoder.toBytes()));

      expect(decoded, stage);
      expect(decoded.class_, 'lab');
    });

    test('a row round-trips through JSON under the unescaped key', () {
      final stage = Stage(id: 7, class_: 'lab');

      final json = stage.toJson();

      expect(json, {'id': 7, 'class': 'lab'});
      expect(Stage.fromJson(json), stage);
    });

    test(
      'the args decoder of a reducer whose parameter is `new` round-trips',
      () {
        final encoder = BsatnEncoder()
          ..writeU32(7)
          ..writeString('lab');

        final args = const RenameStageArgsDecoder().decode(
          BsatnDecoder(encoder.toBytes()),
        );

        expect(args.stageId, 7);
        expect(args.new_, 'lab');
      },
    );

    test(
      'calling a reducer whose parameter is `new` sends its encoded args',
      () async {
        final mockConnection = MockConnection();
        final subscriptionManager = SubscriptionManager(mockConnection);
        addTearDown(subscriptionManager.dispose);
        final reducers = Reducers(
          subscriptionManager.reducers,
          ReducerEmitter(),
        );
        final expectedArgs = BsatnEncoder()
          ..writeU32(7)
          ..writeString('lab');

        final call = reducers.renameStage(stageId: 7, new_: 'lab');
        unawaited(call.then((_) {}, onError: (Object _) {}));

        expect(
          _endsWith(mockConnection.sentMessages.last, expectedArgs.toBytes()),
          isTrue,
        );
      },
    );
  });
}

bool _endsWith(Uint8List message, Uint8List suffix) {
  if (suffix.length > message.length) return false;
  final start = message.length - suffix.length;
  for (var i = 0; i < suffix.length; i++) {
    if (message[start + i] != suffix[i]) return false;
  }
  return true;
}
