import 'dart:async';

class CacheCancelled implements Exception {
  const CacheCancelled();
}

class CacheControl {
  bool _paused = false;
  bool _scheduled = true;
  bool _cancelled = false;
  Completer<void>? _resume;
  final _interruptions = StreamController<void>.broadcast(sync: true);

  bool get paused => _paused;
  bool get blocked => _paused || !_scheduled;
  bool get cancelled => _cancelled;
  Stream<void> get interruptions => _interruptions.stream;

  void setScheduled(bool value) {
    if (_scheduled == value) return;
    _scheduled = value;
    _changed();
  }

  void pause() {
    if (_cancelled || _paused) return;
    _paused = true;
    _changed();
  }

  void resume() {
    _paused = false;
    _changed();
  }

  void cancel() {
    _cancelled = true;
    _changed();
  }

  void _changed() {
    if (blocked || _cancelled) _interruptions.add(null);
    _resume?.complete();
    _resume = null;
  }

  Future<void> checkpoint() async {
    while (blocked && !_cancelled) {
      await (_resume ??= Completer<void>()).future;
    }
    if (_cancelled) throw const CacheCancelled();
  }
}
