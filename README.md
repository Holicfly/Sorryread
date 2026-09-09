# 素若阅读

> [!IMPORTANT]
> **AI 开发提示：**本程序主要由 AI 协助完成设计、编码、重构和文档整理。受限于 AI 的理解与测试覆盖，项目仍可能存在不足、兼容性问题或未发现的缺陷，敬请谅解，也欢迎通过 Issue 提交可复现的问题和改进建议。

相关 AI 与开源项目：

- [DeepSeek 开源主页](https://github.com/deepseek-ai)
- [OpenAI Codex](https://github.com/openai/codex)
- [ZCode](https://zcode.z.ai/)
- [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)

素若阅读是一款面向 Windows 10/11 的轻量小说与文章阅读器，可以从公开或用户有权访问的网页提取正文，并在本地阅读界面中显示。

## 下载

[前往 GitHub Releases 下载最新版安装程序](https://github.com/Holicfly/Sorryread/releases/latest)

## 使用说明

1. 从 Releases 下载 `Sorryread-Setup-<版本>-x64.exe`。
2. 双击运行安装程序，根据提示选择安装位置；默认安装到 `C:\Program Files\Sorryread`。
3. 根据需要保留或取消“创建桌面快捷方式”，然后完成安装。
4. 安装完成后启动“素若阅读”，可以直接输入章节网址，也可以使用小说搜索进入书籍详情和章节目录。
5. 阅读过程中可以切换上一章、下一章、目录、书库、历史记录及透明阅读模式。

## 主要功能

### 🔎 网页正文解析

粘贴小说章节或文章网址后，软件会自动识别标题和正文，尽量过滤导航、广告、推荐列表等无关内容。同时支持识别上一章、下一章链接，方便连续阅读。

### 📚 在线搜书

输入书名即可同时搜索多个在线书源，并分别展示各书源的搜索状态和结果。找到书籍后，可以继续查看书籍详情、章节目录并选择章节阅读。

### 🪟 透明背景阅读

正文解析完成后，按 `F12` 即可进入透明阅读模式，让窗口背景透明、主要保留正文文字。透明模式支持鼠标滚轮、方向键和翻页键阅读，再次按 `F12` 可返回普通界面。

在阅读窗口获得焦点时，音量−/音量+键也可分别用于向上/向下滚动；音量+键滚动到章节末尾后可继续进入下一章。

### ⚡ 快捷键收起应用

按下全局快捷键 `Alt+M` 或 `Shift+E`，可以随时将应用收起到系统托盘，再次按下即可恢复。普通阅读和透明阅读状态下均可使用，即使当前正在操作其他程序也能触发。

其他功能：

- 书籍详情、章节目录、目录高亮和章节切换。
- 最近阅读、书库收藏、历史记录和阅读进度恢复。
- 记住窗口位置、字体、字号、文字颜色和主题设置。
- 可在设置中调整方向键滚动距离，支持 1–100 行。
- 支持导出 TXT。
- 内置登录窗口，可保留网站登录状态。
- 应用获得焦点时，支持 `Shift+F` 切换上一章、`Shift+J` 切换下一章；应用失焦或隐藏后不响应这两个章节快捷键。

## 数据与隐私

运行数据统一保存在：

```text
%LOCALAPPDATA%\Sorryread\
├─ sorryread.db    设置、历史、书库和正文缓存
├─ WebView2\       浏览器 Cookie 与缓存
└─ txt\            用户主动导出的 TXT
```

本仓库和安装包均不包含用户数据库、Cookie、网页缓存、TXT、日志或其他个人记录。

## 开发者说明

### 技术栈

- .NET 8 / WPF
- Microsoft Edge WebView2
- SQLite (`Microsoft.Data.Sqlite`)
- AngleSharp
- PowerShell

### 项目结构

```text
Sorryread/
├─ src/
│  ├─ App/              应用生命周期、主题和路径管理
│  ├─ UI/               主窗口、子窗口、控件和对话框
│  ├─ Parsing/          网页正文和书源规则解析
│  ├─ Search/           聚合搜索、搜索模型和书源目录
│  ├─ Data/             SQLite 与业务数据模型
│  └─ Services/         热键、托盘和 TXT 导出
├─ assets/
│  ├─ icons/            应用图标
│  ├─ images/           界面图片资源
│  └─ themes/           WPF 浅色、深色及公共样式
├─ scripts/             应用发布构建脚本
├─ docs/                详细开发文档
├─ App.xaml             WPF 应用资源入口
├─ ReadAI.csproj        .NET 项目文件
├─ Directory.Build.props
├─ CONTRIBUTING.md
└─ LICENSE
```

更详细的架构和模块说明参见 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)。

### 本地构建

环境要求：

- Windows 10/11 x64
- .NET 8 SDK
- Microsoft Edge WebView2 Runtime

```powershell
dotnet restore .\ReadAI.csproj
dotnet build .\ReadAI.csproj -c Debug
```

### 发布应用

在仓库根目录执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-ReadAI.ps1 -Version 1.1.7
```

发布结果位于 `publish\Sorryread`。当前发布方式为 `win-x64` 自包含多文件版本，仅保留 `zh-Hans` 简体中文卫星资源，用户端不需要预装 .NET 8。

## 参与贡献

请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。提交解析问题时，请只提供可公开访问且有权分享的网址和脱敏后的必要信息，不要提交网页正文、Cookie、账号信息或本地数据库。

## 许可证

本项目使用 [MIT License](LICENSE)。
