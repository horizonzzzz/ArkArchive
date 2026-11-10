import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'catalog.dart';

/// 只发布返回图片类型的资源；暂时性网络错误不写入永久失败缓存。
class ArtworkVerifier {
  ArtworkVerifier(
    this.client,
    this.cache, {
    this.offline = false,
    this.refresh = false,
  });

  final http.Client client;
  final File cache;
  final bool offline;
  final bool refresh;
  final Map<String, bool> _results = {};

  Future<void> load() async {
    if (!await cache.exists()) return;
    final data = object(jsonDecode(await cache.readAsString()), '图片校验缓存');
    for (final entry in data.entries) {
      if (entry.value is bool) _results[entry.key] = entry.value as bool;
    }
  }

  Future<bool> verify(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https' || uri.host != 'media.prts.wiki') {
      return false;
    }
    if (_results.containsKey(url)) return _results[url]!;
    if (offline) return false;
    try {
      final response = await client
          .head(uri)
          .timeout(const Duration(seconds: 15));
      final valid =
          response.statusCode == 200 &&
          (response.headers['content-type'] ?? '').startsWith('image/');
      if (valid || response.statusCode == 404) _results[url] = valid;
      return valid;
    } on Object {
      return false;
    }
  }

  Future<void> save() async {
    await cache.parent.create(recursive: true);
    final temporary = File('${cache.path}.tmp');
    await temporary.writeAsString(jsonEncode(_results));
    await temporary.rename(cache.path);
  }

  Future<Map<String, dynamic>> enrich(
    CharacterCatalog catalog, {
    int concurrency = 8,
    void Function(int done, int total)? onProgress,
  }) async {
    if (concurrency < 1) throw ArgumentError.value(concurrency);
    if (!refresh) await load();
    final art = catalog.people.values.expand((p) => p.artCandidates).toList();
    final urls = art.map((a) => a['url'] as String).toSet().toList();
    final current = <String, bool>{};
    for (var start = 0; start < urls.length; start += concurrency) {
      final batch = urls.skip(start).take(concurrency).toList();
      await Future.wait(
        batch.map((url) async {
          current[url] = await verify(url);
        }),
      );
      if ((start ~/ concurrency) % 12 == 0 ||
          start + concurrency >= urls.length) {
        await save();
        onProgress?.call(current.length, urls.length);
      }
    }
    for (final item in art) {
      item['verified'] = current[item['url']] == true;
      if (item['verified'] == true) {
        final uri = Uri.parse(item['url'] as String);
        item['thumbnailUrl'] = item['kind'] == 'avatar'
            ? uri.toString()
            : mediaUri(uri.pathSegments.last, width: 240).toString();
      }
    }
    final operators = catalog.people.values.where((p) => p.kind == 'operator');
    final covered = operators
        .where(
          (p) => p.artCandidates.any(
            (a) => a['verified'] == true && a['kind'] == 'elite0',
          ),
        )
        .length;
    return {
      'checkedUrls': current.length,
      'validUrls': current.values.where((v) => v).length,
      'operatorsWithPortrait': covered,
      'operatorPortraitCoverage': operators.isEmpty
          ? 0
          : covered / operators.length,
      'offline': offline,
    };
  }
}
