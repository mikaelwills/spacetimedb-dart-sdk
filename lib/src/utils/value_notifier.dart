class ValueNotifier<T> {
  T _value;
  final List<void Function()> _listeners = [];

  ValueNotifier(this._value);

  T get value => _value;

  set value(T newValue) {
    _value = newValue;
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }

  void addListener(void Function() listener) {
    _listeners.add(listener);
  }

  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  void dispose() {
    _listeners.clear();
  }
}
