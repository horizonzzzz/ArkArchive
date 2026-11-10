import 'package:flutter/material.dart';

import '../story_player/data/asset_store.dart';
import 'app_theme.dart';
import 'character_archive_data.dart';
import 'character_archive_widgets.dart';

class CharacterDetailPage extends StatefulWidget {
  const CharacterDetailPage({
    super.key,
    required this.person,
    required this.index,
    required this.repository,
    required this.store,
    this.protectSpoilers = true,
    this.onReplay,
  });
  final CharacterSummary person;
  final CharacterIndex index;
  final CharacterRepository repository;
  final AssetStore store;
  final bool protectSpoilers;
  final CharacterReplay? onReplay;
  @override
  State<CharacterDetailPage> createState() => _CharacterDetailPageState();
}

class _CharacterDetailPageState extends State<CharacterDetailPage> {
  late Future<CharacterDetail> _future = widget.repository.loadDetail(
    widget.person,
  );
  late String _form = widget.person.forms.firstOrNull?.id ?? '';
  late bool _protect = widget.protectSpoilers;
  final _revealedProfiles = <CharacterProfile>{};
  final _revealedStories = <String>{};
  final _expandedChapters = <String>{};
  bool _showAllArtwork = false, _opening = false;
  String _chapterQuery = '';
  int _artIndex = 0;

  Future<void> _toggleProtection() async {
    if (_protect && !await confirmCharacterSpoilers(context)) return;
    if (mounted) {
      setState(() {
        _protect = !_protect;
        _revealedProfiles.clear();
        _revealedStories.clear();
        _showAllArtwork = false;
      });
    }
  }

  Future<void> _replay(CharacterStory story, CharacterSnippet snippet) async {
    if (_opening || widget.onReplay == null) return;
    setState(() => _opening = true);
    try {
      await widget.onReplay!(story, snippet);
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法打开这段剧情，请检查网络后重试。')));
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Widget _identity() {
    final form = widget.person.forms.where((f) => f.id == _form).firstOrNull;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.person.forms.length > 1) ...[
            DropdownButtonFormField<String>(
              initialValue: _form,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '人物形态'),
              items: widget.person.forms
                  .map(
                    (f) => DropdownMenuItem(
                      value: f.id,
                      child: Text(
                        '${f.name} · ${f.profession}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (id) {
                if (id != null) {
                  setState(() {
                    _form = id;
                    _artIndex = 0;
                  });
                }
              },
            ),
            const SizedBox(height: 8),
          ],
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              Text(
                form == null ? '剧情角色' : '${form.profession} · ${form.rarity} 星',
              ),
              if (widget.person.faction.isNotEmpty) Text(widget.person.faction),
              Text(
                '已识别 ${widget.person.storyCount} 幕 · ${widget.person.lineCount} 句',
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<CharacterArtwork> _arts(CharacterDetail detail) => detail.artwork
      .where(
        (art) =>
            art.kind != 'avatar' && (art.formId.isEmpty || art.formId == _form),
      )
      .toList();

  Widget _portrait(String url, {double height = 320}) => SizedBox(
    height: height,
    child: CharacterPortrait(
      store: widget.store,
      url: url,
      name: widget.person.name,
    ),
  );

  Widget _profile(CharacterDetail detail) {
    final profile = detail.profile.where((p) => p.appliesTo(_form)).toList();
    final arts = _arts(detail);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        _portrait(arts.firstOrNull?.url ?? widget.person.portraitUrl),
        if (widget.person.appellation.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              widget.person.appellation,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.subtext),
            ),
          ),
        if (!_protect && widget.person.aliases.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: SelectableText('其他称呼：${widget.person.aliases.join('、')}'),
          ),
        if (profile.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text('此形态暂无可展示的档案资料。'),
          ),
        for (final section in profile)
          Card(
            child: ExpansionTile(
              key: ValueKey(
                '${_form}_${detail.profile.indexOf(section)}_$_protect',
              ),
              initiallyExpanded: !section.spoiler || !_protect,
              title: Text(section.title.isEmpty ? '档案资料' : section.title),
              subtitle: section.spoiler && _protect
                  ? const Text('含剧透 · 点击展开')
                  : null,
              onExpansionChanged: (open) {
                if (open) setState(() => _revealedProfiles.add(section));
              },
              children: [
                if (!section.spoiler ||
                    !_protect ||
                    _revealedProfiles.contains(section))
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: SelectableText(
                        characterPlainText(section.text),
                        style: const TextStyle(height: 1.7),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 20),
        const Text(
          '资料来源：PRTS Wiki / 游戏公开数据。文本随应用更新；出场记录只包含已识别台词。',
          style: TextStyle(color: AppColors.subtext, fontSize: 12, height: 1.5),
        ),
      ],
    );
  }

  Future<void> _zoom(String url) async => showDialog<void>(
    context: context,
    builder: (context) => Dialog.fullscreen(
      child: Scaffold(
        appBar: AppBar(title: Text(widget.person.name)),
        body: InteractiveViewer(
          minScale: 1,
          maxScale: 4,
          child: SizedBox.expand(
            child: CharacterPortrait(
              store: widget.store,
              url: url,
              name: widget.person.name,
            ),
          ),
        ),
      ),
    ),
  );

  Widget _gallery(CharacterDetail detail) {
    final all = _arts(detail);
    final arts = all
        .where(
          (art) =>
              art == all.first || !art.spoiler || !_protect || _showAllArtwork,
        )
        .toList();
    if (arts.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('暂无通过校验的立绘。图片缺失不影响档案阅读。', textAlign: TextAlign.center),
        ),
      );
    }
    final selected = arts[_artIndex.clamp(0, arts.length - 1)];
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 0; i < arts.length; i++)
              ChoiceChip(
                label: Text(
                  '${arts[i].label}${arts[i].kind == 'avg' ? ' ${i + 1}' : ''}',
                ),
                selected: arts[i] == selected,
                onSelected: (_) => setState(() => _artIndex = i),
              ),
          ],
        ),
        if (arts.length < all.length)
          TextButton.icon(
            onPressed: () => setState(() => _showAllArtwork = true),
            icon: const Icon(Icons.visibility_outlined),
            label: const Text('显示其余立绘（可能剧透）'),
          ),
        const SizedBox(height: 16),
        _portrait(selected.url, height: 440),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => _zoom(selected.url),
          icon: const Icon(Icons.zoom_in),
          label: const Text('放大查看'),
        ),
        const SizedBox(height: 12),
        const Text(
          '图片按需联网，已加载图片会进入共享缓存。',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppColors.subtext, fontSize: 12),
        ),
      ],
    );
  }

  Widget _appearance(CharacterAppearance appearance, CharacterStory story) {
    final visible = !_protect || _revealedStories.contains(appearance.story);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              story.title.isEmpty ? story.path : story.title,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              '已识别 ${appearance.lineCount} 句',
              style: const TextStyle(color: AppColors.subtext, fontSize: 12),
            ),
            if (!visible)
              TextButton.icon(
                onPressed: () =>
                    setState(() => _revealedStories.add(appearance.story)),
                icon: const Icon(Icons.visibility_off_outlined, size: 18),
                label: const Text('显示本幕台词（含剧透）'),
              )
            else
              for (final snippet in appearance.snippets)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        snippet.speaker,
                        style: const TextStyle(
                          color: AppColors.subtext,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 4),
                      SelectableText(
                        characterPlainText(snippet.text),
                        style: const TextStyle(height: 1.6),
                      ),
                      if (widget.onReplay != null)
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: _opening
                                ? null
                                : () => _replay(story, snippet),
                            icon: const Icon(
                              Icons.play_circle_outline,
                              size: 20,
                            ),
                            label: const Text('回放此处'),
                          ),
                        ),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Widget _appearances(CharacterDetail detail) {
    final query = _chapterQuery.trim().toLowerCase();
    final groups = <String, List<CharacterAppearance>>{};
    for (final appearance in detail.appearances) {
      final story = widget.index.stories[appearance.story];
      if (story == null ||
          !'${story.chapter} ${story.title}'.toLowerCase().contains(query)) {
        continue;
      }
      groups.putIfAbsent(story.chapter, () => []).add(appearance);
    }
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  onChanged: (value) => setState(() => _chapterQuery = value),
                  decoration: const InputDecoration(
                    hintText: '筛选篇章或剧情标题',
                    prefixIcon: Icon(Icons.search),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  _protect ? '台词默认折叠，可逐幕显示；已有观看断点不代表完整读完。' : '正在显示全部台词节选。',
                  style: const TextStyle(
                    color: AppColors.subtext,
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
                if (detail.appearances.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: Text('暂无已识别的出场记录；这不代表人物从未登场。'),
                  ),
                if (detail.appearances.isNotEmpty && groups.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: Text('没有匹配的篇章。'),
                  ),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
          sliver: SliverList.builder(
            itemCount: groups.length,
            itemBuilder: (context, index) {
              final chapter = groups.keys.elementAt(index);
              return ExpansionTile(
                key: ValueKey('${widget.person.id}:$chapter'),
                initiallyExpanded: _expandedChapters.contains(chapter),
                onExpansionChanged: (open) => setState(() {
                  if (open) {
                    _expandedChapters.add(chapter);
                  } else {
                    _expandedChapters.remove(chapter);
                  }
                }),
                title: Text(chapter.isEmpty ? '其他篇章' : chapter),
                subtitle: Text('${groups[chapter]!.length} 幕已识别出场'),
                children: [
                  for (final appearance in groups[chapter]!)
                    _appearance(
                      appearance,
                      widget.index.stories[appearance.story]!,
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 3,
    child: Scaffold(
      appBar: AppBar(
        title: Text(widget.person.name),
        actions: [
          IconButton(
            tooltip: _protect ? '关闭剧透保护' : '开启剧透保护',
            onPressed: _toggleProtection,
            icon: Icon(
              _protect
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
            ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1080),
            child: FutureBuilder<CharacterDetail>(
              future: _future,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return CharacterLoadError(
                    onRetry: () => setState(() {
                      _future = widget.repository.loadDetail(
                        widget.person,
                        reload: true,
                      );
                    }),
                  );
                }
                final detail = snapshot.data;
                if (detail == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                return Column(
                  children: [
                    _identity(),
                    const TabBar(
                      tabs: [
                        Tab(text: '档案'),
                        Tab(text: '立绘'),
                        Tab(text: '出场'),
                      ],
                    ),
                    Expanded(
                      child: TabBarView(
                        children: [
                          _profile(detail),
                          _gallery(detail),
                          _appearances(detail),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    ),
  );
}
