import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:arknights_story_player/story_player/data/asset_store.dart';
import 'package:arknights_story_player/story_player/data/media_catalog.dart';
import 'package:arknights_story_player/story_player/data/story_repository.dart';

import 'data_test.dart' show MemoryCache;

void main() {
  const live = bool.fromEnvironment('CACHE_AUDIO_LIVE');
  test(
    '真实变量表与 TL 剧情音频依赖均可解析',
    () async {
      final store = AssetStore(cache: MemoryCache());
      addTearDown(store.close);
      final catalog = await MediaCatalog.load(store);
      var checked = 0;
      for (final entry in catalog.variables.entries) {
        if (!entry.value.toString().toLowerCase().startsWith('sound_beta_2/')) {
          continue;
        }
        expect(
          catalog.audio('\$${entry.key.toUpperCase()}'),
          isNotNull,
          reason: entry.key,
        );
        checked++;
      }
      expect(checked, greaterThan(100));
      final repository = StoryRepository(store);
      final groups = await repository.loadIndex();
      const codes = {'TL-2', 'TL-7', 'TL-ST-3', 'TL-8', 'TL-9'};
      final entries = groups
          .expand((group) => group.entries)
          .where((entry) => codes.contains(entry.code))
          .toList();
      expect(entries.length, greaterThanOrEqualTo(6));
      for (final entry in entries) {
        final document = await repository.loadEntry(entry);
        final warnings = <String>[];
        catalog.dependencies(document.script, warnings);
        expect(
          warnings.where((warning) => warning.contains('未解析音频')),
          isEmpty,
          reason: '${entry.title}: $warnings',
        );
      }
      final client = http.Client();
      addTearDown(client.close);
      const keys = [
        'd_avg_OriginiumArts_soundwave',
        'd_avg_OriginiumArts_fire_long',
        'd_avg_OriginiumArts_heart_1',
        'ReunionNormal_loop',
        'ReunionNormal_intro',
        'm_sys_act51sideInstrumental_loop',
        'd_avg_Qinggong',
        'd_avg_OriginiumArts_fire_short',
        'd_avg_Warlockarrow',
      ];
      for (final key in keys) {
        final response = await client
            .head(catalog.audio('\$$key')!)
            .timeout(const Duration(seconds: 30));
        expect(response.statusCode, 200, reason: key);
        expect(
          response.headers['content-type'],
          contains('audio'),
          reason: key,
        );
      }
      // ignore: avoid_print
      print(
        'LIVE AUDIO: $checked variables, ${entries.length} TL scripts, ${keys.length} audio URLs verified',
      );
    },
    skip: !live ? '仅 CACHE_AUDIO_LIVE=true 时访问网络' : false,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
