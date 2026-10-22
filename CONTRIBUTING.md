# 贡献指南

涉及 Flutter 手机端或跨端共享内容时，先阅读 [桌面与手机协同开发约定](docs/CROSS_PLATFORM_DEVELOPMENT.md) 和 [Flutter 技术方案](docs/FLUTTER_TECHNICAL_PLAN.md)。下述开发环境主要适用于现有 Windows 客户端。

## 开发环境

- Windows 10/11
- .NET 8 SDK
- Microsoft Edge WebView2 Runtime

使用 `scripts\Build-ReadAI.ps1` 完成应用发布构建。提交前确保构建通过，且提交内容不包含数据库、Cookie、缓存、TXT、日志或其他用户数据。

## 提交范围

可以提交：

- C#、XAML、项目配置、构建脚本、文档和图标
- 可公开分享的、最小化的解析规则或测试结构说明

不要提交：

- `bin/`、`obj/`、`publish/` 等生成物
- SQLite 数据库、TXT 导出、WebView2 数据、Cookie、账户信息或网页正文
- 受版权保护、私密或无权分享的内容

## 解析问题

报告正文提取问题时，请提供：

1. 可公开访问且有权分享的网址。
2. 期望保留与应当排除的页面区域描述。
3. 解析结果截图或不包含正文内容的结构信息。

本项目不实现访问控制、验证码、付费墙或反爬机制的绕过功能。
