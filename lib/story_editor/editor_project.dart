import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../story_player/script.dart';

const maxAssetBytes = 32 * 1024 * 1024;
const maxProjectBytes = 96 * 1024 * 1024;

const imageFormats = {
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'webp': 'image/webp',
};
const audioFormats = {
  'mp3': 'audio/mpeg',
  'wav': 'audio/wav',
  'm4a': 'audio/mp4',
  'ogg': 'audio/ogg',
};

String newProjectId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

class EditorAsset {
  EditorAsset._(
    this.key,
    this.name,
    this.extension,
    this.bytes,
    this.width,
    this.height,
  );

  factory EditorAsset.create(
    String name,
    Uint8List bytes, {
    int width = 0,
    int height = 0,
  }) {
    final extension = name.split('.').last.toLowerCase();
    if (bytes.isEmpty ||
        bytes.length > maxAssetBytes ||
        !{...imageFormats, ...audioFormats}.containsKey(extension) ||
        (imageFormats.containsKey(extension) &&
            (width <= 0 || height <= 0 || width > 8192 || height > 8192))) {
      throw const FormatException('素材格式、尺寸或体积不受支持');
    }
    final hash = sha256.convert(bytes);
    return EditorAsset._(
      'local_$hash',
      name,
      extension,
      bytes.asUnmodifiableView(),
      width,
      height,
    );
  }

  final String key, name, extension;
  final Uint8List bytes;
  final int width, height;
  bool get isImage => imageFormats.containsKey(extension);
  String get mime => (imageFormats[extension] ?? audioFormats[extension])!;
  Uri get uri => Uri(scheme: 'editor-asset', path: '/$key.$extension');

  Map<String, Object> toJson({bool inline = true}) => {
    'key': key,
    'name': name,
    'width': width,
    'height': height,
    if (inline) 'data': base64Encode(bytes),
  };
  static EditorAsset fromJson(Map<String, dynamic> json, {Uint8List? bytes}) {
    final asset = EditorAsset.create(
      json['name'] as String,
      bytes ?? base64Decode(json['data'] as String),
      width: json['width'] as int,
      height: json['height'] as int,
    );
    if (asset.key != json['key']) throw FormatException('素材校验失败：${asset.name}');
    return asset;
  }
}

class EditCommand {
  const EditCommand(this.tag, [this.args = const {}, this.raw]);
  final String tag;
  final Map<String, String> args;
  final String? raw;

  static final _rawCommands = Expando<List<StoryCommand>>();

  /// 供只读投影使用。无效原文保留在项目里，由编译和预览报告。
  StoryCommand? get parsedRaw {
    final source = raw;
    if (source == null) return null;
    final parsed = _rawCommands[this] ??= _parseRaw(source);
    return parsed.length == 1 ? parsed.single : null;
  }

  static List<StoryCommand> _parseRaw(String raw) {
    try {
      return StoryScript.parse(raw).commands;
    } on FormatException {
      return const [];
    }
  }

  String value(String key) => args[key] ?? '';
  EditCommand withArgs(Map<String, String> changes) =>
      EditCommand(tag, {...args, ...changes}, raw);

  static final _sources = Expando<String>();
  String get source =>
      raw ??
      (_sources[this] ??=
          '[$tag(${args.entries.map((e) => '${e.key}=${_quote(e.value)}').join(', ')})]');

  static final _identifier = RegExp(r'^[a-zA-Z_][a-zA-Z_0-9]*$');

  StoryCommand _compile(String source, int line, String location) {
    if (raw == null &&
        _identifier.hasMatch(tag) &&
        args.keys.every(_identifier.hasMatch) &&
        !source.contains('\uFEFF')) {
      final normalized = Map<String, String>.unmodifiable({
        for (final entry in args.entries) entry.key.toLowerCase(): entry.value,
      });
      final name = tag.toLowerCase();
      return StoryCommand(
        name,
        normalized,
        name == 'dialogue' ? normalized['text'] ?? '' : '',
        line,
        source,
      );
    }
    final parsed = StoryScript.parse(source).commands;
    if (parsed.length != 1) {
      throw FormatException('$location：每项必须对应一条脚本指令');
    }
    final c = parsed.single;
    return StoryCommand(c.tag, c.args, c.text, line + c.line - 1, c.raw);
  }

  static String _quote(String value) =>
      '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll('\r', r'\r').replaceAll('\n', r'\n').replaceAll('\t', r'\t')}"';

  factory EditCommand.fromScript(StoryCommand command) {
    final args = {...command.args};
    if (command.tag == 'dialogue') args['text'] = command.text;
    return editorFields.containsKey(command.tag) &&
            (command.tag == 'dialogue' || command.text.isEmpty)
        ? EditCommand(command.tag, args)
        : EditCommand(command.tag, const {}, command.raw);
  }
}

/// 校验问题；locatable 为 true 时携带可跳转的 (幕, 分镜, 指令) 位置。
class EditorIssue {
  const EditorIssue(
    this.message, {
    this.sceneIndex = -1,
    this.beatIndex = -1,
    this.commandIndex = -1,
  });

  final String message;
  final int sceneIndex, beatIndex, commandIndex;

  bool get locatable => sceneIndex >= 0 && beatIndex >= 0 && commandIndex >= 0;
}

/// 标记预设色键（用于分镜与指令标记）。
const editorMarkerColors = <String, int>{
  'amber': 0xFFE5A93B,
  'red': 0xFFE06C75,
  'cyan': 0xFF56B6C2,
  'green': 0xFF98C379,
  'purple': 0xFFC678DD,
};

/// 标记颜色的中文说明。
const editorMarkerLabels = <String, String>{
  'amber': '待核对',
  'red': '问题',
  'cyan': '重点',
  'green': '完成',
  'purple': '创意',
};

/// 分镜或幕的轻量标记（颜色键 + 可选备注）。
class EditorMarker {
  const EditorMarker({this.color = '', this.note = ''});

  final String color;
  final String note;

  bool get isEmpty => color.isEmpty && note.trim().isEmpty;
  bool get isNotEmpty => !isEmpty;

  EditorMarker copyWith({String? color, String? note}) =>
      EditorMarker(color: color ?? this.color, note: note ?? this.note);

  Map<String, Object> toJson() => {
    if (color.isNotEmpty) 'color': color,
    if (note.isNotEmpty) 'note': note,
  };

  static EditorMarker fromJson(Object? raw) {
    if (raw is! Map) return const EditorMarker();
    final color = raw['color'] is String ? raw['color'] as String : '';
    final note = raw['note'] is String ? raw['note'] as String : '';
    return EditorMarker(
      color: editorMarkerColors.containsKey(color) ? color : '',
      note: note.length > 200 ? note.substring(0, 200) : note,
    );
  }
}

/// 上次编辑位置，用于重新打开作品时恢复视口焦点。
class EditorPosition {
  const EditorPosition({this.scene = 0, this.beat = 0, this.command = -1});

  final int scene;
  final int beat;
  final int command;

  Map<String, Object> toJson() => {
    'scene': scene,
    'beat': beat,
    'command': command,
  };

  static EditorPosition? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final s = raw['scene'];
    final b = raw['beat'];
    final c = raw['command'];
    if (s is! int || b is! int || c is! int) return null;
    return EditorPosition(scene: s, beat: b, command: c);
  }
}

class _Duration {
  const _Duration(this.value);
  final double value;
}

class StoryBeat {
  const StoryBeat(
    this.title, [
    this.commands = const [],
    this.marker = const EditorMarker(),
  ]);
  final String title;
  final List<EditCommand> commands;
  final EditorMarker marker;

  StoryBeat copyWith({
    String? title,
    List<EditCommand>? commands,
    EditorMarker? marker,
  }) => StoryBeat(
    title ?? this.title,
    commands ?? this.commands,
    marker ?? this.marker,
  );

  /// 估算该分镜演出时长（秒），用于编排台、结构树与台本时间轴。
  static final _durations = Expando<_Duration>();
  double get estimatedSeconds => (_durations[this] ??= _Duration(
    commands.fold(0.0, (sum, c) => sum + estimateCommandSeconds(c)),
  )).value;

  /// 分镜内首句可读文案（对白/舞台文字），无则返回空字符串。
  String get leadLine {
    for (final c in commands) {
      if (c.tag == 'dialogue') {
        final text = c.value('text').trim();
        if (text.isNotEmpty) {
          final name = c.value('name').trim();
          return name.isEmpty ? text : '$name：$text';
        }
      } else if (c.tag == 'subtitle') {
        final text = c.value('text').trim();
        if (text.isNotEmpty) return text;
      }
    }
    return '';
  }

  bool get hasAudio => commands.any(
    (c) =>
        c.tag == 'playmusic' ||
        c.tag == 'playsound' ||
        c.tag == 'stopmusic' ||
        c.tag == 'stopsound',
  );

  bool get hasFx => commands.any(
    (c) =>
        c.tag == 'bgeffect' ||
        c.tag == 'effect' ||
        c.tag == 'blocker' ||
        c.tag == 'camerashake' ||
        c.tag == 'cameraeffect',
  );

  bool get hasBranch => commands.any(
    (c) => c.tag == 'decision' || c.tag == 'predicate' || c.tag == 'warp',
  );

  /// 仅与分镜视觉末态相关的轻量签名，用于编排台缩略图缓存去重。
  String get visualSignature {
    final buf = StringBuffer();
    for (final c in commands) {
      if (c.tag == 'background' ||
          c.tag == 'image' ||
          c.tag == 'charslot' ||
          c.tag == 'character' ||
          c.tag == 'subtitle' ||
          c.tag == 'blocker' ||
          c.tag == 'dialogue') {
        buf
          ..write(c.tag)
          ..write(':')
          ..write(c.source)
          ..write('\n');
      }
    }
    return buf.toString();
  }
}

/// 估算单条指令播放耗时（秒）。
double estimateCommandSeconds(EditCommand c) {
  switch (c.tag) {
    case 'dialogue':
      final len = c.value('text').trim().length;
      return (1.6 + len * 0.08).clamp(1.6, 8.0);
    case 'subtitle':
      final text = c.value('text').trim();
      return text.isEmpty ? 0.3 : (1.5 + text.length * 0.08).clamp(1.5, 6.0);
    case 'delay':
      return (double.tryParse(c.value('time')) ?? 1.0).clamp(0.1, 30.0);
    case 'blocker':
    case 'background':
    case 'image':
    case 'bgeffect':
    case 'effect':
      final fade = double.tryParse(c.value('fadetime')) ?? 0;
      return c.value('block') == 'true' ? fade.clamp(0.0, 15.0) : 0.0;
    case 'character':
      final fade = double.tryParse(c.value('fadetime')) ?? .15;
      return fade.clamp(0.0, 15.0);
    case 'charslot':
      final dur = double.tryParse(c.value('duration')) ?? 0;
      return c.value('isblock') == 'true' ? dur.clamp(0.0, 15.0) : 0.0;
    default:
      return 0.0;
  }
}

/// 将秒数格式化为简短时长（如 12s / 1m08s）。
String formatEstimatedDuration(double seconds) {
  final rounded = seconds.round();
  if (rounded < 60) return '${rounded}s';
  final m = rounded ~/ 60;
  final s = rounded % 60;
  return '${m}m${s.toString().padLeft(2, '0')}s';
}

class EditorScene {
  const EditorScene(
    this.title,
    this.beats, [
    this.marker = const EditorMarker(),
  ]);
  final String title;
  final List<StoryBeat> beats;
  final EditorMarker marker;

  EditorScene copyWith({
    String? title,
    List<StoryBeat>? beats,
    EditorMarker? marker,
  }) => EditorScene(
    title ?? this.title,
    beats ?? this.beats,
    marker ?? this.marker,
  );

  static final _durations = Expando<_Duration>();
  double get estimatedSeconds => (_durations[this] ??= _Duration(
    beats.fold(0.0, (sum, b) => sum + b.estimatedSeconds),
  )).value;
}

class EditorProject {
  EditorProject({
    required this.id,
    required this.title,
    required this.scenes,
    this.assets = const {},
    DateTime? updatedAt,
    this.derivedFrom,
    this.lastPosition,
  }) : updatedAt = updatedAt ?? DateTime.now();
  factory EditorProject.create(String title) => EditorProject(
    id: newProjectId(),
    title: title,
    scenes: const [
      EditorScene('第一幕', [StoryBeat('分镜 1')]),
    ],
  );

  final String id, title;
  final List<EditorScene> scenes;
  final Map<String, EditorAsset> assets;
  final DateTime updatedAt;
  final String? derivedFrom;
  final EditorPosition? lastPosition;

  late final double estimatedSeconds = scenes.fold(
    0.0,
    (sum, s) => sum + s.estimatedSeconds,
  );

  late final int beatCount = scenes.fold(0, (sum, s) => sum + s.beats.length);

  EditorProject copyWith({
    String? id,
    String? title,
    List<EditorScene>? scenes,
    Map<String, EditorAsset>? assets,
    DateTime? updatedAt,
    String? derivedFrom,
    EditorPosition? lastPosition,
  }) => EditorProject(
    id: id ?? this.id,
    title: title ?? this.title,
    scenes: scenes ?? this.scenes,
    assets: assets ?? this.assets,
    updatedAt: updatedAt ?? DateTime.now(),
    derivedFrom: derivedFrom ?? this.derivedFrom,
    lastPosition: lastPosition ?? this.lastPosition,
  );

  EditorProject touch() => copyWith(updatedAt: DateTime.now());

  /// 校验作品并返回带位置的问题列表，供编辑器「前往」定位使用。
  List<EditorIssue> validateIssues() {
    final CompiledProject compiled;
    try {
      compiled = compile();
    } on FormatException catch (e) {
      return [EditorIssue(e.message.toString())];
    }
    // compile() 按 幕 → 分镜 → 指令 顺序展开，这里同步生成地址映射。
    final addresses = <(int, int, int)>[];
    for (final (s, scene) in scenes.indexed) {
      for (final (b, beat) in scene.beats.indexed) {
        for (var i = 0; i < beat.commands.length; i++) {
          addresses.add((s, b, i));
        }
      }
    }
    assert(addresses.length == compiled.script.commands.length);
    EditorIssue issue(int index, String message) {
      final (s, b, c) = addresses[index];
      return EditorIssue(message, sceneIndex: s, beatIndex: b, commandIndex: c);
    }

    final issues = <EditorIssue>[];
    final labels = {
      for (final c in compiled.script.commands)
        if (c.tag == 'label') c.value('name'),
    };
    for (final (i, command) in compiled.script.commands.indexed) {
      final place = compiled.locations[i];
      if (command.tag == 'warp' && !labels.contains(command.value('name'))) {
        issues.add(issue(i, '$place：跳转目标不存在：${command.value('name')}'));
      }
      for (final field
          in editorFields[command.tag]?.$2 ?? const <EditorField>[]) {
        final value = command.value(field.key);
        if (value.isEmpty) {
          if (field.key == 'key' &&
              (field.type == FieldType.music ||
                  field.type == FieldType.sound)) {
            issues.add(issue(i, '$place：未选择${field.label}'));
          }
          continue;
        }
        if (field.isAsset && value.startsWith('local_')) {
          final asset = assets[value];
          if (asset == null) {
            issues.add(issue(i, '$place：本地素材缺失：$value'));
          } else if (field.isImage != asset.isImage) {
            issues.add(issue(i, '$place：素材类型与${field.label}不符'));
          }
        }
        if (field.key == 'posfrom' || field.key == 'posto') {
          final point = value.split(',').map(double.tryParse).toList();
          if (point.length != 2 || point.any((n) => n == null || !n.isFinite)) {
            issues.add(issue(i, '$place：${field.label}应为两个数字，以逗号分隔'));
          } else if (point[0]!.abs() > 1280 || point[1]!.abs() > 720) {
            issues.add(issue(i, '$place：${field.label}超出舞台范围'));
          }
        }
        if (field.type != FieldType.number) continue;
        final n = double.tryParse(value);
        if (n == null || !n.isFinite) {
          issues.add(issue(i, '$place：${field.label}不是有效数字'));
        } else if ((field.key == 'x' || field.key == 'y') &&
            (n.abs() > (field.key == 'x' ? 1280 : 720) ||
                (command.tag == 'subtitle' && n < 0))) {
          issues.add(issue(i, '$place：${field.label}超出舞台范围'));
        }
      }
    }
    // 按消息 + 位置去重并保持顺序：同名分镜会产生相同消息但不同地址，
    // 仅按消息去重会丢掉前一个问题的「前往」定位。
    return [
      for (final entry in {
        for (final item in issues)
          '${item.sceneIndex}:${item.beatIndex}:${item.commandIndex}'
                  '\u0001${item.message}':
              item,
      }.values)
        entry,
    ];
  }

  List<String> validate() => [
    for (final item in validateIssues()) item.message,
  ];

  late final _compilation = _tryCompile();

  CompiledProject compile() => switch (_compilation) {
    final CompiledProject compiled => compiled,
    final FormatException error => throw error,
    _ => throw StateError('编译结果无效'),
  };

  Object _tryCompile() {
    try {
      return _compile();
    } on FormatException catch (error) {
      return error;
    }
  }

  CompiledProject _compile() {
    final source = StringBuffer();
    final commands = <StoryCommand>[];
    final ranges = <(int, int), (int, int)>{};
    final locations = <String>[];
    var line = 1;
    for (final (s, scene) in scenes.indexed) {
      for (final (b, beat) in scene.beats.indexed) {
        final start = commands.length;
        for (final (i, command) in beat.commands.indexed) {
          final location = '${scene.title} / ${beat.title} / 指令 ${i + 1}';
          final raw = command.source;
          commands.add(command._compile(raw, line, location));
          locations.add(location);
          source.writeln(raw);
          line += command.raw == null && !raw.contains(RegExp(r'[\r\n]'))
              ? 1
              : const LineSplitter().convert(raw).length;
        }
        ranges[(s, b)] = (start, commands.length);
      }
    }
    return CompiledProject(
      source.toString(),
      StoryScript(List.unmodifiable(commands)),
      Map.unmodifiable(ranges),
      List.unmodifiable(locations),
    );
  }

  Map<String, Object> toJson({bool inlineAssets = true}) => {
    'version': 1,
    if (!inlineAssets) 'draftAssets': 1,
    'id': id,
    'title': title,
    'scenes': [
      for (final s in scenes)
        {
          'title': s.title,
          if (s.marker.isNotEmpty) 'marker': s.marker.toJson(),
          'beats': [
            for (final b in s.beats)
              {
                'title': b.title,
                if (b.marker.isNotEmpty) 'marker': b.marker.toJson(),
                'commands': [for (final c in b.commands) c.source],
              },
          ],
        },
    ],
    'assets': [
      for (final asset in assets.values) asset.toJson(inline: inlineAssets),
    ],
    'updatedAt': updatedAt.toIso8601String(),
    // ignore: use_null_aware_elements
    if (derivedFrom != null) 'derivedFrom': derivedFrom!,
    // ignore: use_null_aware_elements
    if (lastPosition != null) 'lastPosition': lastPosition!.toJson(),
  };

  Uint8List export() =>
      utf8.encode(jsonEncode({...toJson(), 'script': compile().source}));

  Uint8List encodeDraft() =>
      utf8.encode(jsonEncode(toJson(inlineAssets: false)));

  static final _assetKey = RegExp(r'^local_[a-f0-9]{64}$');

  static Future<EditorProject> decodeDraft(
    Uint8List bytes,
    Future<Uint8List?> Function(String key) loadAsset,
  ) async {
    if (bytes.length > maxProjectBytes) {
      throw const FormatException('作品文件超过 96 MB');
    }
    final data = jsonDecode(utf8.decode(bytes));
    if (data is! Map<String, dynamic> || data['draftAssets'] != 1) {
      return decode(bytes);
    }
    final draftId = data['id'];
    if (draftId is! String || !RegExp(r'^[a-f0-9]{32}$').hasMatch(draftId)) {
      throw const FormatException('草稿标识无效');
    }
    final assets = data['assets'];
    if (assets is! List) throw const FormatException('草稿素材列表无效');
    final blobs = <String, Uint8List>{};
    var totalBytes = bytes.length;
    for (final value in assets) {
      if (value is! Map<String, dynamic>) {
        throw const FormatException('草稿素材结构无效');
      }
      final key = value['key'];
      if (key is! String || !_assetKey.hasMatch(key)) {
        throw const FormatException('草稿素材标识无效');
      }
      final blob = await loadAsset('$draftId/$key');
      if (blob == null ||
          blob.length > maxAssetBytes ||
          (totalBytes += blob.length) > maxProjectBytes) {
        throw FormatException('草稿素材缺失或超过体积限制：$key');
      }
      blobs[key] = blob;
    }
    return _decodeJson(data, blobs: blobs);
  }

  static EditorProject decode(Uint8List bytes) {
    if (bytes.length > maxProjectBytes) {
      throw const FormatException('作品文件超过 96 MB');
    }
    final data = jsonDecode(utf8.decode(bytes));
    if (data is! Map<String, dynamic>) {
      throw const FormatException('作品文件结构无效');
    }
    return _decodeJson(data);
  }

  static EditorProject _decodeJson(
    Map<String, dynamic> data, {
    Map<String, Uint8List> blobs = const {},
  }) {
    try {
      if (data['version'] != 1) throw const FormatException('不支持的作品版本');
      final id = data['id'] as String;
      if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(id)) {
        throw const FormatException('作品标识无效');
      }
      final assets = <String, EditorAsset>{};
      for (final value in data['assets'] as List) {
        final assetData = value as Map<String, dynamic>;
        final asset = EditorAsset.fromJson(
          assetData,
          bytes: blobs[assetData['key']],
        );
        if (assets.containsKey(asset.key)) {
          throw const FormatException('作品包含重复素材');
        }
        assets[asset.key] = asset;
      }
      String title(dynamic value) {
        if (value is! String || value.trim().isEmpty || value.length > 120) {
          throw const FormatException('标题无效');
        }
        return value;
      }

      final scenes = <EditorScene>[];
      for (final scene in data['scenes'] as List) {
        final beats = <StoryBeat>[];
        for (final beat in scene['beats'] as List) {
          final commands = <EditCommand>[];
          for (final raw in beat['commands'] as List) {
            final parsed = StoryScript.parse(raw as String).commands;
            if (parsed.length != 1 || parsed.single.raw != raw) {
              throw const FormatException('分镜指令格式无效');
            }
            commands.add(EditCommand.fromScript(parsed.single));
          }
          beats.add(
            StoryBeat(
              title(beat['title']),
              commands,
              EditorMarker.fromJson(beat['marker']),
            ),
          );
        }
        if (beats.isEmpty) throw const FormatException('每一幕至少需要一个分镜');
        scenes.add(
          EditorScene(
            title(scene['title']),
            beats,
            EditorMarker.fromJson(scene['marker']),
          ),
        );
      }
      if (scenes.isEmpty) throw const FormatException('作品至少需要一幕');
      return EditorProject(
        id: id,
        title: title(data['title']),
        scenes: scenes,
        assets: assets,
        updatedAt: DateTime.tryParse(data['updatedAt'] as String? ?? ''),
        derivedFrom: data['derivedFrom'] as String?,
        lastPosition: EditorPosition.fromJson(data['lastPosition']),
      );
    } on TypeError {
      throw const FormatException('作品文件结构无效');
    }
  }

  static EditorProject fromScript(String title, StoryScript script) {
    final beats = <StoryBeat>[];
    final scenes = <EditorScene>[];
    var commands = <EditCommand>[];
    void flushScene() {
      if (beats.isEmpty) return;
      scenes.add(
        EditorScene('第 ${scenes.length + 1} 段', List.unmodifiable(beats)),
      );
      beats.clear();
    }

    String? background;
    void flush() {
      if (commands.isEmpty) return;
      beats.add(StoryBeat('分镜 ${beats.length + 1}', commands));
      commands = [];
      if (beats.length == 30) flushScene();
    }

    for (final command in script.commands) {
      if (command.tag == 'background' && command.value('image').isNotEmpty) {
        final next = command.value('image');
        if (background != null &&
            next != background &&
            beats.length >= 8 &&
            commands.isEmpty) {
          flushScene();
        }
        background = next;
      }
      commands.add(EditCommand.fromScript(command));
      if (const [
        'dialogue',
        'dialog',
        'aside',
        'subtitle',
        'decision',
      ].contains(command.tag)) {
        flush();
      }
    }
    flush();
    flushScene();
    if (scenes.isEmpty) {
      scenes.add(const EditorScene('第 1 段', [StoryBeat('分镜 1')]));
    }
    return EditorProject.create(title)
        .copyWith(scenes: List.unmodifiable(scenes));
  }
}

class CompiledProject {
  const CompiledProject(this.source, this.script, this.ranges, this.locations);
  final String source;
  final StoryScript script;
  final Map<(int, int), (int, int)> ranges;
  final List<String> locations;
}

enum FieldType {
  text,
  multiline,
  number,
  toggle,
  background,
  cg,
  character,
  music,
  sound,
  fx,
  choice,
}

class EditorField {
  const EditorField(
    this.key,
    this.label, [
    this.type = FieldType.text,
    this.initial = '',
    this.options = const {},
  ]);
  final String key, label, initial;
  final FieldType type;
  final Map<String, String> options;
  bool get isImage => const {
    FieldType.background,
    FieldType.cg,
    FieldType.character,
  }.contains(type);
  bool get isAsset =>
      isImage || type == FieldType.music || type == FieldType.sound;
}

const _adapt = EditorField('screenadapt', '画面适配', FieldType.choice, '', {
  'coverall': '铺满',
  'showall': '完整显示',
  'fill': '拉伸',
  '': '原始尺寸',
});
const _x = EditorField('x', 'X', FieldType.number, '0');
const _y = EditorField('y', 'Y', FieldType.number, '0');
const _fade = EditorField('fadetime', '淡入淡出（秒）', FieldType.number, '0');
const _volume = EditorField('volume', '音量（0–1）', FieldType.number, '1');
const _block = EditorField('block', '等待演出完成', FieldType.toggle, 'false');
const _slot = EditorField('slot', '站位', FieldType.choice, 'm', {
  'l': '左',
  'm': '中',
  'r': '右',
});
const _fx = [
  EditorField('name', '特效（留空清除）', FieldType.fx),
  EditorField('layer', '图层（清除时留空=全部）', FieldType.number, '0'),
  _x,
  _y,
  EditorField('roz', '平面旋转（度）', FieldType.number, '0'),
  EditorField('rox', 'X 轴旋转（度）', FieldType.number, '0'),
  EditorField('roy', 'Y 轴旋转（度）', FieldType.number, '0'),
  EditorField('flip', '镜像', FieldType.choice, '0', {
    '0': '不翻转',
    '1': '水平',
    '2': '垂直',
    '3': '水平和垂直',
  }),
  EditorField('delay', '延迟（秒）', FieldType.number, '0'),
  EditorField('fade', '渐变', FieldType.toggle, 'false'),
  _fade,
  _block,
];

const editorFields = <String, (String, List<EditorField>)>{
  'dialogue': (
    '对白',
    [
      EditorField('name', '说话人'),
      EditorField('text', '台词', FieldType.multiline),
    ],
  ),
  'dialog': ('清除对白框', []),
  'background': (
    '背景',
    [
      EditorField('image', '背景（留空清除）', FieldType.background),
      _x,
      _y,
      _adapt,
      _fade,
      _block,
    ],
  ),
  'image': (
    '插图 / CG',
    [EditorField('image', '插图（留空清除）', FieldType.cg), _x, _y, _fade, _block],
  ),
  'character': (
    '立绘（旧版双人指令）',
    [
      EditorField('name', '左侧 / 中间立绘', FieldType.character),
      EditorField('name2', '右侧立绘（可选）', FieldType.character),
      EditorField('focus', '焦点', FieldType.choice, '0', {
        '0': '全部明亮',
        '1': '左侧 / 中间明亮',
        '2': '右侧明亮',
        '3': '全部变暗',
      }),
      EditorField('fadetime', '淡入淡出（秒）', FieldType.number, '0.15'),
      EditorField('enter', '左侧 / 中间入场方向', FieldType.choice, '', {
        '': '无',
        'left': '从左',
        'right': '从右',
        'up': '从上',
        'down': '从下',
      }),
      EditorField('enter2', '右侧入场方向', FieldType.choice, '', {
        '': '无',
        'left': '从左',
        'right': '从右',
        'up': '从上',
        'down': '从下',
      }),
      EditorField('xpos1', '左侧 / 中间 X', FieldType.number, '0'),
      EditorField('ypos1', '左侧 / 中间 Y', FieldType.number, '0'),
      EditorField('xpos2', '右侧 X', FieldType.number, '0'),
      EditorField('ypos2', '右侧 Y', FieldType.number, '0'),
    ],
  ),
  'charslot': (
    '立绘',
    [
      _slot,
      EditorField('name', '立绘或表情差分', FieldType.character),
      EditorField('posfrom', '起点坐标 X,Y', FieldType.text),
      EditorField('posto', '终点坐标 X,Y', FieldType.text, '0,0'),
      EditorField('duration', '过渡（秒）', FieldType.number, '0'),
      EditorField('isblock', '等待演出完成', FieldType.toggle, 'false'),
    ],
  ),
  'subtitle': (
    '舞台文字',
    [
      EditorField('text', '文字（留空清除）', FieldType.multiline),
      EditorField('x', 'X', FieldType.number, '240'),
      EditorField('y', 'Y', FieldType.number, '300'),
      EditorField('width', '宽度', FieldType.number, '800'),
      EditorField('size', '字号', FieldType.number, '36'),
      EditorField('alignment', '对齐', FieldType.choice, 'center', {
        'left': '左',
        'center': '居中',
        'right': '右',
      }),
    ],
  ),
  'playmusic': (
    '播放 BGM',
    [
      EditorField('key', 'BGM', FieldType.music),
      EditorField('intro', '前奏（可选）', FieldType.music),
      _volume,
      EditorField('crossfade', '交叉淡化（秒）', FieldType.number, '0'),
    ],
  ),
  'stopmusic': ('停止 BGM', [_fade]),
  'playsound': (
    '播放音效',
    [
      EditorField('key', '音效', FieldType.sound),
      EditorField('channel', '声道（可选）'),
      _volume,
      EditorField('loop', '循环', FieldType.toggle, 'false'),
    ],
  ),
  'stopsound': ('停止音效', [EditorField('channel', '声道（留空停止全部）'), _fade]),
  'delay': ('等待', [EditorField('time', '秒', FieldType.number, '1')]),
  'blocker': (
    '遮罩',
    [
      EditorField('r', '红（0–1）', FieldType.number, '0'),
      EditorField('g', '绿（0–1）', FieldType.number, '0'),
      EditorField('b', '蓝（0–1）', FieldType.number, '0'),
      EditorField('a', '不透明度（0–1）', FieldType.number, '1'),
      _fade,
      _block,
    ],
  ),
  'bgeffect': ('持续特效', _fx),
  'effect': ('单次特效', _fx),
};

/// 剧本台与台本导出的单条对白/舞台文字行。
class ScriptRowRef {
  const ScriptRowRef({
    required this.sceneIndex,
    required this.beatIndex,
    required this.commandIndex,
    required this.sceneTitle,
    required this.beatTitle,
    required this.command,
  });

  final int sceneIndex;
  final int beatIndex;
  final int commandIndex;
  final String sceneTitle;
  final String beatTitle;
  final EditCommand command;

  String get speaker =>
      command.tag == 'dialogue' ? command.value('name') : '[舞台文字]';
  String get text => command.value('text');
  bool get isDialogue => command.tag == 'dialogue';
}

/// 收集作品中所有对白与舞台文字行（可按幕过滤）。
List<ScriptRowRef> collectScriptRows(EditorProject project, {int? sceneIndex}) {
  final rows = <ScriptRowRef>[];
  for (final (s, scene) in project.scenes.indexed) {
    if (sceneIndex != null && s != sceneIndex) continue;
    for (final (b, beat) in scene.beats.indexed) {
      for (final (c, command) in beat.commands.indexed) {
        if (command.tag == 'dialogue' || command.tag == 'subtitle') {
          rows.add(
            ScriptRowRef(
              sceneIndex: s,
              beatIndex: b,
              commandIndex: c,
              sceneTitle: scene.title,
              beatTitle: beat.title,
              command: command,
            ),
          );
        }
      }
    }
  }
  return rows;
}

/// 导出可读纯文本台本（TXT）。
String exportScriptTxt(EditorProject project, {int? sceneIndex}) {
  final buf = StringBuffer()..writeln(project.title);
  var lastScene = -1;
  var lastBeat = -1;
  for (final row in collectScriptRows(project, sceneIndex: sceneIndex)) {
    if (row.sceneIndex != lastScene) {
      buf
        ..writeln()
        ..writeln('=== ${row.sceneTitle} ===');
      lastScene = row.sceneIndex;
      lastBeat = -1;
    }
    if (row.beatIndex != lastBeat) {
      buf.writeln('--- ${row.beatTitle} ---');
      lastBeat = row.beatIndex;
    }
    final text = row.text.trim();
    if (text.isEmpty) continue;
    if (row.isDialogue) {
      final speaker = row.speaker.trim();
      buf.writeln(speaker.isEmpty ? text : '$speaker：$text');
    } else {
      buf.writeln('[文字] $text');
    }
  }
  return buf.toString();
}

String _csvCell(String value) {
  final needsQuote =
      value.contains(',') ||
      value.contains('"') ||
      value.contains('\n') ||
      value.contains('\r');
  if (!needsQuote) return value;
  return '"${value.replaceAll('"', '""')}"';
}

/// 导出 UTF-8 CSV 表格台本（含 BOM 便于 Excel 直接打开）。
String exportScriptCsv(EditorProject project, {int? sceneIndex}) {
  final buf = StringBuffer(
    '${String.fromCharCode(0xFEFF)}幕,分镜,序号,类型,说话人,台词\r\n',
  );
  for (final row in collectScriptRows(project, sceneIndex: sceneIndex)) {
    final fields = [
      row.sceneTitle,
      row.beatTitle,
      '${row.commandIndex + 1}',
      row.isDialogue ? '对白' : '舞台文字',
      row.isDialogue ? row.speaker : '',
      row.text,
    ];
    buf.writeln(fields.map(_csvCell).join(','));
  }
  return buf.toString();
}

String _srtTimestamp(double seconds) {
  final totalMs = (seconds * 1000).round().clamp(0, 359999999);
  final h = totalMs ~/ 3600000;
  final m = (totalMs % 3600000) ~/ 60000;
  final s = (totalMs % 60000) ~/ 1000;
  final ms = totalMs % 1000;
  return '${h.toString().padLeft(2, '0')}:'
      '${m.toString().padLeft(2, '0')}:'
      '${s.toString().padLeft(2, '0')},'
      '${ms.toString().padLeft(3, '0')}';
}

/// 导出按估算时长顺序排列的 SRT 字幕文件。
String exportScriptSrt(EditorProject project, {int? sceneIndex}) {
  final buf = StringBuffer();
  var cursor = 0.0;
  var index = 1;
  for (final (s, scene) in project.scenes.indexed) {
    if (sceneIndex != null && s != sceneIndex) continue;
    for (final beat in scene.beats) {
      for (final command in beat.commands) {
        final dur = estimateCommandSeconds(command);
        if (command.tag == 'dialogue' || command.tag == 'subtitle') {
          final text = command.value('text').trim();
          if (text.isNotEmpty) {
            final start = cursor;
            final end = cursor + (dur > 0 ? dur : 2.0);
            final speaker = command.tag == 'dialogue'
                ? command.value('name').trim()
                : '';
            final line = speaker.isEmpty ? text : '$speaker：$text';
            buf
              ..writeln(index)
              ..writeln('${_srtTimestamp(start)} --> ${_srtTimestamp(end)}')
              ..writeln(line)
              ..writeln();
            index++;
          }
        }
        cursor += dur;
      }
    }
  }
  return buf.toString();
}
