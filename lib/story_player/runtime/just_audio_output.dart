import 'dart:async';

import 'package:just_audio/just_audio.dart';

import '../data/asset_store.dart';
import '../data/media_catalog.dart';
import '../script.dart';
import 'story_audio.dart';

class _Track {
  _Track(this.channel);
  final String channel;
  final player = AudioPlayer();
  StreamSubscription<int?>? indexSubscription;
  StreamSubscription<PlayerState>? stateSubscription;
  int fade = 0;
  double gain = 0;
  bool released = false;
}

/// BGM 双播放器交叉淡化；音效按脚本 channel 独立停止和调音量。
class JustAudioOutput implements StoryAudio {
  JustAudioOutput(
    this.catalog,
    this.assets, {
    required this.onWarning,
    this.masterVolume = 1,
    this.bgmVolume = 1,
    this.sfxVolume = 1,
  });
  final MediaCatalog catalog;
  final AssetStore assets;
  final void Function(String) onWarning;
  double masterVolume, bgmVolume, sfxVolume;
  final Set<_Track> _tracks = {};
  final Map<String, _Track> _channels = {};
  final Map<String, int> _requests = {};
  bool _paused = false, _disposed = false;
  int _epoch = 0;

  @override
  Future<void> execute(StoryCommand c) async {
    if (_disposed) return;
    final music = c.tag.contains('music');
    final channel = music ? 'music' : c.value('channel', c.value('key'));
    if (c.tag.startsWith('play')) {
      final epoch = _epoch;
      final request = (_requests[channel] ?? 0) + 1;
      _requests[channel] = request;
      // 加载和延迟不阻塞视觉指令，过时请求在播放前丢弃。
      unawaited(
        _play(c, channel, request, epoch).catchError((Object e) {
          onWarning('音频 ${c.value('key')}：$e');
        }),
      );
    } else if (c.tag.startsWith('stop')) {
      final names = channel.isEmpty
          ? {
              ..._channels.keys,
              ..._requests.keys,
            }.where((k) => k != 'music').toList()
          : [channel];
      for (final name in names) {
        _requests[name] = (_requests[name] ?? 0) + 1;
        final track = _channels.remove(name);
        if (track != null) {
          unawaited(_fade(track, 0, c.number('fadetime'), release: true));
        }
      }
    } else {
      final track = _channels[channel];
      if (track != null) {
        unawaited(_fade(track, c.number('volume', 1), c.number('fadetime')));
      }
    }
  }

  Future<void> _play(
    StoryCommand c,
    String channel,
    int request,
    int epoch,
  ) async {
    bool stale() =>
        _disposed || _epoch != epoch || _requests[channel] != request;
    final seconds = c.number('delay');
    if (seconds > 0) {
      await Future<void>.delayed(
        Duration(milliseconds: (seconds * 1000).round()),
      );
    }
    if (stale()) return;
    final key = catalog.audio(c.value('key'));
    if (key == null) {
      onWarning('未找到音频 ${c.value('key')}');
      return;
    }
    final intro = catalog.audio(c.value('intro'));
    final uris = <Uri>[?intro, key];
    final sources = <AudioSource>[];
    for (final uri in uris) {
      await assets.load(uri);
      sources.add(AudioSource.uri(await assets.playableUri(uri)));
    }
    if (stale()) return;
    final track = _Track(channel);
    _tracks.add(track);
    try {
      await track.player.setVolume(0);
      await track.player.setAudioSources(sources);
      if (stale() || track.released) {
        await _release(track);
        return;
      }
      final loop = channel == 'music' || c.flag('loop');
      await track.player.setLoopMode(
        loop && sources.length == 1 ? LoopMode.one : LoopMode.off,
      );
      if (loop && sources.length > 1) {
        // setLoopMode 会重发相同索引，去重避免微任务反馈环阻塞界面。
        track.indexSubscription = track.player.currentIndexStream
            .distinct()
            .listen((index) {
              if (index == sources.length - 1 && !track.released) {
                unawaited(track.player.setLoopMode(LoopMode.one));
              }
            });
      }
      if (!loop) {
        track.stateSubscription = track.player.playerStateStream.listen((
          state,
        ) {
          if (state.processingState == ProcessingState.completed) {
            unawaited(_release(track));
          }
        });
      }
      final previous = _channels[channel];
      _channels[channel] = track;
      final fade = channel == 'music' ? c.number('crossfade', .4) : 0.0;
      if (previous != null) unawaited(_fade(previous, 0, fade, release: true));
      if (!_paused) _start(track);
      unawaited(_fade(track, c.number('volume', 1), fade));
    } catch (_) {
      await _release(track);
      rethrow;
    }
  }

  void _start(_Track track) {
    unawaited(
      track.player.play().catchError((Object e) {
        onWarning('音频播放失败：$e');
      }),
    );
  }

  Future<void> _fade(
    _Track track,
    double target,
    double seconds, {
    bool release = false,
  }) async {
    final token = ++track.fade;
    final from = track.gain;
    target = target.clamp(0.0, 1.0);
    final steps = (seconds * 50).round().clamp(1, 10000);
    try {
      for (var i = 1; i <= steps; i++) {
        if (track.released || token != track.fade) return;
        if (seconds > 0) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        if (track.released || token != track.fade) return;
        track.gain = (from + (target - from) * i / steps).clamp(0.0, 1.0);
        await track.player.setVolume(_mixedVolume(track));
      }
      if (release) await _release(track);
    } catch (e) {
      if (!track.released) onWarning('音量过渡失败：$e');
    }
  }

  double _mixedVolume(_Track track) => (track.gain * masterVolume *
      (track.channel == 'music' ? bgmVolume : sfxVolume)).clamp(0.0, 1.0);

  Future<void> updateVolumes({required double master, required double bgm, required double sfx}) async {
    masterVolume = master;
    bgmVolume = bgm;
    sfxVolume = sfx;
    for (final track in _tracks.toList()) {
      if (!track.released) await track.player.setVolume(_mixedVolume(track));
    }
  }
  Future<void> _release(_Track track) async {
    if (track.released) return;
    track.released = true;
    track.fade++;
    _tracks.remove(track);
    if (identical(_channels[track.channel], track)) {
      _channels.remove(track.channel);
    }
    await track.indexSubscription?.cancel();
    await track.stateSubscription?.cancel();
    await track.player.dispose();
  }

  @override
  Future<void> pause() async {
    _paused = true;
    await Future.wait(_tracks.toList().map((t) => t.player.pause()));
  }

  @override
  Future<void> resume() async {
    _paused = false;
    for (final t in _tracks.toList()) {
      if (!t.released) _start(t);
    }
  }

  @override
  Future<void> stop() async {
    _epoch++;
    _requests.clear();
    _channels.clear();
    await Future.wait(_tracks.toList().map(_release));
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await stop();
  }
}
