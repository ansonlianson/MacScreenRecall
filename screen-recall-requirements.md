# Screen Recall — 需求文档

> 目标读者：在 Claude Code 中接手实施的开发模型 / 工程师
> 最后更新：2026-04-29

---

## 0. 一句话目标

一个常驻 macOS 的轻量应用：**Tier-1** 以可调间隔（默认 30 秒）抓取所有屏幕画面、调用 VLM 做理解并落库；**Tier-2** 在低频时刻（按需 / 定时）做检索问答、每日日报、TODO 抽取等高级任务。两层各自可独立选择「本地模型 / OpenAI 兼容 / Anthropic 兼容」三种后端。提供一个 macOS 26 风格的极简原生 UI 用于状态展示与配置。

---

## 1. 实施方案

### 1.1 形态

单个原生 macOS 应用：菜单栏常驻图标 + 主窗口（按需打开）+ 同进程后台采集 / 分析。无独立守护进程，无 Web 后端，无 Python 运行时。完整可执行体打包为单个 `.app`。

### 1.2 技术栈

**Swift 5.10+ / SwiftUI / macOS 26 SDK**。理由：

- macOS 26 Liquid Glass 设计语言需通过原生 SwiftUI 完整呈现
- 菜单栏 / TCC 权限申请 / 登录启动项（SMAppService）/ 通知中心 / Keychain 全部零依赖
- ScreenCaptureKit、SQLite（GRDB）、URLSession async/await、Combine / @Observable 已覆盖所有所需能力
- 单 .app 分发

### 1.3 设计预留（不在本期实现）
- 采集层抽象 `Capturer` protocol：便于未来更换 frame source
- Provider 抽象层首日完成，便于未来增加 Gemini / Ollama / 自托管等

---

## 2. 用户故事与核心场景

### 2.1 角色
**Anson**（唯一用户）：希望对自己 Mac 上的活动有完整的、可检索的、可追问细节的"第二记忆"。

### 2.2 核心场景

| ID | 场景 | 涉及层 |
|---|---|---|
| A | 开机即静默后台采集 + 分析，每 30s 一轮（间隔随时可改） | Tier-1 |
| B | 关键字 / 自然语言混合检索："我哪天在看《银屏系漫游指南》视频？" | Tier-2 |
| C | 画面细节追问："那时播放量和在线人数是多少？" → 系统调出原图二次询问 VLM | Tier-2 |
| D | 全天 / 全周总结："我昨天下午都在干嘛？" | Tier-2 |
| E | **每日自动日报**：每晚 23:00 自动产出 Markdown 日报存档，可在 UI 中翻阅 | Tier-2（定时） |
| F | **TODO 自动抽取**：从聊天 / 邮件 / 文档画面中识别"待办"，汇总为可勾选的列表 | Tier-2（定时 / 触发） |
| G | UI 状态实时可见：菜单栏图标显示采集 / 分析队列状态；点开看今日帧数、最近活动、错误 | UI |
| H | 配置随时改：菜单栏 → 设置即可改间隔、切换 Provider、调整保留天数，**生效无需重启** | UI |

---

## 3. 架构总览：双层模型 + 多 Provider + 原生 UI

```
┌─────────────────────────────────────────────────────────────────┐
│                    macOS 26 SwiftUI 应用                         │
│  ┌────────────┐  ┌────────────────┐  ┌──────────────────────┐  │
│  │ MenuBar 项 │  │ 主窗口（3 Tab） │  │ 通知 / 偏好设置面板   │  │
│  └─────┬──────┘  └────────┬───────┘  └──────────────────────┘  │
└────────┼─────────────────┼───────────────────────────────────────┘
         │                 │
         ▼                 ▼
┌─────────────────────────────────────────────────────────────────┐
│                       核心服务层（同进程）                         │
│                                                                   │
│  ┌────────────┐    Tier-1 实时管线（高频）                        │
│  │ Capturer   │───►┌──────────┐   ┌───────────┐   ┌──────────┐   │
│  │ (定时器)   │    │ Dedup    │──►│ Provider1 │──►│ Storage  │   │
│  └────────────┘    └──────────┘   │  (VLM)    │   │ (SQLite) │   │
│       ▲                            └───────────┘   └────┬─────┘   │
│       │ 间隔由 Settings 实时驱动                         │         │
│       │                                                  ▼         │
│  ┌────┴────────┐   Tier-2 衍生能力（低频 / 按需）                 │
│  │ Scheduler / │──►┌──────────┐   ┌───────────┐                   │
│  │ Trigger     │   │ Retriever│──►│ Provider2 │──► 报告/答案/TODO │
│  └─────────────┘   │ (FTS+SQL)│   │ (LLM/VLM) │                   │
│                    └──────────┘   └───────────┘                   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
        ┌───────────────────────────────────────────┐
        │ Provider 抽象层（统一接口）               │
        │  • Local (OpenAI 兼容: LM Studio/Ollama)  │
        │  • OpenAI 兼容 (任意 endpoint + key)      │
        │  • Anthropic 兼容 (api.anthropic.com 等)  │
        └───────────────────────────────────────────┘
```

**关键设计原则：**
1. **两层独立配置**：Tier-1 与 Tier-2 各有独立的 Provider / 模型 / 参数
2. **配置热生效**：所有运行参数（间隔、provider、retention）改动后 ≤ 5 秒生效，不重启进程
3. **UI 与核心同进程**：单 `.app`，避免守护进程通信复杂度；后台运行时只保留菜单栏

---

## 4. 功能需求

### 4.1 屏幕采集（Capturer）

| ID | 需求 | 优先级 |
|---|---|---|
| C-1 | 默认每 30 秒一轮，**间隔可在 UI 实时修改**（5s ~ 600s），改完无需重启 | P0 |
| C-2 | 采集**所有**已连接显示器，每屏一张图；显示器热插拔自动适配 | P0 |
| C-3 | 多屏分析串行：避免一次性 N 张图压垮本地 VLM | P0 |
| C-4 | 格式：JPEG q=75，长边 ≤ 1600px | P0 |
| C-5 | 跳过：锁屏 / 系统休眠 / 屏幕保护 | P0 |
| C-6 | 去重：相邻帧 pHash 汉明距离 ≤ 阈值（默认 4，可配）则**仅存元数据**指向上一帧分析 | P1 |
| C-7 | 隐私豁免：bundle id / 窗口标题正则黑名单，命中跳过该屏 | P1 |
| C-8 | 失败容忍：单次采集失败仅记录日志，不中断循环 | P0 |
| C-9 | 背压：当 Tier-1 分析队列积压超阈值（默认 50），新采集进入"仅存图、待补分析"队列 | P1 |

**实现建议（Swift）：**
- 优先 ScreenCaptureKit（macOS 12.3+ 原生、性能好、权限提示自然）
- `CGSessionCopyCurrentDictionary` 检测锁屏；`IOPMrootDomain` 监听休眠
- 显示器枚举：`SCShareableContent.current.displays`
- 间隔变化：用一个 `Timer` 重建（旧的 invalidate）；或用 `DispatchSourceTimer` + `setEventHandler`，间隔变化时调 `schedule(deadline:repeating:)`

### 4.2 Tier-1 实时分析（Realtime Analyzer）

| ID | 需求 | 优先级 |
|---|---|---|
| T1-1 | 每张截图调用 **Tier-1 Provider** 做画面理解（见 §4.5） | P0 |
| T1-2 | 强约束 JSON 结构化输出（schema 见 §4.2.1）；解析失败保留 raw 文本到 `raw_response` | P0 |
| T1-3 | 单请求超时默认 60s，失败重试 ≤ 2 次（指数退避） | P0 |
| T1-4 | 并发：默认 1（保护本地模型），可配 1~4 | P0 |
| T1-5 | Provider / 模型 / 超时 / 并发 / prompt 全部 UI 可调，热生效 | P0 |
| T1-6 | "重新分析"管理操作：对失败记录或指定时段重跑 | P1 |
| T1-7 | 离线兜底：Provider 不可达时，frame 仍入库标记 `pending`，恢复后自动追平 | P0 |

#### 4.2.1 Tier-1 输出 Schema（强约束）

System prompt 要求模型**只输出 JSON**：

```jsonc
{
  "summary": "一句话中文概述",
  "app": "前台应用名（最佳猜测）",
  "window_title": "窗口/标签页标题",
  "url": "若浏览器可见则为 URL，否则 null",
  "activity_type": "browsing|watching_video|coding|writing|chatting|reading|gaming|designing|terminal|idle|other",
  "entities": [
    {"type": "video_title|article_title|person|product|app|file|other",
     "value": "string", "confidence": 0.0}
  ],
  "visible_numbers": [
    {"label": "view_count|online_users|price|time|...",
     "value": "原文（含单位）", "where": "位置提示"}
  ],
  "key_text": "屏幕上 ≤5 段最有用文本，用 ' | ' 拼接",
  "tags": ["3-8 个中文搜索关键词"],
  "todo_candidates": [
    {"text": "可能的待办事项原文", "context": "出现位置"}
  ]
}
```

> `todo_candidates` 字段给 Tier-2 的 TODO 抽取提供低成本召回。Tier-1 只做"识别可能是 todo 的句子"，是否真的入库由 Tier-2 决定。

### 4.3 存储

#### 4.3.1 文件布局

```
~/Library/Application Support/ScreenRecall/
├── Settings.plist            # 偏好（UserDefaults 自动落盘）
├── recall.db                 # SQLite 主库（含 FTS）
├── recall.db-wal
├── frames/YYYY/MM/DD/<ts>_<displayId>.jpg
├── reports/YYYY-MM-DD.md     # 日报缓存
└── logs/recall.log
```

#### 4.3.2 Schema（SQLite + FTS5）

```sql
-- Frame：每次采集
CREATE TABLE frames (
  id              INTEGER PRIMARY KEY AUTOINCREMENT,
  captured_at     INTEGER NOT NULL,           -- ms
  display_id      TEXT NOT NULL,
  display_label   TEXT,
  image_path      TEXT NOT NULL,
  image_phash     TEXT,
  width INTEGER, height INTEGER, bytes INTEGER,
  dedup_of_id     INTEGER REFERENCES frames(id),
  analysis_status TEXT NOT NULL DEFAULT 'pending'   -- pending|analyzing|done|failed|skipped
);
CREATE INDEX idx_frames_time ON frames(captured_at);
CREATE INDEX idx_frames_status ON frames(analysis_status);

-- Tier-1 分析结果
CREATE TABLE analyses (
  frame_id        INTEGER PRIMARY KEY REFERENCES frames(id) ON DELETE CASCADE,
  provider        TEXT NOT NULL,        -- "lmstudio" | "openai" | "anthropic"
  model           TEXT NOT NULL,
  analyzed_at     INTEGER NOT NULL,
  summary TEXT, app TEXT, window_title TEXT, url TEXT, activity_type TEXT,
  key_text TEXT, tags_json TEXT, entities_json TEXT, numbers_json TEXT,
  todo_candidates_json TEXT,
  raw_response TEXT,
  tokens_in INTEGER, tokens_out INTEGER, latency_ms INTEGER,
  cost_usd REAL                          -- 云端 provider 用
);

CREATE VIRTUAL TABLE analyses_fts USING fts5(
  summary, key_text, tags, app, window_title, url,
  content='analyses', content_rowid='frame_id', tokenize='unicode61'
);
-- 配套 INSERT/UPDATE/DELETE 触发器同步 FTS

-- Tier-2 衍生：TODO
CREATE TABLE todos (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  text TEXT NOT NULL,
  source_frame_id INTEGER REFERENCES frames(id),
  detected_at INTEGER NOT NULL,
  due_at INTEGER,                         -- 可空
  status TEXT NOT NULL DEFAULT 'open',    -- open|done|dismissed
  notes TEXT
);

-- Tier-2 衍生：日报 / 周报
CREATE TABLE reports (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL,                     -- 'daily' | 'weekly' | 'custom'
  range_start INTEGER NOT NULL,
  range_end INTEGER NOT NULL,
  generated_at INTEGER NOT NULL,
  provider TEXT, model TEXT,
  markdown TEXT NOT NULL,
  meta_json TEXT
);

-- Tier-2 衍生：计划任务
CREATE TABLE scheduled_tasks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  cron TEXT NOT NULL,                     -- 简化 cron 或 RRULE
  prompt TEXT NOT NULL,                   -- 用户写的提问 / 指令模板
  output_kind TEXT NOT NULL,              -- 'report' | 'todo' | 'notification'
  enabled INTEGER NOT NULL DEFAULT 1,
  last_run_at INTEGER, last_status TEXT
);
```

### 4.4 Tier-2 衍生能力

Tier-2 的共同特征：低频、可调用更强模型（云端 API）、读取 Tier-1 沉淀数据为输入。

**Tier-2 全部任务遵循统一规则：**
1. **调度时间可改**：每一项定时任务（日报 / 周报 / TODO 抽取 / 自定义计划任务）的运行时点都在 UI 设置中可修改，热生效，无需重启
2. **可手动立即运行**：每一项定时任务在对应 UI Tab 必须提供"立即运行"按钮，与定时调度互不冲突
3. **可启用 / 禁用**：每一项可独立开关，关闭后不影响其它任务

#### 4.4.1 检索与问答（Recall / Ask）

**两阶段流水线：**

1. **Retrieval**：
   - 用 Tier-2 模型（或固定的轻量本地路由）将自然语言问题解析为 `{time_range, keywords[], filters{}}`
   - SQLite FTS + 时间 / 字段过滤命中 top-N（默认 N=20）candidate frames
2. **Answer**：
   - 若问题只问"什么时候 / 哪天" → 基于 metadata 聚合时间段直接回答
   - 若问题问**画面细节** → 取 top-K（默认 K=3）的原图，附带原始问题再发给 Tier-2 Provider 做"看图回答"
   - 若 K=0 命中 → 回答"未找到相关记录"

> 注：Tier-2 既可能纯文本，也可能需要看图，故 Provider 必须支持 vision——若用户在 Tier-2 选了纯文本模型，UI 要警告"画面细节追问能力将不可用"。

#### 4.4.2 每日 / 每周日报（Reports）

| ID | 需求 | 优先级 |
|---|---|---|
| R-1 | 默认每日 23:00 自动生成日报；时间可调；可手动立即生成 | P0 |
| R-2 | 输入：当天所有 `analyses` 行（按时间排序，过滤 idle / 重复） | P0 |
| R-3 | 输出 Markdown 报告，结构：① 摘要 ② 时间线（按 30 分钟分桶）③ 各 activity_type 时长占比 ④ TOP 应用 / 网站 ⑤ 今日 TODO 摘要 ⑥ 关键事件 | P0 |
| R-4 | 报告写入 `reports` 表 + `reports/YYYY-MM-DD.md` 文件 | P0 |
| R-5 | 通知中心推送"今日日报已生成"，点击打开 UI 报告页 | P1 |
| R-6 | 周报：每周一 09:00（可调）汇总上周 7 份日报 | P1 |
| R-7 | 失败重试 + 状态可视化在 UI | P1 |

**实现要点：**
- 数据量大时，先做按小时 / 按 activity_type 聚合预压缩，再喂给 LLM，避免 token 爆炸
- 提供两套 prompt：浓缩型 / 详尽型，UI 可选

#### 4.4.3 TODO 自动抽取

| ID | 需求 | 优先级 |
|---|---|---|
| TD-1 | Tier-1 已经在每帧产出 `todo_candidates`；Tier-2 在每日 22:30 / 手动触发时执行去重 + 验证 | P0 |
| TD-2 | 去重逻辑：相同 / 高相似（编辑距离 + 时间窗）的 candidate 只保留一条 | P0 |
| TD-3 | Tier-2 用 LLM 二次审核："这真的是用户自己的待办吗？还是别人的 / 文章里的？" 过滤误召回 | P0 |
| TD-4 | TODO 在 UI 中可勾选完成 / 编辑 / 设置 due / 加备注 | P0 |
| TD-5 | 通知：新增 ≥ 3 条时菜单栏徽标 + 通知推送 | P1 |

#### 4.4.4 自定义计划任务（Scheduled Tasks）

让用户能写自己的定时 prompt，配合特定时间窗的活动数据生成定制化输出。

| ID | 需求 | 优先级 |
|---|---|---|
| S-1 | 用户在 UI 中创建任务：名称 + cron / 频率 + prompt + 输出类型（报告 / TODO / 通知） | P1 |
| S-2 | 调度器到点拉取相应时间窗的 `analyses` 数据 + 用户 prompt → 调 Tier-2 Provider | P1 |
| S-3 | 输出按 `output_kind` 路由：报告入 `reports`、TODO 入 `todos`、通知直接弹通知中心 | P1 |
| S-4 | 任务可启用 / 禁用 / 立即运行一次 / 查看历史 | P1 |
| S-5 | 内置 3 个示例任务（不默认开启）：① 工作时段每 2 小时给一个聚焦度评分通知 ② 每周五下午 17:00 生成周回顾 ③ 每天早上 9 点列出昨天遗留的 TODO | P2 |

### 4.5 模型 Provider 抽象层

#### 4.5.1 统一接口

定义协议：

```swift
protocol LLMProvider {
    var name: String { get }                  // "lmstudio" | "openai" | "anthropic"
    var supportsVision: Bool { get }
    func complete(messages: [LLMMessage],
                  images: [Data],             // 空数组 = 纯文本
                  responseFormat: LLMResponseFormat,   // .text | .json
                  timeout: TimeInterval) async throws -> LLMResponse
}

struct LLMResponse {
    let text: String
    let tokensIn: Int?
    let tokensOut: Int?
    let costUSD: Double?
    let latencyMs: Int
    let raw: String      // 完整原始响应，备查
}
```

#### 4.5.2 三种内置 Provider

| Provider | 协议 | 默认 endpoint | API key | Vision |
|---|---|---|---|---|
| **Local (OpenAI 兼容)** | OpenAI Chat Completions | 用户填写（LM Studio / Ollama 任意） | 可选 | 取决于模型 |
| **OpenAI 兼容** | OpenAI Chat Completions | `https://api.openai.com/v1` | 必填 | 取决于模型 |
| **Anthropic 兼容** | Anthropic Messages API | `https://api.anthropic.com/v1` | 必填 | 是 |

**重要：**
- 三个 Provider **共用 OpenAI 兼容请求体**的两个（Local、OpenAI），仅 endpoint 不同；**Anthropic 单独走 `/v1/messages`**，需要适配（system / messages 格式不同；image content 用 `{"type":"image","source":{"type":"base64",...}}`）
- 模型名不硬编码：启动时调 `/v1/models`（OpenAI 兼容）或 Anthropic 的 list models 端点拉取，UI 下拉选择
- API key 存 macOS Keychain，**不**进 plist / DB

#### 4.5.3 双层独立配置

```
Tier-1 选择：[Provider] [Model] [Temperature] [MaxTokens] [Concurrency]
Tier-2 选择：[Provider] [Model] [Temperature] [MaxTokens]
```

**默认值（首次启动）：**
- **Tier-1 = Local**：endpoint 预填 `http://192.168.0.38:1234/v1`（用户可改），模型从 `/v1/models` 拉取后选择
- **Tier-2 = Anthropic 兼容**：endpoint 预填 `https://api.anthropic.com/v1`，需用户在首启引导中填入 API Key

两层均可在 UI 中独立切换为任意一种 Provider，互不影响。例如用户也可让 Tier-1 走云端、Tier-2 走本地，配置完全自由。

UI 必须明确告知：**Tier-2 应优先选支持视觉的强模型**（如 Claude Opus / GPT-4o / Qwen-VL-Max），否则画面细节追问降级为只读已存的 `key_text`。

### 4.6 macOS 26 原生 UI 模块

设计语言：**Liquid Glass**（macOS 26）—— 半透明材质、柔和圆角、层级模糊、SF Symbols、宽松留白。整体保持「极简」，不做花哨动画。

#### 4.6.1 形态

- **菜单栏图标**（默认形态，常驻）：SF Symbol `eye` / `eye.slash` 表示采集开关
  - 点击弹出 Popover：今日帧数 / 队列状态 / 上一次分析时间 / Tier-1 Provider 名 / "暂停采集" / "打开主窗口" / "立即生成日报"
- **主窗口**（按需打开）：标准 macOS 26 窗口，带侧栏（NavigationSplitView）
- **Dock 图标**：默认隐藏（`LSUIElement = true`），可在设置中启用为常规应用模式

#### 4.6.2 主窗口 Tab 结构

| Tab | 内容 | 关键交互 |
|---|---|---|
| **概览** | 今日活动卡片：帧数、Tier-1 / Tier-2 健康度、磁盘占用、最近 5 条 summary | 点状态卡 → 跳到日志 |
| **时间线** | 按日期选择 → 横向时间轴显示帧缩略图 + summary，鼠标悬停看详细 JSON | 点缩略图查看大图与原始响应 |
| **检索** | 顶部搜索框（关键字）+ "提问"按钮（自然语言）；结果列表 + 缩略图 | 结果可点击 → 打开对应帧详情 |
| **报告** | 左侧日历 / 报告列表，右侧渲染 Markdown 日报；按钮"立即生成今日日报" | Markdown 可导出为文件 |
| **TODO** | 列表（open / done / dismissed 三状态过滤），可勾选 / 编辑 / 设 due；顶部"立即抽取"按钮 | 单条点击展开来源帧 |
| **设置** | 见 §4.6.3 | 所有改动**热生效** |

#### 4.6.3 设置面板分组

```
[采集]
  采集间隔                [滑块 5s—600s] (实时显示当前值)
  暂停 / 恢复采集          [开关]
  保留原图天数             [步进 1—365]
  保留分析天数             [步进 1—1095]
  排除应用 / 窗口          [可编辑列表]

[Tier-1 实时分析]
  Provider                 [Local / OpenAI 兼容 / Anthropic]
  Endpoint URL             [文本框，仅 Local 与 OpenAI 兼容显示]
  API Key                  [密码框，存 Keychain]
  模型                     [下拉，从 /models 拉取]
  并发                     [1—4]
  请求超时                 [10—180s]
  ▸ Prompt 高级编辑        [折叠区，多行文本]

[Tier-2 衍生能力]
  Provider                 [同上]
  Endpoint / Key / 模型    [同上]
  ⚠️ 当前模型不支持视觉 → 画面细节追问将不可用    [警告条带]

[日报]
  自动生成时间             [时间选择器，默认 23:00]
  周报生成时间             [周几 + 时间]
  详尽 / 精简模式           [二选一]

[TODO]
  自动抽取频率             [每日 / 实时 / 关闭]
  误召回二次审核           [开关]

[计划任务]                  [增删列表 + 编辑器]

[隐私与数据]
  打开数据目录             [按钮]
  清除某日期前数据         [日期选择 + 确认按钮]
  全部抹除                 [二次确认按钮]

[关于]
  权限自检                 [屏幕录制 / 通知 / 自启动 检查与申请]
  日志查看                 [打开日志文件]
```

#### 4.6.4 系统集成

| ID | 需求 | 优先级 |
|---|---|---|
| U-1 | 首次启动检测屏幕录制权限并引导申请 | P0 |
| U-2 | 通过 `SMAppService` 注册登录启动项（设置中可开关） | P0 |
| U-3 | macOS 通知中心：日报生成 / 重要错误 / TODO 新增 | P1 |
| U-4 | 单实例：重复打开 .app 仅前置已有实例 | P0 |
| U-5 | 系统外观（浅 / 深色）自动跟随 | P0 |
| U-6 | 配置变更通过 Combine / @Observable 推到核心服务，**5s 内热生效**，无需重启 | P0 |
| U-7 | 长时未交互菜单栏图标进入"待机"色调，错误时变红 | P1 |

### 4.7 控制与可观测

| ID | 需求 | 优先级 |
|---|---|---|
| O-1 | UI 顶栏 / 菜单栏 Popover 实时显示：采集状态、队列长度、Tier-1/2 健康（最近 1h 成功率） | P0 |
| O-2 | 结构化日志（JSON line） | P0 |
| O-3 | "自检"页：屏幕录制权限、磁盘空间、Tier-1/2 连通性 ping、近 1 小时成功率 | P1 |
| O-4 | 错误堆栈本地保留，可一键导出诊断包（zip：日志 + 配置脱敏 + DB schema 摘要） | P1 |
| O-5 | 提供命令行入口（`/Applications/ScreenRecall.app/Contents/MacOS/ScreenRecall --cli search "..."` 之类）作为脚本化兜底 | P2 |

---

## 5. 非功能需求

### 5.1 性能与资源
- 空闲 CPU < 1%；采集瞬时 < 30%；Tier-2 重任务期间不影响 Tier-1
- 内存常驻 < 250MB
- 端到端（采集 → 入库 → 可被搜索）≤ 90s（取决于 Provider）
- UI 任意页面打开 < 200ms

### 5.2 存储
- 默认：原图 30 天、分析记录 365 天、报告永久（用户可手动删）
- 后台清理任务每天 03:00（避开日报）；清理走 `VACUUM INCREMENTAL`
- 估算：2 屏 × 2,880 帧/天 × ~150KB ≈ 840MB/天 → 30 天 ≈ 25GB（UI 必须显示当前实际占用）

### 5.3 隐私与安全
- 100% 本地，唯一外网访问发生在用户**主动选择**云端 Provider 时
- 数据库与图像目录权限 `0700`
- API Key 存 Keychain
- 排除应用 / 窗口黑名单
- 一键清除某日期前 / 全部
- 日志中**不**记录画面像素或解析得到的隐私文本（如密码框、信用卡号特征）

### 5.4 可靠性
- Provider 不可达：Tier-1 进入重试队列；UI 显示降级状态
- 程序崩溃：从 `analysis_status='pending'` 恢复
- 配置错误：写盘前 schema 校验；旧配置在崩溃时回滚
- 单帧失败不阻塞队列

### 5.5 可观测
- 1h 成功率 < 50% 时菜单栏图标变红 + 日志 WARN
- 内置最近 200 条事件流可在 UI 查看（不必查日志文件）

---

## 6. 技术栈建议

| 层 | 选型 | 备注 |
|---|---|---|
| 语言 | Swift 5.10+ | macOS 26 SDK |
| UI | SwiftUI + NavigationSplitView + MenuBarExtra | macOS 26 Liquid Glass |
| 采集 | ScreenCaptureKit | 静态截图模式（一次一张） |
| 数据库 | SQLite 通过 GRDB.swift | FTS5 已支持 |
| HTTP | URLSession + async/await | |
| Keychain | KeychainAccess 或自封 | 存 API Key |
| 配置存储 | UserDefaults + 自定义 Codable struct（@AppStorage 不够用时用 ObservableObject） | |
| 调度 | DispatchSourceTimer（采集）+ 自写 cron-lite（计划任务） | 无需引入完整 cron 库 |
| 启动项 | SMAppService（macOS 13+） | |
| 通知 | UserNotifications | |
| Markdown 渲染 | swift-markdown-ui 或原生 AttributedString | UI 报告页 |
| pHash | 自实现（DCT 8x8）或 `CIImage` + 简化算法 | |

**项目结构（建议）：**
```
ScreenRecall/
├── ScreenRecall.xcodeproj
├── App/                        # SwiftUI 入口、菜单栏、主窗口
│   ├── ScreenRecallApp.swift
│   ├── MenuBar/
│   ├── Windows/
│   └── Views/{Overview,Timeline,Search,Reports,Todos,Settings}/
├── Core/
│   ├── Capture/                # ScreenCaptureKit 封装、定时器、显示器枚举
│   ├── Storage/                # GRDB schema、迁移、查询
│   ├── Provider/               # LLMProvider 协议 + 三个实现
│   ├── Tier1/                  # 实时管线
│   ├── Tier2/                  # 检索 / 报告 / TODO / 计划任务
│   ├── Settings/               # SettingsStore（@Observable，热生效）
│   ├── Scheduler/              # 日报 / 周报 / 计划任务
│   └── Logging/
├── Resources/
│   ├── Prompts/                # tier1.system.txt、tier2.qa.txt 等
│   └── Assets.xcassets
└── Tests/
```

---

## 7. 配置示例

UI 在写入时会同步更新 UserDefaults（key 前缀 `recall.*`），核心服务通过 KVO / Combine 订阅。下面给出**首次启动默认值**及结构示意（便于实施者建模）：

```swift
struct AppSettings: Codable {
    var capture = CaptureSettings()
    var tier1 = ProviderSettings(provider: .local,
                                 endpoint: "http://192.168.0.38:1234/v1",
                                 model: "qwen3-vl-plus",
                                 timeoutSec: 60, concurrency: 1, temperature: 0.2)
    var tier2 = ProviderSettings(provider: .anthropic,
                                 endpoint: "https://api.anthropic.com/v1",
                                 model: "claude-sonnet-4-6",
                                 timeoutSec: 120, concurrency: 1, temperature: 0.3)
    var reports = ReportSettings(dailyAt: "23:00", weeklyDow: 1, weeklyAt: "09:00")
    var todos = TodoSettings(extractMode: .daily2230, secondaryReview: true)
    var retention = RetentionSettings(imagesDays: 30, analysesDays: 365)
    var privacy = PrivacySettings(excludedBundleIds: [], excludedTitleRegex: [])
    var ui = UISettings(showInDock: false, launchAtLogin: true)
}

struct CaptureSettings: Codable {
    var intervalSec: Int = 30          // 5–600
    var jpegQuality: Int = 75
    var maxLongEdge: Int = 1600
    var skipWhenLocked = true
    var dedupPHashDistance: Int = 4
    var maxBacklog: Int = 50
}

enum ProviderKind: String, Codable { case local, openai, anthropic }
struct ProviderSettings: Codable {
    var provider: ProviderKind
    var endpoint: String
    var model: String
    var timeoutSec: Int
    var concurrency: Int
    var temperature: Double
    // API Key 单独从 Keychain 读取，不在此结构体
}
```

API Key 在 Keychain 中按 service `com.anson.ScreenRecall` + account `tier1.apiKey` / `tier2.apiKey` 存取。

---

## 8. 验收标准（DoD）

P0 必须全部通过：

1. ✅ 首次启动引导用户授予屏幕录制权限；授予后 2 分钟内菜单栏 Popover 显示已采集 ≥ 4 帧（双屏环境）
2. ✅ `frames/` 目录下存在按日期分层的 jpg
3. ✅ `analyses` 表对应行 `summary` 非空、含数字画面下 `numbers_json` 非空
4. ✅ **采集间隔在 UI 修改后 ≤ 5s 生效**，不重启进程，旧定时器正确销毁
5. ✅ 关掉 LM Studio 30 分钟、再开启，期间采集不停，恢复后 5 分钟内积压消化
6. ✅ 锁屏期间不产生新 frame
7. ✅ 检索 Tab 中 `key_text` 关键字能找到对应截图
8. ✅ 提问 "我刚才 10 分钟在干嘛？" 返回合理总结
9. ✅ 提问含画面细节："那个视频的播放量是多少？"，能调出原图二次询问 Tier-2 Provider 并给出准确数字（人工抽查 3 例 ≥ 2 通过）
10. ✅ Tier-1 / Tier-2 各自切换 Provider 后，**新请求立即走新 Provider**，旧请求不受污染
11. ✅ Anthropic Provider 与 OpenAI Provider 各跑一次端到端，结果都能正确入库
12. ✅ Tier-2 选了纯文本模型时，UI 显示警告，提问画面细节降级为读 `key_text` 并给出"无法查阅原图"提示
13. ✅ 23:00 自动生成今日日报；手动点"立即生成"也能产出
14. ✅ 日报 Markdown 含：摘要 / 时间线 / activity_type 占比 / TOP 应用 / TODO 摘要
15. ✅ TODO Tab 至少能从测试期间产生的 candidate 中召回正确 todo（人工标注样本，召回 ≥ 60%、误报率 ≤ 30%）
16. ✅ "清除某日期前数据" 同步删除文件 + DB
17. ✅ 关机重启后，登录启动项让应用自动起来，状态正确恢复

---

## 9. 风险与边界情况

| 风险 | 缓解 |
|---|---|
| 屏幕录制权限被拒 | 首启 + 自检页可重新申请；菜单栏图标变红 |
| 本地 Provider 处理 < 间隔 → 永远积压 | UI 显示积压趋势；用户可即时调高间隔；背压队列保护 |
| 多显示器热插拔 | 每轮采集前 `SCShareableContent.current` 重新枚举 |
| 模型未加载 vision 能力 | 启动 ping 一张 1×1 测试图，失败提示并禁用画面分析；Tier-2 警告条带 |
| JSON 解析失败 | 保留 raw_response；P1 加自动修复（重发 + "请只输出 JSON"） |
| API key 误填 / 过期 | 第一次失败立刻通知用户、不重试到无穷 |
| 云端 Provider 费用爆炸 | UI 显示当日 cost_usd 累计；可设硬上限（超过则降级为本地或暂停 Tier-2） |
| 隐私泄漏（密码 / 银行） | excluded_bundle / 标题正则；快捷键一键暂停 N 分钟 |
| 时间窗口理解偏差（"上周三下午"） | Tier-2 路由失败时退化为最近 24h |
| Liquid Glass 效果在低性能 Mac 上掉帧 | 提供"减少透明度"开关，命中系统辅助功能设置则自动关 |
| SwiftUI 后台 Timer 在睡眠后漂移 | 用 `DispatchSourceTimer` + 监听 `NSWorkspace.didWakeNotification` 校准 |

---

## 10. 不在本期范围

- ❌ 音频录制 / 语音转写
- ❌ 跨设备同步、云端备份
- ❌ Windows / Linux 支持
- ❌ 多用户 / 多 profile
- ❌ Embedding 向量检索（首版 FTS 即可，足够时再加）
- ❌ 浏览器扩展直接读 DOM（仍只看画面）
- ❌ 复杂 RAG / 多步 agent

---

## 11. 后续可演进

- 向量检索（本地 bge-m3 / e5）补充 FTS 召回不足
- 计划任务可执行外部 webhook（连 Slack / 企业微信 / 邮件）
- 多 profile（工作 / 个人） + 数据隔离
- iCloud / S3 端到端加密备份
- 在线分享单条记录（短链 + 过期）

---

## 12. 移交说明

实施模型在 Claude Code 中开发时建议的里程碑顺序：

1. **M1 — 骨架 + 权限**：Xcode 工程、菜单栏图标、屏幕录制权限申请、SwiftData/GRDB 初始化、最简单设置面板
2. **M2 — Tier-1 闭环**：单屏抓 1 张 → Local Provider → 落库 → 时间线 Tab 显示
3. **M3 — 多屏 + 定时 + 热生效**：定时器、显示器枚举、间隔实时调整
4. **M4 — Provider 抽象**：补 OpenAI / Anthropic 两个实现，UI 切换
5. **M5 — 检索与问答 (Tier-2)**：FTS、检索 Tab、问答（含画面追问）
6. **M6 — 去重 / 背压 / 错误恢复**：pHash、队列长度、pending 续跑
7. **M7 — 日报 + TODO**：定时器、报告 Tab、TODO Tab
8. **M8 — 计划任务 + 通知 + 自启动 + 自检**
9. **M9 — 抛光**：Liquid Glass 细节、深色模式、性能压测、安装包签名

每个里程碑用 §8 中的对应验收项自测。

**关键外部依赖：**
- LM Studio 运行于 `http://192.168.0.38:1234`，已加载具备视觉能力的 Qwen 模型（Qwen2.5-VL / Qwen3-VL 系列）并启用 Server。
- 模型名以 `/v1/models` 实时返回为准，**不要硬编码**。
- macOS 26 SDK / Xcode 26+ 编译。

---

*文档结束*
