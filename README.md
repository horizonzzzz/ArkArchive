# 明日方舟剧情播放器

Flutter 剧情播放器原型。首页从 PRTS 的剧情索引列出全部剧情节点，选中后加载对应脚本和素材播放；应用不内置关卡地址。

## 运行

```sh
flutter pub get
flutter run -d chrome
```

剧情目录、脚本和游戏素材从 PRTS 静态数据站按需加载。对白字体（`assets/fonts/NotoSansHans-Medium.ttf`）和滑动遮罩纹理已随应用打包，运行时不联网获取。加载剧情需要网络，用户应只使用有权访问的剧情和资源。

## 产品界面与占位边界

界面参考 [交互原型](docs/prototype.html) 和 [设计规范](docs/DESIGN.md)，采用 ak-ui `system` 设计语言，用 Flutter 原生组件实现。窗口宽度达到 1100 时展示固定侧栏和篇章／关卡双栏；窄屏使用底部三项导航和篇章折叠列表。UI 字体复用已打包的 Noto Sans，不新增网络字体或依赖。

- **剧情馆**：保留 PRTS 真实索引、分类搜索和原有播放链路，增加篇章层级、多选及播放准备浮层。分类使用索引的 `entryType`，未识别条目保留在“其他档案”；当前索引未覆盖的玩法衍生篇展示待接入空态。
- **离线与缓存**：展示多选清单、缓存页签、存储统计占位和清理确认流程。缓存、删除、目录迁移按钮只反馈未接入提示，不创建任务、不读写缓存文件；离线状态和容量均不伪造。
- **系统设置**：音量、播放偏好、下载策略和离线开关只更新本次界面预览状态，切换 Tab 后保留，重启后恢复初值；不影响播放器、网络请求、文件存储或系统屏幕方向。网络状态显示“未检测”。

此次不新增缓存、下载调度、音量控制或网络诊断能力。原有播放器和 `AssetStore` 的按需资源加载／缓存行为保持原样，不受预览开关控制。

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

目录页可以调用 `StoryRepository.loadIndex()` 取到按章节分组的 `StoryGroup` 列表，再交给 `loadEntry(entry)` 下载脚本；也可以自行创建 `StoryDocument` 后交给 `prepare()`。`prepare()` 只准备该剧情需要的图片和音频，字体与遮罩不参与下载。播放器核心通过 `StoryEngine` 执行解析后的命令；`StoryPlayer` 负责舞台和交互。资源缓存随 `AssetStore` 所有者管理，应用退出时调用 `assets.close()`。

演出依据、模块边界和未支持效果见 [docs/player_alignment.md](docs/player_alignment.md)。

## 验证与构建

```sh
flutter analyze
flutter test --reporter expanded
flutter build web --release --no-web-resources-cdn
```

Web 构建输出在 `build/web/`，需要通过 HTTP 服务访问。`--no-web-resources-cdn` 将 Flutter 渲染器资源放入构建目录；剧情目录、脚本和游戏素材仍按需联网获取。打包的字体与遮罩同时供原生端和 Web 使用，Web 不再受这两个资源的跨域限制。

`test/reference_live_test.dart` 默认跳过联网。复核真实剧情时，给 `flutter test test/reference_live_test.dart` 传入 `--dart-define=STORY_REFERENCE_URL=<剧情页或原始脚本URL>`；该测试会下载静态依赖并解码图片，需要网络连接。
