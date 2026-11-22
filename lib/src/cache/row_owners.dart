import 'package:flutter/foundation.dart';

class RowOwners {
  int? _single;
  Set<int>? _multiple;

  bool get isEmpty => _single == null && _multiple == null;

  bool get isNotEmpty => !isEmpty;

  @visibleForTesting
  bool get hasSharedOwnerSet => _multiple != null;

  Iterable<int> get ids {
    final multiple = _multiple;
    if (multiple != null) return multiple;
    final single = _single;
    return single == null ? const <int>[] : [single];
  }

  bool contains(int querySetId) {
    final multiple = _multiple;
    if (multiple != null) return multiple.contains(querySetId);
    return _single == querySetId;
  }

  void add(int querySetId) {
    final multiple = _multiple;
    if (multiple != null) {
      multiple.add(querySetId);
      return;
    }
    final single = _single;
    if (single == null) {
      _single = querySetId;
      return;
    }
    if (single == querySetId) return;
    _multiple = {single, querySetId};
    _single = null;
  }

  void addAll(RowOwners other) {
    for (final querySetId in other.ids.toList()) {
      add(querySetId);
    }
  }

  void remove(int querySetId) {
    final multiple = _multiple;
    if (multiple != null) {
      multiple.remove(querySetId);
      _collapseSharedSetIfSingle();
      return;
    }
    if (_single == querySetId) _single = null;
  }

  void _collapseSharedSetIfSingle() {
    final multiple = _multiple;
    if (multiple == null || multiple.length != 1) return;
    _single = multiple.first;
    _multiple = null;
  }

  Set<int> toSet() => {...ids};

  @override
  String toString() => 'RowOwners(${toSet()})';
}
