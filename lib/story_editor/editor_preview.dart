import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../story_player/data/asset_store.dart';
import '../story_player/data/media_catalog.dart';
import '../story_player/fx/fx_asset.dart';
import '../story_player/fx/fx_loader.dart';
import '../story_player/runtime/just_audio_output.dart';
import '../story_player/runtime/story_engine.dart';
import '../story_player/script.dart';
import 'editor_platform.dart';
import 'editor_project.dart';

const _imageFields = {FieldType.background, FieldType.cg, FieldType.character};
const _audioFields = {FieldType.music, FieldType.sound};

bool isMediaField(FieldType type) =>
    _imageFields.contains(type) ||
    _audioFields.contains(type) ||
    type == FieldType.fx;

class EditorCatalog extends MediaCatalog {
  EditorCatalog(MediaCatalog? prts, this.local)
    : super(
        variables: prts?.variables ?? const {},
        characters: prts?.characters ?? const {},
        backgroundPpu: prts?.backgroundPpu ?? const {},
        assetBase: prts?.assetBase,
      );

  final Map<String, EditorAsset> local;

  @override
  Uri image(String key, {bool cg = false, String kind = ''}) =>
      local[key]?.uri ?? super.image(key, cg: cg, kind: kind);

  @override
  String? characterBase(String key) =>
      local[key]?.isImage == true ? key : super.characterBase(key);
  @override
  Uri? audio(String key) => local[key]?.uri ?? super.audio(key);

  @override
  CharacterArt? character(String key) {
    final asset = local[key];
    if (asset == null) return super.character(key);
    if (!asset.isImage) return null;
    final scale = (720 / asset.height).clamp(0.0, 1.0);
    final size = ui.Size(asset.width * scale, asset.height * scale);
    return CharacterArt(
      body: asset.uri,
      size: size,
      position: ui.Offset(0, -size.height / 2),
    );
  }
}

class PreparedStage {
  PreparedStage(
    this.engine,
    this.catalog,
    this.textures,
    this.audio,
    this.audioFiles,
  );
  final StoryEngine engine;
  final EditorCatalog catalog;
  final Map<Uri, ui.Image> textures;
  final JustAudioOutput? audio;
  final EditorAudioFiles? audioFiles;

  void dispose() {
    engine.dispose();
    final files = audioFiles;
    if (files != null) unawaited(files.dispose());
  }
}

/// 当前创作页独占；只读借用已有 PRTS 缓存，缺失资源临时读取。
class EditorPreviewResources extends ChangeNotifier {
  EditorPreviewResources(this.store);
  final AssetStore store;
  final _textures = <Uri, Future<ui.Image>>{};
  final _assets = <String, Future<FxAsset>>{};
  final _thumbnailValues =
      <({String key, bool cg, bool isCharacter}), ImageProvider?>{};
  final _pendingThumbnails =
      <({String key, bool cg, bool isCharacter}), Future<ImageProvider?>>{};
  static const _maxThumbnails = 64;
  static final _defaultCatalog = MediaCatalog(
    variables: const {},
    characters: const {},
    backgroundPpu: const {},
  );
  Future<MediaCatalog>? _catalog;
  Future<List<String>>? _effects;
  Future<List<String>>? _cgImages;
  bool _closed = false;
  Listenable get mediaAvailability => this;
  final _missingTextures = <Uri>{};
  final _missingEffects = <String>{};
  final _missingAudio = <Uri>{};
  MediaCatalog? _resolvedPrts;

  bool mediaUnavailable(FieldType type, String key) {
    final catalog = _resolvedPrts ?? _defaultCatalog;
    switch (type) {
      case FieldType.background:
      case FieldType.cg:
        final uri = catalog.image(key, cg: type == FieldType.cg);
        return _missingTextures.contains(uri);
      case FieldType.character:
        final uri = catalog.character(key)?.body;
        return uri == null
            ? _resolvedPrts != null
            : _missingTextures.contains(uri);
      case FieldType.music:
      case FieldType.sound:
        final uri = catalog.audio(key);
        return uri == null
            ? !key.startsWith(r'$') || _resolvedPrts != null
            : _missingAudio.contains(uri);
      case FieldType.fx:
        return _missingEffects.contains(key);
      default:
        return false;
    }
  }

  void _rememberThumbnail(
    ({String key, bool cg, bool isCharacter}) cacheKey,
    ImageProvider? provider,
  ) {
    _thumbnailValues.remove(cacheKey);
    while (_thumbnailValues.length >= _maxThumbnails) {
      _thumbnailValues.remove(_thumbnailValues.keys.first);
    }
    _thumbnailValues[cacheKey] = provider;
  }

  /// 同步命中编排台缩略图缓存；未命中返回 null，由调用方按需异步加载。
  ImageProvider? peekThumbnail(
    String key, {
    bool cg = false,
    bool isCharacter = false,
  }) {
    final normalized = key.trim().toLowerCase();
    if (normalized.isEmpty) return null;
    final cacheKey = (key: normalized, cg: cg, isCharacter: isCharacter);
    if (!_thumbnailValues.containsKey(cacheKey)) return null;
    final value = _thumbnailValues.remove(cacheKey);
    _thumbnailValues[cacheKey] = value;
    return value;
  }

  /// 加载并解码降采样后的缩略图 Provider，同键值在当前会话内去重并限制缓存上限。
  Future<ImageProvider?> loadThumbnail(
    String key, {
    bool cg = false,
    bool isCharacter = false,
    String? story,
  }) {
    final raw = key.trim();
    final normalized = raw.toLowerCase();
    if (_closed || normalized.isEmpty) return Future.value(null);
    final cacheKey = (key: normalized, cg: cg, isCharacter: isCharacter);
    if (_thumbnailValues.containsKey(cacheKey)) {
      return Future.value(peekThumbnail(key, cg: cg, isCharacter: isCharacter));
    }
    return _pendingThumbnails.putIfAbsent(cacheKey, () async {
      try {
        Uri? uri;
        if (isCharacter) {
          final catalog = await prts();
          uri = catalog.character(raw)?.body;
        } else {
          uri = _defaultCatalog.image(raw, cg: cg);
        }
        if (uri == null || _closed) return null;
        final data = await store.loadTransient(uri, story: story);
        if (_closed || data.isEmpty) return null;
        final provider = ResizeImage.resizeIfNeeded(
          isCharacter ? 240 : 480,
          null,
          MemoryImage(data),
        );
        _rememberThumbnail(cacheKey, provider);
        return provider;
      } catch (_) {
        if (!_closed) _rememberThumbnail(cacheKey, null);
        return null;
      } finally {
        _pendingThumbnails.remove(cacheKey);
      }
    });
  }

  Future<MediaCatalog> prts() async {
    final pending = _catalog ??= MediaCatalog.load(store, transient: true);
    try {
      return await pending;
    } catch (_) {
      if (identical(_catalog, pending)) _catalog = null;
      rethrow;
    }
  }

  Future<Uint8List> loadBytes(Uri uri) => store.loadTransient(uri);

  Future<List<String>> cgImages() async {
    final pending = _cgImages ??= _loadCgImages();
    try {
      return await pending;
    } catch (_) {
      if (identical(_cgImages, pending)) _cgImages = null;
      rethrow;
    }
  }

  Future<List<String>> _loadCgImages() async {
    final endpoint = Uri.https(
      'torappu.prts.wiki',
      '/api/v1/story-resources/explore',
    );
    const pageSize = 500;
    Future<Map<String, dynamic>> loadPage(int page) async {
      final uri = endpoint.replace(
        queryParameters: {
          'type': 'image',
          'page': '$page',
          'pageSize': '$pageSize',
        },
      );
      return jsonDecode(utf8.decode(await store.loadTransient(uri)))
          as Map<String, dynamic>;
    }

    final first = await loadPage(1);
    final pageCount = first['pageCount'];
    if (pageCount is! int || pageCount < 1 || pageCount > 100) {
      throw const FormatException('PRTS CG 索引页数无效');
    }
    final keys = <String>{};
    void addKeys(Map<String, dynamic> data) {
      final entries = data['entries'];
      if (entries is! List) throw const FormatException('PRTS CG 索引格式无效');
      for (final entry in entries) {
        if (entry is! Map || entry['resource'] is! Map) continue;
        final resource = entry['resource'] as Map;
        final key = resource['id'];
        if (resource['type'] == 'image' &&
            key is String &&
            RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(key)) {
          keys.add(key.toLowerCase());
        }
      }
    }

    addKeys(first);
    for (var page = 2; page <= pageCount; page++) {
      addKeys(await loadPage(page));
    }
    return keys.toList()..sort();
  }

  Future<List<String>> effects() => _effects ??= () async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final names = {
      for (final path in manifest.listAssets())
        if (path.startsWith('assets/fx-runtime/') && path.endsWith('/fx.json'))
          path.split('/')[3],
    }.toList()..sort();
    return names;
  }();

  Future<ui.Image> _texture(Uri uri, Future<Uint8List> Function() load) {
    if (_closed) throw StateError('预览已关闭');
    return _textures.putIfAbsent(uri, () async {
      final codec = await ui.instantiateImageCodec(await load());
      try {
        final image = (await codec.getNextFrame()).image;
        if (_closed) {
          image.dispose();
          throw StateError('预览已关闭');
        }
        return image;
      } finally {
        codec.dispose();
      }
    });
  }

  Future<PreparedStage> prepare(
    EditorProject project,
    CompiledProject compiled, {
    required int end,
    required bool audible,
    required bool Function() active,
  }) async {
    final script = StoryScript(
      compiled.script.commands.take(end).toList(growable: false),
    );
    final warnings = <String>[];
    final locations = {
      for (final (i, c) in script.commands.indexed)
        c.line: compiled.locations[i],
    };
    String locate(String text) => text.replaceFirstMapped(
      RegExp(r'^第 (\d+) 行'),
      (m) => locations[int.parse(m[1]!)] ?? m[0]!,
    );
    bool needsPrts(StoryCommand c) {
      final fields = editorFields[c.tag]?.$2;
      if (fields == null) {
        return const {
          'character',
          'interlude',
          'charactercutin',
        }.contains(c.tag);
      }
      return fields.any((f) {
        final key = c.value(f.key);
        if (key.isEmpty || key.startsWith('local_')) return false;
        return f.type == FieldType.character ||
            key.startsWith(r'$') ||
            (_imageFields.contains(f.type) && !key.startsWith('local_'));
      });
    }

    MediaCatalog? base;
    if (script.commands.any(needsPrts)) {
      try {
        base = await prts();
      } catch (e) {
        warnings.add('PRTS 素材目录暂不可用，请检查资源目录后重试');
      }
    }
    if (!active() || _closed) throw StateError('预览已关闭');
    final catalog = EditorCatalog(base, project.assets);
    if (base != null && !identical(_resolvedPrts, base)) {
      _resolvedPrts = base;
      notifyListeners();
    }
    final local = {for (final a in project.assets.values) a.uri: a};
    Future<Uint8List> bytes(Uri u) async =>
        local[u]?.bytes ??
        await store.loadTransient(u, story: project.derivedFrom);
    final textures = <Uri, ui.Image>{};
    final imageRefs = <Uri, Set<String>>{};
    catalog.collect(
      script,
      warnings,
      onReference: (line, ref) {
        if (const {
          AssetKind.music,
          AssetKind.sfx,
          AssetKind.video,
        }.contains(ref.kind)) {
          return;
        }
        for (final file in ref.files) {
          (imageRefs[file.uri] ??= {}).add(locations[line] ?? '第 $line 行');
        }
      },
    );
    final entries = imageRefs.entries.toList();
    for (var i = 0; i < entries.length && active() && !_closed; i += 6) {
      await Future.wait(
        entries.skip(i).take(6).map((entry) async {
          try {
            textures[entry.key] = await _texture(
              entry.key,
              () => bytes(entry.key),
            );
          } catch (_) {
            if (!_closed && _missingTextures.add(entry.key)) {
              notifyListeners();
            }
            warnings.add(
              '${entry.value.join('、')}：无法加载图片 ${entry.key.pathSegments.last}',
            );
          }
        }),
      );
    }
    final effects = <String, FxAsset>{};
    final effectCommands = script.commands.where(
      (c) =>
          (c.tag == 'bgeffect' || c.tag == 'effect') &&
          c.value('name').isNotEmpty,
    );
    for (final c in effectCommands) {
      if (!active() || _closed) break;
      final key = c.value('name');
      try {
        final name = resolveFxName(key, catalog.variables);
        if (effects.containsKey(name)) continue;
        final loader = FxLoader(storyFxRoot, store, transient: true);
        final asset = await _assets.putIfAbsent(name, () => loader.load(name));
        for (final file in asset.textures) {
          final u = asset.textureUri(file);
          textures[u] = await _texture(u, () => loader.bytes(u));
        }
        effects[name] = asset;
      } catch (_) {
        if (!_closed && _missingEffects.add(key)) {
          notifyListeners();
        }
        warnings.add('${locations[c.line]}：无法加载特效 $key');
      }
    }
    if (!active() || _closed) throw StateError('预览已关闭');
    final audioFiles = audible ? EditorAudioFiles() : null;
    late final StoryEngine engine;
    final audio = audioFiles == null
        ? null
        : JustAudioOutput(
            catalog,
            store,
            resolveSource: (u) => audioFiles.resolve(u, () async {
              try {
                return await bytes(u);
              } catch (_) {
                if (!_closed && _missingAudio.add(u)) {
                  notifyListeners();
                }
                rethrow;
              }
            }),
            onWarning: (message) {
              if (active()) engine.warn(message);
            },
          );
    engine = StoryEngine(
      script,
      audio: audio,
      variables: catalog.variables,
      effectAssets: effects,
      characterArtSize: (key) {
        final art = catalog.character(key);
        return art == null ? null : ui.Offset(art.size.width, art.size.height);
      },
      imageNaturalWidth: (key) =>
          textures[catalog.image(key, cg: true)]?.width.toDouble(),
    );
    engine.warnings.addAll(warnings.map(locate));
    for (final c in script.commands) {
      if (!engine.handlers.containsKey(c.tag) &&
          !const {
            'dialogue',
            'dialog',
            'aside',
            'endtip',
            'multiline',
          }.contains(c.tag)) {
        engine.warnings.add('${locations[c.line]}：当前播放器不支持 ${c.tag}，原样保留');
      }
    }
    return PreparedStage(engine, catalog, textures, audio, audioFiles);
  }

  @override
  void dispose() {
    _closed = true;
    super.dispose();
    _thumbnailValues.clear();
    _pendingThumbnails.clear();
    for (final pending in _textures.values) {
      unawaited(
        pending.then(
          (image) => image.dispose(),
          onError: (Object _, StackTrace _) {},
        ),
      );
    }
  }
}
