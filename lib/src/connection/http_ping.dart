import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:spacetimedb_sdk/src/utils/sdk_logger.dart';

const _pingPath = '/v1/ping';
const _httpOk = 200;

Uri httpPingUri({required String host, required String scheme}) =>
    Uri.parse('$scheme://$host$_pingPath');

Future<bool> serverAnswersHttpPing(Uri pingUri, Duration timeout) async {
  try {
    final response = await http.get(pingUri).timeout(timeout);
    final answered = response.statusCode == _httpOk;
    SdkLogger.i('HTTP ping ${response.statusCode}');
    return answered;
  } on TimeoutException {
    SdkLogger.w('HTTP ping timed out after ${timeout.inMilliseconds}ms');
    return false;
  } on http.ClientException catch (e) {
    SdkLogger.w('HTTP ping failed: $e');
    return false;
  }
}
