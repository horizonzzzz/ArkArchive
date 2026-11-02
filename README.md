# 明日方舟剧情播放器

Flutter 剧情播放器原型。主界面接受 PRTS 剧情页、原始 `.txt` 剧本 URL 或直接粘贴的剧情 DSL；应用没有内置关卡链接。

## 运行

```sh
flutter pub get
flutter run -d chrome
```

剧情和资源从配置的数据源按需加载。Web 版受上游 CORS 策略限制；字体和游戏素材不会打包进应用。加载需要网络，用户应只使用有权访问的剧情和资源。

## 复用播放器

播放器不依赖应用入口或关卡目录。外部页面先准备 `PreparedStory`，再将其传入 `StoryPlayer`：

```dart
import 'package:arknights_story_player/story_player/story_player.dart';

final assets = AssetStore();
final repository = StoryRepository(assets);
final document = await repository.load(Uri.parse(storyUrl));
final prepared = await repository.prepare(document);

Navigator.of(context).push(MaterialPageRoute<void>(
  builder: (_) => StoryPlayer(story: prepared),
));
```

目录页可以调用 `StoryRepository.loadIndex()`，或自行创建 `StoryDocument` 后交给 `prepare()`。播放器核心通过 `StoryEngine` 执行解析后的命令；`StoryPlayer` 负责舞台和交互。资源缓存随 `AssetStore` 所有者管理，应用退出时调用 `assets.close()`。

演出依据、模块边界和未支持效果见 [docs/player_alignment.md](docs/player_alignment.md)。

## 验证与构建

```sh
flutter analyze
flutter test --reporter expanded
flutter build web --release --no-web-resources-cdn
```

Web 构建输出在 `build/web/`，需要通过 HTTP 服务访问。`--no-web-resources-cdn` 将 Flutter 渲染器资源放入构建目录；剧情和游戏素材仍按需联网获取。PRTS 的字体和滑动遮罩纹理当前受 CORS 限制，Web 会记录诊断并使用回退效果。

`test/reference_live_test.dart` 默认跳过联网。复核真实剧情时，给 `flutter test test/reference_live_test.dart` 传入 `--dart-define=STORY_REFERENCE_URL=<剧情页或原始脚本URL>`；该测试会下载静态依赖并解码图片，需要网络连接。
