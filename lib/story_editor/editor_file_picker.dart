import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';

import 'editor_project.dart';

/// image 为 null 时选择作品文件，否则选择相应类型的本地素材。
Future<(String, Uint8List)?> pickEditorFile({bool? image}) async {
  final types = switch (image) {
    true => const XTypeGroup(
      label: '图片',
      extensions: ['png', 'jpg', 'jpeg', 'webp'],
      mimeTypes: ['image/png', 'image/jpeg', 'image/webp'],
      uniformTypeIdentifiers: [
        'public.png',
        'public.jpeg',
        'org.webmproject.webp',
      ],
    ),
    false => const XTypeGroup(
      label: '音频',
      extensions: ['mp3', 'wav', 'm4a', 'ogg'],
      mimeTypes: ['audio/mpeg', 'audio/wav', 'audio/mp4', 'audio/ogg'],
      uniformTypeIdentifiers: [
        'public.mp3',
        'com.microsoft.waveform-audio',
        'public.mpeg-4-audio',
        'org.xiph.ogg',
      ],
    ),
    null => const XTypeGroup(
      label: '剧情作品',
      extensions: ['json'],
      mimeTypes: ['application/json'],
      uniformTypeIdentifiers: ['public.json'],
    ),
  };
  final file = await openFile(acceptedTypeGroups: [types]);
  if (file == null) return null;
  if (await file.length() > (image == null ? maxProjectBytes : maxAssetBytes)) {
    throw FormatException(image == null ? '作品文件超过 96 MB' : '单个素材超过 32 MB');
  }
  return (file.name, await file.readAsBytes());
}
