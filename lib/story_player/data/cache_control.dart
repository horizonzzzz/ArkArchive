import 'dart:async';

class CacheCancelled implements Exception {
  const CacheCancelled();
}

class CacheControl {
  bool _paused = false;
  bool _cancelled = false;
  Completer<void>? _resume;

  bool get paused => _paused;
  bool get cancelled => _cancelled;

  void pause() {
    if (!_cancelled) _paused = true;
  }

  void resume() {
    _paused = false;
    _resume?.complete();
    _resume = null;
  }

  void cancel() {
    _cancelled = true;
    resume();
  }

  Future<void> checkpoint() async {
    while (_paused && !_cancelled) {
      await (_resume ??= Completer<void>()).future;
    }
    if (_cancelled) throw const CacheCancelled();
  }
}
