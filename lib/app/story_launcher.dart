import 'package:flutter/material.dart';
import '../story_player/story_player.dart';

class StoryLauncher extends StatefulWidget {
  const StoryLauncher({super.key});
  @override
  State<StoryLauncher> createState() => _StoryLauncherState();
}

class _StoryLauncherState extends State<StoryLauncher> {
  final _input = TextEditingController();
  late final AssetStore _assets = AssetStore();
  late final StoryRepository _repository = StoryRepository(_assets);
  bool _busy = false;
  String? _error;
  int _done = 0, _total = 0;

  Future<void> _open() async {
    final source = _input.text.trim();
    if (source.isEmpty || _busy) return;
    setState(() { _busy = true; _error = null; _done = 0; _total = 0; });
    try {
      StoryDocument document;
      if (source.startsWith('[')) {
        document = StoryDocument(title: '导入剧情', script: StoryScript.parse(source));
      } else {
        final uri = Uri.tryParse(source);
        if (uri == null || !['https', 'http'].contains(uri.scheme)) throw const FormatException('请输入 HTTP(S) 剧情页或原始脚本地址，也可以直接粘贴 DSL');
        document = await _repository.load(uri);
      }
      if (!document.script.commands.any((c) => c.tag == 'dialogue' || c.text.isNotEmpty)) throw const FormatException('脚本中没有可播放内容');
      final prepared = await _repository.prepare(document, onProgress: (done, total) { if (mounted) setState(() { _done = done; _total = total; }); });
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => StoryPlayer(story: prepared)));
    } catch (e) {
      if (mounted) setState(() => _error = '加载失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('明日方舟剧情播放器')), body: SafeArea(child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text('打开剧情', style: Theme.of(context).textTheme.headlineMedium),
    const SizedBox(height: 12),
    const Text('输入 PRTS 剧情页或原始 .txt 的 HTTP(S) 地址，也可以直接粘贴剧情脚本。播放器会先获取当前剧情需要的背景、立绘、字体和音频。'),
    const SizedBox(height: 24),
    TextField(key: const Key('story-source'), controller: _input, enabled: !_busy, minLines: 3, maxLines: 10, decoration: const InputDecoration(labelText: '剧情地址或 DSL 脚本', border: OutlineInputBorder())),
    const SizedBox(height: 16),
    FilledButton.icon(onPressed: _busy ? null : _open, icon: const Icon(Icons.play_arrow), label: Text(_busy ? '加载中…' : '加载全部资源并打开')),
    if (_busy) ...[const SizedBox(height: 16), LinearProgressIndicator(value: _total == 0 ? null : _done / _total), const SizedBox(height: 8), Text(_total == 0 ? '正在读取脚本与资源配置…' : '已处理 $_done / $_total 个资源')],
    if (_error != null) Padding(padding: const EdgeInsets.only(top: 16), child: SelectableText(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
    const SizedBox(height: 24),
    const Text('Android / iOS 会将已下载资源保存在应用目录。Web 版只提供内存缓存，跨域访问受上游服务器限制。', style: TextStyle(color: Colors.white60)),
  ]))))));

  @override
  void dispose() { _input.dispose(); _assets.close(); super.dispose(); }
}
