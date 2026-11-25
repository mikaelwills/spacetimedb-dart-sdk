abstract class RowPredicate {
  const RowPredicate();

  factory RowPredicate.parse(String whereClause) =>
      _PredicateParser(_tokensOf(whereClause)).parseWhole();

  bool matches(Map<String, dynamic> rowJson);
}

class UnsupportedPredicate implements Exception {
  UnsupportedPredicate(this.reason);

  final String reason;

  @override
  String toString() => 'UnsupportedPredicate: $reason';
}

class _Both extends RowPredicate {
  const _Both(this.left, this.right);

  final RowPredicate left;
  final RowPredicate right;

  @override
  bool matches(Map<String, dynamic> rowJson) =>
      left.matches(rowJson) && right.matches(rowJson);
}

class _Either extends RowPredicate {
  const _Either(this.left, this.right);

  final RowPredicate left;
  final RowPredicate right;

  @override
  bool matches(Map<String, dynamic> rowJson) =>
      left.matches(rowJson) || right.matches(rowJson);
}

typedef _Verdict = bool Function(int comparison);

const Map<String, _Verdict> _verdicts = {
  '=': _isEqual,
  '!=': _isDifferent,
  '<>': _isDifferent,
  '<': _isLess,
  '<=': _isLessOrEqual,
  '>': _isGreater,
  '>=': _isGreaterOrEqual,
};

bool _isEqual(int comparison) => comparison == 0;
bool _isDifferent(int comparison) => comparison != 0;
bool _isLess(int comparison) => comparison < 0;
bool _isLessOrEqual(int comparison) => comparison <= 0;
bool _isGreater(int comparison) => comparison > 0;
bool _isGreaterOrEqual(int comparison) => comparison >= 0;

class _Comparison extends RowPredicate {
  const _Comparison(this.column, this.verdict, this.literal);

  final String column;
  final _Verdict verdict;
  final Object literal;

  @override
  bool matches(Map<String, dynamic> rowJson) {
    final value = _columnValue(rowJson);
    if (value == null) return false;
    return verdict(_compare(value, literal));
  }

  Object? _columnValue(Map<String, dynamic> rowJson) {
    final wanted = _foldedName(column);
    for (final entry in rowJson.entries) {
      if (_foldedName(entry.key) == wanted) return entry.value;
    }
    throw UnsupportedPredicate('the row has no column "$column"');
  }
}

String _foldedName(String name) => name.replaceAll('_', '').toLowerCase();

int _compare(Object value, Object literal) {
  if (value is num && literal is num) return value.compareTo(literal);
  if (value is bool && literal is bool) return value == literal ? 0 : 1;
  return value.toString().compareTo(literal.toString());
}

enum _TokenKind { word, text, number, operator, open, close }

class _Token {
  const _Token(this.kind, this.text);

  final _TokenKind kind;
  final String text;
}

final RegExp _tokenPattern = RegExp(
  r"\s*(?:(?<text>'(?:[^']|'')*')|(?<number>-?\d+(?:\.\d+)?)"
  r'|(?<operator><=|>=|<>|!=|=|<|>)|(?<open>\()|(?<close>\))'
  r'|(?<word>"[^"]+"|[A-Za-z_][A-Za-z0-9_.]*))',
);

List<_Token> _tokensOf(String clause) {
  final tokens = <_Token>[];
  var position = 0;
  final trimmedLength = clause.trimRight().length;
  while (position < trimmedLength) {
    final match = _tokenPattern.matchAsPrefix(clause, position);
    if (match == null) {
      throw UnsupportedPredicate('cannot read "${clause.substring(position)}"');
    }
    tokens.add(_tokenOf(match as RegExpMatch));
    position = match.end;
  }
  return tokens;
}

_Token _tokenOf(RegExpMatch match) {
  for (final kind in _TokenKind.values) {
    final text = match.namedGroup(kind.name);
    if (text != null) return _Token(kind, text);
  }
  throw UnsupportedPredicate('cannot read "${match.group(0)}"');
}

class _PredicateParser {
  _PredicateParser(this._tokens);

  final List<_Token> _tokens;
  int _next = 0;

  RowPredicate parseWhole() {
    final predicate = _parseEither();
    if (_next != _tokens.length) {
      throw UnsupportedPredicate('unexpected "${_tokens[_next].text}"');
    }
    return predicate;
  }

  RowPredicate _parseEither() {
    var left = _parseBoth();
    while (_takeKeyword('OR')) {
      left = _Either(left, _parseBoth());
    }
    return left;
  }

  RowPredicate _parseBoth() {
    var left = _parseOperand();
    while (_takeKeyword('AND')) {
      left = _Both(left, _parseOperand());
    }
    return left;
  }

  RowPredicate _parseOperand() {
    if (_peekKind == _TokenKind.open) {
      _next++;
      final inner = _parseEither();
      _take(_TokenKind.close);
      return inner;
    }
    final column = _columnName(_take(_TokenKind.word).text);
    final verdict = _verdicts[_take(_TokenKind.operator).text]!;
    return _Comparison(column, verdict, _parseLiteral());
  }

  Object _parseLiteral() {
    final token = _takeAny();
    return switch (token.kind) {
      _TokenKind.text =>
        token.text.substring(1, token.text.length - 1).replaceAll("''", "'"),
      _TokenKind.number => num.parse(token.text),
      _TokenKind.word => _wordLiteral(token.text),
      _ => throw UnsupportedPredicate('"${token.text}" is not a literal'),
    };
  }

  Object _wordLiteral(String word) => switch (word.toLowerCase()) {
    'true' => true,
    'false' => false,
    _ => word,
  };

  String _columnName(String word) {
    final unquoted = word.replaceAll('"', '');
    return unquoted.substring(unquoted.lastIndexOf('.') + 1);
  }

  _TokenKind? get _peekKind =>
      _next < _tokens.length ? _tokens[_next].kind : null;

  bool _takeKeyword(String keyword) {
    if (_next >= _tokens.length) return false;
    final token = _tokens[_next];
    if (token.kind != _TokenKind.word || token.text.toUpperCase() != keyword) {
      return false;
    }
    _next++;
    return true;
  }

  _Token _take(_TokenKind kind) {
    final token = _takeAny();
    if (token.kind != kind) {
      throw UnsupportedPredicate('unexpected "${token.text}"');
    }
    return token;
  }

  _Token _takeAny() {
    if (_next >= _tokens.length) {
      throw UnsupportedPredicate('the clause ends too early');
    }
    return _tokens[_next++];
  }
}
