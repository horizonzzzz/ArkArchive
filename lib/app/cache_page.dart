import 'package:flutter/material.dart';

import '../story_player/data/story_repository.dart';
import 'app_theme.dart';
import 'archive_widgets.dart';

class CachePage extends StatefulWidget {
  const CachePage({super.key, required this.selected, required this.onBrowse});
  final List<StoryEntry> selected;
  final VoidCallback onBrowse;

  @override
  State<CachePage> createState() => _CachePageState();
}

class _CachePageState extends State<CachePage> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final padding = constraints.maxWidth < 600 ? 16.0 : 28.0;
      return CustomScrollView(
        key: const PageStorageKey('cache-scroll'),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(padding, padding, padding, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const ArchiveHeading('离线与缓存'),
                  const SizedBox(height: 20),
                  ArchivePanel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Row(
                          children: [
                            Text(
                              '本地素材空间',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                              ),
                            ),
                            Spacer(),
                            Text(
                              'STORAGE',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 10,
                                color: AppColors.muted,
                                letterSpacing: 1.2,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        const Row(
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          children: [
                            Text(
                              '—',
                              style: TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.w800,
                                color: AppColors.cyan,
                              ),
                            ),
                            SizedBox(width: 6),
                            Text(
                              'MB',
                              style: TextStyle(
                                fontSize: 12,
                                color: AppColors.muted,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Container(height: 3, color: AppColors.surface),
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            const ArchiveTag('文本 · 0 B'),
                            const ArchiveTag('图片 · 0 B'),
                            const ArchiveTag('音频 · 0 B'),
                            OutlinedButton.icon(
                              onPressed: () =>
                                  showCachePreviewConfirmation(context),
                              icon: const Icon(Icons.delete_outline, size: 16),
                              label: const Text('清理缓存'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ChoiceChip(
                        label: Text('待缓存 (${widget.selected.length})'),
                        selected: _tab == 0,
                        onSelected: (_) => setState(() => _tab = 0),
                      ),
                      ChoiceChip(
                        label: const Text('已离线'),
                        selected: _tab == 1,
                        onSelected: (_) => setState(() => _tab = 1),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                ],
              ),
            ),
          ),
          if (_tab == 1 || widget.selected.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _tab == 1
                  ? const ArchiveEmpty(
                      icon: Icons.cloud_off_outlined,
                      title: '暂无离线档案',
                      message: '已下载完成的剧情剧目将在此归档呈现。',
                    )
                  : ArchiveEmpty(
                      icon: Icons.download_for_offline_outlined,
                      title: '待缓存清单为空',
                      message: '在剧情馆选择关卡后，可以在此统一发起离线存储。',
                      action: FilledButton.icon(
                        onPressed: widget.onBrowse,
                        icon: const Icon(
                          Icons.library_books_outlined,
                          size: 18,
                        ),
                        label: const Text('前往剧情馆'),
                      ),
                    ),
            )
          else ...[
            SliverPadding(
              padding: EdgeInsets.symmetric(horizontal: padding),
              sliver: SliverList.builder(
                itemCount: widget.selected.length,
                itemBuilder: (context, index) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: ArchivePanel(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.description_outlined,
                          color: AppColors.cyan,
                          size: 18,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            widget.selected[index].title,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: AppColors.text,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        const ArchiveTag('待缓存', color: AppColors.yellow),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(padding, 8, padding, 16),
                child: FilledButton.icon(
                  onPressed: () => showPreviewMessage(context, '批量缓存'),
                  icon: const Icon(Icons.download_outlined, size: 18),
                  label: Text('缓存 ${widget.selected.length} 幕（预览）'),
                ),
              ),
            ),
          ],
        ],
      );
    },
  );
}
