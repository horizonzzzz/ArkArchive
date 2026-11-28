import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../app/archive_widgets.dart';

import '../story_player/data/asset_store.dart';
import '../story_player/ui/story_stage.dart';
import 'editor_board.dart';
import 'editor_inspector.dart';
import 'editor_materials.dart';
import 'editor_platform.dart';
import 'editor_preview.dart';
import 'editor_project.dart';
import 'editor_script.dart';
import 'editor_stage.dart';
import 'editor_structure.dart';
import 'editor_timeline.dart';
import 'editor_timeline_materials.dart';
import 'editor_timeline_view.dart';

enum _PreviewMode { beat, fromBeat, full }

enum _EditorWorkspace { stage, board, script }

typedef _Selection = (EditorProject, int, int, int);

// —— 传输控制快捷键（P0-2）：disabled 时事件继续冒泡给文本框/舞台 ——

class _TogglePlayIntent extends Intent {
  const _TogglePlayIntent();
}

class _StepStopIntent extends Intent {
  const _StepStopIntent(this.delta);
  final int delta;
}

class _StepCommandIntent extends Intent {
  const _StepCommandIntent(this.delta);
  final int delta;
}

class _GotoIntent extends Intent {
  const _GotoIntent(this.toStart);
  final bool toStart;
}

class _UndoIntent extends Intent {
  const _UndoIntent();
}

class _RedoIntent extends Intent {
  const _RedoIntent();
}

class _CopyCommandsIntent extends Intent {
  const _CopyCommandsIntent();
}

class _CutCommandsIntent extends Intent {
  const _CutCommandsIntent();
}

class _PasteCommandsIntent extends Intent {
  const _PasteCommandsIntent();
}

class _DuplicateCommandsIntent extends Intent {
  const _DuplicateCommandsIntent();
}

class _DeleteCommandsIntent extends Intent {
  const _DeleteCommandsIntent();
}

class _SelectAllCommandsIntent extends Intent {
  const _SelectAllCommandsIntent();
}

class _CommandPaletteIntent extends Intent {
  const _CommandPaletteIntent();
}

class _NavHistoryIntent extends Intent {
  const _NavHistoryIntent(this.delta);
  final int delta;
}

/// 快捷键动作：被焦点场景屏蔽时不消费按键，交给文本框编辑或舞台微调。
class _GuardedAction<T extends Intent> extends Action<T> {
  _GuardedAction({required this.blocked, required this.handler});

  final bool Function() blocked;
  final Object? Function(T intent) handler;

  @override
  bool isEnabled(T intent) => !blocked();

  @override
  Object? invoke(T intent) => handler(intent);
}

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

/// 跨作品共享的编辑器指令剪贴板（P0-3：支持跨分镜、跨幕、跨作品粘贴）。
List<EditCommand> _sharedCommandClipboard = const [];

class _StoryEditorPageState extends State<StoryEditorPage> {
  EditorProject? _project;
  int _scene = 0, _beat = 0, _command = -1, _formVersion = 0;
  final Set<int> _selectedCommands = {};
  int? _selectionAnchor;
  final _undo = <_Selection>[];
  final _redo = <_Selection>[];
  final _navBack = <EditorPosition>[];
  final _navForward = <EditorPosition>[];
  final _positions = <String, EditorPosition>{};
  EditorPosition get _position =>
      EditorPosition(scene: _scene, beat: _beat, command: _command);
  Timer? _validationTimer;
  final _drafts = <String, EditorProject>{};
  final _batchSpeakerController = TextEditingController();
  Timer? _saveTimer;
  Future<void> _writes = Future.value();
  EditorProject? _pending;
  (String, DateTime, EditorPosition)? _pendingPosition;
  EditorProject? _failedSave;
  String _status = '';
  bool _busy = false;
  String? _typing;
  bool _loaded = false;
  bool _playing = false, _loop = false;
  int _speed = 1;
  _EditorWorkspace _workspace = _EditorWorkspace.stage;
  final _stageKey = GlobalKey();
  TrackAddress? _timelineSource;
  bool _compactTimeline = false;

  void _selectWorkspace(_EditorWorkspace target) {
    _scriptKey.currentState?.commitPendingEdits();
    setState(() => _workspace = target);
  }

  final _scriptKey = GlobalKey<EditorScriptViewState>();
  late final _resources = EditorPreviewResources(widget.store);
  EditorProject get project => _project!;
  EditorScene get scene => project.scenes[_scene];
  StoryBeat get beat => scene.beats[_beat];
  EditCommand? get command => _command < 0 ? null : beat.commands[_command];
  _Selection get _selection => (project, _scene, _beat, _command);

  List<EditorIssue> _validationCache = const [];

  void _scheduleValidation(EditorProject current) {
    _validationTimer?.cancel();
    _validationTimer = Timer(const Duration(milliseconds: 500), () {
      if (mounted && identical(_project, current)) {
        setState(() => _validateNow(current));
      }
    });
  }

  List<EditorIssue> _validateNow(EditorProject current) {
    _validationTimer?.cancel();
    return _validationCache = current.validateIssues();
  }

  void _refreshTimelineAvailability() {
    if (_workspace == _EditorWorkspace.board && mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _resources.mediaAvailability.addListener(_refreshTimelineAvailability);
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

  void _toast(String text) => _message(text);

  void _open(EditorProject next, {bool save = false}) {
    _scriptKey.currentState?.commitPendingEdits();
    _flush();
    // P1-4：重开作品恢复上次停留的幕/分镜/指令位置。
    final pos = _positions[next.id] ?? next.lastPosition;
    var s = 0, b = 0, c = -1;
    if (pos != null && next.scenes.isNotEmpty) {
      s = pos.scene.clamp(0, next.scenes.length - 1);
      final beats = next.scenes[s].beats;
      if (beats.isNotEmpty) {
        b = pos.beat.clamp(0, beats.length - 1);
        final cmds = beats[b].commands;
        c = pos.command < 0 || cmds.isEmpty
            ? -1
            : pos.command.clamp(0, cmds.length - 1);
      }
    }
    setState(() {
      _restore((next, s, b, c));
      _drafts[next.id] = next;
      _undo.clear();
      _redo.clear();
      _navBack.clear();
      _navForward.clear();
      _workspace = _EditorWorkspace.stage;
      _validationCache = const [];
      _status = save ? '待保存' : '本地草稿';
    });
    if (save) _queueSave(next);
    _scheduleValidation(next);
  }

  void _restore(_Selection value) {
    _project = value.$1;
    _timelineSource = null;
    _scene = value.$2;
    _beat = value.$3;
    _command = value.$4;
    _selectedCommands
      ..clear()
      ..addAll(_command >= 0 ? [_command] : const []);
    _selectionAnchor = _command >= 0 ? _command : null;
    _formVersion++;
    _typing = null;
    _playing = false;
  }

  void _change(
    EditorProject next, {
    int? sceneIndex,
    int? beatIndex,
    int? selected,
    Set<int>? selectedSet,
    String? typing,
  }) {
    if (typing == null || _typing != typing) {
      _undo.add(_selection);
      if (_undo.length > 60) _undo.removeAt(0);
    }
    _redo.clear();
    final targetScene = sceneIndex ?? _scene;
    final targetBeat = beatIndex ?? _beat;
    final targetCmd = selected ?? _command;
    setState(() {
      _project = next;
      _timelineSource = null;
      _scene = targetScene;
      _beat = targetBeat;
      _command = targetCmd;
      if (selectedSet != null) {
        _selectedCommands
          ..clear()
          ..addAll(selectedSet);
      } else if (selected != null || sceneIndex != null || beatIndex != null) {
        _selectedCommands
          ..clear()
          ..addAll(targetCmd >= 0 ? [targetCmd] : const []);
        _selectionAnchor = targetCmd >= 0 ? targetCmd : null;
      } else {
        final len = next.scenes[targetScene].beats[targetBeat].commands.length;
        _selectedCommands.removeWhere((i) => i < 0 || i >= len);
        if (_command >= len) _command = len - 1;
      }
      if (typing == null) _formVersion++;
      _typing = typing;
    });
    _queueSave(next);
    _scheduleValidation(next);
  }

  void _history({required bool redo}) {
    final from = redo ? _redo : _undo;
    final to = redo ? _undo : _redo;
    if (from.isEmpty) return;
    to.add(_selection);
    setState(() => _restore(from.removeLast()));
    _queueSave(project);
    _scheduleValidation(project);
  }

  void _queueSave(EditorProject next) {
    _positions[next.id] = _position;
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
    final navigation = _pendingPosition;
    _pendingPosition = null;
    if (snapshot == null && navigation != null) {
      final (id, revision, position) = navigation;
      final storage = widget.storage;
      _writes = _writes.then((_) async {
        try {
          await storage.savePosition(id, revision, position);
        } catch (_) {
          // 导航位置可从上次完整草稿恢复，失败不影响内容保存。
        }
      });
      return;
    }
    final position = _positions[snapshot?.id];
    final stored = snapshot?.copyWith(
      lastPosition: position,
      updatedAt: snapshot.updatedAt,
    );
    _pending = null;
    if (snapshot == null || stored == null) return;
    final storage = widget.storage;
    _writes = _writes.then((_) async {
      try {
        await storage.save(stored);
        if (mounted && identical(_project, snapshot)) {
          final now = DateTime.now();
          setState(
            () => _status =
                '已保存 '
                '${now.hour.toString().padLeft(2, '0')}:'
                '${now.minute.toString().padLeft(2, '0')}',
          );
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
    _validationTimer?.cancel();
    _batchSpeakerController.dispose();
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
    _scriptKey.currentState?.commitPendingEdits();
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
                    for (final draft
                        in _drafts.values.toList()
                          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)))
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
                            ArchivePopupMenuItem(
                              value: 'play',
                              enabled: widget.onPlayProject != null,
                              child: const Text('播放'),
                            ),
                            const ArchivePopupMenuItem(
                              value: 'rename',
                              child: Text('重命名'),
                            ),
                            const ArchivePopupMenuItem(
                              value: 'duplicate',
                              child: Text('复制'),
                            ),
                            const ArchivePopupMenuItem(
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
    _scriptKey.currentState?.commitPendingEdits();
    try {
      final current = project;
      final issues = _validateNow(current);
      if (issues.isNotEmpty) {
        final outcome = await _issues(issues, title: '作品检查', allowExport: true);
        if (!mounted || !outcome.proceed) return;
        if (outcome.goto != null) {
          _gotoIssue(outcome.goto!);
          return;
        }
      }
      if (scriptOnly && current.assets.isNotEmpty) {
        final proceed = await _issues(
          [const EditorIssue('纯脚本不包含上传素材。跨设备使用请导出作品文件。')],
          title: '导出脚本',
          allowExport: true,
        );
        if (!mounted || !proceed.proceed) return;
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

  /// 校验/警告对话框：可定位问题提供「前往」，返回是否继续导出与跳转目标。
  Future<({bool proceed, EditorIssue? goto})> _issues(
    List<EditorIssue> issues, {
    String title = '提示',
    bool allowExport = false,
  }) async {
    EditorIssue? goto;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: math.min(460, MediaQuery.sizeOf(context).width - 48),
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final issue in issues)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(issue.message),
                  trailing: issue.locatable
                      ? TextButton(
                          onPressed: () {
                            goto = issue;
                            Navigator.pop(dialog, true);
                          },
                          child: const Text('前往'),
                        )
                      : null,
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
    );
    return (proceed: proceed ?? false, goto: goto);
  }

  /// 记录导航历史并跳转到指定位置（P1-4：Alt+←/→ 前进后退）。
  void _navigateTo(
    int sceneIndex,
    int beatIndex, {
    int commandIndex = -1,
    bool recordHistory = true,
    _EditorWorkspace? workspace,
  }) {
    _scriptKey.currentState?.commitPendingEdits();
    if (sceneIndex < 0 || sceneIndex >= project.scenes.length) return;
    final targetBeats = project.scenes[sceneIndex].beats;
    if (beatIndex < 0 || beatIndex >= targetBeats.length) return;
    final targetCmds = targetBeats[beatIndex].commands;
    final clampedCmd = commandIndex < 0 || targetCmds.isEmpty
        ? -1
        : commandIndex.clamp(0, targetCmds.length - 1);
    final current = EditorPosition(
      scene: _scene,
      beat: _beat,
      command: _command,
    );
    final nextPos = EditorPosition(
      scene: sceneIndex,
      beat: beatIndex,
      command: clampedCmd,
    );
    if (recordHistory &&
        (current.scene != nextPos.scene ||
            current.beat != nextPos.beat ||
            current.command != nextPos.command)) {
      _navBack.add(current);
      if (_navBack.length > 50) _navBack.removeAt(0);
      _navForward.clear();
    }
    setState(() {
      _scene = sceneIndex;
      _beat = beatIndex;
      _command = clampedCmd;
      _selectedCommands
        ..clear()
        ..addAll(clampedCmd >= 0 ? [clampedCmd] : const []);
      _selectionAnchor = clampedCmd >= 0 ? clampedCmd : null;
      _playing = false;
      _timelineSource = null;
      _typing = null;
      _formVersion++;
      if (workspace != null) _workspace = workspace;
    });
    final currentProject = project;
    _positions[currentProject.id] = nextPos;
    _pendingPosition = (currentProject.id, currentProject.updatedAt, nextPos);
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 450), _flush);
  }

  void _stepNavHistory(int delta) {
    if (delta < 0) {
      if (_navBack.isEmpty) return;
      final current = EditorPosition(
        scene: _scene,
        beat: _beat,
        command: _command,
      );
      final target = _navBack.removeLast();
      _navForward.add(current);
      _navigateTo(
        target.scene.clamp(0, project.scenes.length - 1),
        target.beat.clamp(
          0,
          project
                  .scenes[target.scene.clamp(0, project.scenes.length - 1)]
                  .beats
                  .length -
              1,
        ),
        commandIndex: target.command,
        recordHistory: false,
      );
    } else {
      if (_navForward.isEmpty) return;
      final current = EditorPosition(
        scene: _scene,
        beat: _beat,
        command: _command,
      );
      final target = _navForward.removeLast();
      _navBack.add(current);
      _navigateTo(
        target.scene.clamp(0, project.scenes.length - 1),
        target.beat.clamp(
          0,
          project
                  .scenes[target.scene.clamp(0, project.scenes.length - 1)]
                  .beats
                  .length -
              1,
        ),
        commandIndex: target.command,
        recordHistory: false,
      );
    }
  }

  /// 校验「前往」：切到问题所在分镜并选中问题指令（P0-6 校验定位）。
  void _gotoIssue(EditorIssue issue) {
    if (!issue.locatable ||
        issue.sceneIndex >= project.scenes.length ||
        issue.beatIndex >= project.scenes[issue.sceneIndex].beats.length) {
      return;
    }
    _navigateTo(
      issue.sceneIndex,
      issue.beatIndex,
      commandIndex: issue.commandIndex,
      workspace: _EditorWorkspace.stage,
    );
  }

  EditorProject _withScene(EditorScene next, [int? sceneIndex]) => project
      .copyWith(scenes: [...project.scenes]..[sceneIndex ?? _scene] = next);

  EditorProject _withBeat(StoryBeat next, {int? sceneIndex, int? beatIndex}) {
    final si = sceneIndex ?? _scene;
    final bi = beatIndex ?? _beat;
    final targetScene = project.scenes[si];
    return _withScene(
      targetScene.copyWith(beats: [...targetScene.beats]..[bi] = next),
      si,
    );
  }

  void _seekTimeline(TrackAddress cursor, {TrackAddress? source}) {
    _navigateTo(cursor.scene, cursor.beat, commandIndex: cursor.command);
    _timelineSource = source;
  }

  void _openTimelineAddress(TrackAddress address) => _navigateTo(
    address.scene,
    address.beat,
    commandIndex: address.command,
    workspace: _EditorWorkspace.stage,
  );

  StoryBeat _timelineBeat(TrackAddress address) =>
      project.scenes[address.scene].beats[address.beat];

  void _insertTimelineCommands(
    TrackAddress address,
    List<EditCommand> commands, [
    EditorAsset? asset,
  ]) {
    if (commands.isEmpty) return;
    final target = _timelineBeat(address);
    final list = [...target.commands]..insertAll(address.command, commands);
    var next = _withBeat(
      target.copyWith(commands: list),
      sceneIndex: address.scene,
      beatIndex: address.beat,
    );
    if (asset != null) {
      next = next.copyWith(assets: {...next.assets, asset.key: asset});
    }
    _change(
      next,
      sceneIndex: address.scene,
      beatIndex: address.beat,
      selected: address.command + commands.length - 1,
    );
  }

  void _trimTimeline(
    TrackAddress address,
    EditCommand clear,
    List<TrackAddress> reentries,
  ) {
    final scene = project.scenes[address.scene];
    final changed = <int, List<EditCommand>>{};
    List<EditCommand> at(int beat) =>
        changed.putIfAbsent(beat, () => [...scene.beats[beat].commands]);
    // 同段内带素材的差分指令会重新上场。去掉素材，保留其余字段及全局聚焦。
    for (final reentry in reentries) {
      final commands = at(reentry.beat);
      commands[reentry.command] = commands[reentry.command].withArgs({
        'name': '',
      });
    }
    at(address.beat).insert(address.command, clear);
    final scenes = [...project.scenes];
    scenes[address.scene] = scene.copyWith(
      beats: [
        for (final (index, beat) in scene.beats.indexed)
          changed[index] == null
              ? beat
              : beat.copyWith(commands: changed[index]),
      ],
    );
    _change(
      project.copyWith(scenes: scenes),
      sceneIndex: address.scene,
      beatIndex: address.beat,
      selected: address.command,
    );
    setState(() => _timelineSource = address);
  }

  void _editTimelineSource(
    TrackAddress address,
    EditCommand updated, {
    String? typing,
    EditorAsset? asset,
  }) {
    final target = _timelineBeat(address);
    final list = [...target.commands]..[address.command] = updated;
    var next = _withBeat(
      target.copyWith(commands: list),
      sceneIndex: address.scene,
      beatIndex: address.beat,
    );
    if (asset != null) {
      next = next.copyWith(assets: {...next.assets, asset.key: asset});
    }
    _change(next, typing: typing);
    _timelineSource = address;
  }

  void _replaceTimelineMedia(
    TrackAddress address,
    String field,
    TimelineMaterial material,
  ) {
    final current = _timelineBeat(address).commands[address.command];
    if (current.raw != null) return;
    _editTimelineSource(
      address,
      current.withArgs({field: material.key}),
      asset: material.asset,
    );
  }

  bool _timelineMissing(TrackValue value, TrackKind kind) {
    final key = value.label;
    if (!key.startsWith('local_')) {
      final type =
          kind.media ??
          switch (kind) {
            TrackKind.sound => FieldType.sound,
            TrackKind.effect => FieldType.fx,
            _ => null,
          };
      return type != null && _resources.mediaUnavailable(type, key);
    }
    final asset = project.assets[key];
    return asset == null ||
        asset.isImage != (kind != TrackKind.music && kind != TrackKind.sound);
  }

  Widget _buildTimelineInspector(TrackAddress address) {
    final target = _timelineBeat(address);
    final current = target.commands[address.command];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('修改来源会影响整段', style: Theme.of(context).textTheme.labelMedium),
        Text('${project.scenes[address.scene].title} / ${target.title}'),
        EditorInspector(
          key: ValueKey(address),
          project: project,
          commands: target.commands,
          activeIndex: address.command,
          selectedIndices: {address.command},
          formVersion: _formVersion,
          onUpdateCommand: (values, {String? typing}) => _editTimelineSource(
            address,
            current.withArgs(values),
            typing: typing,
          ),
          onUpdateMany: (_, values) =>
              _editTimelineSource(address, current.withArgs(values)),
          onReplaceSource: (updated) =>
              _editTimelineSource(address, updated, typing: 'source'),
          onPickMedia: (field) async {
            final original = project;
            final result = await showDialog<(String, EditorAsset?)>(
              context: context,
              builder: (_) => EditorMaterialPicker(
                field: field,
                current: current.value(field.key),
                resources: _resources,
                assets: original.assets,
                storage: widget.storage,
              ),
            );
            if (!mounted ||
                !identical(original, project) ||
                _timelineSource != address ||
                result == null) {
              return;
            }
            _replaceTimelineMedia(
              address,
              field.key,
              TimelineMaterial(field.type, result.$1, result.$2),
            );
          },
          onDropMedia: (field, material) =>
              _replaceTimelineMedia(address, field.key, material),
          onFocusTypingEnd: (fieldKey) {
            if (_typing == fieldKey) _typing = null;
          },
          onResetCommand: () {
            final definition = editorFields[current.tag];
            if (current.raw != null || definition == null) return;
            _editTimelineSource(
              address,
              EditCommand(current.tag, {
                for (final field in definition.$2)
                  if (field.initial.isNotEmpty) field.key: field.initial,
              }),
            );
          },
        ),
      ],
    );
  }

  Widget _timelineInheritance() {
    final state = EditorTimeline.of(project, _scene).stateBeforeBeat(_beat);
    if (state.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          for (final entry in state.entries)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ActionChip(
                visualDensity: VisualDensity.compact,
                tooltip: '跳到继承来源：${entry.value.label}',
                label: Text('入镜继承 · ${trackSlotLabel(entry.key)}'),
                onPressed: () => _openTimelineAddress(entry.value.source),
              ),
            ),
        ],
      ),
    );
  }

  EditorProject _withCommands(List<EditCommand> next) =>
      _withBeat(beat.copyWith(commands: next));

  void _selectBeat(int index, {int? sceneIndex}) =>
      _navigateTo(sceneIndex ?? _scene, index, commandIndex: -1);

  // —— 播放头与传输控制（P0-1 / P0-2）——

  /// 当前分镜的停顿点，不为绘制传输条编译全作品。
  List<int> _stopIndexes() {
    final stops = <int>[];
    for (final (i, command) in beat.commands.indexed) {
      final isStop = switch (command.tag) {
        'dialogue' => command.value('text').isNotEmpty,
        'aside' || 'multiline' || 'endtip' => command.raw != null,
        'decision' => command.value('options').isNotEmpty,
        _ => false,
      };
      if (isStop) stops.add(i);
    }
    return stops;
  }

  int get _beatLength => beat.commands.length;

  void _selectCommand(int index) {
    if (_beatLength == 0) return;
    final clamped = index.clamp(-1, _beatLength - 1);
    setState(() {
      _command = clamped;
      _selectedCommands
        ..clear()
        ..addAll(clamped >= 0 ? [clamped] : const []);
      _selectionAnchor = clamped >= 0 ? clamped : null;
      _typing = null;
      _formVersion++;
    });
  }

  /// 多选点击：支持单击、Shift 连续区间选、Ctrl/⌘ 增减单条（P0-3）。
  void _onTapCommandRow(int index) {
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    final shift =
        keys.contains(LogicalKeyboardKey.shiftLeft) ||
        keys.contains(LogicalKeyboardKey.shiftRight);
    final ctrl =
        keys.contains(LogicalKeyboardKey.controlLeft) ||
        keys.contains(LogicalKeyboardKey.controlRight) ||
        keys.contains(LogicalKeyboardKey.metaLeft) ||
        keys.contains(LogicalKeyboardKey.metaRight);
    if (shift && _selectionAnchor != null) {
      final start = math.min(_selectionAnchor!, index);
      final end = math.max(_selectionAnchor!, index);
      setState(() {
        _selectedCommands
          ..clear()
          ..addAll([for (var i = start; i <= end; i++) i]);
        _command = index;
        _typing = null;
        _formVersion++;
      });
      return;
    }
    if (ctrl) {
      _toggleMultiCommand(index);
      return;
    }
    _selectCommand(index);
  }

  /// 长按或 Ctrl 点击增减选中（含移动端轻量多选）。
  void _toggleMultiCommand(int index) {
    if (index < 0 || index >= _beatLength) return;
    setState(() {
      if (_selectedCommands.contains(index)) {
        _selectedCommands.remove(index);
        if (_command == index) {
          _command = _selectedCommands.isEmpty ? -1 : _selectedCommands.last;
        }
      } else {
        _selectedCommands.add(index);
        _command = index;
        _selectionAnchor ??= index;
      }
      _typing = null;
      _formVersion++;
    });
  }

  void _selectAllCommands() {
    if (_beatLength == 0) return;
    setState(() {
      _selectedCommands
        ..clear()
        ..addAll([for (var i = 0; i < _beatLength; i++) i]);
      _command = _beatLength - 1;
      _selectionAnchor = 0;
      _typing = null;
      _formVersion++;
    });
  }

  void _invertCommandSelection() {
    if (_beatLength == 0) return;
    setState(() {
      final next = <int>{
        for (var i = 0; i < _beatLength; i++)
          if (!_selectedCommands.contains(i)) i,
      };
      _selectedCommands
        ..clear()
        ..addAll(next);
      _command = next.isEmpty ? -1 : next.last;
      _selectionAnchor = next.isEmpty ? null : next.first;
      _typing = null;
      _formVersion++;
    });
  }

  void _clearMultiSelection() {
    setState(() {
      _selectedCommands.clear();
      if (_command >= 0 && _command < _beatLength) {
        _selectedCommands.add(_command);
      }
      _selectionAnchor = _command >= 0 ? _command : null;
      _formVersion++;
    });
  }

  List<int> _effectiveSelectedSorted() {
    if (_selectedCommands.isNotEmpty) {
      final sorted =
          _selectedCommands.where((i) => i >= 0 && i < _beatLength).toList()
            ..sort();
      if (sorted.isNotEmpty) return sorted;
    }
    if (_command >= 0 && _command < _beatLength) return [_command];
    return const [];
  }

  void _copySelectedCommands({bool cut = false}) {
    final indices = _effectiveSelectedSorted();
    if (indices.isEmpty) return;
    _sharedCommandClipboard = [for (final i in indices) beat.commands[i]];
    if (cut) {
      final removeSet = indices.toSet();
      final next = [
        for (var i = 0; i < beat.commands.length; i++)
          if (!removeSet.contains(i)) beat.commands[i],
      ];
      _change(
        _withCommands(next),
        selected: next.isEmpty ? -1 : math.min(indices.first, next.length - 1),
      );
      _toast('已剪切 ${indices.length} 条指令');
    } else {
      _toast('已复制 ${indices.length} 条指令');
    }
  }

  void _pasteClipboardCommands() {
    if (_sharedCommandClipboard.isEmpty) {
      _toast('剪贴板为空');
      return;
    }
    final insertAt = _command < 0
        ? beat.commands.length
        : (_command + 1).clamp(0, beat.commands.length);
    final next = [...beat.commands]
      ..insertAll(insertAt, _sharedCommandClipboard);
    final pastedSet = {
      for (var i = 0; i < _sharedCommandClipboard.length; i++) insertAt + i,
    };
    _change(
      _withCommands(next),
      selected: insertAt + _sharedCommandClipboard.length - 1,
      selectedSet: pastedSet,
    );
    _toast('已粘贴 ${_sharedCommandClipboard.length} 条指令');
  }

  void _duplicateSelectedCommands() {
    final indices = _effectiveSelectedSorted();
    if (indices.isEmpty) return;
    final copies = [for (final i in indices) beat.commands[i]];
    final insertAt = indices.last + 1;
    final next = [...beat.commands]..insertAll(insertAt, copies);
    final dupSet = {for (var i = 0; i < copies.length; i++) insertAt + i};
    _change(
      _withCommands(next),
      selected: insertAt + copies.length - 1,
      selectedSet: dupSet,
    );
    _toast('已复制 ${copies.length} 条指令');
  }

  void _deleteSelectedCommands() {
    final indices = _effectiveSelectedSorted();
    if (indices.isEmpty) return;
    final removeSet = indices.toSet();
    final next = [
      for (var i = 0; i < beat.commands.length; i++)
        if (!removeSet.contains(i)) beat.commands[i],
    ];
    _change(
      _withCommands(next),
      selected: next.isEmpty ? -1 : math.min(indices.first, next.length - 1),
    );
    _toast('已删除 ${indices.length} 条指令');
  }

  void _applyBatchSpeaker(String speaker) {
    final indices = _effectiveSelectedSorted();
    if (indices.isEmpty) return;
    final next = [...beat.commands];
    var changed = 0;
    for (final i in indices) {
      final cmd = next[i];
      if (cmd.raw == null && (cmd.tag == 'dialogue' || cmd.tag == 'dialog')) {
        next[i] = cmd.withArgs({'name': speaker});
        changed++;
      }
    }
    if (changed == 0) {
      _toast('所选指令中没有可修改说话人的对白');
      return;
    }
    _change(_withCommands(next), selectedSet: indices.toSet());
    _toast('已更新 $changed 条对白的说话人');
  }

  void _updateManyCommands(Set<int> indices, Map<String, String> values) {
    if (indices.isEmpty) return;
    final next = [...beat.commands];
    for (final i in indices) {
      if (i < 0 || i >= next.length) continue;
      if (next[i].raw != null) continue;
      next[i] = next[i].withArgs(values);
    }
    _change(_withCommands(next), selectedSet: indices);
  }

  void _resetCurrentCommand() {
    final current = command;
    if (current == null || current.raw != null) return;
    final definition = editorFields[current.tag];
    if (definition == null) return;
    final defaults = EditCommand(current.tag, {
      for (final field in definition.$2)
        if (field.initial.isNotEmpty) field.key: field.initial,
    });
    _change(
      _withCommands([...beat.commands]..[_command] = defaults),
      selected: _command,
    );
  }

  /// 处理拖动前序分镜继承对象时的轻量二选一（P0-4）。
  Future<void> _handleInheritedStageDrag(StageInheritedRequest req) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text('「${req.label}」继承自前序分镜'),
        content: Text(
          '该对象由「${project.scenes[req.sourceScene].title} / '
          '${project.scenes[req.sourceScene].beats[req.sourceBeat].title}」继承而来。\n'
          '你可以直接跳到来源指令修改（会影响后续所有继承该状态的分镜），或在当前分镜插入一条覆盖指令。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('取消'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(dialog, 'goto'),
            child: const Text('跳转到来源指令'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, 'override'),
            child: const Text('在当前分镜插入覆盖指令'),
          ),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'goto') {
      _navigateTo(
        req.sourceScene,
        req.sourceBeat,
        commandIndex: req.sourceCommand,
      );
      return;
    }
    final insertAt = _command < 0
        ? beat.commands.length
        : (_command + 1).clamp(0, beat.commands.length);
    final sourceBeatCommands =
        project.scenes[req.sourceScene].beats[req.sourceBeat].commands;
    final sourceCmd =
        req.sourceCommand >= 0 && req.sourceCommand < sourceBeatCommands.length
        ? sourceBeatCommands[req.sourceCommand]
        : EditCommand(req.tag, {
            if (req.slot.isNotEmpty) 'slot': req.slot,
            if (req.keyName.isNotEmpty)
              (req.tag == 'charslot' ? 'name' : 'image'): req.keyName,
          });
    final next = [...beat.commands]
      ..insert(insertAt, sourceCmd.withArgs(req.values));
    _change(_withCommands(next), selected: insertAt);
    _toast('已在当前分镜插入覆盖指令');
  }

  Future<void> _sceneActionAt(int si, String action) async {
    if (si < 0 || si >= project.scenes.length) return;
    final original = project;
    final targetScene = project.scenes[si];
    if (action == 'add' || action == 'rename') {
      final name = await _title(
        action == 'add' ? '新建幕' : '重命名幕',
        action == 'add'
            ? '第 ${project.scenes.length + 1} 幕'
            : targetScene.title,
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
        _change(_withScene(targetScene.copyWith(title: name), si));
      }
      return;
    }
    final scenes = [...project.scenes];
    if (action == 'delete') {
      if (scenes.length == 1) return;
      scenes.removeAt(si);
      final nextScene = math.min(_scene == si ? si : _scene, scenes.length - 1);
      _change(
        project.copyWith(scenes: scenes),
        sceneIndex: nextScene,
        beatIndex: 0,
        selected: -1,
      );
    } else if (action == 'duplicate') {
      scenes.insert(
        si + 1,
        targetScene.copyWith(
          title: '${targetScene.title} 副本'.characters.take(120).toString(),
        ),
      );
      _change(
        project.copyWith(scenes: scenes),
        sceneIndex: si + 1,
        beatIndex: 0,
        selected: -1,
      );
    } else if (action == 'up' || action == 'down') {
      final target = si + (action == 'up' ? -1 : 1);
      if (target < 0 || target >= scenes.length) return;
      scenes.insert(target, scenes.removeAt(si));
      _change(project.copyWith(scenes: scenes), sceneIndex: target);
    }
  }

  Future<void> _beatActionAt(int si, int bi, String action) async {
    if (si < 0 || si >= project.scenes.length) return;
    final targetScene = project.scenes[si];
    if (bi < 0 || bi >= targetScene.beats.length) return;
    final targetBeat = targetScene.beats[bi];
    final beats = [...targetScene.beats];
    if (action == 'add' || action == 'duplicate') {
      final index = bi + 1;
      beats.insert(
        index,
        action == 'add'
            ? StoryBeat('分镜 ${beats.length + 1}')
            : targetBeat.copyWith(
                title: '${targetBeat.title} 副本'.characters.take(120).toString(),
              ),
      );
      _change(
        _withScene(targetScene.copyWith(beats: beats), si),
        sceneIndex: si,
        beatIndex: index,
        selected: -1,
      );
    } else if (action == 'rename') {
      final original = project;
      final name = await _title('重命名分镜', targetBeat.title);
      if (mounted && name != null && identical(original, project)) {
        _change(
          _withBeat(
            targetBeat.copyWith(title: name),
            sceneIndex: si,
            beatIndex: bi,
          ),
        );
      }
    } else if (action == 'delete') {
      if (beats.length == 1) return;
      beats.removeAt(bi);
      _change(
        _withScene(targetScene.copyWith(beats: beats), si),
        sceneIndex: si,
        beatIndex: math.min(bi, beats.length - 1),
        selected: -1,
      );
    } else if (action == 'up' || action == 'down') {
      final target = bi + (action == 'up' ? -1 : 1);
      if (target < 0 || target >= beats.length) return;
      beats.insert(target, beats.removeAt(bi));
      _change(
        _withScene(targetScene.copyWith(beats: beats), si),
        sceneIndex: si,
        beatIndex: target,
      );
    }
  }

  void _addBeatToScene(int si) {
    if (si < 0 || si >= project.scenes.length) return;
    final targetScene = project.scenes[si];
    final beats = [
      ...targetScene.beats,
      StoryBeat('分镜 ${targetScene.beats.length + 1}'),
    ];
    _change(
      _withScene(targetScene.copyWith(beats: beats), si),
      sceneIndex: si,
      beatIndex: beats.length - 1,
      selected: -1,
    );
  }

  void _moveBeatTo(BeatRef from, int toScene, int toBeat) {
    if (from.scene < 0 ||
        from.scene >= project.scenes.length ||
        toScene < 0 ||
        toScene >= project.scenes.length) {
      return;
    }
    final scenes = [
      for (final s in project.scenes) s.copyWith(beats: [...s.beats]),
    ];
    final srcBeats = scenes[from.scene].beats;
    if (from.beat < 0 || from.beat >= srcBeats.length) return;
    if (from.scene != toScene && srcBeats.length <= 1) {
      _toast('每一幕至少需要保留一个分镜');
      return;
    }
    final moved = srcBeats.removeAt(from.beat);
    final dstBeats = scenes[toScene].beats;
    final insertAt = toBeat.clamp(0, dstBeats.length);
    dstBeats.insert(insertAt, moved);
    _change(
      project.copyWith(scenes: scenes),
      sceneIndex: toScene,
      beatIndex: insertAt,
      selected: -1,
    );
  }

  void _duplicateBeats(List<BeatRef> refs) {
    if (refs.isEmpty) return;
    final scenes = [
      for (final s in project.scenes) s.copyWith(beats: [...s.beats]),
    ];
    final sorted = [...refs]
      ..sort((a, b) {
        final s = b.scene.compareTo(a.scene);
        return s != 0 ? s : b.beat.compareTo(a.beat);
      });
    for (final ref in sorted) {
      if (ref.scene >= scenes.length) continue;
      final list = scenes[ref.scene].beats;
      if (ref.beat >= list.length) continue;
      final orig = list[ref.beat];
      list.insert(
        ref.beat + 1,
        orig.copyWith(
          title: '${orig.title} 副本'.characters.take(120).toString(),
        ),
      );
    }
    _change(project.copyWith(scenes: scenes));
    _toast('已复制 ${sorted.length} 个分镜');
  }

  void _deleteBeats(List<BeatRef> refs) {
    if (refs.isEmpty) return;
    final scenes = [
      for (final s in project.scenes) s.copyWith(beats: [...s.beats]),
    ];
    final sorted = [...refs]
      ..sort((a, b) {
        final s = b.scene.compareTo(a.scene);
        return s != 0 ? s : b.beat.compareTo(a.beat);
      });
    var deleted = 0;
    for (final ref in sorted) {
      if (ref.scene >= scenes.length) continue;
      final list = scenes[ref.scene].beats;
      if (list.length <= 1 || ref.beat >= list.length) continue;
      list.removeAt(ref.beat);
      deleted++;
    }
    if (deleted == 0) {
      _toast('每一幕至少需要保留一个分镜');
      return;
    }
    final nextScene = _scene.clamp(0, scenes.length - 1);
    final nextBeat = _beat.clamp(0, scenes[nextScene].beats.length - 1);
    _change(
      project.copyWith(scenes: scenes),
      sceneIndex: nextScene,
      beatIndex: nextBeat,
      selected: -1,
    );
    _toast('已删除 $deleted 个分镜');
  }

  Future<void> _markScene(int si) async {
    if (si < 0 || si >= project.scenes.length) return;
    final target = project.scenes[si];
    final next = await showMarkerDialog(
      context,
      targetTitle: target.title,
      initial: target.marker,
    );
    if (!mounted || next == null) return;
    final marker = next.clear
        ? const EditorMarker()
        : (next.marker ?? const EditorMarker());
    _change(_withScene(target.copyWith(marker: marker), si));
  }

  Future<void> _markBeat(int si, int bi) async {
    if (si < 0 ||
        si >= project.scenes.length ||
        bi < 0 ||
        bi >= project.scenes[si].beats.length) {
      return;
    }
    final target = project.scenes[si].beats[bi];
    final next = await showMarkerDialog(
      context,
      targetTitle: target.title,
      initial: target.marker,
    );
    if (!mounted || next == null) return;
    final marker = next.clear
        ? const EditorMarker()
        : (next.marker ?? const EditorMarker());
    _change(
      _withBeat(
        target.copyWith(marker: marker),
        sceneIndex: si,
        beatIndex: bi,
      ),
    );
  }

  void _editScriptRow(ScriptRowRef row, {String? speaker, String? text}) {
    if (row.sceneIndex >= project.scenes.length) return;
    final s = project.scenes[row.sceneIndex];
    if (row.beatIndex >= s.beats.length) return;
    final b = s.beats[row.beatIndex];
    if (row.commandIndex >= b.commands.length) return;
    final cmd = b.commands[row.commandIndex];
    final nextCmd = cmd.withArgs({'name': ?speaker, 'text': ?text});
    final nextCommands = [...b.commands]..[row.commandIndex] = nextCmd;
    _change(
      _withBeat(
        b.copyWith(commands: nextCommands),
        sceneIndex: row.sceneIndex,
        beatIndex: row.beatIndex,
      ),
      typing: 'script:${row.sceneIndex}:${row.beatIndex}:${row.commandIndex}',
    );
  }

  void _batchReplaceScriptSpeaker(List<ScriptRowRef> rows, String speaker) {
    if (rows.isEmpty) return;
    final scenes = [
      for (final s in project.scenes)
        s.copyWith(
          beats: [
            for (final b in s.beats) b.copyWith(commands: [...b.commands]),
          ],
        ),
    ];
    var changed = 0;
    for (final row in rows) {
      if (!row.isDialogue) continue;
      if (row.sceneIndex >= scenes.length) continue;
      final b = scenes[row.sceneIndex].beats[row.beatIndex];
      if (row.commandIndex >= b.commands.length) continue;
      b.commands[row.commandIndex] = b.commands[row.commandIndex].withArgs({
        'name': speaker,
      });
      changed++;
    }
    if (changed == 0) {
      _toast('所选行中没有可批量修改说话人的对白');
      return;
    }
    _change(project.copyWith(scenes: scenes));
    _toast('已批量替换 $changed 条对白的说话人');
  }

  Future<void> _exportScriptFormat(String format) async {
    _scriptKey.currentState?.commitPendingEdits();
    final content = switch (format) {
      'csv' => exportScriptCsv(project),
      'srt' => exportScriptSrt(project),
      _ => exportScriptTxt(project),
    };
    try {
      await widget.storage.exportFile(
        project.title,
        format,
        Uint8List.fromList(utf8.encode(content)),
      );
      if (mounted) {
        _toast('已导出 ${format.toUpperCase()} 台本');
      }
    } catch (_) {
      _toast('导出失败，请检查存储空间后重试');
    }
  }

  /// 全局搜索弹窗（P1-4：按标题/台词/角色/素材 key/标记过滤并直达）。
  Future<void> _openGlobalSearch() async {
    final controller = TextEditingController();
    final hit = await showDialog<EditorSearchHit>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, setDialogState) {
          final hits = searchProjectContent(project, controller.text);
          return AlertDialog(
            title: const Text('全局搜索'),
            content: SizedBox(
              width: math.min(540, MediaQuery.sizeOf(context).width - 48),
              height: math.min(420, MediaQuery.sizeOf(context).height - 180),
              child: Column(
                children: [
                  TextField(
                    key: const ValueKey('global-search-input'),
                    controller: controller,
                    autofocus: true,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: '搜索幕、分镜、说话人、台词、素材 key 或标记备注…',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (_) => setDialogState(() {}),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: controller.text.trim().isEmpty
                        ? const Center(child: Text('输入关键词快速定位幕、分镜或指令'))
                        : hits.isEmpty
                        ? const Center(child: Text('没有找到匹配内容'))
                        : ListView.builder(
                            itemCount: hits.length,
                            itemBuilder: (_, i) {
                              final item = hits[i];
                              return ListTile(
                                dense: true,
                                leading: Chip(
                                  label: Text(item.kind),
                                  visualDensity: VisualDensity.compact,
                                ),
                                title: Text(
                                  item.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  item.subtitle,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onTap: () => Navigator.pop(dialog, item),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    if (!mounted || hit == null) return;
    _navigateTo(
      hit.sceneIndex,
      hit.beatIndex,
      commandIndex: hit.commandIndex,
      workspace: _EditorWorkspace.stage,
    );
  }

  /// 命令面板（P0-3：Ctrl+K 快捷执行所有编辑、切换与导出操作）。
  Future<void> _openCommandPalette() async {
    final actions = <({String label, String hint, VoidCallback run})>[
      (
        label: '切换到演出台',
        hint: '工作区',
        run: () => _selectWorkspace(_EditorWorkspace.stage),
      ),
      (
        label: '切换到编排台（故事板）',
        hint: '工作区',
        run: () => _selectWorkspace(_EditorWorkspace.board),
      ),
      (
        label: '切换到剧本台（对白表格）',
        hint: '工作区',
        run: () => _selectWorkspace(_EditorWorkspace.script),
      ),
      (label: '全局搜索', hint: '导航', run: _openGlobalSearch),
      (label: '添加演出指令', hint: '编辑', run: _showCommandChooser),
      (label: '新建分镜', hint: '结构', run: () => _beatAction('add')),
      (label: '新建幕', hint: '结构', run: () => _sceneAction('add')),
      (label: '全选当前分镜指令', hint: 'Ctrl+A', run: _selectAllCommands),
      (label: '反选当前分镜指令', hint: '选择集', run: _invertCommandSelection),
      (label: '复制选中指令', hint: 'Ctrl+C', run: () => _copySelectedCommands()),
      (
        label: '剪切选中指令',
        hint: 'Ctrl+X',
        run: () => _copySelectedCommands(cut: true),
      ),
      (label: '粘贴指令到播放头后', hint: 'Ctrl+V', run: _pasteClipboardCommands),
      (label: '快速副本（选中指令）', hint: 'Ctrl+D', run: _duplicateSelectedCommands),
      (label: '删除选中指令', hint: 'Delete', run: _deleteSelectedCommands),
      (label: '标记当前分镜', hint: '标记', run: () => _markBeat(_scene, _beat)),
      (label: '导出 TXT 台本', hint: '台本', run: () => _exportScriptFormat('txt')),
      (label: '导出 CSV 台本', hint: '台本', run: () => _exportScriptFormat('csv')),
      (label: '导出 SRT 字幕', hint: '台本', run: () => _exportScriptFormat('srt')),
      (label: '作品素材管理', hint: '素材', run: _assets),
      (label: '作品校验检查', hint: '检查', run: _checkProjectIssues),
    ];
    final controller = TextEditingController();
    final chosen = await showDialog<VoidCallback>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, setDialogState) {
          final q = controller.text.trim().toLowerCase();
          final filtered = [
            for (final a in actions)
              if (q.isEmpty ||
                  a.label.toLowerCase().contains(q) ||
                  a.hint.toLowerCase().contains(q))
                a,
          ];
          return AlertDialog(
            title: const Text('命令面板'),
            content: SizedBox(
              width: math.min(460, MediaQuery.sizeOf(context).width - 48),
              height: math.min(380, MediaQuery.sizeOf(context).height - 180),
              child: Column(
                children: [
                  TextField(
                    key: const ValueKey('command-palette-input'),
                    controller: controller,
                    autofocus: true,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.terminal),
                      hintText: '输入命令名称或快捷键…',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: (_) => setDialogState(() {}),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (_, i) {
                        final item = filtered[i];
                        return ListTile(
                          dense: true,
                          title: Text(item.label),
                          trailing: Text(
                            item.hint,
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                          onTap: () => Navigator.pop(dialog, item.run),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    if (!mounted || chosen == null) return;
    chosen();
  }

  Future<void> _checkProjectIssues() async {
    final issues = _validateNow(project);
    final outcome = await _issues(
      issues.isEmpty ? [const EditorIssue('没有发现结构问题。')] : issues,
      title: '作品检查',
    );
    if (outcome.goto != null) _gotoIssue(outcome.goto!);
  }

  void _stepStop(int delta) {
    if (_beatLength == 0) return;
    final stops = _stopIndexes();
    final candidates = delta < 0
        ? stops.where((s) => s < _command)
        : stops.where((s) => s > _command);
    _selectCommand(
      delta < 0
          ? candidates.lastOrNull ?? 0
          : candidates.firstOrNull ?? _beatLength - 1,
    );
  }

  void _stepCommand(int delta) =>
      _selectCommand(_command < 0 && delta > 0 ? 0 : _command + delta);

  void _togglePlay() {
    if (_beatLength == 0 || _busy) return;
    setState(() => _playing = !_playing);
  }

  void _onPlayhead(int index) => setState(() {
    if (index >= 0 && index < _beatLength) {
      _command = index;
    }
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
        'background' || 'image' || 'charslot' || 'character' => '画面',
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
      final warnings = {
        ...[
          for (final issue in _validateNow(current)) issue.message,
          ...stage.engine.warnings,
        ],
      };
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
                              onPressed: () => _issues([
                                for (final issue in issues) EditorIssue(issue),
                              ]),
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
    // 播放头快捷键的默认焦点。文本框聚焦时方向键/空格交还给文本编辑
    //（Action.isEnabled=false 时快捷键系统继续向上冒泡）；舞台聚焦时方向键让位微调。
    bool focusInTextField() {
      final focus = FocusManager.instance.primaryFocus;
      if (focus == null) return false;
      var found = false;
      focus.context?.visitAncestorElements((element) {
        final widget = element.widget;
        if (widget is EditableText ||
            widget is TextField ||
            widget is TextFormField) {
          found = true;
          return false;
        }
        return true;
      });
      return found;
    }

    bool stageFocused() =>
        FocusManager.instance.primaryFocus?.debugLabel == '剧情舞台';

    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.space):
            const _TogglePlayIntent(),
        const SingleActivator(LogicalKeyboardKey.arrowLeft):
            const _StepStopIntent(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight):
            const _StepStopIntent(1),
        const SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true):
            const _StepCommandIntent(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight, shift: true):
            const _StepCommandIntent(1),
        const SingleActivator(LogicalKeyboardKey.home): const _GotoIntent(true),
        const SingleActivator(LogicalKeyboardKey.end): const _GotoIntent(false),
        // P0-3：撤销/重做/剪贴板/副本/删除/全选/命令面板
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true):
            const _UndoIntent(),
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true):
            const _UndoIntent(),
        const SingleActivator(LogicalKeyboardKey.keyY, control: true):
            const _RedoIntent(),
        const SingleActivator(
          LogicalKeyboardKey.keyZ,
          control: true,
          shift: true,
        ): const _RedoIntent(),
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true):
            const _RedoIntent(),
        const SingleActivator(LogicalKeyboardKey.keyC, control: true):
            const _CopyCommandsIntent(),
        const SingleActivator(LogicalKeyboardKey.keyC, meta: true):
            const _CopyCommandsIntent(),
        const SingleActivator(LogicalKeyboardKey.keyX, control: true):
            const _CutCommandsIntent(),
        const SingleActivator(LogicalKeyboardKey.keyX, meta: true):
            const _CutCommandsIntent(),
        const SingleActivator(LogicalKeyboardKey.keyV, control: true):
            const _PasteCommandsIntent(),
        const SingleActivator(LogicalKeyboardKey.keyV, meta: true):
            const _PasteCommandsIntent(),
        const SingleActivator(LogicalKeyboardKey.keyD, control: true):
            const _DuplicateCommandsIntent(),
        const SingleActivator(LogicalKeyboardKey.keyD, meta: true):
            const _DuplicateCommandsIntent(),
        const SingleActivator(LogicalKeyboardKey.keyA, control: true):
            const _SelectAllCommandsIntent(),
        const SingleActivator(LogicalKeyboardKey.keyA, meta: true):
            const _SelectAllCommandsIntent(),
        const SingleActivator(LogicalKeyboardKey.delete):
            const _DeleteCommandsIntent(),
        const SingleActivator(LogicalKeyboardKey.keyK, control: true):
            const _CommandPaletteIntent(),
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
            const _CommandPaletteIntent(),
        // P1-4：导航历史 Alt+← / Alt+→
        const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true):
            const _NavHistoryIntent(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight, alt: true):
            const _NavHistoryIntent(1),
      },
      child: Actions(
        actions: {
          _TogglePlayIntent: _GuardedAction<_TogglePlayIntent>(
            blocked: () =>
                focusInTextField() || _workspace != _EditorWorkspace.stage,
            handler: (_) => _togglePlay(),
          ),
          _StepStopIntent: _GuardedAction<_StepStopIntent>(
            blocked: () =>
                focusInTextField() ||
                stageFocused() ||
                _workspace != _EditorWorkspace.stage,
            handler: (intent) => _stepStop(intent.delta),
          ),
          _StepCommandIntent: _GuardedAction<_StepCommandIntent>(
            blocked: () =>
                focusInTextField() ||
                stageFocused() ||
                _workspace != _EditorWorkspace.stage,
            handler: (intent) => _stepCommand(intent.delta),
          ),
          _GotoIntent: _GuardedAction<_GotoIntent>(
            blocked: () =>
                focusInTextField() || _workspace != _EditorWorkspace.stage,
            handler: (intent) => intent.toStart
                ? _selectCommand(0)
                : _selectCommand(_beatLength - 1),
          ),
          _UndoIntent: _GuardedAction<_UndoIntent>(
            blocked: focusInTextField,
            handler: (_) {
              if (!_busy && _undo.isNotEmpty) _history(redo: false);
              return null;
            },
          ),
          _RedoIntent: _GuardedAction<_RedoIntent>(
            blocked: focusInTextField,
            handler: (_) {
              if (!_busy && _redo.isNotEmpty) _history(redo: true);
              return null;
            },
          ),
          _CopyCommandsIntent: _GuardedAction<_CopyCommandsIntent>(
            blocked: () =>
                focusInTextField() || _workspace != _EditorWorkspace.stage,
            handler: (_) => _copySelectedCommands(),
          ),
          _CutCommandsIntent: _GuardedAction<_CutCommandsIntent>(
            blocked: () =>
                focusInTextField() || _workspace != _EditorWorkspace.stage,
            handler: (_) => _copySelectedCommands(cut: true),
          ),
          _PasteCommandsIntent: _GuardedAction<_PasteCommandsIntent>(
            blocked: () =>
                focusInTextField() || _workspace != _EditorWorkspace.stage,
            handler: (_) => _pasteClipboardCommands(),
          ),
          _DuplicateCommandsIntent: _GuardedAction<_DuplicateCommandsIntent>(
            blocked: () =>
                focusInTextField() || _workspace != _EditorWorkspace.stage,
            handler: (_) => _duplicateSelectedCommands(),
          ),
          _DeleteCommandsIntent: _GuardedAction<_DeleteCommandsIntent>(
            blocked: () =>
                focusInTextField() || _workspace != _EditorWorkspace.stage,
            handler: (_) => _deleteSelectedCommands(),
          ),
          _SelectAllCommandsIntent: _GuardedAction<_SelectAllCommandsIntent>(
            blocked: () =>
                focusInTextField() || _workspace != _EditorWorkspace.stage,
            handler: (_) => _selectAllCommands(),
          ),
          _CommandPaletteIntent: _GuardedAction<_CommandPaletteIntent>(
            blocked: () => _busy,
            handler: (_) => _openCommandPalette(),
          ),
          _NavHistoryIntent: _GuardedAction<_NavHistoryIntent>(
            blocked: focusInTextField,
            handler: (intent) => _stepNavHistory(intent.delta),
          ),
        },
        child: Focus(
          autofocus: true,
          skipTraversal: true,
          debugLabel: '编辑器快捷键',
          child: _editorBody(),
        ),
      ),
    );
  }

  Widget _editorBody() => LayoutBuilder(
    builder: (context, size) {
      final wide = size.maxWidth >= 1100;
      final landscape = !wide && size.maxWidth >= 580 && size.maxHeight < 530;
      final issues = _validationCache;
      final stage = EditorStage(
        key: _stageKey,
        project: project,
        scene: _scene,
        beat: _beat,
        selected: _command,
        resources: _resources,
        playing: _playing,
        loop: _loop,
        speed: _speed,
        onPlayhead: _onPlayhead,
        onPlaybackEnded: () => setState(() => _playing = false),
        onSelectCommand: _selectCommand,
        onInheritedDrag: _handleInheritedStageDrag,
        onMove: (index, values) {
          _change(
            _withCommands(
              [...beat.commands]
                ..[index] = beat.commands[index].withArgs(values),
            ),
            selected: index,
          );
        },
        onIssues: (messages, {title = '提示', allowExport = false}) => _issues(
          [for (final message in messages) EditorIssue(message)],
          title: title,
          allowExport: allowExport,
        ).then((outcome) => outcome.proceed),
      );
      final transport = _transportBar(compact: !wide && !landscape);
      final structureTree = EditorStructureTree(
        project: project,
        activeScene: _scene,
        activeBeat: _beat,
        issues: issues,
        onSelectBeat: (si, bi) => _navigateTo(
          si,
          bi,
          commandIndex: -1,
          workspace: _workspace == _EditorWorkspace.board
              ? _EditorWorkspace.stage
              : null,
        ),
        onSceneAction: _sceneActionAt,
        onBeatAction: _beatActionAt,
        onMarkScene: _markScene,
        onMarkBeat: _markBeat,
        onMoveBeat: _moveBeatTo,
        onOpenSearch: _openGlobalSearch,
      );

      Widget centerContent;
      if (_workspace == _EditorWorkspace.board) {
        final timeline = EditorTimeline.of(project, _scene);
        final playhead = timeline.columnOf(_beat, _command);
        final source = _timelineSource;
        final affected = source == null
            ? <BeatRef>{}
            : {
                for (
                  var sceneIndex = source.scene;
                  sceneIndex < project.scenes.length;
                  sceneIndex++
                )
                  for (final beatIndex in EditorTimeline.of(
                    project,
                    sceneIndex,
                  ).affectedBeats(source))
                    (scene: sceneIndex, beat: beatIndex),
              };
        final compact = !wide && !landscape;
        final board = EditorBoardView(
          project: project,
          activeScene: _scene,
          activeBeat: _beat,
          issues: issues,
          compact: !wide && !landscape,
          resources: _resources,
          affectedBeats: affected,
          onPreviewBeat: compact ? null : (si, bi) => _navigateTo(si, bi),
          onOpenBeat: (si, bi) =>
              _navigateTo(si, bi, workspace: _EditorWorkspace.stage),
          onAddBeat: _addBeatToScene,
          onInsertBeatAfter: (si, bi) => _beatActionAt(si, bi, 'add'),
          onDuplicateBeats: _duplicateBeats,
          onDeleteBeats: _deleteBeats,
          onMoveBeat: _moveBeatTo,
          onMarkBeat: _markBeat,
        );
        final lanes = EditorTimelineView(
          timeline: timeline,
          project: project,
          playhead: playhead,
          source: source,
          affectedCount: affected.length,
          missing: _timelineMissing,
          monitor: IgnorePointer(child: stage),
          materials: TimelineMaterialBox(
            key: ValueKey(project.id),
            project: project,
            resources: _resources,
            storage: widget.storage,
          ),
          inspector: source == null
              ? const SizedBox.shrink()
              : ListView(
                  padding: const EdgeInsets.all(8),
                  children: [_buildTimelineInspector(source)],
                ),
          onSeek: (address) => _seekTimeline(address),
          onSelectSource: (cursor, source) =>
              _seekTimeline(cursor, source: source),
          onOpen: _openTimelineAddress,
          onInsert: _insertTimelineCommands,
          onSplit: (address, command) {
            _insertTimelineCommands(address, [command]);
            setState(() => _timelineSource = address);
          },
          onTrim: _trimTimeline,
          onReplace: _replaceTimelineMedia,
          onFreeze: () => _insertTimelineCommands(
            timeline.insertAfter(playhead),
            timeline.freeze(playhead),
          ),
        );
        centerContent = compact || size.maxHeight < 350
            ? Column(
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      icon: Icon(
                        _compactTimeline
                            ? Icons.view_module_outlined
                            : Icons.view_timeline_outlined,
                      ),
                      label: Text(_compactTimeline ? '分镜卡片' : '可视化轨道'),
                      onPressed: () =>
                          setState(() => _compactTimeline = !_compactTimeline),
                    ),
                  ),
                  Expanded(child: _compactTimeline ? lanes : board),
                ],
              )
            : Column(
                children: [
                  Expanded(flex: 3, child: board),
                  const Divider(height: 1),
                  Expanded(flex: 2, child: lanes),
                ],
              );
      } else if (_workspace == _EditorWorkspace.script) {
        centerContent = EditorScriptView(
          key: _scriptKey,
          project: project,
          activeScene: _scene,
          compact: !wide && !landscape,
          formVersion: _formVersion,
          onEditRow: _editScriptRow,
          onBatchReplaceSpeaker: _batchReplaceScriptSpeaker,
          onJumpToRow: (row) => _navigateTo(
            row.sceneIndex,
            row.beatIndex,
            commandIndex: row.commandIndex,
            workspace: _EditorWorkspace.stage,
          ),
          onExportScript: _exportScriptFormat,
        );
      } else if (wide) {
        centerContent = Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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
                  transport,
                  _timelineInheritance(),
                  const Divider(height: 1),
                  Expanded(flex: 4, child: _commands(inlineInspector: false)),
                ],
              ),
            ),
            const VerticalDivider(width: 1),
            SizedBox(
              width: 300,
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [_buildInspectorWidget()],
              ),
            ),
          ],
        );
      } else if (landscape) {
        centerContent = Row(
          children: [
            Expanded(
              child: Column(
                children: [
                  Expanded(child: Center(child: stage)),
                  transport,
                  _timelineInheritance(),
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
        );
      } else {
        centerContent = ListView(
          children: [
            _sceneBar(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: stage,
            ),
            transport,
            _timelineInheritance(),
            _outline(vertical: false, showScene: false),
            const Divider(height: 1),
            _commandHeader(),
            if (_selectedCommands.length > 1) _batchBar(compact: true),
            // 窄屏指令同样支持拖动重排（P0-6）。
            ReorderableListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              onReorderItem: _reorderCommands,
              children: _commandRows(inlineInspector: true),
            ),
          ],
        );
      }
      final workspaceContent = _workspace == _EditorWorkspace.script
          ? Stack(
              fit: StackFit.expand,
              children: [
                centerContent,
                Offstage(offstage: true, child: stage),
              ],
            )
          : centerContent;

      return Column(
        children: [
          _toolbar(wide: wide, compact: !wide && !landscape),
          if (wide) _breadcrumbBar(),
          if (_busy)
            const LinearProgressIndicator(minHeight: 2)
          else
            const Divider(height: 2),
          Expanded(
            child: wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(width: 228, child: structureTree),
                      const VerticalDivider(width: 1),
                      Expanded(child: workspaceContent),
                    ],
                  )
                : workspaceContent,
          ),
        ],
      );
    },
  );

  /// 桌面端顶部面包屑（P1-4：作品 / 幕 / 分镜 / 指令 逐级可点 + Alt+←/→ 历史按钮）。
  Widget _breadcrumbBar() {
    final scheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.labelSmall;
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: '后退（Alt+←）',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
            iconSize: 16,
            onPressed: _navBack.isEmpty ? null : () => _stepNavHistory(-1),
            icon: const Icon(Icons.arrow_back),
          ),
          IconButton(
            tooltip: '前进（Alt+→）',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
            iconSize: 16,
            onPressed: _navForward.isEmpty ? null : () => _stepNavHistory(1),
            icon: const Icon(Icons.arrow_forward),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  InkWell(
                    onTap: () =>
                        setState(() => _workspace = _EditorWorkspace.board),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(project.title, style: style),
                    ),
                  ),
                  Text(' / ', style: style),
                  InkWell(
                    onTap: () => _navigateTo(
                      _scene,
                      0,
                      commandIndex: -1,
                      workspace: _EditorWorkspace.stage,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(scene.title, style: style),
                    ),
                  ),
                  Text(' / ', style: style),
                  InkWell(
                    onTap: () => _navigateTo(
                      _scene,
                      _beat,
                      commandIndex: -1,
                      workspace: _EditorWorkspace.stage,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(beat.title, style: style),
                    ),
                  ),
                  if (_command >= 0) ...[
                    Text(' / ', style: style),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(
                        '指令 ${_command + 1}',
                        style: style?.copyWith(
                          color: scheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          Text(
            '共 ${project.beatCount} 镜 · 约 ${formatEstimatedDuration(project.estimatedSeconds)}',
            style: style?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  /// 常驻传输条（P0-2 & §4.2）：宽屏单行；窄屏紧凑双行避免位置标签截断。
  Widget _transportBar({bool compact = false}) {
    final length = _beatLength;
    final disabled = _busy || length == 0;
    final stops = _stopIndexes();
    final stopAt = stops.where((s) => s <= _command).length;
    final position = _command < 0
        ? '分镜末态 · $length 条指令'
        : stops.isEmpty
        ? '指令 ${_command + 1} / $length'
        : '指令 ${_command + 1} / $length · 第 $stopAt / ${stops.length} 句';
    final firstBtn = IconButton(
      tooltip: '分镜开头（Home）',
      visualDensity: VisualDensity.compact,
      onPressed: disabled ? null : () => _selectCommand(0),
      icon: const Icon(Icons.first_page),
    );
    final prevBtn = IconButton(
      tooltip: '上一句（←）',
      visualDensity: VisualDensity.compact,
      onPressed: disabled ? null : () => _stepStop(-1),
      icon: const Icon(Icons.skip_previous),
    );
    final playBtn = IconButton(
      tooltip: _playing ? '暂停（空格）' : '播放（空格）',
      visualDensity: VisualDensity.compact,
      onPressed: disabled ? null : _togglePlay,
      icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
    );
    final nextBtn = IconButton(
      tooltip: '下一句（→）',
      visualDensity: VisualDensity.compact,
      onPressed: disabled ? null : () => _stepStop(1),
      icon: const Icon(Icons.skip_next),
    );
    final endBtn = IconButton(
      tooltip: '分镜末态（End）',
      visualDensity: VisualDensity.compact,
      onPressed: disabled ? null : () => _selectCommand(length - 1),
      icon: const Icon(Icons.last_page),
    );
    final loopBtn = IconButton(
      tooltip: '循环本段',
      visualDensity: VisualDensity.compact,
      isSelected: _loop,
      onPressed: () => setState(() => _loop = !_loop),
      icon: const Icon(Icons.repeat),
    );
    final speedBtn = OutlinedButton(
      onPressed: disabled
          ? null
          : () => setState(
              () => _speed = _speed == 1
                  ? 2
                  : _speed == 2
                  ? 4
                  : 1,
            ),
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        minimumSize: const Size(40, 32),
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
      child: Text('$_speed×'),
    );
    final fullBtn = IconButton(
      tooltip: '全屏试播（含音频，从当前分镜开始）',
      visualDensity: VisualDensity.compact,
      onPressed: _busy ? null : () => _preview(_PreviewMode.fromBeat),
      icon: const Icon(Icons.fullscreen),
    );
    if (compact) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(8, 2, 8, 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                firstBtn,
                prevBtn,
                playBtn,
                nextBtn,
                endBtn,
                const Spacer(),
                loopBtn,
                speedBtn,
                fullBtn,
              ],
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      position,
                      style: Theme.of(context).textTheme.labelSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (_command >= 0)
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        minimumSize: const Size(0, 26),
                      ),
                      onPressed: _openMobileInspectorSheet,
                      icon: const Icon(Icons.tune, size: 15),
                      label: const Text('属性抽屉'),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          const SizedBox(width: 8),
          firstBtn,
          prevBtn,
          playBtn,
          nextBtn,
          endBtn,
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                position,
                style: Theme.of(context).textTheme.labelSmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          loopBtn,
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: speedBtn,
          ),
          fullBtn,
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  /// 移动端底部检查器抽屉（§4.2：peek / half / full 可拖拽抽屉）。
  Future<void> _openMobileInspectorSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.55,
        minChildSize: 0.3,
        maxChildSize: 0.92,
        builder: (_, scrollController) => Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 16),
          child: Column(
            children: [
              Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Expanded(
                child: ListView(
                  controller: scrollController,
                  children: [_buildInspectorWidget()],
                ),
              ),
            ],
          ),
        ),
      ),
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

  Widget _toolbar({required bool wide, required bool compact}) {
    final scheme = Theme.of(context).colorScheme;
    Widget tabButton(
      _EditorWorkspace target,
      String label,
      IconData icon, {
      bool compactTab = false,
    }) {
      final active = _workspace == target;
      return InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => _selectWorkspace(target),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: compactTab ? 7 : 10,
            vertical: compactTab ? 5 : 6,
          ),
          decoration: BoxDecoration(
            color: active
                ? scheme.primaryContainer.withValues(alpha: .7)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: active ? scheme.primary : scheme.outlineVariant,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: compactTab ? 14 : 15,
                color: active ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 3),
              Text(
                label,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: active ? scheme.primary : scheme.onSurface,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Row(
      children: [
        if (_failedSave != null)
          IconButton(
            tooltip: '保存失败，点击重试',
            onPressed: _retrySave,
            icon: const Icon(Icons.error_outline, color: Colors.red),
          ),
        IconButton(
          tooltip: '本地作品',
          visualDensity: compact
              ? VisualDensity.compact
              : VisualDensity.standard,
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
        if (wide) ...[
          tabButton(
            _EditorWorkspace.stage,
            '演出台',
            Icons.movie_creation_outlined,
          ),
          const SizedBox(width: 6),
          tabButton(_EditorWorkspace.board, '编排台', Icons.grid_view_outlined),
          const SizedBox(width: 6),
          tabButton(_EditorWorkspace.script, '剧本台', Icons.table_rows_outlined),
          const SizedBox(width: 10),
          IconButton(
            tooltip: '全局搜索',
            onPressed: _busy ? null : _openGlobalSearch,
            icon: const Icon(Icons.search),
          ),
          IconButton(
            tooltip: '命令面板（Ctrl+K）',
            onPressed: _busy ? null : _openCommandPalette,
            icon: const Icon(Icons.bolt),
          ),
        ] else ...[
          // §4.2 移动端轻量化：仅保留演出台与分镜切换，不上桌面式剧本表格。
          tabButton(
            _EditorWorkspace.stage,
            compact ? '演出' : '演出台',
            Icons.movie_creation_outlined,
            compactTab: compact,
          ),
          const SizedBox(width: 4),
          tabButton(
            _EditorWorkspace.board,
            compact ? '分镜' : '分镜切换',
            Icons.view_carousel_outlined,
            compactTab: compact,
          ),
          if (!compact) ...[
            const SizedBox(width: 4),
            tabButton(
              _EditorWorkspace.script,
              '剧本台',
              Icons.table_rows_outlined,
            ),
          ],
          IconButton(
            tooltip: '全局搜索',
            visualDensity: VisualDensity.compact,
            padding: compact ? EdgeInsets.zero : null,
            constraints: compact
                ? const BoxConstraints(minWidth: 32, minHeight: 32)
                : null,
            onPressed: _busy ? null : _openGlobalSearch,
            icon: const Icon(Icons.search, size: 19),
          ),
        ],
        IconButton(
          tooltip: '撤销',
          visualDensity: compact
              ? VisualDensity.compact
              : VisualDensity.standard,
          padding: compact ? EdgeInsets.zero : null,
          constraints: compact
              ? const BoxConstraints(minWidth: 32, minHeight: 32)
              : null,
          onPressed: _busy || _undo.isEmpty
              ? null
              : () => _history(redo: false),
          icon: const Icon(Icons.undo),
        ),
        IconButton(
          tooltip: '重做',
          visualDensity: compact
              ? VisualDensity.compact
              : VisualDensity.standard,
          padding: compact ? EdgeInsets.zero : null,
          constraints: compact
              ? const BoxConstraints(minWidth: 32, minHeight: 32)
              : null,
          onPressed: _busy || _redo.isEmpty ? null : () => _history(redo: true),
          icon: const Icon(Icons.redo),
        ),
        PopupMenuButton<_PreviewMode>(
          tooltip: '全屏试播',
          enabled: !_busy,
          icon: const Icon(Icons.play_arrow),
          onSelected: _preview,
          itemBuilder: (_) => const [
            ArchivePopupMenuItem(
              value: _PreviewMode.beat,
              child: Text('全屏：仅当前分镜'),
            ),
            ArchivePopupMenuItem(
              value: _PreviewMode.fromBeat,
              child: Text('全屏：从当前分镜开始'),
            ),
            ArchivePopupMenuItem(
              value: _PreviewMode.full,
              child: Text('全屏：从头播放'),
            ),
          ],
        ),
        PopupMenuButton<String>(
          tooltip: '作品操作',
          enabled: !_busy,
          onSelected: (action) async {
            switch (action) {
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
              case 'export_txt':
                await _exportScriptFormat('txt');
              case 'export_csv':
                await _exportScriptFormat('csv');
              case 'export_srt':
                await _exportScriptFormat('srt');
              case 'delete':
                await _deleteProject();
              case 'check':
                final issues = _validateNow(project);
                await _issues(
                  issues.isEmpty ? [const EditorIssue('没有发现结构问题。')] : issues,
                  title: '作品检查',
                ).then((outcome) {
                  if (outcome.goto != null) _gotoIssue(outcome.goto!);
                });
            }
          },
          itemBuilder: (_) => [
            ArchivePopupMenuItem(
              value: 'play',
              enabled: widget.onPlayProject != null,
              child: const Text('播放作品'),
            ),
            const ArchivePopupMenuItem(value: 'assets', child: Text('作品素材管理')),
            const ArchivePopupMenuItem(
              value: 'export',
              child: Text('导出作品（含上传素材）'),
            ),
            const ArchivePopupMenuItem(value: 'script', child: Text('导出纯脚本')),
            const ArchivePopupMenuItem(
              value: 'export_txt',
              child: Text('导出台本 TXT'),
            ),
            const ArchivePopupMenuItem(
              value: 'export_csv',
              child: Text('导出台本 CSV'),
            ),
            const ArchivePopupMenuItem(
              value: 'export_srt',
              child: Text('导出字幕 SRT'),
            ),
            const ArchivePopupMenuItem(value: 'duplicate', child: Text('复制作品')),
            const ArchivePopupMenuItem(value: 'check', child: Text('检查作品')),
            const ArchivePopupMenuItem(value: 'delete', child: Text('删除作品')),
          ],
        ),
      ],
    );
  }

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
          const ArchivePopupMenuItem(value: 'add', child: Text('新建幕')),
          const ArchivePopupMenuItem(value: 'rename', child: Text('重命名幕')),
          ..._reorderMenu(_scene, project.scenes.length),
          ArchivePopupMenuItem(
            value: 'delete',
            enabled: project.scenes.length > 1,
            child: const Text('删除幕'),
          ),
        ],
      ),
    ],
  );

  List<PopupMenuEntry<String>> _reorderMenu(int index, int count) => [
    ArchivePopupMenuItem(
      value: 'up',
      enabled: index > 0,
      child: const Text('向前移动'),
    ),
    ArchivePopupMenuItem(
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

  Widget _commandHeader() {
    final multiCount = _selectedCommands.length;
    final hasClip = _sharedCommandClipboard.isNotEmpty;
    return Row(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    beat.title,
                    style: Theme.of(context).textTheme.titleSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    multiCount > 1 ? '已选 $multiCount 条' : 'Shift 连选 · Ctrl 增减',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: multiCount > 1
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (hasClip)
          IconButton(
            tooltip: '粘贴剪贴板（${_sharedCommandClipboard.length} 条，Ctrl+V）',
            visualDensity: VisualDensity.compact,
            onPressed: _pasteClipboardCommands,
            icon: const Icon(Icons.content_paste, size: 18),
          ),
        PopupMenuButton<String>(
          tooltip: '选择与批量',
          icon: const Icon(Icons.checklist, size: 20),
          onSelected: (action) {
            switch (action) {
              case 'all':
                _selectAllCommands();
              case 'invert':
                _invertCommandSelection();
              case 'copy':
                _copySelectedCommands();
              case 'paste':
                _pasteClipboardCommands();
              case 'clear':
                _clearMultiSelection();
            }
          },
          itemBuilder: (_) => [
            ArchivePopupMenuItem(
              value: 'all',
              enabled: beat.commands.isNotEmpty,
              child: const Text('全选指令（Ctrl+A）'),
            ),
            ArchivePopupMenuItem(
              value: 'invert',
              enabled: beat.commands.isNotEmpty,
              child: const Text('反选指令'),
            ),
            ArchivePopupMenuItem(
              value: 'copy',
              enabled: _selectedCommands.isNotEmpty || _command >= 0,
              child: const Text('复制所选（Ctrl+C）'),
            ),
            ArchivePopupMenuItem(
              value: 'paste',
              enabled: _sharedCommandClipboard.isNotEmpty,
              child: Text('粘贴到播放头后（${_sharedCommandClipboard.length}）'),
            ),
            if (_selectedCommands.length > 1)
              const ArchivePopupMenuItem(value: 'clear', child: Text('取消多选')),
          ],
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
            const ArchivePopupMenuItem(value: 'rename', child: Text('重命名分镜')),
            const ArchivePopupMenuItem(value: 'duplicate', child: Text('复制分镜')),
            const ArchivePopupMenuItem(value: 'mark', child: Text('标记与备注')),
            ..._reorderMenu(_beat, scene.beats.length),
            ArchivePopupMenuItem(
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
  }

  /// P0-3 多选批量操作条（桌面端含批量改说话人；移动端仅轻量复制/删除/取消）。
  Widget _batchBar({bool compact = false}) {
    final scheme = Theme.of(context).colorScheme;
    final count = _selectedCommands.length;
    return Container(
      key: const ValueKey('editor-batch-bar'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: .35),
        border: Border(
          top: BorderSide(color: scheme.primary.withValues(alpha: .4)),
          bottom: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            '已选 $count 条',
            style: Theme.of(context).textTheme.labelMedium
                ?.copyWith(color: scheme.primary, fontWeight: FontWeight.w600),
          ),
          if (!compact) ...[
            SizedBox(
              width: 150,
              child: TextField(
                key: const ValueKey('batch-speaker-input'),
                controller: _batchSpeakerController,
                decoration: const InputDecoration(
                  hintText: '批量修改说话人…',
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (v) => _applyBatchSpeaker(v),
              ),
            ),
            FilledButton.tonal(
              onPressed: () => _applyBatchSpeaker(_batchSpeakerController.text),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
              child: const Text('应用'),
            ),
          ],
          OutlinedButton.icon(
            onPressed: _copySelectedCommands,
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
            ),
            icon: const Icon(Icons.copy, size: 15),
            label: const Text('复制'),
          ),
          OutlinedButton.icon(
            onPressed: _duplicateSelectedCommands,
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
            ),
            icon: const Icon(Icons.copy_all, size: 15),
            label: const Text('创建副本'),
          ),
          OutlinedButton.icon(
            onPressed: _deleteSelectedCommands,
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              foregroundColor: scheme.error,
            ),
            icon: const Icon(Icons.delete_outline, size: 15),
            label: const Text('删除'),
          ),
          TextButton(
            onPressed: _clearMultiSelection,
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            child: const Text('取消选择'),
          ),
        ],
      ),
    );
  }

  void _reorderCommands(int oldIndex, int newIndex) {
    // material_ui 的 onReorderItem 已按「移除旧项后的位置」调整 newIndex，
    // 直接按新位置插入即可。
    final commands = [...beat.commands];
    final moved = commands.removeAt(oldIndex);
    commands.insert(newIndex.clamp(0, commands.length), moved);
    _change(
      _withCommands(commands),
      selected: newIndex.clamp(0, commands.length - 1),
    );
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
      'character' =>
        '立绘：${value('name')}${value('name2').isEmpty ? '' : ' / ${value('name2')}'}',
      'playmusic' => '播放音乐：${value('key')}',
      'playsound' => '播放音效：${value('key')}',
      'delay' =>
        '等待：${value('time').isEmpty ? value('duration') : value('time')} 秒',
      'bgeffect' || 'effect' => '特效：${value('name')}',
      _ => entry.tag,
    };
  }

  Widget _commands({required bool inlineInspector}) => Column(
    children: [
      _commandHeader(),
      if (_selectedCommands.length > 1) _batchBar(compact: inlineInspector),
      Expanded(
        // 窄屏与宽屏统一支持拖动重排（P0-6 窄屏拖动修复）。
        child: ReorderableListView(
          buildDefaultDragHandles: false,
          onReorderItem: _reorderCommands,
          children: _commandRows(inlineInspector: inlineInspector),
        ),
      ),
    ],
  );

  Future<void> _showCommandContextMenu(int index, Offset globalPosition) async {
    if (!_selectedCommands.contains(index)) {
      _selectCommand(index);
    }
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        globalPosition.dx + 1,
        globalPosition.dy + 1,
      ),
      items: [
        const ArchivePopupMenuItem(value: 'copy', child: Text('复制（Ctrl+C）')),
        const ArchivePopupMenuItem(value: 'cut', child: Text('剪切（Ctrl+X）')),
        ArchivePopupMenuItem(
          value: 'paste',
          enabled: _sharedCommandClipboard.isNotEmpty,
          child: const Text('粘贴到此处后（Ctrl+V）'),
        ),
        const ArchivePopupMenuItem(
          value: 'duplicate',
          child: Text('创建副本（Ctrl+D）'),
        ),
        const ArchivePopupMenuItem(value: 'insert', child: Text('在此之后插入指令')),
        const ArchivePopupMenuItem(
          value: 'toggle_multi',
          child: Text('加入/移出多选'),
        ),
        const PopupMenuDivider(),
        const ArchivePopupMenuItem(value: 'delete', child: Text('删除（Delete）')),
      ],
    );
    if (action == null) return;
    switch (action) {
      case 'copy':
        _copySelectedCommands();
      case 'cut':
        _copySelectedCommands(cut: true);
      case 'paste':
        _pasteClipboardCommands();
      case 'duplicate':
        _duplicateSelectedCommands();
      case 'insert':
        await _showCommandChooser(insertAt: index + 1);
      case 'toggle_multi':
        _toggleMultiCommand(index);
      case 'delete':
        _deleteSelectedCommands();
    }
  }

  /// 窄屏指令行与内联检查器合并为单个可重排 item，
  /// 避免检查器成为独立拖动单位导致索引错位。
  List<Widget> _commandRows({required bool inlineInspector}) {
    final scheme = Theme.of(context).colorScheme;
    final multiMode = _selectedCommands.length > 1;
    return [
      if (beat.commands.isEmpty)
        const ListTile(
          key: ValueKey('empty-command'),
          title: Text('暂无演出指令'),
          leading: Icon(Icons.movie_outlined),
        ),
      for (final (i, entry) in beat.commands.indexed)
        Column(
          // 行身份按位置而非指令对象标识：每次输入都会创建新的指令对象，
          // 用 ObjectKey(entry) 会让内联检查器随整行被替换，输入一次即丢焦点。
          key: ValueKey('command-$i'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GestureDetector(
              onSecondaryTapDown: (d) =>
                  _showCommandContextMenu(i, d.globalPosition),
              child: Material(
                color: _selectedCommands.contains(i) && i != _command
                    ? scheme.primaryContainer.withValues(alpha: .28)
                    : Colors.transparent,
                child: ListTile(
                  dense: true,
                  selected: i == _command,
                  leading: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (multiMode)
                        Checkbox(
                          visualDensity: VisualDensity.compact,
                          value: _selectedCommands.contains(i),
                          onChanged: (_) => _toggleMultiCommand(i),
                        ),
                      ReorderableDragStartListener(
                        index: i,
                        child: Icon(
                          Icons.drag_handle,
                          color: scheme.onSurfaceVariant.withValues(alpha: .55),
                        ),
                      ),
                    ],
                  ),
                  title: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onLongPress: () => _toggleMultiCommand(i),
                    child: Text(editorFields[entry.tag]?.$1 ?? '原始指令'),
                  ),
                  subtitle: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onLongPress: () => _toggleMultiCommand(i),
                    child: Text(
                      entry.raw ?? _commandSummary(entry),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  onTap: () => _onTapCommandRow(i),
                  trailing: PopupMenuButton<String>(
                    tooltip: '指令操作 ${i + 1}',
                    onSelected: (action) => _commandAction(i, action),
                    itemBuilder: (_) => [
                      const ArchivePopupMenuItem(
                        value: 'duplicate',
                        child: Text('复制指令'),
                      ),
                      const ArchivePopupMenuItem(
                        value: 'insert',
                        child: Text('在此之后插入'),
                      ),
                      ..._reorderMenu(i, beat.commands.length),
                      const ArchivePopupMenuItem(
                        value: 'delete',
                        child: Text('删除指令'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (inlineInspector && i == _command)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: _buildInspectorWidget(),
              ),
          ],
        ),
    ];
  }

  Widget _buildInspectorWidget() {
    return EditorInspector(
      project: project,
      commands: beat.commands,
      activeIndex: _command,
      selectedIndices: _selectedCommands,
      formVersion: _formVersion,
      onUpdateCommand: (values, {String? typing}) =>
          _updateCommand(values, typing: typing),
      onUpdateMany: (indices, values) => _updateManyCommands(indices, values),
      onReplaceSource: (updated) {
        if (_command < 0 || _command >= beat.commands.length) return;
        final next = [...beat.commands];
        next[_command] = updated;
        _change(_withCommands(next), selected: _command, typing: 'source');
      },
      onPickMedia: _pick,
      onFocusTypingEnd: (fieldKey) {
        if (_typing == fieldKey) _typing = null;
      },
      onResetCommand: _resetCurrentCommand,
    );
  }
}
