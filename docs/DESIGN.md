# 《明日方舟》视觉设计与交互工程规范 (Arknights Design System Spec)

> **定位**：本文档沉淀了《明日方舟》（Arknights / Rhodes Island OS）经典战术终端与剧情播放器的完整视觉风格、交互准则与 Flutter / Web 落地工程规范。
> **参考依据**：
> - 社区成熟开源设计系统：PRTS 官方维基设计系统 [`@mooncellwiki/prts-design`](https://github.com/MooncellWiki/prts-design)、[`ak-ui`](https://ak-ui.yyj.moe/)、[`hikari`](https://github.com/celestia-island/hikari)
> - 游戏学术/UX深度分析：《“舟味”从何而来？解析明日方舟设计美学》（腾讯游戏学堂 & 行业 UI 拆解）
> - 官方解包与排版度量规范

---

## 1. 核心设计哲学与风格基石（The "Ark" Aesthetics）

业界常称的**“舟味”**，本质是**后现代战术机能风（Tactical / Industrial FUI）与极简瑞士平面排版（Swiss Style / Flat Design）的高度融合**：

1. **黑白为体、青为用 (Dark Terminal First)**：
   - 全局界面以大面积灰黑、哑光碳黑与高对比冷灰打底；
   - **罗德岛青（Cyan `#00E5FF`）** 作为唯一的系统最高级别聚焦色、超链接与主执行动作（Primary Action）；
   - **预警黄（Hazard Yellow `#FFD600` / `#F6C344`）** 作为战术警示、次强调标签与重要侧边提示；
   - **危险红（Danger Red `#FF5252`）** 极为克制，仅在破坏性删除、阻断警告与严重报错时出现。
2. **硬朗几何与克制圆角 (Restrained Geometry)**：
   - 拒绝大圆角与软绵绵的气泡质感；
   - 按钮、卡片、标签统一使用 **0~2px 直角/微倒角**，或 **45度切角（Bevel Clip / `polygon`）**；
   - 装饰语言：警示色条、45° 斜向安全警戒斑马线（Warning Stripes）、网点（Halftone Dots）、直角线框与小十字瞄准线（Crosshairs）。
3. **高密度信息层级与排版秩序 (Typographic Hierarchy)**：
   - 中文采用高质量无衬线屏显字体（思源黑体 / Noto Sans Hans SC），小字号配合高可读字间距；
   - 英文与数字强制使用**高机械感等宽或工业大写无衬线**（Oswald, DIN, Chakra Petch, Roboto Mono）；
   - 主标题普遍带有伴生的小号大写英文副标（如 `慈悲灯塔 / EPISODE 14`），强化战术终端的档案归档感。
4. **质感与光影 (Tactical Light & Depth)**：
   - 放弃廉价的高斯辉光，改用 **1px 微透明硬边界边框（`rgba(255,255,255,0.08)`）**；
   - 背景层使用深度视差（Parallax）与局部的暗色遮罩模糊（`backdrop-filter: blur(12px)`），强化“战术面板悬浮于战场舞台之上”的层级深度。

---

## 2. 设计令牌定义 (Design Tokens)

### 2.1 色彩令牌 (Color Tokens)

```scss
// 主体终端背景色板 (Dark Surfaces)
--ak-bg-root:         #0a0d12; // 终端最深底色
--ak-bg-primary:      #12161f; // 核心工作区与主窗口底色
--ak-bg-secondary:    #181d26; // 侧边栏、卡片背景色
--ak-bg-surface:      #1f2633; // 关卡列表行、条目卡片未激活态
--ak-bg-hover:        #283242; // 条目悬停色
--ak-bg-tertiary:     #2a3444; // 进度条底色、搜索框输入底色

// 语义强调与战术色彩 (Semantic Signals)
--ak-cyan:            #00e5ff; // 罗德岛科技青 (主执行/已选高亮/活动链接)
--ak-cyan-dark:       #0097a7; // 青色按压态 / 激活边框
--ak-cyan-glow:       rgba(0, 229, 255, 0.25); // 选中行泛光
--ak-cyan-bg:         rgba(0, 229, 255, 0.12); // 青色半透明标签底色

--ak-yellow:          #f6c344; // 警示黄 / 支线活动金 / 稀有度次高
--ak-yellow-bg:       rgba(246, 195, 68, 0.12);

--ak-green:           #00e676; // 已缓存离线 / 校验通过 (Emerald Green)
--ak-green-bg:        rgba(0, 230, 118, 0.15);

--ak-red:             #ff5252; // 警告红 / 清空缓存 / 致命错误 (Signal Red)
--ak-red-bg:          rgba(255, 82, 82, 0.12);

// 文本与排版对比阶梯 (Typography Text Colors)
--ak-text-primary:    #ffffff; // 关卡主标题、剧情正文
--ak-text-secondary:  #a2b0c2; // 关卡副标、副标题、大纲描述
--ak-text-muted:      #64748b; // 纯英文代码、无版权标注、未激活占位符
--ak-border-base:     #2b3545; // 界面标准 1px 分隔线
--ak-border-subtle:   rgba(255, 255, 255, 0.06);
```

### 2.2 几何与网格系统 (Geometry & Spacing)

- **圆角规则**：
  - 核心原则：**极小圆角或纯直角（Sharp Edges）**。
  - 普通按钮/输入框：`border-radius: 2px ~ 4px`；
  - 弹层浮板/主窗口外框：`border-radius: 6px`（最大不超过 8px）；
  - 关卡代号角标（Badge）：`border-radius: 0px`（纯直角），左侧或顶部附带 2px 细色标。
- **排版字体栈**：
  - 中文主文本：`"Noto Sans SC", "PingFang SC", "Microsoft YaHei", sans-serif`
  - 战术代号、数字、仪表：`"Chakra Petch", "DIN Alternate", "Roboto Mono", monospace`

---

## 3. 典型交互组件规范 (Component Specifications)

### 3.1 战术关卡条目卡片 (Stage Item Card)
- **静态形态**：高度 52px~56px，深灰底色，左侧为亮青色等宽字体的关卡代号（如 `14-1 BEF`），中间展示关卡标题与出场人物，右侧固定展示离线状态徽标与圆形极简播放入口。
- **状态徽标（Status Badge）**：
  - `已离线`：青绿微透明胶囊（`#00e676`），前置 `✓` 符号；
  - `未缓存`：暗灰幽灵标签（Ghost Tag），不显示虚假预估大小；
  - `缓存中`：青色旋转雷达环（Spinner）配合“缓存中”动态呼吸文本。

### 3.2 批量管理操作浮条 (Batch Action Bar)
- **移动端**：勾选后以弹性贝塞尔曲线（`cubic-bezier(0.16, 1, 0.3, 1)`）自手机屏幕底部向上滑出；
  - 背景使用深色战术磨砂（`rgba(15, 23, 42, 0.94)`）与顶部 1px 青色边界；
  - 点击【立即缓存】后，原地平滑展开多关卡总进度条，动态显示 `已下载 X/N` 与 `实时带宽 MB/s`，下载完成自动伴随轻微绿色闪烁收起。
- **桌面端**：常驻于各章节详情工作区顶栏，包含全选 Checkbox、已勾选幕数统计、一键缓存与批量释放缓存按钮。

### 3.3 在线点播缓冲转场 (Streaming Preload Modal)
- **触发条件**：用户在未缓存状态下直接点击关卡的 ▶ 播放按钮；
- **交互过程**：
  1. 瞬间唤起全屏 80% 暗色半透明战术遮罩，底层内容保持 `blur(10px)`；
  2. 画面中央展示罗德岛通信雷达指示环；
  3. 下方紧凑显示流式抓取当前资源（如 `GET .../char_002_amiya.png (3.1 MB)`）与整体依赖百分比（0%~100%）；
  4. 缓冲加载完毕瞬间，移动端执行平滑旋转至横屏全屏并进入舞台，避免任何黑屏突兀跳变。

---

## 4. 动效与过渡标准 (Motion & Transition Curves)

明日方舟的动效绝非“慢条斯理的弹性”，而是**快速、干脆、机械利落（Swift & Snappy）**：

| 动效场景 | 持续时长 (Duration) | 缓动曲线 (Easing Curve) | 动效形式 |
| :--- | :--- | :--- | :--- |
| **按钮悬停 / 点击反馈** | `120ms` | `ease-out` | 背景色快速亮化、1px 边框青色渐显、微缩放 (`scale(0.98)`) |
| **手风琴折叠展开** | `220ms` | `cubic-bezier(0.2, 0.8, 0.2, 1)` | 垂直高度裁剪展开，右侧尖角图标旋转 180° |
| **批量操作条滑入** | `260ms` | `cubic-bezier(0.16, 1, 0.3, 1)` | 底部向上平移 100% ➔ 0%，透明度 0 ➔ 1 |
| **手机横竖屏切换转场** | `400ms` | `cubic-bezier(0.4, 0.0, 0.2, 1)` | 旋转平滑补间，对白 HUD 与对白字标淡入 |
| **打字机对白字符吐字** | `30ms ~ 50ms / 字` | 线性 (`linear`) | 光标方块周期性闪烁（0.8s 循环），可随快速点击瞬时跳过 |

---

## 5. Flutter 跨平台工程落地指引 (Flutter Parity)

后续在将本规范实装至 `arknights_story_player` 代码库时，建议采用以下架构：

1. **色彩与主题映射 (`lib/story_player/theme/`)**：
   - 编写 `ArknightsThemeData`，继承 Flutter `ThemeExtension<ArknightsThemeData>`，统一分发 `--ak-*` 系列颜色、间距与字体。
2. **切角与直角装饰组件 (`BeveledBorder`)**：
   - 充分利用 Flutter 自带的 `BeveledRectangleBorder` 替代 Material 3 默认的 `RoundedRectangleBorder`，原生实现 45° 战术切角按钮。
3. **音频与触觉反馈**：
   - 在移动端点击关键交互项时，引入轻微的触觉敲击（`HapticFeedback.lightImpact()`），还原游戏内触碰金属机械面板的手感。
4. **资源预加载与流式准备**：
   - 复用现有的 `StoryRepository.prepare(document, onProgress: (done, total) => ...)` 回调，直接与 Loading 弹层的 `LinearProgressIndicator` 建立响应式状态绑定。
