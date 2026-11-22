import 'dart:convert';
import 'dart:ui';

import 'package:crypto/crypto.dart';

import '../script.dart';
import 'asset_store.dart';

class CharacterArt {
  const CharacterArt({
    required this.body,
    required this.size,
    required this.position,
    this.face,
    this.faceRect,
  });
  final Uri body;
  final Uri? face;
  final Rect? faceRect;
  final Size size;
  final Offset position;
  Iterable<Uri> get assets => [body, ?face];
}

/// 资源条目类别；script 由 StoryRepository 在聚合层补充。
enum AssetKind {
  background,
  cg,
  cutin,
  other,
  character,
  music,
  sfx,
  script,
  video,
}

/// 单个资源文件的导出描述：来源地址与导出目录内的相对路径。
class AssetFile {
  const AssetFile(this.uri, this.exportPath, {this.alternates = const []});

  /// 主来源地址；缓存命中优先，未命中走网络。
  final Uri uri;

  /// 相对导出根目录的路径，固定使用 `/` 分隔。
  final String exportPath;

  /// 主地址取不到时的备用地址（仅脚本镜像使用）。
  final List<Uri> alternates;
}

/// 一次指令引用产生的资源描述；同一曲目前奏与循环体、同一立绘的
/// 身体与表情差分在此层仍是独立引用，由 AssetPackage 聚合成条目。
class AssetRef {
  const AssetRef(this.kind, this.title, this.files, {this.group = ''});
  final AssetKind kind;
  final String title;
  final String group;
  final List<AssetFile> files;
}

/// 只在数据适配层记录 PRTS 的资源规则，播放器运行时不感知服务地址。
class MediaCatalog {
  MediaCatalog({
    required this.variables,
    required this.characters,
    required this.backgroundPpu,
    Uri? assetBase,
  }) : assetBase = assetBase ?? Uri.parse('https://torappu.prts.wiki/assets/'),
       _variableKeys = {
         for (final key in variables.keys) key.toLowerCase(): key,
       },
       _characterKeys = {
         for (final key in characters.keys) key.toLowerCase(): key,
       };
  final Map<String, dynamic> variables;
  final Map<String, dynamic> characters;
  final Map<String, String> _variableKeys;
  final Map<String, String> _characterKeys;
  final Map<String, dynamic> backgroundPpu;
  final Uri assetBase;

  /// 对白字体与滑动遮罩随应用打包，不随剧情下载。
  static const fontAsset = 'assets/fonts/NotoSansHans-Medium.ttf';
  static const slideMaskAsset = 'assets/images/slide_mask.png';

  static final tableUris = [
    Uri.parse(
      'https://torappu.prts.wiki/gamedata/latest/story/story_variables.json',
    ),
    Uri.parse('https://torappu.prts.wiki/assets/avg/character.json'),
    Uri.parse('https://torappu.prts.wiki/assets/avg/background.json'),
  ];

  static Future<MediaCatalog> load(
    AssetStore store, {
    bool transient = false,
  }) async {
    final tables = <Map<String, dynamic>>[];
    for (final uri in tableUris) {
      tables.add(
        jsonDecode(
          utf8.decode(
            await (transient
                ? store.loadTransient(uri)
                : store.loadShared(uri)),
          ),
        ) as Map<String, dynamic>,
      );
    }
    return MediaCatalog(
      variables: {
        ...tables[0],
        if (!tables[0].keys.any((key) => key.toLowerCase() == 'e_snakeslayer'))
          'e_snakeslayer': 'avg_079_daoguang01',
      },
      characters: tables[1],
      backgroundPpu: tables[2],
    );
  }

  Uri image(String key, {bool cg = false, String kind = ''}) {
    if (kind == 'cutin') {
      final filename = 'Avg_${key.toLowerCase().replaceAll('#', '-')}.png';
      final hash = md5.convert(utf8.encode(filename)).toString();
      return Uri.https(
        'media.prts.wiki',
        '/${hash[0]}/${hash.substring(0, 2)}/$filename',
      );
    }
    final dir = kind.isNotEmpty
        ? kind
        : cg
        ? 'images'
        : 'background';
    return assetBase.resolve('avg/$dir/${key.toLowerCase()}.png');
  }

  /// 剧情内嵌视频：`url` 为完整 http(s) 地址时直接使用；其余取值与 `res`
  /// 一样按参考端规则（context.DG_3DzZj.js 的 l()：非 http 一律拼资源根）
  /// 去开头斜杠、整体小写、逐段编码后拼到资源根，例如
  /// `video/act55side/TL02.mp4` →
  /// `https://torappu.prts.wiki/assets/video/act55side/tl02.mp4`。
  /// 两者都为空时返回 null，调用方按 invalid_parameter 处理。
  Uri? video(String url, String res) {
    final direct = url.trim();
    final isHttp = RegExp(r'^https?://', caseSensitive: false).hasMatch(direct);
    var path = (direct.isEmpty || isHttp ? res : direct).trim();
    if (isHttp) {
      return Uri.tryParse(direct);
    }
    while (path.startsWith('/')) {
      path = path.substring(1);
    }
    if (path.isEmpty) return null;
    return assetBase.resolve(
      path.toLowerCase().split('/').map(Uri.encodeComponent).join('/'),
    );
  }

  Uri _characterUri(String path) => assetBase.resolve(
    'avg/characters/${path.split('/').map(Uri.encodeComponent).join('/')}.png',
  );
  Uri? audio(String key) {
    key = key.trim();
    if (key.isEmpty) return null;
    final variable = key.startsWith(r'$') ? key.substring(1) : null;
    var path = variable == null
        ? key
        : (variables[variable] ??
                  variables[_variableKeys[variable.toLowerCase()]])
              ?.toString();
    if (path == null) return null;
    if (path.startsWith('https://') || path.startsWith('http://')) {
      return Uri.parse(path);
    }
    if (path.startsWith('@')) return assetBase.resolve(path.substring(1));
    path = path.toLowerCase();
    if (!path.startsWith('sound_beta_2/')) return null;
    // 逐段编码：路径段中的 #（如 act24side#retro）若不编码会被解析成
    // URI fragment，导致下载到错误地址。
    final relative = path.substring('sound_beta_2/'.length);
    return assetBase.resolve(
      'audio/${relative.split('/').map(Uri.encodeComponent).join('/')}.mp3',
    );
  }

  /// 立绘键的组成：基础键（角色/形态）+ 差分序号、别名与差分体序号。
  static final _characterPattern = RegExp(
    r'^([^#@$]+)(?:#(\d+)|@([^$]+))?(?:\$(\d+))?$',
  );

  /// 立绘引用所属的基础键：同一角色的多个差分按它聚合。
  String? characterBase(String key) =>
      _characterPattern.firstMatch(key.trim().toLowerCase())?[1];

  CharacterArt? character(String key) {
    final match = _characterPattern.firstMatch(key.trim().toLowerCase());
    if (match == null) return null;
    final base = match[1]!;
    final data = characters[_characterKeys[base]] as Map<String, dynamic>?;
    if (data == null) return null;
    final items = (data['array'] as List).cast<Map<String, dynamic>>();
    if (items.isEmpty) return null;
    final index = (int.tryParse(match[2] ?? '') ?? 1) - 1;
    final body = (int.tryParse(match[4] ?? '') ?? 1) - 1;
    Map<String, dynamic>? item;
    if (match[3] != null) {
      for (final candidate in items) {
        if (candidate['alias'].toString().toLowerCase() == match[3]) {
          item = candidate;
          break;
        }
      }
    } else if (match[2] == null && match[4] == null) {
      item = items.first;
    } else {
      final candidates = items.where((i) => i['body'] == body).toList();
      for (final candidate in candidates) {
        if (candidate['index'] == index) {
          item = candidate;
          break;
        }
      }
      if (item == null && !items.first.containsKey('body')) {
        final legacy = match[4] == null
            ? items
            : items
                  .where((i) => i['name'].toString().endsWith('\$${body + 1}'))
                  .toList();
        if (index >= 0 && index < legacy.length) item = legacy[index];
      }
    }
    if (item == null) return null;
    double n(dynamic v) => (v as num?)?.toDouble() ?? 0;
    final size = data['size'] as Map;
    final pos = data['pos'] as Map;
    final group = (item['group'] as num?)?.toInt() ?? -1;
    if (group < 0) {
      final imagePath = item['image'];
      final bodyUri = imagePath is String
          ? _characterUri(imagePath)
          : item['name'] is String
          ? image(item['name'] as String, kind: 'cutin')
          : null;
      if (bodyUri == null) return null;
      return CharacterArt(
        body: bodyUri,
        size: Size(n(size['x']), n(size['y'])),
        position: Offset(n(pos['x']), n(pos['y'])),
      );
    }
    final groups = data['groups'] as List;
    if (group >= groups.length) return null;
    final config = groups[group] as Map;
    if (config['mode'] != 'face_overlay') return null;
    final rect = config['faceRect'] as Map;
    return CharacterArt(
      body: _characterUri(config['base'] as String),
      face: _characterUri(item['face'] as String),
      faceRect: Rect.fromLTWH(
        n(rect['x']),
        n(rect['y']),
        n(rect['w']),
        n(rect['h']),
      ),
      size: Size(n(size['x']), n(size['y'])),
      position: Offset(n(pos['x']), n(pos['y'])),
    );
  }

  /// 素材导出路径的公共前缀检查：仅在资源来自默认资源站时保留上游
  /// 相对结构，其余地址（完整 http URL 等）统一放入 extras/。
  String _assetExportPath(Uri uri, {required String dir}) {
    final segments = uri.pathSegments;
    var matches = uri.host == assetBase.host;
    if (matches) {
      final head = switch (dir) {
        'characters' => 'assets/avg/characters',
        'audio' => 'assets/audio',
        'video' => 'assets/video',
        _ => '',
      }.split('/').where((s) => s.isNotEmpty).toList();
      if (segments.length < head.length) {
        matches = false;
      } else {
        for (var i = 0; i < head.length; i++) {
          if (segments[i] != head[i]) {
            matches = false;
            break;
          }
        }
      }
      if (matches) return [dir, ...segments.skip(head.length)].join('/');
    }
    return 'extras/${segments.isEmpty ? uri.toString() : segments.last}';
  }

  String _imageExportPath(AssetKind kind, Uri uri) {
    final dir = switch (kind) {
      AssetKind.background => 'images/background',
      AssetKind.cg => 'images/cg',
      AssetKind.cutin => 'images/cutin',
      _ => 'images/item',
    };
    return '$dir/${uri.pathSegments.last}';
  }

  static String _stripExtension(String name) {
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// 曲目条目名：去掉扩展名与 intro/loop 后缀，前奏与循环体归为同一首。
  static String _audioTitle(Uri uri) {
    var name = _stripExtension(uri.pathSegments.last);
    for (final suffix in ['_loop', '_intro']) {
      if (name.toLowerCase().endsWith(suffix)) {
        return name.substring(0, name.length - suffix.length);
      }
    }
    return name;
  }

  AssetRef? _characterRef(
    String name,
    int line,
    List<String> warnings, {
    bool warnOnMissing = true,
  }) {
    final base = characterBase(name);
    final art = character(name);
    if (art == null || base == null) {
      if (warnOnMissing) warnings.add('第 $line 行：未找到立绘 $name');
      return null;
    }
    return AssetRef(AssetKind.character, base, [
      for (final uri in art.assets)
        AssetFile(uri, _assetExportPath(uri, dir: 'characters')),
    ], group: base);
  }

  /// 逐条指令收集带分类的资源引用；warnings 与 [dependencies] 一致。
  List<AssetRef> collect(StoryScript script, List<String> warnings) {
    final refs = <AssetRef>[];
    void addImage(String key, AssetKind kind) {
      if (key.isEmpty) return;
      final uri = image(
        key,
        cg: kind == AssetKind.cg,
        kind: switch (kind) {
          AssetKind.background => 'background',
          AssetKind.cg => 'images',
          AssetKind.cutin => 'cutin',
          _ => 'images',
        },
      );
      final name = uri.pathSegments.last;
      refs.add(
        AssetRef(kind, _stripExtension(name), [
          AssetFile(uri, _imageExportPath(kind, uri)),
        ]),
      );
    }

    for (final c in script.commands) {
      if (['background', 'image'].contains(c.tag) &&
          c.value('image').isNotEmpty) {
        addImage(
          c.value('image'),
          c.tag == 'image' ? AssetKind.cg : AssetKind.background,
        );
      }
      if (['gridbg', 'verticalbg', 'largebg', 'largeimg'].contains(c.tag)) {
        final group = c.value('imagegroup').isNotEmpty
            ? c.value('imagegroup')
            : c.value('cggroup');
        final kind = c.value('imagegroup').isNotEmpty
            ? AssetKind.background
            : AssetKind.cg;
        for (final key in group.split('/').where((s) => s.trim().isNotEmpty)) {
          addImage(key, kind);
        }
      }
      if ([
        'charslot',
        'character',
        'interlude',
        'charactercutin',
      ].contains(c.tag)) {
        for (final key in ['name', 'name2']) {
          final name = c.value(key);
          if (name.isEmpty || name == 'char_empty') continue;
          if (c.tag != 'interlude') {
            final ref = _characterRef(name, c.line, warnings);
            if (ref != null) refs.add(ref);
          }
        }
      }
      if (c.tag == 'interlude') {
        final type = c.number('type').toInt();
        final name = c.value('name');
        if (name.isNotEmpty) {
          if (type == 3) {
            // type=3 的切入图允许立绘缺失，静默回退；不产生告警。
            final ref = _characterRef(
              name,
              c.line,
              warnings,
              warnOnMissing: false,
            );
            if (ref != null) {
              refs.add(ref);
            } else {
              addImage(name, AssetKind.cutin);
            }
          } else {
            addImage(name, type == 2 ? AssetKind.background : AssetKind.cutin);
          }
        }
      }
      if (['cgitem', 'showitem', 'blocker'].contains(c.tag)) {
        addImage(c.value('image'), AssetKind.other);
      }
      if (c.tag == 'avgdisplay' &&
          c.value('name').isNotEmpty &&
          ['bg', '5'].contains(c.value('style'))) {
        addImage(c.value('name'), AssetKind.background);
      }
      if (['playmusic', 'playsound'].contains(c.tag)) {
        final files = <AssetFile>[];
        Uri? first;
        for (final key in ['key', 'intro']) {
          if (c.value(key).isEmpty) continue;
          final uri = audio(c.value(key));
          if (uri != null) {
            if (!files.any((file) => file.uri == uri)) {
              files.add(AssetFile(uri, _assetExportPath(uri, dir: 'audio')));
            }
            first ??= uri;
          } else {
            warnings.add('未解析音频：${c.value(key)}');
          }
        }
        if (files.isNotEmpty) {
          refs.add(
            AssetRef(
              c.tag == 'playmusic' ? AssetKind.music : AssetKind.sfx,
              _audioTitle(first!),
              files,
            ),
          );
        }
      }
      if (c.tag == 'video') {
        final uri = video(c.value('url'), c.value('res'));
        if (uri == null) {
          warnings.add('第 ${c.line} 行：video 缺少 url 或 res 参数');
        } else {
          // 无路径段的绝对地址（如 https://x?clip=1）用稳定标题兜底，
          // 不让准备阶段抛错。
          final title = uri.pathSegments.isNotEmpty
              ? _stripExtension(uri.pathSegments.last)
              : 'video';
          refs.add(
            AssetRef(AssetKind.video, title, [
              AssetFile(uri, _assetExportPath(uri, dir: 'video')),
            ], group: title),
          );
        }
      }
    }
    return refs;
  }

  /// 完整缓存的静态依赖集合；与 [collect] 的投影保持一致，避免
  /// “能播放、能缓存，导出却缺素材”。
  Set<Uri> dependencies(StoryScript script, List<String> warnings) => {
    for (final ref in collect(script, warnings)) ...[
      for (final file in ref.files) file.uri,
    ],
  };
}
