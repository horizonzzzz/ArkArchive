import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../story_player/data/asset_store.dart';
import 'app_theme.dart';

class CharacterPortrait extends StatefulWidget {
  const CharacterPortrait({
    super.key,
    required this.store,
    required this.url,
    required this.name,
    this.fit = BoxFit.contain,
  });
  final AssetStore store;
  final String url, name;
  final BoxFit fit;
  @override
  State<CharacterPortrait> createState() => _CharacterPortraitState();
}

class _CharacterPortraitState extends State<CharacterPortrait> {
  Future<Uint8List>? _bytes;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(CharacterPortrait oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url || oldWidget.store != widget.store) _load();
  }

  void _load() {
    final uri = Uri.tryParse(widget.url);
    _bytes =
        uri != null && uri.scheme == 'https' && uri.host == 'media.prts.wiki'
        ? widget.store.loadShared(uri)
        : null;
  }

  Widget _placeholder() => ColoredBox(
    color: AppColors.panel,
    child: Center(
      child: Text(
        widget.name.characters.firstOrNull ?? '?',
        style: const TextStyle(fontSize: 42, color: AppColors.subtext),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: _bytes == null
        ? _placeholder()
        : FutureBuilder<Uint8List>(
            future: _bytes,
            builder: (context, snapshot) {
              if (snapshot.data == null) return _placeholder();
              return Image.memory(
                snapshot.data!,
                fit: widget.fit,
                alignment: Alignment.topCenter,
                width: double.infinity,
                height: double.infinity,
                cacheWidth: 1000,
                gaplessPlayback: false,
                errorBuilder: (_, error, stack) => _placeholder(),
              );
            },
          ),
  );
}

class CharacterLoadError extends StatelessWidget {
  const CharacterLoadError({super.key, required this.onRetry, this.onBrowse});
  final VoidCallback onRetry;
  final VoidCallback? onBrowse;
  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.folder_off_outlined,
            size: 40,
            color: AppColors.subtext,
          ),
          const SizedBox(height: 16),
          const Text('人物档案暂时无法读取', style: TextStyle(fontSize: 18)),
          const SizedBox(height: 8),
          const Text('请重试；若仍失败，请检查应用资源是否完整。', textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton(onPressed: onRetry, child: const Text('重试')),
          if (onBrowse != null)
            TextButton(onPressed: onBrowse, child: const Text('先看剧情')),
        ],
      ),
    ),
  );
}

Future<bool> confirmCharacterSpoilers(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('显示含剧透内容？'),
        content: const Text('将显示人物深层档案、身份信息及剧情台词。关闭保护仅在本次浏览中生效。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('保持保护'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('显示全部'),
          ),
        ],
      ),
    ) ??
    false;

String characterPlainText(String text) =>
    text.replaceAll(RegExp(r'<(?:@[^>]*|/)>'), '');
