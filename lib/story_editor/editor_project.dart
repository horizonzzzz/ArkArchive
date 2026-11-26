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

  Map<String, Object> toJson() => {
    'key': key,
    'name': name,
    'width': width,
    'height': height,
    'data': base64Encode(bytes),
  };
  static EditorAsset fromJson(Map<String, dynamic> json) {
    final asset = EditorAsset.create(
      json['name'] as String,
      base64Decode(json['data'] as String),
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

  String value(String key) => args[key] ?? '';
  EditCommand withArgs(Map<String, String> changes) =>
      EditCommand(tag, {...args, ...changes}, raw);

  String get source =>
      raw ??
      '[$tag(${args.entries.map((e) => '${e.key}=${_quote(e.value)}').join(', ')})]';

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

class StoryBeat {
  const StoryBeat(this.title, [this.commands = const []]);
  final String title;
  final List<EditCommand> commands;
  StoryBeat copyWith({String? title, List<EditCommand>? commands}) =>
      StoryBeat(title ?? this.title, commands ?? this.commands);
}

class EditorScene {
  const EditorScene(this.title, this.beats);
  final String title;
  final List<StoryBeat> beats;
  EditorScene copyWith({String? title, List<StoryBeat>? beats}) =>
      EditorScene(title ?? this.title, beats ?? this.beats);
}

class EditorProject {
  EditorProject({
    required this.id,
    required this.title,
    required this.scenes,
    this.assets = const {},
    DateTime? updatedAt,
    this.derivedFrom,
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

  EditorProject copyWith({
    String? id,
    String? title,
    List<EditorScene>? scenes,
    Map<String, EditorAsset>? assets,
    DateTime? updatedAt,
    String? derivedFrom,
  }) => EditorProject(
    id: id ?? this.id,
    title: title ?? this.title,
    scenes: scenes ?? this.scenes,
    assets: assets ?? this.assets,
    updatedAt: updatedAt ?? DateTime.now(),
    derivedFrom: derivedFrom ?? this.derivedFrom,
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
              '\u0001${item.message}': item,
      }.values)
        entry,
    ];
  }

  List<String> validate() =>
      [for (final item in validateIssues()) item.message];

  CompiledProject compile() {
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
          final parsed = StoryScript.parse(raw).commands;
          if (parsed.length != 1) {
            throw FormatException('$location：每项必须对应一条脚本指令');
          }
          final c = parsed.single;
          commands.add(
            StoryCommand(c.tag, c.args, c.text, line + c.line - 1, c.raw),
          );
          locations.add(location);
          source.writeln(raw);
          line += const LineSplitter().convert(raw).length;
        }
        ranges[(s, b)] = (start, commands.length);
      }
    }
    return CompiledProject(
      source.toString(),
      StoryScript(List.unmodifiable(commands)),
      ranges,
      locations,
    );
  }

  Map<String, Object> toJson() => {
    'version': 1,
    'id': id,
    'title': title,
    'scenes': [
      for (final s in scenes)
        {
          'title': s.title,
          'beats': [
            for (final b in s.beats)
              {
                'title': b.title,
                'commands': [for (final c in b.commands) c.source],
              },
          ],
        },
    ],
    'assets': [for (final asset in assets.values) asset.toJson()],
    'updatedAt': updatedAt.toIso8601String(),
    // ignore: use_null_aware_elements
    if (derivedFrom != null) 'derivedFrom': derivedFrom!,
  };

  Uint8List export() =>
      utf8.encode(jsonEncode({...toJson(), 'script': compile().source}));

  static EditorProject decode(Uint8List bytes) {
    if (bytes.length > maxProjectBytes) {
      throw const FormatException('作品文件超过 96 MB');
    }
    try {
      final data = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      if (data['version'] != 1) throw const FormatException('不支持的作品版本');
      final id = data['id'] as String;
      if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(id)) {
        throw const FormatException('作品标识无效');
      }
      final assets = <String, EditorAsset>{};
      for (final value in data['assets'] as List) {
        final asset = EditorAsset.fromJson(value as Map<String, dynamic>);
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
          beats.add(StoryBeat(title(beat['title']), commands));
        }
        if (beats.isEmpty) throw const FormatException('每一幕至少需要一个分镜');
        scenes.add(EditorScene(title(scene['title']), beats));
      }
      if (scenes.isEmpty) throw const FormatException('作品至少需要一幕');
      return EditorProject(
        id: id,
        title: title(data['title']),
        scenes: scenes,
        assets: assets,
        updatedAt: DateTime.tryParse(data['updatedAt'] as String? ?? ''),
        derivedFrom: data['derivedFrom'] as String?,
      );
    } on TypeError {
      throw const FormatException('作品文件结构无效');
    }
  }

  static EditorProject fromScript(String title, StoryScript script) {
    final beats = <StoryBeat>[];
    var commands = <EditCommand>[];
    void flush() {
      if (commands.isEmpty) return;
      beats.add(StoryBeat('分镜 ${beats.length + 1}', commands));
      commands = [];
    }

    for (final command in script.commands) {
      commands.add(EditCommand.fromScript(command));
      if ([
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
    return EditorProject.create(title).copyWith(
      scenes: [
        EditorScene('第一幕', beats.isEmpty ? const [StoryBeat('分镜 1')] : beats),
      ],
    );
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
