import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:arknights_story_player/story_player/data/media_catalog.dart';
import 'package:arknights_story_player/story_player/runtime/story_engine.dart';
import 'package:arknights_story_player/story_player/runtime/story_video.dart';
import 'package:arknights_story_player/story_player/script.dart';

/// 受控的视频输出替身：execute 挂起直到测试或 stop 放行。
class FakeStoryVideo implements StoryVideo {
  final List<String> calls = <String>[];
  final List<Completer<void>> waiters = <Completer<void>>[];
  int pauses = 0, resumes = 0, stops = 0, disposals = 0;
  bool _active = false;

  @override
  bool get active => _active;

  @override
  Future<void> execute(StoryCommand command) {
    final url = command.value('url');
    final res = command.value('res');
    calls.add('execute:${url.isEmpty ? res : url}');
    _active = true;
    final completer = Completer<void>();
    waiters.add(completer);
    return completer.future.then((_) => _active = false);
  }

  @override
  Widget? buildSurface() => const SizedBox.shrink();

  @override
  Future<void> pause() async => pauses++;

  @override
  Future<void> resume() async => resumes++;

  @override
  Future<void> stop() async {
    stops++;
    _active = false;
    for (final waiter in waiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
  }

  @override
  Future<void> dispose() async {
    disposals++;
    await stop();
  }
}

void main() {
  group('MediaCatalog.video', () {
    final catalog = MediaCatalog(
      variables: {},
      characters: {},
      backgroundPpu: {},
    );

    test('url 直用，res 小写拼资源根并逐段编码，缺参返回 null', () {
      expect(
        catalog.video('https://example.com/Clip.mp4', '').toString(),
        'https://example.com/Clip.mp4',
      );
      expect(
        catalog.video('', 'video/act55side/TL02.mp4').toString(),
        'https://torappu.prts.wiki/assets/video/act55side/tl02.mp4',
      );
      expect(
        catalog.video('', '/video/main_13/main_13_01.mp4').toString(),
        'https://torappu.prts.wiki/assets/video/main_13/main_13_01.mp4',
      );
      expect(catalog.video('', '   '), isNull);
    });

    // 参考端（context l()）对非 http(s) 的 url 同样按相对路径拼资源根。
    test('非 http 的 url 按相对路径规则处理，与 res 同语义', () {
      expect(
        catalog.video('clips/movie.mp4', '').toString(),
        'https://torappu.prts.wiki/assets/clips/movie.mp4',
      );
      expect(
        catalog.video('Video/ACT.mp4', '').toString(),
        'https://torappu.prts.wiki/assets/video/act.mp4',
      );
    });

    // 无路径段的绝对地址不能让准备阶段抛错（pathSegments.last 崩溃回归）。
    test('缺路径段的 url 收集时用稳定标题兜底', () {
      final warnings = <String>[];
      final refs = catalog.collect(
        StoryScript.parse('[Video(url="https://example.com?clip=1")]'),
        warnings,
      );
      expect(warnings, isEmpty);
      expect(refs.single.kind, AssetKind.video);
      expect(refs.single.title, 'video');
      expect(
        refs.single.files.single.uri.toString(),
        'https://example.com?clip=1',
      );
    });

    // 2026-11 全量扫描剧情脚本得到的 7 处 [Video(res=...)] 引用；
    // 对应资源站地址已实测 HTTP 200（大小写规则是资源可用性的前提）。
    test('已知的全部剧情视频 res 映射到实测可用地址', () {
      const cases = {
        'video/01.mp4': 'https://torappu.prts.wiki/assets/video/01.mp4',
        'video/02.mp4': 'https://torappu.prts.wiki/assets/video/02.mp4',
        'video/03.mp4': 'https://torappu.prts.wiki/assets/video/03.mp4',
        'video/main_13/main_13_01.mp4':
            'https://torappu.prts.wiki/assets/video/main_13/main_13_01.mp4',
        'video/act45side/SS01.mp4':
            'https://torappu.prts.wiki/assets/video/act45side/ss01.mp4',
        'video/act49side/TA02.mp4':
            'https://torappu.prts.wiki/assets/video/act49side/ta02.mp4',
        'video/act55side/TL02.mp4':
            'https://torappu.prts.wiki/assets/video/act55side/tl02.mp4',
      };
      for (final entry in cases.entries) {
        expect(catalog.video('', entry.key).toString(), entry.value);
      }
    });

    test('collect 收集视频依赖与导出路径，缺参告警', () {
      final warnings = <String>[];
      final refs = catalog.collect(
        StoryScript.parse('[Video(res="video/act55side/TL02.mp4")]'),
        warnings,
      );
      expect(warnings, isEmpty);
      expect(refs.single.kind, AssetKind.video);
      expect(
        refs.single.files.single.uri.toString(),
        'https://torappu.prts.wiki/assets/video/act55side/tl02.mp4',
      );
      expect(refs.single.files.single.exportPath, 'video/act55side/tl02.mp4');
      expect(
        catalog
            .dependencies(
              StoryScript.parse('[Video(res="video/01.mp4")]'),
              warnings,
            )
            .single
            .toString(),
        'https://torappu.prts.wiki/assets/video/01.mp4',
      );
      expect(warnings, isEmpty);

      final invalid = <String>[];
      catalog.collect(StoryScript.parse('[Video]'), invalid);
      expect(invalid.single, contains('video 缺少 url 或 res'));
    });
  });

  group('StoryEngine video 指令', () {
    test('默认 Noop 输出跳过视频并记录诊断，剧情继续', () async {
      final engine = StoryEngine(
        StoryScript.parse('[Video(res="video/01.mp4")]\n[name="甲"]对话'),
      );
      addTearDown(engine.dispose);
      await engine.start();
      expect(engine.state.text, '对话');
      expect(engine.warnings.single, contains('暂不支持'));
      expect(engine.video.active, isFalse);
      expect(engine.video.buildSurface(), isNull);
    });

    test('video 阻塞指令队列，播放完成后才继续推进', () async {
      final fake = FakeStoryVideo();
      final engine = StoryEngine(
        StoryScript.parse('[Video(res="video/01.mp4")]\n[name="甲"]对话'),
        video: fake,
      );
      addTearDown(engine.dispose);
      final done = engine.start();
      await Future<void>.delayed(Duration.zero);
      expect(fake.calls, ['execute:video/01.mp4']);
      expect(engine.state.text, isEmpty);
      fake.waiters.single.complete();
      await done;
      expect(engine.state.text, '对话');
    });

    test('seek 中断播放，重建路径不重播视频', () async {
      final fake = FakeStoryVideo();
      final script = StoryScript.parse(
        '[Delay(time=0)]\n[name="甲"]第一句\n'
        '[Video(res="video/02.mp4")]\n[name="乙"]视频后',
      );
      final engine = StoryEngine(
        script,
        video: fake,
        typingInterval: Duration.zero,
      );
      addTearDown(engine.dispose);
      await engine.start();
      expect(engine.state.text, '第一句');
      // 第一次 advance 补全打字显示，第二次推进到 [Video] 并挂起。
      await engine.advance();
      unawaited(engine.advance());
      await Future<void>.delayed(Duration.zero);
      expect(fake.calls, hasLength(1));

      final ok = await engine.seekToCommand(1);
      expect(ok, isTrue);
      expect(fake.stops, greaterThanOrEqualTo(1));
      // 重建经过 [Video] 行（_rebuilding）不再触发输出。
      expect(fake.calls, hasLength(1));
      expect(engine.state.text, '第一句');
    });

    test('暂停与恢复转发到视频输出', () async {
      final fake = FakeStoryVideo();
      final engine = StoryEngine(
        StoryScript.parse('[Video(res="video/01.mp4")]'),
        video: fake,
      );
      addTearDown(engine.dispose);
      unawaited(engine.start());
      await Future<void>.delayed(Duration.zero);
      await engine.setPaused(true);
      expect(fake.pauses, 1);
      await engine.setPaused(false);
      expect(fake.resumes, 1);
      await fake.stop();
    });

    test('dispose 释放视频输出', () {
      final fake = FakeStoryVideo();
      final engine = StoryEngine(StoryScript.parse('旁白'), video: fake);
      engine.dispose();
      expect(fake.disposals, 1);
    });
  });
}
