import 'dart:convert';

import 'package:flutter/services.dart';

import '../data/asset_store.dart';
import 'fx_asset.dart';
import 'fx_file_stub.dart' if (dart.library.io) 'fx_file_io.dart';

/// 默认使用随应用打包的特效；开发时可指定本地或 HTTP(S) 目录覆盖。
const storyFxRoot = String.fromEnvironment(
  'STORY_FX_ROOT',
  defaultValue: 'asset:///assets/fx-runtime/',
);

String resolveFxName(String raw, Map<String, dynamic> variables) {
  var value = raw.trim();
  if (value.startsWith(r'$')) {
    final key = value.substring(1).toLowerCase();
    value =
        variables.entries
            .where((e) => e.key.toLowerCase() == key)
            .map((e) => e.value.toString())
            .firstOrNull ??
        value;
  }
  value = value.toLowerCase();
  if (!RegExp(r'^[a-z0-9_-]+$').hasMatch(value)) {
    throw FormatException('未解析或无效的特效名称：$raw');
  }
  return value;
}

class FxLoader {
  FxLoader(String root, this.store) : root = directory(root);
  final Uri root;
  final AssetStore store;

  static Uri directory(String value) {
    final normalized = value.replaceAll('\\', '/');
    final uri = RegExp(r'^[a-zA-Z]:/').hasMatch(normalized)
        ? Uri.directory(normalized, windows: true)
        : normalized.startsWith('/')
        ? Uri.directory(normalized)
        : Uri.parse(normalized);
    if (!const ['asset', 'file', 'http', 'https'].contains(uri.scheme)) {
      throw const FormatException('特效目录必须是 asset: URI、绝对目录或 HTTP(S) 地址');
    }
    if (uri.hasQuery || uri.hasFragment) {
      throw const FormatException('特效目录不能包含查询或片段');
    }
    return uri.path.endsWith('/') ? uri : uri.replace(path: '${uri.path}/');
  }

  Future<Uint8List> bytes(Uri uri) async {
    if (uri.scheme == 'asset') {
      final data = await rootBundle.load(
        uri.path.replaceFirst(RegExp(r'^/'), ''),
      );
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    }
    return uri.scheme == 'file' ? readFxFile(uri) : store.load(uri);
  }

  Future<FxAsset> load(String name) async {
    if (!RegExp(r'^[a-z0-9_-]+$').hasMatch(name)) {
      throw const FormatException('无效特效名');
    }
    final base = root.resolve('$name/');
    final asset = FxAsset.parse(
      jsonDecode(utf8.decode(await bytes(base.resolve('fx.json'))))
          as Map<String, dynamic>,
      base: base,
    );
    if (asset.name != name) throw const FormatException('特效名称与目录不一致');
    return asset;
  }
}
