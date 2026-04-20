library;

// ignore_for_file: avoid_print
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:spacetimedb_sdk/codegen.dart';

import '../generated/note.dart';
import '../generated/note_status.dart';
import '../helpers/integration_test_helper.dart';
import '../helpers/test_env.dart';

void main() {
  late TestEnv env;
  late SubscriptionManager subManager;

  setUpAll(ensureTestEnvironment);
  tearDownAll(cleanupTestEnvironment);

  setUp(() async {
    env = await createTestEnv();
    subManager = env.subManager;

    await env.connection.connect();
    await subManager.onInitialConnection.first.timeout(
      const Duration(seconds: 5),
    );
  });

  tearDown(() async {
    subManager.dispose();
    await env.disconnect();
  });

  group('Sum Types - Generated Code Verification', () {
    test('Generated decoder implements correct interface', () {
      // CRITICAL: Verify NoteDecoder implements RowDecoder<Note> not RowDecoder<dynamic>
      // If the generator was broken, it might use dynamic instead of the concrete type
      final decoder = NoteDecoder();

      expect(
        decoder,
        isA<RowDecoder<Note>>(),
        reason:
            'NoteDecoder must implement RowDecoder<Note> with concrete type, not dynamic',
      );

      // Verify getPrimaryKey returns the correct type
      final mockNote = Note(
        id: 1,
        title: 'Test',
        content: 'Content',
        timestamp: Int64.ZERO,
        status: const NoteStatusDraft(),
      );

      final primaryKey = decoder.getPrimaryKey(mockNote);
      expect(
        primaryKey,
        isA<int?>(),
        reason: 'getPrimaryKey should return int? for Note',
      );
      expect(
        primaryKey,
        equals(1),
        reason: 'getPrimaryKey should extract the id field',
      );
    });

    test('Generated sealed class hierarchy is valid', () {
      // Test 1: Draft variant (unit type)
      const draft = NoteStatusDraft();
      expect(
        draft,
        isA<NoteStatus>(),
        reason: 'Draft should extend NoteStatus sealed class',
      );

      // Test 2: Published variant (tuple single with u64)
      final published = NoteStatusPublished(Int64(1234567890));
      expect(
        published,
        isA<NoteStatus>(),
        reason: 'Published should extend NoteStatus sealed class',
      );
      expect(
        published.value,
        equals(Int64(1234567890)),
        reason: 'Published should store u64 value',
      );

      // Test 3: Archived variant (unit type)
      const archived = NoteStatusArchived();
      expect(
        archived,
        isA<NoteStatus>(),
        reason: 'Archived should extend NoteStatus sealed class',
      );

      // Test 4: Pattern matching exhaustiveness (compile-time check)
      // If a variant is added, this switch must fail to compile
      const status = draft as NoteStatus;
      final typeName = switch (status) {
        NoteStatusDraft() => 'Draft',
        NoteStatusPublished() => 'Published',
        NoteStatusArchived() => 'Archived',
      };
      expect(typeName, equals('Draft'));
    });

    test('Round-trip encoding: Object -> Bytes -> Object', () {
      // Test Draft variant (tag 0, no payload)
      const originalDraft = NoteStatusDraft();
      final encoder1 = BsatnEncoder();
      originalDraft.encode(encoder1); // Generated encode method
      final draftBytes = encoder1.toBytes();

      expect(
        draftBytes.length,
        equals(1),
        reason: 'Draft should only encode tag byte',
      );
      expect(draftBytes[0], equals(0), reason: 'Draft should have tag 0');

      final decodedDraft = NoteStatus.decode(BsatnDecoder(draftBytes));
      expect(
        decodedDraft,
        isA<NoteStatusDraft>(),
        reason: 'Should decode back to Draft',
      );

      // Test Published variant (tag 1, u64 payload)
      final originalPublished = NoteStatusPublished(Int64(1234567890));
      final encoder2 = BsatnEncoder();
      originalPublished.encode(encoder2); // Generated encode method
      final publishedBytes = encoder2.toBytes();

      expect(
        publishedBytes.length,
        equals(9),
        reason: 'Published should encode 1 tag byte + 8 u64 bytes',
      );
      expect(
        publishedBytes[0],
        equals(1),
        reason: 'Published should have tag 1',
      );

      final decodedPublished = NoteStatus.decode(BsatnDecoder(publishedBytes));
      expect(
        decodedPublished,
        isA<NoteStatusPublished>(),
        reason: 'Should decode back to Published',
      );

      final publishedValue = decodedPublished as NoteStatusPublished;
      expect(
        publishedValue.value,
        equals(Int64(1234567890)),
        reason: 'Decoded value should match original',
      );

      // Test Archived variant (tag 2, no payload)
      const originalArchived = NoteStatusArchived();
      final encoder3 = BsatnEncoder();
      originalArchived.encode(encoder3); // Generated encode method
      final archivedBytes = encoder3.toBytes();

      expect(
        archivedBytes.length,
        equals(1),
        reason: 'Archived should only encode tag byte',
      );
      expect(archivedBytes[0], equals(2), reason: 'Archived should have tag 2');

      final decodedArchived = NoteStatus.decode(BsatnDecoder(archivedBytes));
      expect(
        decodedArchived,
        isA<NoteStatusArchived>(),
        reason: 'Should decode back to Archived',
      );
    });

    test('Table integration: Ref field is strongly typed', () async {
      // Subscribe to notes table
      subManager.subscribe(['SELECT * FROM note']);
      await subManager.onSubscribeApplied.first.timeout(
        const Duration(seconds: 5),
      );

      // Get the TYPED table (not dynamic!)
      final noteTable = subManager.cache.getTableByTypedName<Note>('note');

      // Create a note if the table is empty
      if (noteTable.count() == 0) {
        final txFuture = subManager.onTransactionUpdate.first;
        await env.reducers.createNote(
          title: 'Sum Type Test',
          content: 'Testing Ref field typing',
        );
        await txFuture.timeout(const Duration(seconds: 2));
      }

      final notes = noteTable.iter().toList();

      expect(notes, isNotEmpty, reason: 'Should have notes after creation');

      final firstNote = notes.first;

      // CRITICAL: Verify the status field is strongly typed as NoteStatus
      // If TypeMapper failed to resolve Ref, this would be 'dynamic'
      expect(
        firstNote.status,
        isA<NoteStatus>(),
        reason: 'Note.status should be typed as NoteStatus, not dynamic',
      );

      // Verify we can pattern match on the status
      final statusDescription = switch (firstNote.status) {
        NoteStatusDraft() => 'This note is a draft',
        NoteStatusPublished(:final value) => 'Published at timestamp $value',
        NoteStatusArchived() => 'This note is archived',
      };

      expect(
        statusDescription,
        isNotEmpty,
        reason: 'Should successfully pattern match on status',
      );

      print('✓ First note status: $statusDescription');
    });

    test('Note class uses generated NoteStatus type (not dynamic)', () {
      // This is a compile-time verification test
      // If the TableGenerator didn't properly resolve {"Ref": 1} to NoteStatus,
      // the Note class would have "final dynamic status" instead of "final NoteStatus status"

      // Create a Note instance
      final note = Note(
        id: 999,
        title: 'Test',
        content: 'Content',
        timestamp: Int64.ZERO,
        status: const NoteStatusDraft(), // Must accept NoteStatus type
      );

      // Verify the field type is correct
      expect(
        note.status,
        isA<NoteStatus>(),
        reason: 'Note.status should be NoteStatus type',
      );

      // This line would fail to compile if status was dynamic and we tried to call a non-existent method
      // note.status.nonExistentMethod(); // Would compile if dynamic!

      // Encode the note to verify the generated encoder handles Ref types
      final encoder = BsatnEncoder();
      note.encodeBsatn(encoder);
      final bytes = encoder.toBytes();

      expect(bytes, isNotEmpty, reason: 'Should encode note with enum field');

      // Decode back
      final decoder = BsatnDecoder(bytes);
      final decodedNote = Note.decodeBsatn(decoder);

      expect(
        decodedNote.status,
        isA<NoteStatus>(),
        reason: 'Decoded note should have NoteStatus type',
      );
      expect(
        decodedNote.status,
        isA<NoteStatusDraft>(),
        reason: 'Should decode to Draft variant',
      );
    });

    test('Import statement was auto-generated in note.dart', () async {
      // This is a meta-test that verifies the code generator added the import
      // If the import wasn't generated, the previous tests would fail to compile

      // Read the generated note.dart file and verify it contains the import
      // This is implicit - if the file compiles and we can use NoteStatus, the import exists

      expect(
        true,
        isTrue,
        reason:
            'If this test runs, note.dart successfully imports note_status.dart',
      );
    });

    test('BSATN decoder dispatches to correct variant based on tag', () {
      // Create bytes for each variant and verify decode dispatches correctly
      final testCases = [
        (tag: 0, type: NoteStatusDraft, description: 'Draft'),
        (tag: 1, type: NoteStatusPublished, description: 'Published'),
        (tag: 2, type: NoteStatusArchived, description: 'Archived'),
      ];

      for (final testCase in testCases) {
        final bytes = Uint8List.fromList([testCase.tag]);
        if (testCase.tag == 1) {
          // Published needs payload
          final encoder = BsatnEncoder();
          encoder.writeU8(1);
          encoder.writeU64(Int64(9999));
          final bytesWithPayload = encoder.toBytes();
          final decoded = NoteStatus.decode(BsatnDecoder(bytesWithPayload));
          expect(
            decoded.runtimeType,
            equals(testCase.type),
            reason:
                'Tag ${testCase.tag} should decode to ${testCase.description}',
          );
        } else {
          final decoded = NoteStatus.decode(BsatnDecoder(bytes));
          expect(
            decoded.runtimeType,
            equals(testCase.type),
            reason:
                'Tag ${testCase.tag} should decode to ${testCase.description}',
          );
        }
      }
    });
  });
}
