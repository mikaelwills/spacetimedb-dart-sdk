// GENERATED CODE - DO NOT MODIFY BY HAND

import 'dart:async';

import 'package:spacetimedb_sdk/codegen.dart';

import 'note_status.dart';

class Procedures {
  Procedures(this._procedureCaller);

  final ProcedureCaller _procedureCaller;

  /// Calls the `add_numbers` procedure and returns its result.
  ///
  /// Throws [SpacetimeDbProcedureException] with the server's message
  /// when the procedure fails, and [SpacetimeDbConnectionException]
  /// when the connection is down or drops before the result arrives.
  Future<int> addNumbers({required int a, required int b, Duration? timeout}) {
    final encoder = BsatnEncoder();
    encoder.writeU32(a);
    encoder.writeU32(b);
    return _procedureCaller.call<int>(
      'add_numbers',
      encoder.toBytes(),
      (decoder) => decoder.readU32(),
      timeout: timeout,
    );
  }

  /// Calls the `divide_by_zero` procedure and returns its result.
  ///
  /// Throws [SpacetimeDbProcedureException] with the server's message
  /// when the procedure fails, and [SpacetimeDbConnectionException]
  /// when the connection is down or drops before the result arrives.
  Future<int> divideByZero({required int numerator, Duration? timeout}) {
    final encoder = BsatnEncoder();
    encoder.writeU32(numerator);
    return _procedureCaller.call<int>(
      'divide_by_zero',
      encoder.toBytes(),
      (decoder) => decoder.readU32(),
      timeout: timeout,
    );
  }

  /// Calls the `echo_status` procedure and returns its result.
  ///
  /// Throws [SpacetimeDbProcedureException] with the server's message
  /// when the procedure fails, and [SpacetimeDbConnectionException]
  /// when the connection is down or drops before the result arrives.
  Future<NoteStatus> echoStatus({
    required NoteStatus status,
    Duration? timeout,
  }) {
    final encoder = BsatnEncoder();
    status.encodeBsatn(encoder);
    return _procedureCaller.call<NoteStatus>(
      'echo_status',
      encoder.toBytes(),
      (decoder) => NoteStatus.decodeBsatn(decoder),
      timeout: timeout,
    );
  }

  /// Calls the `maybe_greeting` procedure and returns its result.
  ///
  /// Throws [SpacetimeDbProcedureException] with the server's message
  /// when the procedure fails, and [SpacetimeDbConnectionException]
  /// when the connection is down or drops before the result arrives.
  Future<String?> maybeGreeting({required String? name, Duration? timeout}) {
    final encoder = BsatnEncoder();
    encoder.writeOption<String>(name, (value) => encoder.writeString(value));
    return _procedureCaller.call<String?>(
      'maybe_greeting',
      encoder.toBytes(),
      (decoder) => decoder.readOption<String>(() => decoder.readString()),
      timeout: timeout,
    );
  }

  /// Calls the `return_nothing` procedure and returns its result.
  ///
  /// Throws [SpacetimeDbProcedureException] with the server's message
  /// when the procedure fails, and [SpacetimeDbConnectionException]
  /// when the connection is down or drops before the result arrives.
  Future<void> returnNothing({Duration? timeout}) {
    final encoder = BsatnEncoder();
    return _procedureCaller.call<void>(
      'return_nothing',
      encoder.toBytes(),
      (_) {},
      timeout: timeout,
    );
  }
}
