sealed class ConnectionState {
  const ConnectionState();

  bool get isConnected => this is Connected;

  bool get isConnecting => this is Connecting || this is Reconnecting;

  bool get canRetry =>
      this is Disconnected || this is FatalError || this is AuthError;

  String get displayName => switch (this) {
    Disconnected() => 'Disconnected',
    Connecting() => 'Connecting...',
    Connected() => 'Connected',
    Reconnecting() => 'Reconnecting...',
    AuthError() => 'Authentication Failed',
    FatalError() => 'Connection Failed',
  };
}

class Disconnected extends ConnectionState {
  const Disconnected();
}

class Connecting extends ConnectionState {
  const Connecting();
}

class Connected extends ConnectionState {
  const Connected();
}

class Reconnecting extends ConnectionState {
  final int attempt;
  final Duration? nextDelay;

  const Reconnecting({required this.attempt, this.nextDelay});
}

class AuthError extends ConnectionState {
  final String? message;

  const AuthError({this.message});
}

class FatalError extends ConnectionState {
  final String? message;

  const FatalError({this.message});
}
