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
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
    final padding = constraints.maxWidth < 600 ? 16.0 : 28.0;
    return CustomScrollView(key: const PageStorageKey('cache-scroll'), slivers: [
      SliverToBoxAdapter(child: Padding(padding: EdgeInsets.fromLTRB(padding, padding, padding, 0), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const ArchiveHeading('离线与缓存', 'OFFLINE ARCHIVE', trailing: ArchiveTag('尚未接入', color: AppColors.yellow)),
        const SizedBox(height: 22),
        const PreviewNotice(text: '缓存管理预览 · 已选剧情仅用于演示任务清单，不会创建下载任务或修改现有文件。'),
        const SizedBox(height: 20),
        ArchivePanel(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('本地素材空间', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          const Text('—', style: TextStyle(fontSize: 32, color: AppColors.cyan)),
          const Text('尚未接入存储统计', style: TextStyle(color: AppColors.muted, fontSize: 12)),
          const SizedBox(height: 14),
          Container(height: 5, color: AppColors.surface),
          const SizedBox(height: 16),
          Wrap(spacing: 12, runSpacing: 8, children: [
            const ArchiveTag('文本 · 未统计'), const ArchiveTag('图片 · 未统计'), const ArchiveTag('音频 · 未统计'),
            OutlinedButton.icon(onPressed: () => showCachePreviewConfirmation(context), icon: const Icon(Icons.delete_outline, size: 16), label: const Text('清理缓存')),
          ]),
        ])),
        const SizedBox(height: 20),
        Wrap(spacing: 8, runSpacing: 8, children: [
          ChoiceChip(label: Text('待缓存 (${widget.selected.length})'), selected: _tab == 0, onSelected: (_) => setState(() => _tab = 0)),
          ChoiceChip(label: const Text('已离线'), selected: _tab == 1, onSelected: (_) => setState(() => _tab = 1)),
        ]),
        const SizedBox(height: 12),
      ]))),
      if (_tab == 1 || widget.selected.isEmpty)
        SliverFillRemaining(hasScrollBody: false, child: _tab == 1
          ? const ArchiveEmpty(icon: Icons.cloud_off_outlined, title: '离线档案尚未接入', message: '后续将在这里展示已缓存剧情及校验状态。当前不代表设备上没有缓存。')
          : ArchiveEmpty(icon: Icons.download_for_offline_outlined, title: '先选几幕想重温的故事', message: '在剧情馆勾选关卡后，可以在这里预览待缓存清单。', action: FilledButton.icon(onPressed: widget.onBrowse, icon: const Icon(Icons.library_books_outlined, size: 18), label: const Text('前往剧情馆'))),
        )
      else ...[
        SliverPadding(padding: EdgeInsets.symmetric(horizontal: padding), sliver: SliverList.builder(
          itemCount: widget.selected.length,
          itemBuilder: (context, index) => Padding(padding: const EdgeInsets.only(bottom: 8), child: ArchivePanel(padding: const EdgeInsets.all(14), child: Row(children: [
            const Icon(Icons.description_outlined, color: AppColors.muted, size: 20),
            const SizedBox(width: 12),
            Expanded(child: Text(widget.selected[index].title, style: const TextStyle(fontSize: 13))),
            const SizedBox(width: 8), const ArchiveTag('待接入'),
          ]))),
        )),
        SliverToBoxAdapter(child: Padding(
          padding: EdgeInsets.fromLTRB(padding, 8, padding, 16),
          child: FilledButton.icon(onPressed: () => showPreviewMessage(context, '批量缓存'), icon: const Icon(Icons.download_outlined, size: 18), label: Text('缓存 ${widget.selected.length} 幕（预览）')),
        )),
      ],
    ]);
  });
}
