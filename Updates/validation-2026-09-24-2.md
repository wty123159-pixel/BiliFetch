# Windows 更新安装修复验证记录 · 2026-09-24

当前基线：`7d7971bb8a3841c89c01cecc2711b11e6a1a90f6`，已发布为 `v2026.09.24`。本次 Windows 版本为 **1.1.12**；macOS 仍为 **1.5.17 / Build 27**。没有提交、推送或发布。

## 定位证据与修复

- 在 Windows 11 ARM64（10.0.26200.9457）运行 x64 Electron 44：旧启动参数的 PowerShell 返回退出代码 0，但没有执行命令或生成状态；普通启动可执行。仅取消 detached 又会使安装子进程随 Electron 父进程退出，因此加入独立的 Go Windows GUI 启动组件，独立启动后再以隐藏方式运行 PowerShell。
- 旧 PowerShell 安装脚本在文件占用时替换失败；带方括号的源路径被通配符处理，漏复制后启动失败。新流程使用字面路径复制、逐文件 SHA-256 校验和同卷目录原子重命名，提供有界重试。
- 开始安装前等待组件确认 ready，失败保留原软件运行；安装后需要新版回传版本号和实际执行位置，才记录成功并清理备份。失败保留原文件或回退、显示提示并记录阶段。锁改用随进程结束释放的文件锁，兼容旧目录锁残留。
- 用户当次故障电脑的安装日志尚未取得，以上是本地可复现的故障类别及修复证据，不冒充对用户那台电脑具体触发原因的确认。

## 本轮通过的检查

- macOS：163 项 Swift 自测及独立更新网络测试通过；共享 Go race 检查通过；抖音解析 17 项 Python 测试通过。
- 共享 Node：31 项通过。Windows Node：80 项中 77 项通过，3 项为运行环境条件跳过；Windows 打包完成。
- macOS Electron 44：21 项中 19 项通过，2 项 Windows 专用安装测试跳过。
- Windows Electron 44：8 项安装测试全部通过，包括组件无法启动、准备超时、错误可见、仅 ready 才准许退出、启动版本/位置匹配，以及父 Electron 进程退出后继续替换并重启。
- 原生 Windows PowerShell：8 项场景通过。正常替换、中文/空格/方括号路径、临时占用后重试、旧锁残留成功；永久占用、缺少源文件、并发锁、启动未确认均按预期失败并保留或恢复旧版。
- 正式包链路：在隔离的 Windows SYSTEM 测试目录启动已发布 1.1.10，用新版本的安装组件执行升级（不宣称旧版安装器已自行修复），实际退出 Electron 父进程。安装器确认新 1.1.12 在原目录启动；42 个文件逐一 SHA-256 对照正式 1.1.12 全部一致，EXE FileVersion 为 1.1.12。
- 增量包以 GitHub 实际发布的 1.1.11 ZIP 为基线，下载后与 GitHub SHA-256 对照通过。在 Electron 44 中真实解压、应用增量并比较，42 个文件与 1.1.12 完整包完全一致；4 个核心打包源码逐字节一致，应用版本/入口/依赖元数据一致。所有交付 ZIP 的 CRC 检查通过。
- 已核对内置 yt-dlp、FFmpeg、FFprobe、aria2、视频号捕获及新增安装启动组件，兼容入口 BiliFetch.exe 保留。
- 发布工作流新增 Windows runner 门禁；本轮未推送，所以尚未在 GitHub Actions 运行这项新增作业。

## 验证边界

- Windows 测试是 Windows 11 ARM64 虚拟机内真实 x64 程序运行，不是另一台实体 x64 Windows 电脑实测，也没有进行本轮真实账号视频下载或电源恢复测试。
- 未绕过使用声明。新程序在 Electron ready 阶段确认版本和路径，用户进入主界面仍需点击“我已知晓”。
- 旧版已安装的脚本不会被尚未安装的新 ZIP 修复；建议 1.1.10 / 1.1.11 受影响用户使用完整包手动过渡一次。
- 新增代码未改动 macOS 安装器、代理/捕获策略、下载画质与合并校验等功能。macOS 本轮交付复用线上 1.5.17 ZIP，不是另一次同版本重编译。
- 部分本机测试工具调用有过超时，打包源码检查脚本也曾因模块定位/打包元数据格式差异失败；已保留原始记录。正式安装成功依据独立读取的状态、实际运行路径和 42 项文件校验，不把工具等待超时算作产品安装失败或测试通过。

## 日志

/Users/santoswang/.codex/.chatgpt-projects/g-p-6aa2778237748191a7f4ec682a4ee073/BiliFetch/.build/windows-install-fix

主要证据：`launch-probe.log`、`launch-probe-matrix.log`、`original-reproduction-2.log`、`native-installer-2.log`、`windows-electron-installer-tests.log`、`packaged-install-verified-final.log`、`running-helper-bootstrap.log`、`delta-verified-final.log`、`all-platform-tests.log`、`electron-tests-bootstrap.log`、`build-windows-bootstrap.log`。

## 实际成品

- `/Users/santoswang/Downloads/记住你宇哥-2026-09-24-更新修复/BiliFetch-Windows-x64-1.1.12.zip` — 229,126,957 bytes；SHA-256 `c502d58339267efcb3fd242958b5460c612dd3bdb580818c3b1dc6018e454a1c`。
- `/Users/santoswang/Downloads/记住你宇哥-2026-09-24-更新修复/BiliFetch-Windows-x64-delta-1.1.11-to-1.1.12.zip` — 3,674,898 bytes；SHA-256 `e316df0d26e060c7ba7d9a45c8391463bfa772aae738813681a031f100057f1b`。
- `/Users/santoswang/Downloads/记住你宇哥-2026-09-24-更新修复/BiliFetch-macOS-1.5.17.zip` — 54,522,740 bytes；SHA-256 `3393b2b682138d53f327ba9aeb79f9960a96ce7d0de65ba85765d89f1d53f58e`。
- `/Users/santoswang/Downloads/记住你宇哥-2026-09-24-更新修复/update.json` — 15,981 bytes；SHA-256 `051548a8c44924eb56fb6996bfc40969f1e1db24d7fc8582fa6dd7eba535a8a1`。

Windows 原始成品同时位于仓库 `dist/`；macOS 原始复用包位于 `.build/windows-install-fix/baseline/`。`update.json` 是待发布清单，Windows 地址尚未上线，macOS 地址指向已发布的 v2026.09.24。
