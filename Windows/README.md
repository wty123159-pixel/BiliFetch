# 记住你宇哥 · Windows

原名 BiliFetch。软件显示名和图标已更新；为兼容旧版在线更新，发布包名和应用数据目录继续使用 BiliFetch 标识；主程序文件已改为“记住你宇哥.exe”，BiliFetch.exe 仅作旧版更新与旧快捷方式的兼容入口。无需迁移已有设置、登录状态或未完成任务。

1.1.9 增加视频号本机播放捕获（测试阶段）：从「视频号捕获」开启，在已登录的电脑微信播放目标作品，再勾选加入原有下载列表。已有 HTTP/HTTPS 代理会动态接续，不固定代理端口；关闭捕获恢复原设置。需要确认本机捕获证书及临时代理，PAC 自动代理和认证代理尚未支持。Windows 真机微信播放和下载尚待验证，详见 Shared/WeChatCapture/README.md。

1.1.8 接入抖音单条视频的分享链接和整段分享文案，解析入口与 B 站共用。抖音无需登录或导入 Cookie，登录设置仍只用于 B 站。共享解析器已在 macOS 使用内置工具完成用户样例的免登录下载与音视频检查；Windows 未做真机运行、安装和下载实测，详见根目录 README 的验证边界。

支持 Windows 10/11 x64。粘贴 B 站视频、合集或多 P 链接后，先解析封面和标题并勾选分集，再开始下载。

## 使用

1. 解压整个 `BiliFetch-Windows-x64-1.1.12.zip`，不要只复制其中的启动文件。
2. 双击 `记住你宇哥.exe`，阅读启动声明并手动点击“我已知晓”。每次启动均需确认，关闭声明或退出不会进入主界面。
3. 软件会自动检测并调用包内的 yt-dlp、FFmpeg、FFprobe 和 aria2，不需要联网安装环境或管理员权限。
4. 粘贴链接并等待分集预览，选择保存位置和需要的分集，然后点击“开始下载”。只有组件被删除或损坏时，界面才会显示“修复组件”。

应用关闭或系统睡眠时会保留 `.part`/`.aria2` 断点。重新打开后会恢复未完成列表，点击“开始下载”即可续传。每个任务失败会自动重试三次；只有 FFprobe 确认最终文件同时包含视频轨和音频轨时才标记成功。

## 开发构建

开发环境使用 Go 1.27.1、Node.js 24 与 pnpm 11；以下脚本在 macOS / zsh 构建环境中从仓库根目录运行：

```bash
./scripts/build-windows.sh
```

构建脚本会下载并校验固定版本的 Windows 组件，然后放入程序的 `resources/tools` 目录。为减小体积，FFmpeg 与 FFprobe 共用同一组动态运行库，Electron 仅保留简体中文、繁体中文和英文资源；这些调整不会减少下载、合并或音视频轨检查能力。重复构建会使用 `build/windows-tools-cache` 缓存。构建结果位于 `dist/BiliFetch-Windows-x64-1.1.12.zip`。

FFmpeg 上游每日构建只保留最近 14 次。固定版本的原始压缩包已过期时，构建脚本会从 BiliFetch `v2026.09.07-3` 的 Windows 1.1.6 发布包恢复完全相同的 FFmpeg、FFprobe 和 7 个运行库，并验证固定的 SHA-256；不会恢复旧应用或替换其他下载组件。工作流已经下载的历史发布包可直接复用，否则自动下载并缓存。原始 FFmpeg 压缩包缓存若校验通过，也仍可使用。

更新文件回归测试可在 Windows 或 macOS 执行 `node scripts/test-electron-update.mjs`。该命令使用项目锁定的 Electron 版本，必要时调用其安装脚本准备运行时；已有运行时可通过 `BILIFETCH_ELECTRON_BIN` 指定。`scripts/test-all-platforms.sh` 已包含这项检查。

Windows 1.1.12 起，点击“退出并升级”会先在原目录旁准备并逐文件校验完整新版；准备成功才退出。安装器等待文件占用释放后原子替换目录，确认新程序在原位置以预期版本启动后才清理备份。失败保留原文件或回退，并显示失败提示。安装日志位于 `%APPDATA%\bilifetch-windows\Updates\update-install.log`，同目录的 `install-*.json` 和 `*.launcher.log` 保留阶段及启动错误。

如果 1.1.10 / 1.1.11 点击升级后仍是旧版，请退出旧程序，将 1.1.12 完整 ZIP 解压到新的可写目录，运行其中的 `记住你宇哥.exe`，并将原快捷方式改到新目录；不要只替换 EXE。原有设置和任务保存在同一用户数据目录，可继续使用。旧版自带的安装脚本无法由尚未安装的新版本修正。

原生安装回归可在 Windows 执行 `go build -o build/update-probe.exe Windows/tests/fixtures/update-probe/main.go`，再运行 `powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test-windows-installer.ps1 -Helper Windows/update-install.ps1 -Probe build/update-probe.exe`。测试仅使用临时目录，覆盖替换、重启、中文及方括号路径、临时与永久占用、启动失败回退、旧锁残留和并发安装锁；Release 工作流增加 Windows runner 门禁。

## 在线升级发布

Windows 1.1.0 起支持便携版应用内升级。更新包会先下载到当前用户的应用数据目录，SHA-256 校验通过后，用户点击“退出并升级”，程序才会替换应用文件并自动重启。`Tools`、登录 Cookie、设置与未完成下载任务都在用户数据目录，不会因升级丢失。

Windows 1.1.2 起，更新清单地址完全内置且不在界面展示。软件每次启动自动检查一次；没有新版或检查失败时不会影响使用，发现新版才弹出确认窗口。安装包优先使用内置 aria2 的 8 连接下载，失败后自动切换标准下载。

Windows 1.1.3 起支持文件级增量升级。只有清单中存在与当前版本精确匹配的增量包时才使用；版本不匹配、下载失败、SHA-256 不一致或增量文件校验失败时，会自动改用完整 ZIP。安装前会在用户数据目录生成完整的待替换副本，替换失败则恢复旧程序，设置、Cookie 和下载任务不受影响。

Windows 1.1.5 起，点击“退出并升级”后会立即锁定安装操作、显示退出状态，并在正常退出失效时自动强制结束旧进程。安装器只允许一个实例替换程序，避免重复点击造成多个安装器互相覆盖。

Windows 1.1.6 起，更新窗口会根据当前版本显示所有尚未安装版本的说明，并按版本从旧到新排列。发布清单自动继承历史，旧客户端仍可读取累计说明。

Windows 1.1.7 修复更新下载完成后的解压、校验和增量准备问题。若旧版在这个阶段报错，请先退出旧版，将 1.1.7 完整包解压到新的可写文件夹并运行一次，沿用已有设置和任务；修复代码需要这次手动过渡才能生效。

Windows 1.1.0 与 macOS 1.5.7 起共用一个长期不变、可公开访问的 HTTPS 清单地址：

```text
https://github.com/你的用户名/BiliFetch/releases/latest/download/update.json
```

仓库根目录的 `.github/workflows/release.yml` 会在发布时自动写入该地址、测试并构建两个平台、下载上一版完整包进行比较、生成可用的增量包与统一的 `update.json`，然后把完整包、增量包和清单上传到同一个 GitHub Release。完整步骤见根目录的 `GITHUB_RELEASE_GUIDE.md`。

如果不使用自动工作流，也可以手动构建两个平台并生成统一清单：

```bash
node scripts/create-release-manifest.mjs \
  --windows dist/BiliFetch-Windows-x64-1.1.12.zip \
  --windows-url https://你的下载地址/BiliFetch-Windows-x64-1.1.12.zip \
  --macos dist/BiliFetch-macOS-1.5.16.zip \
  --macos-url https://你的下载地址/BiliFetch-macOS-1.5.16.zip \
  --notes release-notes.txt \
  --history Updates/release-history.json \
  --previous-manifest previous/update.json \
  --output dist/update.json
```

把两个 ZIP 与 `update.json` 上传到同一次发布。客户端会在每次启动时检查并在发现新版时提示。

1.0.0 本身没有升级客户端，因此现有 1.0.0 用户需要手动换到 1.1.0 一次；从 1.1.0 开始可直接在软件内升级。

## 第三方组件

- yt-dlp：Unlicense
- FFmpeg：LGPL 共享构建，具体许可随其构建包提供
- aria2：GPL-2.0-or-later
- Electron：MIT

仅下载你有权保存的内容。本工具不绕过会员、付费、DRM、私密内容或平台访问控制。

## 1.1.11 网络与窗口修复

普通网络不需要第三方代理。视频号捕获读取 Windows 原生 WinINet 设置；无代理和默认“自动检测设置”可直接开启，临时代理使用系统分配的空闲端口，关闭或下次启动恢复原配置。已有 HTTP/HTTPS 手动代理动态接续。主动启用 PAC 脚本或账号密码代理仍需调整配置，软件会明确提示，不会静默改写。

捕获对话框按可用窗口宽高排版，按钮换行、标题自动折行，作品列表独立滚动。更新主地址连接失败后，自动尝试 GitHub 官方 API 下载同一 Release 的同名文件，不使用公共中转服务或内置账号，校验完整包及增量包的 SHA-256。

如果旧版已无法读取更新清单，需要手动换用本版一次。官方备用通道依然可能受所在网络限制，不保证覆盖所有大陆网络。旧的任务栏固定项可能保留图标缓存，可从新的“记住你宇哥.exe”重新固定；已有快捷方式仍可通过兼容入口启动。

验证：Windows 11 ARM64 虚拟机运行 x64 成品相关测试，已验证原生代理读取与恢复；这不等同于 Windows x64 物理机微信真实播放和下载完成。完整记录见 `Updates/validation-2026-09-24.md`。
