import 'dart:math' as math;

import 'package:meta/meta.dart';

const double _minJitterFraction = 0.5;
const int _maxBackoffExponent = 30;

@visibleForTesting
Duration reconnectDelay(
  int attempt,
  double random, {
  required Duration base,
  required Duration max,
}) {
  final cappedUs = _cappedBackoffUs(attempt, base: base, max: max);
  return Duration(microseconds: _jitteredUs(cappedUs, random).round());
}

double _cappedBackoffUs(
  int attempt, {
  required Duration base,
  required Duration max,
}) {
  final exponent = (attempt - 1).clamp(0, _maxBackoffExponent);
  return math.min(
    base.inMicroseconds * math.pow(2, exponent).toDouble(),
    max.inMicroseconds.toDouble(),
  );
}

double _jitteredUs(double cappedUs, double random) {
  final jitterSpan = 1 - _minJitterFraction;
  return cappedUs * (_minJitterFraction + random * jitterSpan);
}
