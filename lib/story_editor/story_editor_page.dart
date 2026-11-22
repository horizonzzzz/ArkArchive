import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../story_player/data/asset_store.dart';
import '../story_player/script.dart';
import '../story_player/ui/story_stage.dart';
import 'editor_materials.dart';
import 'editor_platform.dart';
import 'editor_preview.dart';
import 'editor_project.dart';
import 'editor_stage.dart';

enum _PreviewMode { beat, fromBeat, full }

typedef _Selection = (EditorProject, int, int, int);

class StoryEditorPage extends StatefulWidget {
  const StoryEditorPage({
    super.key,
    required this.storage,
    required this.store,
    this.incoming,
    this.onPlayProject,
  });
  final EditorStorage storage;
  final AssetStore store;
  final EditorProject? incoming;
  final Future<void> Function(EditorProject project)? onPlayProject;

  @override
  State<StoryEditorPage> createState() => _StoryEditorPageState();
}

class _StoryEditorPageState extends State<StoryEditorPage> {
  EditorProject? _project;
  int _scene = 0, _beat = 0, _command = -1, _formVersion = 0;
  final _undo = <_Selection>[];
  final _redo = <_Selection>[];
  final _drafts = <String, EditorProject>{};
  Timer? _saveTimer;
  Future<void> _writes = Future.value();
  EditorProject? _pending;
  EditorProject? _failedSave;
  String _status = '';
  bool _busy = false;
  String? _typing;
  bool _loaded = false;
  late final _resources = EditorPreviewResources(widget.store);

  EditorProject get project => _project!;
  EditorScene get scene => project.scenes[_scene];
  StoryBeat get beat => scene.beats[_beat];
  EditCommand? get command => _command < 0 ? null : beat.commands[_command];
  _Selection get _selection => (project, _scene, _beat, _command);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(StoryEditorPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final incoming = widget.incoming;
    if (incoming != null && incoming != oldWidget.incoming) {
      _open(incoming, save: true);
    }
  }

  Future<void> _load() async {
    try {
      final list = await widget.storage.list();
      if (!mounted) return;
      setState(() {
        _drafts.addEntries(list.map((p) => MapEntry(p.id, p)));
        _loaded = true;
      });
      if (_project != null) return;
      final next = widget.incoming ?? list.firstOrNull;
      if (next != null) _open(next, save: widget.incoming != null);
    } catch (e) {
      if (!mounted || _project != null) return;
      setState(() => _loaded = true);
      if (widget.incoming != null) _open(widget.incoming!, save: false);
      _message('暂时无法读取本地作品，请新建或导入作品');
    }
  }

  void _message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  void _open(EditorProject next, {bool save = false}) {
    _flush();
    setState(() {
      _restore((next, 0, 0, -1));
      _drafts[next.id] = next;
      _undo.clear();
      _redo.clear();
      _status = save ? '待保存' : '本地草稿';
    });
    if (save) _queueSave(next);
  }

  void _restore(_Selection value) {
    _project = value.$1;
    _scene = value.$2;
    _beat = value.$3;
    _command = value.$4;
    _formVersion++;
    _typing = null;
  }

  void _change(
    EditorProject next, {
    int? sceneIndex,
    int? beatIndex,
    int? selected,
    String? typing,
  }) {
    if (typing == null || _typing != typing) {
      _undo.add(_selection);
      if (_undo.length > 60) _undo.removeAt(0);
    }
    _redo.clear();
    setState(() {
      _project = next;
      _scene = sceneIndex ?? _scene;
      _beat = beatIndex ?? _beat;
      _command = selected ?? _command;
      if (typing == null) _formVersion++;
      _typing = typing;
    });
    _queueSave(next);
  }

  void _history({required bool redo}) {
    final from = redo ? _redo : _undo;
    final to = redo ? _undo : _redo;
    if (from.isEmpty) return;
    to.add(_selection);
    setState(() => _restore(from.removeLast()));
    _queueSave(project);
  }

  void _queueSave(EditorProject next) {
    _drafts[next.id] = next;
    _pending = next;
    _status = '待保存';
    _saveTimer?.cancel();
    _failedSave = null;
    _saveTimer = Timer(const Duration(milliseconds: 450), _flush);
  }

  void _flush() {
    _saveTimer?.cancel();
    final snapshot = _pending;
    _pending = null;
    if (snapshot == null) return;
    final storage = widget.storage;
    _writes = _writes.then((_) async {
      try {
        await storage.save(snapshot);
        if (mounted && identical(_project, snapshot)) {
          setState(() => _status = '已自动保存');
        }
      } catch (e) {
        if (mounted && identical(_project, snapshot)) {
          setState(() {
            _status = '保存失败';
            _failedSave = snapshot;
          });
        }
        if (identical(_pending, null)) _pending = snapshot;
        _message('保存失败，请检查存储空间后重试');
      }
    });
  }

  void _retrySave() {
    final failed = _failedSave ?? _pending ?? _project;
    if (failed == null) return;
    _queueSave(failed);
    _flush();
  }

  @override
  void dispose() {
    _flush();
    _resources.dispose();
    super.dispose();
  }

  Future<String?> _title(String label, String initial) async {
    var value = initial;
    return showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(label),
        content: TextFormField(
          initialValue: initial,
          autofocus: true,
          maxLength: 120,
          onChanged: (v) => value = v,
          onFieldSubmitted: (v) {
            if (v.trim().isNotEmpty) Navigator.pop(dialog, v.trim());
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (value.trim().isNotEmpty) Navigator.pop(dialog, value.trim());
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  Future<void> _projects() async {
    _flush();
    final selection = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('我的作品'),
        content: SizedBox(
          width: math.min(560, MediaQuery.sizeOf(context).width - 48),
          child: _drafts.isEmpty
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Text('还没有本地作品。'),
                )
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final draft in _drafts.values.toList().reversed)
                      ListTile(
                        selected: draft.id == project.id,
                        leading: const Icon(Icons.auto_stories_outlined),
                        title: Text(draft.title),
                        subtitle: Text(
                          '${draft.scenes.length} 幕 · 最近修改 ${draft.updatedAt.toLocal().toString().split('.').first}',
                        ),
                        onTap: () => Navigator.pop(dialog, draft.id),
                        trailing: PopupMenuButton<String>(
                          tooltip: '作品操作',
                          onSelected: (action) =>
                              Navigator.pop(dialog, '$action:${draft.id}'),
                          itemBuilder: (_) => [
                            PopupMenuItem(
                              value: 'play',
                              enabled: widget.onPlayProject != null,
                              child: const Text('播放'),
                            ),
                            const PopupMenuItem(
                              value: 'rename',
                              child: Text('重命名'),
                            ),
                            const PopupMenuItem(
                              value: 'duplicate',
                              child: Text('复制'),
                            ),
                            const PopupMenuItem(
                              value: 'delete',
                              child: Text('删除'),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, 'import'),
            child: const Text('导入'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(dialog, 'new'),
            icon: const Icon(Icons.add),
            label: const Text('新建作品'),
          ),
        ],
      ),
    );
    if (!mounted || selection == null) return;
    if (selection == 'new') {
      await _newProject();
    } else if (selection == 'import') {
      await _import();
    } else {
      final separator = selection.indexOf(':');
      if (separator > 0) {
        final action = selection.substring(0, separator);
        final id = selection.substring(separator + 1);
        final target = _drafts[id];
        if (target == null) return;
        switch (action) {
          case 'play':
            if (widget.onPlayProject != null) {
              await widget.onPlayProject!(target);
            }
          case 'rename':
            await _renameProject(target);
          case 'duplicate':
            await _duplicateProject(target);
          case 'delete':
            await _deleteProject(target);
        }
      } else if (selection != project.id && _drafts.containsKey(selection)) {
        _open(_drafts[selection]!);
      }
    }
  }

  Future<void> _import() async {
    try {
      final next = await widget.storage.importProject();
      if (next == null || !mounted) return;
      _open(next.copyWith(id: newProjectId()), save: true);
    } catch (e) {
      _message('导入失败，请确认文件完整后重试');
    }
  }

  Future<void> _deleteProject([EditorProject? target]) async {
    final current = target ?? project;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text('删除「${current.title}」？'),
        content: const Text('本地草稿将被删除，已导出的作品不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    setState(() => _busy = true);
    try {
      _flush();
      await _writes;
      await widget.storage.delete(current.id);
      if (!mounted) return;
      _drafts.remove(current.id);
      if (current.id != project.id) {
        setState(() {});
        return;
      }
      final other = _drafts.values.lastOrNull;
      if (other == null) {
        setState(() {
          _project = null;
          _scene = _beat = 0;
          _command = -1;
          _status = '';
        });
      } else {
        _open(other);
      }
    } catch (e) {
      _message('删除失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export({required bool scriptOnly}) async {
    try {
      final current = project;
      final issues = current.validate();
      if (issues.isNotEmpty) {
        final proceed = await _issues(issues, title: '作品检查', allowExport: true);
        if (!mounted || !proceed) return;
      }
      if (scriptOnly && current.assets.isNotEmpty) {
        final proceed = await _issues(
          ['纯脚本不包含上传素材。跨设备使用请导出作品文件。'],
          title: '导出脚本',
          allowExport: true,
        );
        if (!mounted || !proceed) return;
      }
      final bytes = scriptOnly
          ? utf8.encode(current.compile().source)
          : current.export();
      await widget.storage.exportFile(
        current.title,
        scriptOnly ? 'txt' : 'json',
        Uint8List.fromList(bytes),
      );
    } catch (e) {
      _message('导出失败，请检查存储空间后重试');
    }
  }

  Future<bool> _issues(
    List<String> issues, {
    String title = '提示',
    bool allowExport = false,
  }) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: math.min(460, MediaQuery.sizeOf(context).width - 48),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final issue in issues)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(issue),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: Text(allowExport ? '返回编辑' : '关闭'),
            ),
            if (allowExport)
              FilledButton(
                onPressed: () => Navigator.pop(dialog, true),
                child: const Text('仍然导出'),
              ),
          ],
        ),
      ) ??
      false;

  EditorProject _withScene(EditorScene next) =>
      project.copyWith(scenes: [...project.scenes]..[_scene] = next);
  EditorProject _withBeat(StoryBeat next) =>
      _withScene(scene.copyWith(beats: [...scene.beats]..[_beat] = next));
  EditorProject _withCommands(List<EditCommand> next) =>
      _withBeat(beat.copyWith(commands: next));

  void _selectBeat(int index, {int? sceneIndex}) => setState(() {
    _scene = sceneIndex ?? _scene;
    _beat = index;
    _command = -1;
    _typing = null;
    _formVersion++;
  });

  Future<void> _sceneAction(String action) async {
    final original = project;
    if (action == 'add' || action == 'rename') {
      final name = await _title(
        action == 'add' ? '新建幕' : '重命名幕',
        action == 'add' ? '第 ${project.scenes.length + 1} 幕' : scene.title,
      );
      if (!mounted || name == null || !identical(original, project)) return;
      if (action == 'add') {
        _change(
          project.copyWith(
            scenes: [
              ...project.scenes,
              EditorScene(name, const [StoryBeat('分镜 1')]),
            ],
          ),
          sceneIndex: project.scenes.length,
          beatIndex: 0,
          selected: -1,
        );
      } else {
        _change(_withScene(scene.copyWith(title: name)));
      }
      return;
    }
    final scenes = [...project.scenes];
    if (action == 'delete') {
      if (scenes.length == 1) return;
      scenes.removeAt(_scene);
      _change(
        project.copyWith(scenes: scenes),
        sceneIndex: math.min(_scene, scenes.length - 1),
        beatIndex: 0,
        selected: -1,
      );
    } else {
      final target = _scene + (action == 'up' ? -1 : 1);
      if (target < 0 || target >= scenes.length) return;
      scenes.insert(target, scenes.removeAt(_scene));
      _change(project.copyWith(scenes: scenes), sceneIndex: target);
    }
  }

  Future<void> _beatAction(String action) async {
    final beats = [...scene.beats];
    if (action == 'add' || action == 'duplicate') {
      final index = _beat + 1;
      beats.insert(
        index,
        action == 'add'
            ? StoryBeat('分镜 ${beats.length + 1}')
            : beat.copyWith(
                title: '${beat.title} 副本'.characters.take(120).toString(),
              ),
      );
      _change(
        _withScene(scene.copyWith(beats: beats)),
        beatIndex: index,
        selected: -1,
      );
    } else if (action == 'rename') {
      final original = project;
      final name = await _title('重命名分镜', beat.title);
      if (mounted && name != null && identical(original, project)) {
        _change(_withBeat(beat.copyWith(title: name)));
      }
    } else if (action == 'delete') {
      if (beats.length == 1) return;
      beats.removeAt(_beat);
      _change(
        _withScene(scene.copyWith(beats: beats)),
        beatIndex: math.min(_beat, beats.length - 1),
        selected: -1,
      );
    } else {
      final target = _beat + (action == 'up' ? -1 : 1);
      if (target < 0 || target >= beats.length) return;
      beats.insert(target, beats.removeAt(_beat));
      _change(_withScene(scene.copyWith(beats: beats)), beatIndex: target);
    }
  }

  Future<void> _showCommandChooser({int? insertAt}) async {
    final groups = <String, List<MapEntry<String, dynamic>>>{};
    for (final entry in editorFields.entries) {
      final group = switch (entry.key) {
        'dialogue' || 'dialog' || 'aside' || 'subtitle' => '文字',
        'background' || 'image' || 'charslot' => '画面',
        'playmusic' || 'stopmusic' || 'playsound' || 'stopsound' => '音频',
        'delay' || 'blocker' => '流程',
        _ => '效果',
      };
      groups.putIfAbsent(group, () => []).add(entry);
    }
    final tag = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(insertAt == null ? '添加演出指令' : '在此之后插入'),
        content: SizedBox(
          width: math.min(420, MediaQuery.sizeOf(context).width - 48),
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final group in groups.entries) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 8, bottom: 4),
                  child: Text(
                    group.key,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
                for (final entry in group.value)
                  ListTile(
                    dense: true,
                    title: Text(entry.value.$1),
                    subtitle: Text(entry.key),
                    onTap: () => Navigator.pop(context, entry.key),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
    if (!mounted || tag == null) return;
    _addCommandAt(tag, insertAt);
  }

  void _addCommandAt(String tag, int? index) {
    final definition = editorFields[tag];
    if (definition == null) return;
    final next = EditCommand(tag, {
      for (final field in definition.$2)
        if (field.initial.isNotEmpty) field.key: field.initial,
    });
    final commands = [...beat.commands];
    final target = index == null
        ? commands.length
        : index.clamp(0, commands.length);
    commands.insert(target, next);
    _change(_withCommands(commands), selected: target);
  }

  Future<void> _insertCommand(int index) =>
      _showCommandChooser(insertAt: index + 1);

  void _updateCommand(
    Map<String, String> values, {
    String? typing,
    EditorAsset? asset,
  }) {
    final current = command;
    if (current == null || current.raw != null) return;
    var next = _withCommands(
      [...beat.commands]..[_command] = current.withArgs(values),
    );
    if (asset != null) {
      next = next.copyWith(assets: {...next.assets, asset.key: asset});
    }
    _change(next, typing: typing);
  }

  void _commandAction(int index, String action) {
    if (action == 'insert') {
      _insertCommand(index);
      return;
    }
    final list = [...beat.commands];
    if (action == 'delete') {
      list.removeAt(index);
      _change(_withCommands(list), selected: -1);
    } else if (action == 'duplicate') {
      list.insert(index + 1, list[index]);
      _change(_withCommands(list), selected: index + 1);
    } else {
      final target = index + (action == 'up' ? -1 : 1);
      if (target < 0 || target >= list.length) return;
      list.insert(target, list.removeAt(index));
      _change(_withCommands(list), selected: target);
    }
  }

  Future<void> _pick(EditorField field) async {
    final address = (project.id, _scene, _beat, _command, _formVersion);
    final result = await showDialog<(String, EditorAsset?)>(
      context: context,
      builder: (_) => EditorMaterialPicker(
        field: field,
        current: command!.value(field.key),
        resources: _resources,
        assets: project.assets,
        storage: widget.storage,
      ),
    );
    if (!mounted ||
        result == null ||
        address != (project.id, _scene, _beat, _command, _formVersion)) {
      return;
    }
    _updateCommand({field.key: result.$1}, asset: result.$2);
  }

  Future<void> _preview(_PreviewMode mode) async {
    if (_busy) return;
    setState(() => _busy = true);
    PreparedStage? prepared;
    try {
      final current = project;
      final compiled = current.compile();
      final range = compiled.ranges[(_scene, _beat)]!;
      final start = mode == _PreviewMode.full ? 0 : range.$1;
      final end = mode == _PreviewMode.beat
          ? range.$2
          : compiled.script.commands.length;
      prepared = await _resources.prepare(
        current,
        compiled,
        end: end,
        audible: true,
        active: () => mounted,
      );
      if (!mounted) return;
      final stage = prepared;
      final reached = await stage.engine.rebuildBefore(
        start,
        resumeAudio: true,
      );
      if (!mounted) return;
      if (!reached) throw StateError('无法从当前分镜开始播放');
      final warnings = {...current.validate(), ...stage.engine.warnings};
      var autoPlay = true;
      var stopped = false;
      Future<void> runAutoPlay() async {
        while (!stopped && autoPlay && !stage.engine.finished && mounted) {
          await stage.engine.advance();
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }

      unawaited(runAutoPlay());
      await showDialog<void>(
        context: context,
        builder: (dialog) => StatefulBuilder(
          builder: (dialog, setDialogState) => Dialog(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 960),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: AspectRatio(
                      aspectRatio: 16 / 9,
                      child: StoryStage(
                        engine: stage.engine,
                        catalog: stage.catalog,
                        textures: stage.textures,
                      ),
                    ),
                  ),
                  AnimatedBuilder(
                    animation: stage.engine,
                    builder: (_, _) {
                      final issues = {
                        ...warnings,
                        ...stage.engine.warnings,
                      }.toList();
                      return Row(
                        children: [
                          IconButton(
                            tooltip: autoPlay ? '暂停' : '继续播放',
                            onPressed: () {
                              setDialogState(() => autoPlay = !autoPlay);
                              if (autoPlay) unawaited(runAutoPlay());
                            },
                            icon: Icon(
                              autoPlay ? Icons.pause : Icons.play_arrow,
                            ),
                          ),
                          IconButton(
                            tooltip: '重播',
                            onPressed: () async {
                              setDialogState(() => autoPlay = false);
                              await stage.engine.rebuildBefore(
                                start,
                                resumeAudio: true,
                              );
                              if (!mounted) return;
                              setDialogState(() => autoPlay = true);
                              unawaited(runAutoPlay());
                            },
                            icon: const Icon(Icons.replay),
                          ),
                          IconButton(
                            tooltip: '下一步',
                            onPressed: stage.engine.finished
                                ? null
                                : stage.engine.advance,
                            icon: const Icon(Icons.skip_next),
                          ),
                          Expanded(
                            child: Text(
                              stage.engine.finished ? '播放完毕' : '试播',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (issues.isNotEmpty)
                            IconButton(
                              tooltip: '预览提示（${issues.length}）',
                              icon: const Icon(Icons.warning_amber),
                              onPressed: () => _issues(issues),
                            ),
                          IconButton(
                            tooltip: '退出试播',
                            onPressed: () {
                              stopped = true;
                              Navigator.pop(dialog);
                            },
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    } catch (e) {
      _message('试播失败，请检查脚本和素材后重试');
    } finally {
      prepared?.dispose();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _newProject() async {
    final name = await _title('新建作品', '未命名剧情');
    if (mounted && name != null) {
      _open(EditorProject.create(name), save: true);
    }
  }

  Future<void> _renameProject(EditorProject target) async {
    final name = await _title('重命名作品', target.title);
    if (!mounted || name == null || name == target.title) return;
    final next = target.copyWith(title: name);
    if (target.id == project.id) {
      _change(next);
      return;
    }
    try {
      await widget.storage.save(next);
      if (!mounted) return;
      setState(() => _drafts[target.id] = next);
    } catch (_) {
      _message('重命名失败，请稍后重试');
    }
  }

  Future<void> _duplicateProject([EditorProject? source]) async {
    final original = source ?? project;
    final name = await _title('复制作品', '${original.title} 副本');
    if (!mounted || name == null) return;
    _open(
      EditorProject(
        id: newProjectId(),
        title: name,
        scenes: original.scenes,
        assets: original.assets,
        derivedFrom: original.derivedFrom ?? original.id,
      ),
      save: true,
    );
  }

  Widget _emptyState() => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.auto_stories_outlined,
              size: 64,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 16),
            const Text(
              '还没有本地作品',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            const Text(
              '新建、导入或从剧情馆派生一个作品，作品会自动保存到本地。',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              alignment: WrapAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: _newProject,
                  icon: const Icon(Icons.add),
                  label: const Text('新建作品'),
                ),
                OutlinedButton.icon(
                  onPressed: _import,
                  icon: const Icon(Icons.upload_file),
                  label: const Text('导入作品'),
                ),
                TextButton.icon(
                  onPressed: _projects,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('查看作品'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (_project == null) {
      return _loaded
          ? _emptyState()
          : const Center(child: CircularProgressIndicator());
    }
    return LayoutBuilder(
      builder: (context, size) {
        final wide = size.maxWidth >= 1100;
        final landscape = !wide && size.maxWidth >= 580 && size.maxHeight < 530;
        final stage = EditorStage(
          project: project,
          scene: _scene,
          beat: _beat,
          selected: _command,
          resources: _resources,
          onMove: (index, values) {
            _change(
              _withCommands(
                [...beat.commands]
                  ..[index] = beat.commands[index].withArgs(values),
              ),
              selected: index,
            );
          },
          onIssues: _issues,
        );
        return Column(
          children: [
            _toolbar(),
            if (_busy)
              const LinearProgressIndicator(minHeight: 2)
            else
              const Divider(height: 2),
            Expanded(
              child: wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(width: 215, child: _outline(vertical: true)),
                        const VerticalDivider(width: 1),
                        Expanded(
                          child: Column(
                            children: [
                              Flexible(
                                flex: 5,
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Center(child: stage),
                                ),
                              ),
                              const Divider(height: 1),
                              Expanded(
                                flex: 4,
                                child: _commands(inlineInspector: false),
                              ),
                            ],
                          ),
                        ),
                        const VerticalDivider(width: 1),
                        SizedBox(
                          width: 290,
                          child: ListView(
                            key: ValueKey((_scene, _beat, _command)),
                            padding: const EdgeInsets.all(12),
                            children: _inspector(),
                          ),
                        ),
                      ],
                    )
                  : landscape
                  ? Row(
                      children: [
                        Expanded(
                          child: Column(
                            children: [
                              Expanded(child: Center(child: stage)),
                              _outline(vertical: false, showScene: false),
                            ],
                          ),
                        ),
                        const VerticalDivider(width: 1),
                        Expanded(
                          child: Column(
                            children: [
                              _sceneBar(),
                              Expanded(child: _commands(inlineInspector: true)),
                            ],
                          ),
                        ),
                      ],
                    )
                  : ListView(
                      children: [
                        _sceneBar(),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: stage,
                        ),
                        _outline(vertical: false, showScene: false),
                        const Divider(height: 1),
                        _commandHeader(),
                        ..._commandRows(inlineInspector: true),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }

  Map<String, int> _assetUsage(EditorProject value) {
    final usage = {for (final key in value.assets.keys) key: 0};
    for (final scene in value.scenes) {
      for (final beat in scene.beats) {
        for (final entry in beat.commands) {
          for (final argument in entry.args.values) {
            if (usage.containsKey(argument)) {
              usage[argument] = usage[argument]! + 1;
            }
          }
        }
      }
    }
    return usage;
  }

  Future<void> _assets() async {
    var current = project;
    await showDialog<void>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, setDialogState) {
          final usage = _assetUsage(current);
          final unused = usage.values.where((count) => count == 0).length;
          final totalBytes = current.assets.values.fold<int>(
            0,
            (sum, asset) => sum + asset.bytes.length,
          );
          return AlertDialog(
            title: const Text('作品素材'),
            content: SizedBox(
              width: math.min(560, MediaQuery.sizeOf(context).width - 48),
              height: math.min(520, MediaQuery.sizeOf(context).height - 160),
              child: current.assets.isEmpty
                  ? const Center(child: Text('还没有作品素材'))
                  : ListView(
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            '${current.assets.length} 项 · ${(totalBytes / 1024 / 1024).toStringAsFixed(1)} MB',
                          ),
                        ),
                        for (final asset in current.assets.values)
                          ListTile(
                            leading: Icon(
                              asset.isImage
                                  ? Icons.image_outlined
                                  : Icons.audiotrack_outlined,
                            ),
                            title: Text(asset.name),
                            subtitle: Text(
                              '${usage[asset.key]} 处引用 · ${(asset.bytes.length / 1024 / 1024).toStringAsFixed(1)} MB',
                            ),
                          ),
                      ],
                    ),
            ),
            actions: [
              TextButton(
                onPressed: unused == 0
                    ? null
                    : () {
                        final next = current.copyWith(
                          assets: {
                            for (final entry in current.assets.entries)
                              if (usage[entry.key] != 0) entry.key: entry.value,
                          },
                        );
                        current = next;
                        _change(next);
                        setDialogState(() {});
                      },
                child: Text('清理未引用${unused == 0 ? '' : '（$unused）'}'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialog),
                child: const Text('完成'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _toolbar() => Row(
    children: [
      if (_failedSave != null)
        IconButton(
          tooltip: '保存失败，点击重试',
          onPressed: _retrySave,
          icon: const Icon(Icons.error_outline, color: Colors.red),
        ),
      IconButton(
        tooltip: '本地作品',
        onPressed: _busy ? null : _projects,
        icon: const Icon(Icons.folder_open),
      ),
      Expanded(
        child: Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: _busy
                ? null
                : () async {
                    final original = project;
                    final title = await _title('作品名称', original.title);
                    if (mounted &&
                        title != null &&
                        identical(project, original) &&
                        title != project.title) {
                      _change(project.copyWith(title: title));
                    }
                  },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  project.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(_status, style: Theme.of(context).textTheme.labelSmall),
              ],
            ),
          ),
        ),
      ),
      IconButton(
        tooltip: '撤销',
        onPressed: _busy || _undo.isEmpty ? null : () => _history(redo: false),
        icon: const Icon(Icons.undo),
      ),
      IconButton(
        tooltip: '重做',
        onPressed: _busy || _redo.isEmpty ? null : () => _history(redo: true),
        icon: const Icon(Icons.redo),
      ),
      PopupMenuButton<_PreviewMode>(
        tooltip: '试播',
        enabled: !_busy,
        icon: const Icon(Icons.play_arrow),
        onSelected: _preview,
        itemBuilder: (_) => const [
          PopupMenuItem(value: _PreviewMode.beat, child: Text('仅当前分镜')),
          PopupMenuItem(value: _PreviewMode.fromBeat, child: Text('从当前分镜开始')),
          PopupMenuItem(value: _PreviewMode.full, child: Text('从头播放')),
        ],
      ),
      PopupMenuButton<String>(
        tooltip: '作品操作',
        enabled: !_busy,
        onSelected: (action) async {
          switch (action) {
            case 'import':
              await _import();
            case 'play':
              if (widget.onPlayProject != null) {
                await widget.onPlayProject!(project);
              }
            case 'assets':
              await _assets();
            case 'export':
              await _export(scriptOnly: false);
            case 'duplicate':
              await _duplicateProject();
            case 'script':
              await _export(scriptOnly: true);
            case 'delete':
              await _deleteProject();
            case 'check':
              final issues = project.validate();
              await _issues(
                issues.isEmpty ? ['没有发现结构问题。'] : issues,
                title: '作品检查',
              );
          }
        },
        itemBuilder: (_) => [
          PopupMenuItem(value: 'import', child: Text('导入作品')),
          PopupMenuItem(
            value: 'play',
            enabled: widget.onPlayProject != null,
            child: const Text('播放作品'),
          ),
          PopupMenuItem(value: 'assets', child: Text('作品素材管理')),
          PopupMenuItem(value: 'export', child: Text('导出作品（含上传素材）')),
          PopupMenuItem(value: 'script', child: Text('导出纯脚本')),
          PopupMenuItem(value: 'duplicate', child: Text('复制作品')),
          PopupMenuItem(value: 'check', child: Text('检查作品')),
          PopupMenuItem(value: 'delete', child: Text('删除作品')),
        ],
      ),
    ],
  );

  Widget _sceneBar() => Row(
    children: [
      Expanded(
        child: Padding(
          padding: const EdgeInsets.only(left: 10),
          child: DropdownButton<int>(
            isExpanded: true,
            value: _scene,
            onChanged: (i) {
              if (i != null) _selectBeat(0, sceneIndex: i);
            },
            items: [
              for (final (i, value) in project.scenes.indexed)
                DropdownMenuItem(
                  value: i,
                  child: Text(
                    value.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ),
      ),
      PopupMenuButton<String>(
        tooltip: '幕操作',
        onSelected: _sceneAction,
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'add', child: Text('新建幕')),
          const PopupMenuItem(value: 'rename', child: Text('重命名幕')),
          ..._reorderMenu(_scene, project.scenes.length),
          PopupMenuItem(
            value: 'delete',
            enabled: project.scenes.length > 1,
            child: const Text('删除幕'),
          ),
        ],
      ),
    ],
  );

  List<PopupMenuEntry<String>> _reorderMenu(int index, int count) => [
    PopupMenuItem(value: 'up', enabled: index > 0, child: const Text('向前移动')),
    PopupMenuItem(
      value: 'down',
      enabled: index + 1 < count,
      child: const Text('向后移动'),
    ),
  ];

  Widget _outline({required bool vertical, bool showScene = true}) {
    final list = ListView.builder(
      key: PageStorageKey(('beats', project.id, _scene, vertical)),
      scrollDirection: vertical ? Axis.vertical : Axis.horizontal,
      itemCount: scene.beats.length,
      itemBuilder: (_, i) {
        final label = scene.beats[i].title;
        return vertical
            ? ListTile(
                dense: true,
                selected: i == _beat,
                leading: Text('${i + 1}'),
                title: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => _selectBeat(i),
              )
            : Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Center(
                  child: ChoiceChip(
                    label: Text(
                      label.length > 22
                          ? '${label.characters.take(20)}…'
                          : label,
                    ),
                    selected: i == _beat,
                    onSelected: (_) => _selectBeat(i),
                  ),
                ),
              );
      },
    );
    return vertical
        ? Column(
            children: [
              if (showScene) _sceneBar(),
              Expanded(child: list),
            ],
          )
        : SizedBox(height: 52, child: list);
  }

  Widget _commandHeader() => Row(
    children: [
      Expanded(
        child: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: Text(
            beat.title,
            style: Theme.of(context).textTheme.titleSmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
      IconButton(
        tooltip: '添加分镜',
        onPressed: () => _beatAction('add'),
        icon: const Icon(Icons.post_add),
      ),
      PopupMenuButton<String>(
        tooltip: '分镜操作',
        onSelected: _beatAction,
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'rename', child: Text('重命名分镜')),
          const PopupMenuItem(value: 'duplicate', child: Text('复制分镜')),
          ..._reorderMenu(_beat, scene.beats.length),
          PopupMenuItem(
            value: 'delete',
            enabled: scene.beats.length > 1,
            child: const Text('删除分镜'),
          ),
        ],
      ),
      IconButton(
        tooltip: '添加演出指令',
        onPressed: () => _showCommandChooser(),
        icon: const Icon(Icons.add),
      ),
    ],
  );

  void _reorderCommands(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex--;
    final commands = [...beat.commands];
    final moved = commands.removeAt(oldIndex);
    commands.insert(newIndex, moved);
    _change(_withCommands(commands), selected: newIndex);
  }

  String _commandSummary(EditCommand entry) {
    if (entry.raw != null) return entry.raw!;
    final value = entry.value;
    return switch (entry.tag) {
      'dialogue' || 'dialog' =>
        value('text').isEmpty
            ? '清除对白框'
            : '对白：${value('text').replaceAll('\n', ' ')}',
      'aside' || 'subtitle' =>
        value('text').isEmpty
            ? '清除文字'
            : '文字：${value('text').replaceAll('\n', ' ')}',
      'background' => '背景：${value('image')}',
      'image' => 'CG：${value('image')}',
      'charslot' => '人物：${value('name')}（${value('slot')}）',
      'playmusic' => '播放音乐：${value('key')}',
      'playsound' => '播放音效：${value('key')}',
      'delay' => '等待：${value('duration')} 秒',
      'bgeffect' || 'effect' => '特效：${value('name')}',
      _ => entry.tag,
    };
  }

  Widget _commands({required bool inlineInspector}) => Column(
    children: [
      _commandHeader(),
      Expanded(
        child: inlineInspector
            ? ListView(children: _commandRows(inlineInspector: true))
            : ReorderableListView(
                buildDefaultDragHandles: false,
                onReorderItem: _reorderCommands,
                children: _commandRows(inlineInspector: false),
              ),
      ),
    ],
  );

  List<Widget> _commandRows({required bool inlineInspector}) => [
    if (beat.commands.isEmpty)
      const ListTile(
        key: ValueKey('empty-command'),
        title: Text('暂无演出指令'),
        leading: Icon(Icons.movie_outlined),
      ),
    for (final (i, entry) in beat.commands.indexed) ...[
      ListTile(
        key: ObjectKey(entry),
        dense: true,
        selected: i == _command,
        leading: inlineInspector
            ? Icon(
                Icons.drag_handle,
                color: Theme.of(context).colorScheme.onSurfaceVariant
                    .withValues(alpha: .55),
              )
            : ReorderableDragStartListener(
                index: i,
                child: Icon(
                  Icons.drag_handle,
                  color: Theme.of(context).colorScheme.onSurfaceVariant
                      .withValues(alpha: .55),
                ),
              ),
        title: Text(editorFields[entry.tag]?.$1 ?? '原始指令'),
        subtitle: Text(
          entry.raw ?? _commandSummary(entry),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        onTap: () => setState(() {
          _command = _command == i ? -1 : i;
          _formVersion++;
          _typing = null;
        }),
        trailing: PopupMenuButton<String>(
          tooltip: '指令操作 ${i + 1}',
          onSelected: (action) => _commandAction(i, action),
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'duplicate', child: Text('复制指令')),
            const PopupMenuItem(value: 'insert', child: Text('在此之后插入')),
            ..._reorderMenu(i, beat.commands.length),
            const PopupMenuItem(value: 'delete', child: Text('删除指令')),
          ],
        ),
      ),
      if (inlineInspector && i == _command)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: _inspector(),
          ),
        ),
    ],
  ];

  List<Widget> _inspector() {
    final current = command;
    if (current == null) {
      return const [ListTile(title: Text('指令属性'), subtitle: Text('未选中指令'))];
    }
    final definition = editorFields[current.tag];
    if (definition == null || current.raw != null) {
      return [
        Text(
          definition?.$1 ?? '高级指令',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        TextFormField(
          key: ValueKey((_formVersion, 'source')),
          initialValue: current.source,
          minLines: 5,
          maxLines: 12,
          keyboardType: TextInputType.multiline,
          decoration: const InputDecoration(
            labelText: '脚本源码',
            helperText: '编辑后会保留为单条指令；格式错误时不会覆盖当前内容。',
            border: OutlineInputBorder(),
          ),
          onChanged: (source) {
            try {
              final parsed = StoryScript.parse(source).commands;
              if (parsed.length != 1) return;
              final commands = [...beat.commands];
              commands[_command] = EditCommand.fromScript(parsed.single);
              _change(_withCommands(commands), typing: 'source');
            } on FormatException {
              // 输入中的半成品等待用户继续编辑。
            }
          },
        ),
      ];
    }
    return [
      Text(definition.$1, style: Theme.of(context).textTheme.titleMedium),
      for (final field in definition.$2)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: _field(field, current),
        ),
    ];
  }

  Widget _field(EditorField field, EditCommand current) {
    final value = current.args[field.key] ?? field.initial;
    final key = ValueKey((_formVersion, field.key));
    if (field.type == FieldType.toggle) {
      return SwitchListTile(
        key: key,
        contentPadding: EdgeInsets.zero,
        title: Text(field.label),
        value: value == 'true' || value == '1',
        onChanged: (v) => _updateCommand({field.key: '$v'}),
      );
    }
    if (field.type == FieldType.choice) {
      return DropdownButtonFormField<String>(
        key: key,
        isExpanded: true,
        initialValue: field.options.containsKey(value) ? value : null,
        decoration: InputDecoration(labelText: field.label),
        items: [
          for (final item in field.options.entries)
            DropdownMenuItem(value: item.key, child: Text(item.value)),
        ],
        onChanged: (v) {
          if (v != null) _updateCommand({field.key: v});
        },
      );
    }
    if (isMediaField(field.type)) {
      return OutlinedButton.icon(
        key: key,
        onPressed: () => _pick(field),
        icon: Icon(
          field.type == FieldType.fx
              ? Icons.auto_awesome
              : Icons.perm_media_outlined,
        ),
        label: Text(
          value.isEmpty
              ? field.label
              : '${field.label}：${project.assets[value]?.name ?? value}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      );
    }
    return Focus(
      key: key,
      onFocusChange: (focused) {
        if (!focused && _typing == field.key) _typing = null;
      },
      child: TextFormField(
        initialValue: value,
        minLines: field.type == FieldType.multiline ? 3 : 1,
        maxLines: field.type == FieldType.multiline ? 6 : 1,
        keyboardType: field.type == FieldType.number
            ? const TextInputType.numberWithOptions(decimal: true, signed: true)
            : TextInputType.text,
        decoration: InputDecoration(
          labelText: field.label,
          border: const OutlineInputBorder(),
          isDense: true,
        ),
        onChanged: (v) => _updateCommand({field.key: v}, typing: field.key),
      ),
    );
  }
}
