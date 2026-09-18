# 素若阅读项目结构与技术栈开发文档

本文档以当前仓库源码为准，说明素若阅读的架构、模块职责、数据存储、构建发布和日常开发约定。

## 1. 项目定位

素若阅读是面向 Windows 10/11 的轻量文章/小说阅读器。用户输入公开或已获授权访问的章节网址后，应用在内嵌浏览器中加载页面，提取正文并以本地阅读器呈现。除网址解析外，应用还提供多书源聚合搜索、书库、历史记录、章节切换、TXT 导出、托盘隐藏及透明阅读。

核心原则：

- 正文提取优先依据 HTML 语义、可见布局和文本密度进行通用判断，不依赖某个网站的固定 CSS 类名。
- 本地仅保存阅读所需的设置、历史/书库元数据、正文缓存和用户主动导出的 TXT；不将这些运行数据提交到 Git。
- 遇到登录墙、访问限制或站点反爬限制时，应用只使用用户在内置浏览器中已拥有的访问状态，不绕过访问控制。

## 2. 技术栈

| 类别 | 选型 | 用途 |
| --- | --- | --- |
| 运行时 | .NET 8 (`net8.0-windows`) | Windows 桌面应用运行与自包含发布 |
| UI | WPF + XAML | 主窗口、历史窗口、登录窗口、透明阅读窗口 |
| 网页引擎 | Microsoft WebView2 | 加载页面、保留内置浏览器登录状态、执行页面端提取脚本 |
| 页面解析 | AngleSharp + C# + 浏览器端 JavaScript | 书源 CSS 规则、正文候选评分、段落恢复、章节链接识别、懒加载推进 |
| 数据库 | SQLite（`Microsoft.Data.Sqlite`） | 设置、历史、书库、正文缓存、章节链接与阅读进度 |
| 文档渲染 | WPF `FlowDocument` / `RichTextBox` | 按段落显示文章并维护阅读位置 |
| 系统集成 | Win32 低级键盘钩子、Windows Forms `NotifyIcon` | `Alt+M` 托盘显隐及托盘菜单 |
| 构建发布 | PowerShell + `dotnet publish` | 发布为 `win-x64` 自包含多文件应用 |

NuGet 依赖定义在 [ReadAI.csproj](../ReadAI.csproj)：

```xml
<PackageReference Include="Microsoft.Data.Sqlite" Version="8.0.8" />
<PackageReference Include="Microsoft.Web.WebView2" Version="1.0.2903.40" />
<PackageReference Include="AngleSharp" Version="1.7.2" />
```

## 3. 运行架构

```text
App 启动
  ├─ 单实例 Mutex 检查
  ├─ 解析数据目录并初始化 SQLite
  └─ 创建 MainWindow

MainWindow
  ├─ 网址解析：隐藏 WebView2 导航 → PageParser 提取 → FlowDocument 渲染
  ├─ 聚合搜索：12 个 HTTP 书源并行搜索 → 按源状态/结果条 → 每源独立分页
  ├─ 即时阅读：已完成书源结果 → 取消其余搜索 → 复用详情/目录/正文链路
  ├─ 书源阅读：详情/目录/章节规则 → 现有目录面板与 FlowDocument
  ├─ 18mh 搜索：WebView2 搜索页 → NovelSearchParser（兼容原链路）
  ├─ 阅读状态：ReaderDatabase 分别保存历史、书库章节/进度和显示设置
  ├─ 普通阅读：RichTextBox + ReaderScrollController
  └─ 透明阅读：TransparentReaderWindow 复用文章与阅读进度
```

### 3.1 启动与单实例

[App.xaml.cs](../src/App/App.xaml.cs) 创建命名 Mutex，阻止同一用户重复启动 ReadAI。随后：

1. 通过 `AppPaths.ResolveDataDirectory()` 选择数据目录；
2. 创建并初始化 `ReaderDatabase`；
3. 创建并显示 `MainWindow`；
4. 退出时释放数据库连接和 Mutex。

每个 Windows 用户的数据目录固定为 `%LOCALAPPDATA%\Sorryread\`。其中保存 `sorryread.db`、WebView2 用户数据和 TXT 导出；首次启动且新数据库不存在时，会从程序根目录 `UserData\` 或 `%LOCALAPPDATA%\ReadAI` 中选择旧数据库来源进行复制迁移，旧目录不会自动删除。程序文件可以安全安装到 `Program Files`。

### 3.2 网页加载与正文提取

主窗口中的 `ParserView` 是移出可视区域、不可点击的 `WebView2`。它只负责网页加载和页面端脚本执行，正文在 WPF 阅读器内渲染，不直接把网页嵌入主界面。

[PageParser.cs](../src/Parsing/PageParser.cs) 的处理层次如下：

1. 移除脚本、导航、广告、推荐、评论控件等高噪声元素；
2. 收集 `article`、`main`、`role=main`、`articleBody` 以及名称含 `chapter`、`article`、`post`、`content`、`reader` 等语义信号的候选容器；
3. 结合正文长度、段落数量、`br` 数量、链接文本比例、标题数量和节点深度进行评分，选择最可能的正文容器；
4. 优先还原真实的 `p`、`pre`、`blockquote` 段落；若页面没有语义段落，则依次回退到可见块元素和渲染间距推断；
5. 清理私有区字符、替换字符、无意义纯数字行和多余空白；空的语义 `<p>` 会被保留为段落分隔；
6. 根据链接可见文字、`aria-label`、`title`、`rel`、id/class 等信号，匹配上一章和下一章；
7. 对滚动加载的页面，推进主要阅读滚动面，直到内容高度与正文指纹稳定或达到 45 秒上限，再合并去重后的段落。

`PageParseResult` 统一承载标题、正文、当前来源网址、内容就绪状态及上一章/下一章链接。新网站适配应先增强这套通用策略；只有能够明确证明通用策略无法涵盖的稳定规则，才考虑新增站点专用分支。

### 3.3 聚合搜索与书源阅读流程

[BookSourceCatalog.cs](../src/Search/BookSourceCatalog.cs) 集中定义 12 个 HTTP 书源和原有 18mh 书源。配置只存在于程序代码中，不读取外部规则文件；新增或调整书源必须修改代码并重新构建。

1. “小说搜索”默认进入聚合模式；同一个关键字由 `AggregatedSearchService` 同时分发给 12 个 HTTP 书源。双击“小说搜索”只在当前会话切换为 18mh 单独搜索，再次双击恢复聚合模式。
2. 每个书源独立维护“搜索中、成功、空结果、失败”状态；单源超时或 HTTP 失败只更新该源按钮，不会取消其他请求。聚合搜索尚未结束时，已成功书源的可见结果可立即进入阅读；此时递增操作版本并取消其余请求，过期进度回调不能覆盖新解析状态。
3. 结果区上方的书源按钮显示当前结果数或失败状态；切换书源恢复该源第 1 页，上一页/下一页只读写当前源的分页缓存。
4. HTTP 书源由 `BookSourceParser` 使用 AngleSharp 和代码内 CSS 规则解析搜索页、详情页、分页目录和章节正文；请求有独立超时和一次重试，目录与正文分页都有上限。
5. 正文规则支持普通段落、广告过滤和两种 Base64 载荷处理；章节的上一章/下一章来自当前书籍目录，继续复用现有右侧目录面板、阅读区、TXT 与进度逻辑。
6. 18mh 保留原 `NovelSearchParser` + WebView2 流程，仅供双击切换后的单独搜索使用，不进入聚合书源选择条；普通“网址解析”仍直接使用 `PageParser`，不经过书源规则。

网站 DOM、限流或可达性可能变化。运行时应把规则失效作为单书源失败处理，而不是降级为错误结果或中断整次搜索。

### 3.4 阅读与显示模式

[ArticleDocumentFactory.cs](../src/Parsing/ArticleDocumentFactory.cs) 将双换行分隔的正文块创建为 `FlowDocument` 段落，保证网页提取出的段落关系在 WPF 中继续保留。

普通阅读使用主窗口的 `ReaderBox`。`ReaderScrollController` 为方向键、`PageUp`、`PageDown` 和鼠标滚轮提供统一滚动处理。

按 `F12` 进入透明阅读：

- 主窗口隐藏；透明窗口无边框、无菜单、无状态栏和无可见滚动条；
- 透明窗口只放置与原 `ReaderBox` 屏幕区域一致的正文视口，不改变文章区域尺寸；
- 点击正文区域可拖动窗口，滚轮和导航键继续控制阅读；
- 再按 `F12` 返回普通窗口，窗口位置、大小和进度会同步回来。

### 3.5 托盘与快捷键

[HotKeyService.cs](../src/Services/HotKeyService.cs) 通过 `WH_KEYBOARD_LL` 监听键盘。它同时维护左右 Alt 键状态，因此 `Alt+M` 无论使用左 Alt 或右 Alt 都可切换窗口与托盘状态；`Shift+E` 同样保持全局显隐能力。章节快捷键仅在应用窗口获得焦点时响应，其中 `Shift+F` 切换上一章、`Shift+J` 切换下一章。关闭主窗口默认隐藏至托盘；用户从托盘菜单选择退出时才会真正结束进程。

## 4. 代码结构

```text
Sorryread/
├─ src/
│  ├─ App/                                 # 生命周期、数据路径与应用主题
│  ├─ UI/Main/                             # 主阅读窗口和业务编排
│  ├─ UI/Windows/                          # 历史、登录与透明阅读窗口
│  ├─ UI/Controls/                         # 书库卡片、跑马灯和滚动控制
│  ├─ UI/Dialogs/                          # 信息与确认对话框
│  ├─ Parsing/                             # 网页正文、书源和文档解析
│  ├─ Search/                              # 聚合搜索、搜索模型与书源目录
│  ├─ Data/                                # SQLite 和业务数据模型
│  └─ Services/                            # 热键、托盘和 TXT 导出
├─ assets/icons/                           # 应用图标
├─ assets/images/                          # WPF 图片资源
├─ assets/themes/                          # 浅色、深色与公共样式
├─ scripts/                                # 应用发布构建脚本
├─ docs/DEVELOPMENT.md                     # 本文档
├─ App.xaml                                # WPF 应用资源入口
├─ ReadAI.csproj                           # .NET/WPF 项目与 NuGet 依赖
├─ Directory.Build.props                   # 确定性构建与语言版本
├─ README.md / CONTRIBUTING.md
└─ LICENSE                                 # MIT 许可证
```

### 4.1 模块边界

| 模块 | 负责 | 不负责 |
| --- | --- | --- |
| `MainWindow` | UI 状态机、用户操作、异步流程编排、状态提示 | 不直接实现网页 DOM 规则或 SQL |
| `PageParser` | 通用 DOM/布局解析、懒加载推进、章节导航识别 | UI 渲染和数据库持久化 |
| `NovelSearchParser` | 18mh 的搜索、目录和阅读入口提取 | 其他 HTTP 书源或通用正文提取 |
| `BookSourceCatalog` | 集中维护代码内书源与选择器规则 | 运行时外部配置或用户编辑 |
| `BookSourceParser` | HTTP 书源的搜索、目录分页、章节正文与编码处理 | UI 状态、SQLite 或 18mh WebView2 脚本 |
| `AggregatedSearchService` | 并发调度、单源状态和失败隔离 | DOM 规则与结果显示 |
| `ReaderDatabase` | SQLite 表、兼容迁移、读写和缓存清理 | 窗口控件和网页逻辑 |
| `ArticleDocumentFactory` | 文本块到可阅读文档的转换 | 页面提取或历史保存 |
| `TransparentReaderWindow` | 无边框透明阅读的视口、移动和输入 | 解析网页或修改数据库模型 |

## 5. 数据模型与存储

数据库文件为 `%LOCALAPPDATA%\Sorryread\sorryread.db`，以 WAL 模式运行。

### 5.1 `Settings` 表

键值形式保存：字体、字号、背景主题、文字颜色、透明模式、主窗口大小/位置/状态和最后解析网址。

### 5.2 `History` 表

| 字段 | 说明 |
| --- | --- |
| `Url` | 唯一章节网址 |
| `Title` | 展示标题；搜索进入时为“书名-第 x 章” |
| `Content` | 当前正文缓存 |
| `PreviousUrl` / `NextUrl` | 已解析出的章节导航链接 |
| `Progress` | 0 到 1 的阅读位置比例 |
| `CreatedUtc` | 首次解析时间 |
| `LastParsedUtc` / `ParseCount` | 最近解析时间与累计解析次数 |
| `LastReadUtc` | 最近阅读时间，用于缓存过期判定 |
| `LocalPath` | TXT 导出路径记录 |
| `SourceId` | 聚合书源标识；旧数据库启动时自动补列，普通网址解析为空 |

应用启动后会按“最后阅读时间早于当前时间 15 天”的条件清空 `Content`，但保留同一条历史元数据、网址、标题、进度和 TXT 文件。用户从该条历史记录打开时，会自动重新解析原网址。

TXT 仅在用户执行“保存为 TXT”时写入 `<数据目录>\txt\`，编码为 UTF-8 无 BOM。历史记录界面的“清空历史记录”会同时清除历史表与该目录下的 TXT 文件。

### 5.3 `LibraryBooks` 表

书库与历史记录相互独立，仅收录从聚合搜索或 18mh 单独搜索进入阅读的书籍；手动网址解析不写入书库。

| 字段 | 说明 |
| --- | --- |
| `BookKey` | `SourceId + DetailUrl` 生成的稳定书籍键，同一书源同一本书不重复 |
| `Title` / `SourceId` / `SourceName` | 书名与来源书源 |
| `DetailUrl` | 书籍详情页，用于目录缓存缺失时重新拉取 |
| `ChapterUrl` / `ChapterTitle` | 最后阅读章节 |
| `Progress` | 最后章节内的 `0..1` 滚动比例 |
| `LastReadUtc` | 非空表示属于最近阅读；按时间最多保留 10 条 |
| `FavoriteUtc` | 非空表示已收藏；最多保留 50 本 |
| `CatalogJson` | 章节目录缓存，恢复阅读时优先使用 |

清除最近阅读只清空 `LastReadUtc`，取消收藏只清空 `FavoriteUtc`；当两者都为空时才删除基础记录。书库恢复章节时使用 `recordToHistory: false`，不会重复写入历史记录，但会刷新最近阅读时间。

## 6. 构建、发布与运行

### 6.1 开发前提

- Windows 10/11；
- .NET 8 SDK；
- Microsoft Edge WebView2 Runtime（Windows 11 通常已安装）；
- 可访问 NuGet 的网络环境，以便首次还原依赖。

### 6.2 调试构建

```powershell
dotnet restore .\ReadAI.csproj
dotnet build .\ReadAI.csproj -c Debug
```

### 6.3 发布可双击运行的版本

在仓库根目录执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-ReadAI.ps1
```

脚本会：

1. 检查是否有从 `publish\Sorryread` 启动且会锁定发布目录的副本；
2. 自动选择系统 `dotnet` 或 `%LOCALAPPDATA%\ReadAISdk\dotnet8\dotnet.exe` 中的 .NET 8 SDK；
3. 使用 `--runtime win-x64` 执行 restore；
4. 执行 Release、`win-x64` 自包含多文件发布；
5. 复制图标至发布目录。

最终目录为 `publish\Sorryread`，其中包含 `素若阅读.exe`、应用程序集、.NET 运行库及原生依赖。用户端不需要预装 .NET 8。如果发布时出现 `NETSDK1047`，通常是先前没有按 `win-x64` 运行 restore；重新运行上述脚本即可。

## 7. 开发与验证约定

### 7.1 修改网页解析器

1. 先保存或提供可公开、可授权使用的 HTML/DOM 证据；不要只根据截图猜测节点结构。
2. 优先检查候选容器选择、噪声过滤、语义段落、可见块和视觉间距五个层次。
3. 新规则必须说明它覆盖的通用结构信号，避免绑定单个网站的易变 class 名称。
4. 验证至少包括：正文纯度、段落数量、标题、上一章/下一章、懒加载结果，以及不回归已有样本。

### 7.2 修改持久化

- 对现有数据库字段使用可重复执行的迁移逻辑；`ReaderDatabase.Initialize()` 已通过 `EnsureHistoryColumn` 支持旧库补列。
- 阅读位置必须限定在 `0..1`，并与 `LastReadUtc` 一起更新。
- 不要把 `sorryread.db`、`readai.db`、`*-wal`、`*-shm`、WebView2 用户数据或 TXT 放入版本库。

### 7.3 修改 UI

- 普通模式和透明模式都要验证：滚轮、方向键、`PageUp`/`PageDown`、阅读进度恢复、`F12` 往返和窗口拖动。
- 涉及托盘和热键时，测试左 Alt 与右 Alt 的 `Alt+M`、`Shift+E`，并测试关闭窗口、双击托盘图标和明确退出；还需确认 `Shift+F`/`Shift+J` 的上下章映射，以及应用失焦或隐藏时不会响应章节快捷键。
- 搜索功能至少验证：全部书源并发、单源失败隔离、书源按钮状态、切源回第 1 页、每源上一页/下一页、搜索未结束时点击已返回结果、目录/正文/翻章，以及返回原搜索页的滚动位置。
- 书库至少验证：仅搜索阅读自动收录、最近阅读 10 条裁剪、收藏 50 本上限、两类删除关系、收藏按钮双向同步、目录缓存命中/缺失恢复、章节与滚动进度恢复，以及返回原搜索/阅读界面。
- 同时回归普通网址解析、18mh 原 WebView2 搜索、历史记录、设置、右侧目录、阅读进度和透明阅读；书源网络验证需要区分“代码通过”与“目标站点当前可达”。

### 7.4 版本控制与产物

[.gitignore](../.gitignore) 已排除 `bin/`、`obj/`、`publish/`、数据库、WebView2 数据、日志和测试产物。提交前建议执行：

```powershell
git diff --check
git status --short
dotnet build .\ReadAI.csproj -c Release
```

当需要源代码备份时，建议用已提交版本创建归档，而不是压缩工作目录：

```powershell
git archive --format=zip --output=ReadAI-source.zip HEAD
```

这样压缩包只包含受版本控制的项目代码和文档，不会混入数据库、缓存或发布产物。

## 8. 已知边界

- 网页 DOM、登录限制、动态加载和反自动化策略由网站控制；解析器只能处理当前浏览器可访问、可渲染的内容。
- “通用解析”是基于结构与布局的启发式判断，不能保证所有网页 100% 无误；发现问题时，应提供实际 HTML/DOM 和期望正文边界以便改进通用规则。
- 18mh 单独搜索对应 `18mh.net` 的公开页面结构；若站点页面或路由改变，需要更新 `NovelSearchParser`。
- 应用用于读取用户有权访问的内容。项目不提供绕过登录、付费墙、地区限制或网站安全机制的功能。
