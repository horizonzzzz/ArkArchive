import 'dart:convert';
import 'dart:ui';
import '../script.dart';
import 'asset_store.dart';

class CharacterArt {
  const CharacterArt({required this.body, required this.size, required this.position, this.face, this.faceRect});
  final Uri body;
  final Uri? face;
  final Rect? faceRect;
  final Size size;
  final Offset position;
  Iterable<Uri> get assets => [body, ?face];
}

/// 只在数据适配层记录 PRTS 的资源规则，播放器运行时不感知服务地址。
class MediaCatalog {
  MediaCatalog({required this.variables, required this.characters, required this.backgroundPpu, Uri? assetBase})
      : assetBase = assetBase ?? Uri.parse('https://torappu.prts.wiki/assets/');
  final Map<String, dynamic> variables;
  final Map<String, dynamic> characters;
  final Map<String, dynamic> backgroundPpu;
  final Uri assetBase;
  static final fontUri = Uri.parse('https://static.prts.wiki/NotoSansHans-Medium.woff2');
  static final slideMaskUri = Uri.parse('https://static.prts.wiki/widgets/production/slide_mask.BQ3hXFW7.png');

  static Future<MediaCatalog> load(AssetStore store) async {
    final urls = ['https://torappu.prts.wiki/gamedata/latest/story/story_variables.json',
      'https://torappu.prts.wiki/assets/avg/character.json', 'https://torappu.prts.wiki/assets/avg/background.json'];
    final tables = await Future.wait(urls.map((u) async => jsonDecode(utf8.decode(await store.load(Uri.parse(u)))) as Map<String, dynamic>));
    return MediaCatalog(variables: tables[0], characters: tables[1], backgroundPpu: tables[2]);
  }

  Uri image(String key, {bool cg = false}) => assetBase.resolve('avg/${cg ? 'images/' : 'background/'}${key.toLowerCase()}.png');
  Uri _characterUri(String path) => assetBase.resolve('avg/characters/${path.split('/').map(Uri.encodeComponent).join('/')}.png');
  Uri? audio(String key) {
    if (key.isEmpty) return null;
    var path = key.startsWith(r'$') ? variables[key.substring(1).toLowerCase()]?.toString() : key;
    if (path == null) return null;
    if (path.startsWith('https://') || path.startsWith('http://')) return Uri.parse(path);
    if (path.startsWith('@')) return assetBase.resolve(path.substring(1));
    path = path.toLowerCase();
    if (!path.startsWith('sound_beta_2/')) return null;
    return assetBase.resolve('audio/${path.substring('sound_beta_2/'.length)}.mp3');
  }

  CharacterArt? character(String key) {
    final match = RegExp(r'^([^#@$]+)(?:#(\d+)|@([^$]+))?(?:\$(\d+))?$').firstMatch(key.toLowerCase());
    if (match == null) return null;
    final base = match[1]!;
    final data = characters[base] as Map<String, dynamic>?;
    if (data == null) return null;
    final items = (data['array'] as List).cast<Map<String, dynamic>>();
    if (items.isEmpty) return null;
    final index = (int.tryParse(match[2] ?? '') ?? 1) - 1;
    final body = (int.tryParse(match[4] ?? '') ?? 1) - 1;
    Map<String, dynamic>? item;
    if (match[3] != null) {
      for (final candidate in items) { if (candidate['alias'].toString().toLowerCase() == match[3]) { item = candidate; break; } }
    } else if (match[2] == null && match[4] == null) {
      item = items.first;
    } else {
      final candidates = items.where((i) => i['body'] == body).toList();
      for (final candidate in candidates) { if (candidate['index'] == index) { item = candidate; break; } }
      if (item == null && !items.first.containsKey('body')) {
        final legacy = match[4] == null ? items : items.where((i) => i['name'].toString().endsWith('\$${body + 1}')).toList();
        if (index >= 0 && index < legacy.length) item = legacy[index];
      }
    }
    if (item == null) return null;
    double n(dynamic v) => (v as num?)?.toDouble() ?? 0;
    final size = data['size'] as Map;
    final pos = data['pos'] as Map;
    final group = (item['group'] as num?)?.toInt() ?? -1;
    if (group < 0) {
      return CharacterArt(body: _characterUri(item['image'] as String), size: Size(n(size['x']), n(size['y'])), position: Offset(n(pos['x']), n(pos['y'])));
    }
    final groups = data['groups'] as List;
    if (group >= groups.length) return null;
    final config = groups[group] as Map;
    if (config['mode'] != 'face_overlay') return null;
    final rect = config['faceRect'] as Map;
    return CharacterArt(body: _characterUri(config['base'] as String), face: _characterUri(item['face'] as String),
      faceRect: Rect.fromLTWH(n(rect['x']), n(rect['y']), n(rect['w']), n(rect['h'])),
      size: Size(n(size['x']), n(size['y'])), position: Offset(n(pos['x']), n(pos['y'])));
  }

  Set<Uri> dependencies(StoryScript script, List<String> warnings) {
    final assets = <Uri>{};
    for (final c in script.commands) {
      if (['background', 'image'].contains(c.tag) && c.value('image').isNotEmpty) assets.add(image(c.value('image'), cg: c.tag == 'image'));
      if (['charslot', 'character', 'interlude'].contains(c.tag)) {
        for (final key in ['name', 'name2']) {
          final name = c.value(key);
          if (name.isEmpty || name == 'char_empty') continue;
          final art = character(name);
          if (art == null) { warnings.add('第 ${c.line} 行：未找到立绘 $name'); }
          else { assets.addAll(art.assets); }
        }
      }
      if (['playmusic', 'playsound'].contains(c.tag)) {
        for (final key in ['key', 'intro']) {
          if (c.value(key).isEmpty) continue;
          final uri = audio(c.value(key));
          if (uri != null) { assets.add(uri); } else { warnings.add('未解析音频：${c.value(key)}'); }
        }
      }
      if (c.tag == 'blocker' && ['slider', 'verticalslider'].contains(c.value('style'))) assets.add(slideMaskUri);
    }
    return assets;
  }
}
