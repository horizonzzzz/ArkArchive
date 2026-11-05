import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../runtime/playback_checkpoint.dart';
import '../script.dart';

class PlaybackProgress {
  const PlaybackProgress({
    required this.path,
    required this.scriptHash,
    required this.checkpoint,
  });

  final String path;
  final String scriptHash;
  final PlaybackCheckpoint checkpoint;

  static String fingerprint(StoryScript script) => sha256
      .convert(utf8.encode(jsonEncode(script.commands.map((c) => c.raw).toList())))
      .toString();

  bool matches(StoryScript script) =>
      scriptHash == fingerprint(script) && checkpoint.isValidFor(script);

  Map<String, dynamic> toJson() => {
    'path': path,
    'scriptHash': scriptHash,
    'checkpoint': checkpoint.toJson(),
  };

  factory PlaybackProgress.fromJson(Map<String, dynamic> json) {
    final path = json['path'];
    final hash = json['scriptHash'];
    if (path is! String || path.isEmpty || hash is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
      throw const FormatException('观看记录格式无效');
    }
    return PlaybackProgress(
      path: path,
      scriptHash: hash,
      checkpoint: PlaybackCheckpoint.fromJson(json['checkpoint'] as Map<String, dynamic>),
    );
  }
}
