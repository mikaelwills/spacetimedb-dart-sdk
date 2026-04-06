import 'dart:async';
import '../events/event_context.dart';
import 'reducer_def.dart';

class ReducerEmitter {
  final Map<String, StreamController<EventContext>> _controllers = {};

  Stream<EventContext> on<A>(ReducerDef<A> def) {
    if (!_controllers.containsKey(def.name)) {
      _controllers[def.name] = StreamController<EventContext>.broadcast();
    }
    return _controllers[def.name]!.stream;
  }

  void emit(String reducerName, EventContext context) {
    final controller = _controllers[reducerName];
    if (controller == null) return;
    controller.add(context);
  }

  bool hasListeners(String reducerName) {
    final controller = _controllers[reducerName];
    return controller != null && controller.hasListener;
  }

  List<String> get activeReducers => _controllers.keys.toList();

  void dispose() {
    for (final controller in _controllers.values) {
      controller.close();
    }
    _controllers.clear();
  }
}
