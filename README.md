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

当前发布目标为 Windows x64。安装程序尚未进行商业代码签名，Windows 可能显示“未知发布者”或 SmartScreen 提示，请确认下载来源为本仓库后再继续。

## 使用说明

1. 从 Releases 下载 `Sorryread-Setup-<版本>-x64.exe`。
2. 双击运行安装程序，根据提示选择安装位置；默认安装到 `C:\Program Files\Sorryread`。
3. 根据需要保留或取消“创建桌面快捷方式”，然后完成安装。
4. 安装完成后启动“素若阅读”，可以直接输入章节网址，也可以使用小说搜索进入书籍详情和章节目录。
5. 阅读过程中可以切换上一章、下一章、目录、书库、历史记录及透明阅读模式。

安装程序会检测 Microsoft Edge WebView2 Runtime；缺失时需要保持联网，以便调用微软官方安装程序。卸载软件时默认保留阅读记录和设置，只有主动确认后才会删除用户数据。

## 主要功能

- 使用 WebView2 加载网页并提取章节标题、正文、上一章和下一章链接。
- 并行聚合多个内置书源，按书源展示搜索结果、失败状态和分页内容。
- 支持书籍详情、章节目录、章节切换及目录高亮。
- 提供最近阅读、收藏、历史记录和阅读进度恢复。
- 保存窗口位置、字体、字号、文字颜色、主题和透明阅读状态。
- 支持 `F12` 透明阅读，以及滚轮、方向键、`PageUp`、`PageDown` 阅读控制。
- 支持 `Alt+M` 全局隐藏到托盘或恢复窗口。
- 支持用户主动导出 TXT，并自动清理长期未阅读的正文缓存。
- 提供内置登录窗口，Cookie 仅保存在本机 WebView2 用户数据目录。

## 数据与隐私

运行数据统一保存在：

```text
%LOCALAPPDATA%\Sorryread\
├─ sorryread.db    设置、历史、书库和正文缓存
├─ WebView2\       浏览器 Cookie 与缓存
└─ txt\            用户主动导出的 TXT
```

从旧版本首次迁移时，程序会复制旧数据并保留原目录。本仓库和安装包均不包含用户数据库、Cookie、网页缓存、TXT、日志或其他个人记录。

## 开发者说明

### 技术栈

- .NET 8 / WPF
- Microsoft Edge WebView2
- SQLite (`Microsoft.Data.Sqlite`)
- AngleSharp
- PowerShell
- Inno Setup 7

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
│  ├─ icons/            应用与安装程序图标
│  ├─ images/           界面图片资源
│  └─ themes/           WPF 浅色、深色及公共样式
├─ scripts/             应用发布和安装包构建脚本
├─ installer/           Inno Setup 配置
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
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-ReadAI.ps1 -Version 1.0.0
```

发布结果位于 `publish\Sorryread`。当前发布方式为 `win-x64` 自包含多文件版本，仅保留 `zh-Hans` 简体中文卫星资源，用户端不需要预装 .NET 8。

### 生成安装程序

开发机需要安装 Inno Setup 7 64 位版并保持联网，然后执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build-Installer.ps1 -Version 1.0.0
```

安装包输出到：

```text
installer\output\Sorryread-Setup-1.0.0-x64.exe
```

构建脚本会验证 WebView2 Bootstrapper 的微软数字签名，并拒绝把数据库、Cookie、WebView2 用户数据、TXT、日志、调试符号或 `UserData` 打入安装包。

## 参与贡献

请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。提交解析问题时，请只提供可公开访问且有权分享的网址和脱敏后的必要信息，不要提交网页正文、Cookie、账号信息或本地数据库。

## 许可证

本项目使用 [MIT License](LICENSE)。
