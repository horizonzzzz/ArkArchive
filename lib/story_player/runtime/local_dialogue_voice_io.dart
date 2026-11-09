import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../data/voice_pack.dart';
import 'dialogue_voice.dart';
import 'voice_synthesis_worker.dart';

DialogueVoice createLocalDialogueVoice(VoicePackStore packs, double volume) =>
    packs.supported ? LocalDialogueVoice(packs: packs, volume: volume) : SilentDialogueVoice();

class LocalDialogueVoice implements DialogueVoice {
  LocalDialogueVoice({required this.packs, required this._volume}) {
    packs.addListener(_packChanged);
    packs.releaseUsers.add(_unload);
    unawaited(packs.initialize());
  }
  final VoicePackStore packs;
  final _status = ValueNotifier(VoiceStatus.unavailable);
  @override
  ValueListenable<VoiceStatus> get status => _status;
  VoiceSynthesisWorker? _worker;
  AudioPlayer? _player;
  StreamSubscription<PlayerState>? _subscription;
  Future<void> _synthesis = Future.value();
  Future<void> _audio = Future.value();
  Completer<void>? _completion;
  Directory? _temp;
  int _token = 0;
  int? _playingToken;
  double _volume;
  bool _paused = false;
  bool _disposed = false;

  Future<void> _serializeAudio(Future<void> Function() action) =>
      _audio = _audio.catchError((Object _) {}).then((_) => action());
  bool _current(int token) => !_disposed && token == _token && packs.installed && _volume > 0;

  void _packChanged() {
    if (_disposed) return;
    if (!packs.installed) {
      unawaited(_unload());
      _status.value = VoiceStatus.unavailable;
    } else if (_completion == null && _volume > 0) {
      _status.value = VoiceStatus.idle;
    }
  }

  void _finish(int token, {bool failed = false}) {
    if (_disposed || token != _token) return;
    _playingToken = null;
    final completion = _completion;
    _completion = null;
    if (completion != null && !completion.isCompleted) completion.complete();
    _status.value = failed ? VoiceStatus.failed :
        (packs.installed && _volume > 0 ? VoiceStatus.idle : VoiceStatus.unavailable);
  }

  @override
  Future<void> speak({required String speaker, required String text, int? requestId}) async {
    final stopped = stop();
    final token = _token;
    await stopped;
    if (!_current(token) || text.trim().isEmpty) return;
    final completion = _completion = Completer<void>();
    _status.value = _paused ? VoiceStatus.paused : VoiceStatus.synthesizing;
    final sid = packs.profile.resolve(speaker);
    _synthesis = _synthesis.catchError((Object _) {}).then((_) async {
      if (!_current(token)) return;
      try {
        final worker = _worker ??= VoiceSynthesisWorker();
        final bytes = await worker.synthesize(packs.directory!, text, sid);
        if (!_current(token)) return;
        _temp ??= await Directory((await getTemporaryDirectory()).path).createTemp('ark_voice_');
        if (!_current(token)) return;
        final file = File('${_temp!.path}/dialogue-$token.wav');
        await file.writeAsBytes(bytes, flush: true);
        await _serializeAudio(() async {
          if (!_current(token)) return;
          final player = _player ??= AudioPlayer();
          _subscription ??= player.playerStateStream.listen((state) {
            if (state.processingState == ProcessingState.completed && _playingToken != null) {
              _finish(_playingToken!);
            }
          }, onError: (Object _) { if (_playingToken != null) _finish(_playingToken!, failed: true); });
          await player.setVolume(_volume);
          await player.setFilePath(file.path);
          if (!_current(token)) return;
          _playingToken = token;
          _status.value = _paused ? VoiceStatus.paused : VoiceStatus.speaking;
          if (!_paused) unawaited(player.play().catchError((Object _) => _finish(token, failed: true)));
        });
        await completion.future;
        if (await file.exists()) await file.delete();
      } catch (e) {
        debugPrint('对白语音失败：$e');
        _finish(token, failed: true);
      }
    });
    return completion.future;
  }

  @override
  Future<void> stop() {
    _token++;
    _playingToken = null;
    final completion = _completion;
    _completion = null;
    if (completion != null && !completion.isCompleted) completion.complete();
    if (!_disposed) _status.value = packs.installed && _volume > 0 ? VoiceStatus.idle : VoiceStatus.unavailable;
    return _serializeAudio(() async { await _player?.stop(); });
  }
  @override
  Future<void> pause() {
    _paused = true;
    if (!_disposed && _completion != null) _status.value = VoiceStatus.paused;
    return _serializeAudio(() async { await _player?.pause(); });
  }
  @override
  Future<void> resume() {
    _paused = false;
    return _serializeAudio(() async {
      if (_disposed || _completion == null) return;
      if (_playingToken == _token) {
        _status.value = VoiceStatus.speaking;
        final token = _token;
        unawaited(_player!.play().catchError((Object _) => _finish(token, failed: true)));
      } else { _status.value = VoiceStatus.synthesizing; }
    });
  }
  @override
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0, 1);
    if (_volume == 0) { await stop(); } else {
      await _serializeAudio(() async { await _player?.setVolume(_volume); });
      if (!_disposed && _completion == null && packs.installed) _status.value = VoiceStatus.idle;
    }
  }
  Future<void>? _unloading;
  Future<void> _unload() => _unloading ??= _doUnload().whenComplete(() => _unloading = null);
  Future<void> _doUnload() async {
    await stop();
    final worker = _worker;
    _worker = null;
    await worker?.dispose();
    await _synthesis;
  }
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    packs.removeListener(_packChanged);
    packs.releaseUsers.remove(_unload);
    await stop();
    _disposed = true;
    await _worker?.dispose();
    await _subscription?.cancel();
    await _player?.dispose();
    await _synthesis;
    final temp = _temp;
    if (temp != null && await temp.exists()) await temp.delete(recursive: true);
    _status.dispose();
  }
}
