# 《明日方舟》视觉设计与交互工程规范 (Arknights Design System Spec)

> **定位**：本文档沉淀了《明日方舟》（Arknights / Rhodes Island OS）经典战术终端与剧情播放器的完整视觉风格、交互准则与 Flutter 落地工程规范。
> **参考依据**：
> - 鹰角网络官方网站：[`hypergryph.com`](https://www.hypergryph.com/)
> - 明日方舟官方网站：[`ak.hypergryph.com`](https://ak.hypergryph.com/)
> - 社区开源设计系统：PRTS 官方维基 [`@mooncellwiki/prts-design`](https://github.com/MooncellWiki/prts-design)、[`ak-ui`](https://ak-ui.yyj.moe/)
> - 游戏学术/UX深度分析：腾讯游戏学堂《〈明日方舟〉UI/UX 分析——藏在「好看」背后的先进性》、站酷/机核视觉拆解与生产环境 CSS 实测提取。

---

## 1. 核心设计哲学与风格基石 (The "Ark" Aesthetics)

业界常称的**“舟味”**，本质是**后现代战术机能风（Tactical / Industrial FUI）、磁带盒未来主义（Cassette Futurism）与极简瑞士平面排版（Swiss Style / Flat Design）的高度融合**：

1. **冷峻工业与极高对比 (Cold Industrial Contrast)**：
   - 绝非消费级 Web App 的彩色渐变与软绵绵圆角；
   - 界面以纯黑、碳黑（`#121212`、`#181818`）与低反光灰阶构成沉稳低调的战术基底；
   - 强调信息自身的高对比度与秩序感，极度克制彩色使用，杜绝无意义的高饱和杂色。
2. **功能第一与反装饰主义 (Form Follows Function)**：
   - 每一个点、线、方块、条纹都有其信息学或工程学意义，拒绝“为了好看而贴标签”；
   - 追求操作面板的机械感、严谨度与坚固感（Robustness）。
3. **左锚定与工业秩序排版 (Left-anchored Precision Layout)**：
   - 摈弃大量居中堆叠的“互联网宣传页”套路，采用严谨的网格系统与左对齐信息主轴；
   - 层次依托字体粗细、字号阶梯与 1px 微透明硬质细线划分，而非大面积投影或厚重阴影。

---

## 2. 严禁事项：反 AI 伪装与去 Slop 门禁 (Anti-AI Slop Quality Gate)

AI 在生成此类界面时极其容易陷入“刻板机能风”与“保姆话痨综合征”，导致界面充满廉价感。**开发与设计时必须无条件遵守以下“四绝红线”**：

### ❌ 红线 1：严禁无意义的装饰性英文 (Zero Decorative English)
- **现象**：在每个中文词汇旁边机械拼凑全大写英文（如在“剧情播放器”下拼 `STORY PLAYER / ARCHIVE`，在“5 幕”旁边拼 `5 SCENES`，在“设置”旁拼 `PREFERENCES`）。这种中英硬凑是典型的廉价 AI 假洋鬼子病。
- **强制规则**：
  - **绝不在普通中文旁边附赠英文翻译**；
  - **英文仅允许出现在三处**：
    1. **官方业务/档案代码**（如关卡代码 `14-1 BEF`、行动代号 `EPISODE 14`、干员名 `KAL'TSIT`）；
    2. **工程终端协议与指标**（如协议状态 `PRTS-OS v4.1`、物理单位 `MB/s`、网络状态 `NET // OK`）；
    3. **官方固有的不可替代入口名**（如官方板块 `BREAKING NEWS`、`ABOUT US`、`PROJECTS`）。

### ❌ 红线 2：严禁鸡汤副标与抒情文案 (Zero Emotional Slogans)
- **现象**：在标题下或卡片内增加文艺煽情小字（如 `在文字与声影之间，重温每一个故事。`、`探索未知的泰拉大地` 等）。
- **强制规则**：
  - 战术终端是客观、严肃、理性的操作界面，**完全没有标语、口号与感伤文青小作文**；
  - 标题即业务实体名（如 `主线残卷`、`物资筹备`、`本地存储`），下方直接陈列数据或列表，绝不硬塞副标题。

### ❌ 红线 3：严禁保姆式免责 Tips 与唠叨提示 (Zero Apologetic Microcopy)
- **现象**：反复在界面上解释“尚未接入实际能力”、“此处仅供预览，确认后不会生效”、“等待接入存储统计”等免责小字。
- **强制规则**：
  - 未开发或不可用功能，直接以**禁用灰（Disabled）**、**战术锁定图标（`Icons.lock_outline`）**或横杠（`—`）表示；
  - 严禁用两行浅灰色小字向操作员反复解释小作文，界面应当干脆利落。

### ❌ 红线 4：严禁移动互联网常见套路 (Zero Generic Mobile Tropes)
- 严禁 Material 3 默认的大圆角胶囊（Pill Chips，`radius: 20px+`）；
- 严禁在标题上方加带 ✨ Sparkle 图标的胶囊小帽子（Eyebrow Chips）；
- 严禁彩色大弥散阴影（Colored Glow / BoxShadow Blur > 16px）；
- 严禁无意义的卡片嵌套卡片（Cards inside Cards）。

---

## 3. 设计令牌定义 (Design Tokens)

依据鹰角官网（`hypergryph.com`）与明日方舟官网（`ak.hypergryph.com`）提取的生产级 CSS 色彩规范全面纠偏：

### 3.1 色彩令牌 (Color Tokens)

```scss
// ==========================================
// 1. 核心高光与战术信号色 (Corrected Semantic Signals)
// ==========================================

// 终端反白高亮与指示色 (Terminal Inverse White & Indicator)
// 纠偏：彻底摒弃破坏方舟末日战术质感的科幻商业蓝/青色，采用方舟游戏内终端标准反白高对比块
--ak-active:           #ffffff; // 核心选中/主操作按钮底色（高对比反显黑字）
--ak-on-active:        #000000; // 反白块上的文字/图标色
--ak-indicator:        #ffffff; // 侧边栏/标尺左侧指示条
--ak-terminal-white:   #f0f2f5; // 战术代号、HUD 数值高亮冷白

// 战术预警黄 (Hazard Yellow)
--ak-yellow:          #ffd600; // 战术警告 / 推荐选段 / 次重要强调
--ak-yellow-fluor:    #f3ff00; // 鹰角官网标志性荧光黄 (超高亮视觉点缀，仅用于单点高光)
--ak-yellow-bg:       rgba(255, 214, 0, 0.12);

// 状态与指令色
--ak-green:           #8fc31f; // 官网/游戏校验通过绿 (Emerald/Olive Green)，已缓存/通信畅通
--ak-green-bg:        rgba(143, 195, 31, 0.15);
--ak-red:             #ff4444; // 致命警告/删除动作 (Signal Red)
--ak-red-bg:          rgba(255, 68, 68, 0.12);

// ==========================================
// 2. 终端深色表面与灰阶 (Surfaces & Industrial Grayscale)
// 纠偏：摆脱蓝紫杂色偏色，回归纯正的冷感碳黑与矿物灰阶
// ==========================================

--ak-bg-root:         #000000; // 纯黑环境底色
--ak-bg-primary:      #121212; // 主工作区、主窗口底色
--ak-bg-surface:      #181818; // 侧边导航、顶栏底色
--ak-bg-card:         #242424; // 关卡列表行、卡片常态背景
--ak-bg-hover:        #292929; // 列表悬停/按压选中色
--ak-bg-tertiary:     #333333; // 搜索框/输入框底色、进度槽底色

// ==========================================
// 3. 文本与边界对比阶梯 (Typography & Border Ranks)
// ==========================================

--ak-text-primary:    #ffffff; // 一级文字、关键指令
--ak-text-regular:    #d2d2d2; // 常规正文、关卡名称
--ak-text-secondary:  #ababab; // 描述信息、次级标签
--ak-text-muted:      #585858; // 纯代号、未激活占位、时间戳 (严禁灰底灰字)

--ak-border-base:     #333333; // 标准 1px 细线边界
--ak-border-subtle:   rgba(255, 255, 255, 0.08); // 极细半透明辅助分隔线
--ak-border-active:   #ffffff; // 激活项高亮边框（或亮灰 #505256）
```

### 3.2 几何与网格系统 (Geometry & Spacing)

- **圆角规则**：
  - 核心原则：**极硬直角（Sharp Edges）为主，微倒角为辅**；
  - 关卡条目、状态徽标、代号角标：**`0px`（纯直角）**；
  - 常规交互按钮、输入框、微型弹窗：**`border-radius: 2px`**（最大不超过 `4px`）；
  - 关键战术按钮：采用 **45° 战术切角（`BeveledRectangleBorder`，切角尺寸 3px~5px）**。
- **工业边框与点缀线**：
  - 边框宽度固定为 **`1px`**，绝不使用 2px+ 粗钝描边；
  - 允许在卡片左边缘放置 **2px 宽度的实心强调色竖条（`18d1ff` 或 `#ffd600`）**。

### 3.3 字体族谱与阶梯 (Typography Stack)

- **中文字体**：
  - 优先选择：`"Source Han Sans"`, `"Noto Sans SC"`, `"PingFang SC"`, `"Microsoft YaHei"`, `sans-serif`；
  - 特点：笔画硬朗、字重清晰、中正严谨。
- **代号与数字（战术机械感字体）**：
  - 优先选择：`"Bender"`, `"Novecentosanswide"`, `"Oswald"`, `"Chakra Petch"`, `"DIN Alternate"`, `"Roboto Mono"`, `monospace`；
  - 特点：紧凑窄体或横向延展宽体，充满仪器仪表工业感。

---

## 4. 典型交互组件规范 (Component Specifications)

### 4.1 战术关卡条目行 (Stage Item Row)
- **形态**：高度固定 48px~54px，纯色深灰底色（`#242424`），纯直角；
- **左侧**：关卡代号（如 `14-1`、`CW-EX-1`），字体采用高可读等宽/Bender 风格，颜色为 `#18d1ff`；
- **中间**：剧情标题（`#ffffff`），无多余修饰；
- **右侧**：
  - 离线状态：绿色直角小方块或 `[CACHED]` 极简标识（`#8fc31f`）；
  - 播放按钮：极简方框或 45° 倒角按钮，点击立即响应。

### 4.2 顶栏与左侧导航 (Tactical Navigation Hub)
- **顶栏**：高度 44px~48px，深色底色带底部 1px 细分割线（`#333333`）；
- **导航项**：
  - 选中态：左侧或底侧带 2px `#18d1ff` 高亮线，文字纯白；
  - 未选中态：文字 `#ababab`，无背景；
  - **严禁**在导航标题下方硬挂一行字号为 8px 的假英文单词。

### 4.3 批量操作条 (Action Deck)
- 吸附于视口底部或右侧，背景为 `#181818` 配合顶部 1px 青色光硬线；
- 操作按钮：直角实心青色按钮（`#18d1ff` 底、黑字）或直角线框按钮；
- 统计信息直接显示真实数字（如 `已选择 3 幕`），不加修饰词。

---

## 5. 动效与过渡标准 (Motion & Transition Curves)

明日方舟的终端动效特征是**干脆利落、机械切变（Snappy & Tactical）**：

| 动效场景 | 持续时长 (Duration) | 缓动曲线 (Easing Curve) | 动效形式 |
| :--- | :--- | :--- | :--- |
| **按钮按压 / 悬停** | `100ms` | `Curves.easeOut` | 背景色快速亮化、边框即刻高亮、无夸张弹性 |
| **抽屉 / 侧边栏滑出**| `200ms` | `Cubic(0.16, 1, 0.3, 1)` | 机械利落平移，伴随 1px 细线边界切入 |
| **关卡列表展开** | `180ms` | `Curves.fastOutSlowIn` | 垂直硬性裁切展开，箭头图标 90°/180° 瞬转 |
| **缓冲与雷达扫描** | `1200ms` | 线性 (`Curves.linear`) | 单色旋转圆环，周期性雷达刻度扫描 |

---

## 6. Flutter 跨平台工程落地映射 (Flutter Parity Guide)

在编写或优化 Flutter 代码时，必须贯彻以下具体写法：

1. **废弃默认 Material 3 形状**：
   - 按钮必须配置 `shape: BeveledRectangleBorder(borderRadius: BorderRadius.circular(3))` 或 `shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero)`；
   - 严禁使用默认的大圆角 `ElevatedButton` 或 `Card`。
2. **色彩完全统一至常量类 (`AppColors`)**：
   - 彻底废除青蓝色强调，切换为高对比黑白反白（`AppColors.active`、`AppColors.onActive`、`AppColors.indicator`）；
   - 将背景色统一为深炭黑与机能灰阶（`AppColors.canvas` `#0F0F10`、`AppColors.panel` `#18191A`、`AppColors.surface` `#232425`）。
3. **文本排版清理**：
   - 彻底删除代码中所有形式为 `Text('STORY PLAYER / ARCHIVE', style: TextStyle(fontSize: 8, ...))` 的假洋鬼子装饰；
   - 彻底删除“在文字与声影之间…”等鸡汤副标；
   - 保证文字对齐以 `CrossAxisAlignment.start` 为主，营造出坚实的阅读基线。
