# BiliFetch for Windows

支持 Windows 10/11 x64。粘贴 B 站视频、合集或多 P 链接后，先解析封面和标题并勾选分集，再开始下载。

## 使用

1. 解压整个 `BiliFetch-Windows-x64-1.1.3.zip`，不要只复制其中的 `BiliFetch.exe`。
2. 双击 `BiliFetch.exe`。
3. 软件会自动检测并调用包内的 yt-dlp、FFmpeg、FFprobe 和 aria2，不需要联网安装环境或管理员权限。
4. 粘贴链接并等待分集预览，选择保存位置和需要的分集，然后点击“开始下载”。只有组件被删除或损坏时，界面才会显示“修复组件”。

应用关闭或系统睡眠时会保留 `.part`/`.aria2` 断点。重新打开后会恢复未完成列表，点击“开始下载”即可续传。每个任务失败会自动重试三次；只有 FFprobe 确认最终文件同时包含视频轨和音频轨时才标记成功。

## 开发构建

在 macOS 或 Windows 安装 Node.js 20+ 与 pnpm，然后从仓库根目录运行：

```bash
./scripts/build-windows.sh
```

构建脚本会下载并校验固定版本的 Windows 组件，然后放入程序的 `resources/tools` 目录。为减小体积，FFmpeg 与 FFprobe 共用同一组动态运行库，Electron 仅保留简体中文、繁体中文和英文资源；这些调整不会减少下载、合并或音视频轨检查能力。重复构建会使用 `build/windows-tools-cache` 缓存。构建结果位于 `dist/BiliFetch-Windows-x64-1.1.3.zip`。

## 在线升级发布

Windows 1.1.0 起支持便携版应用内升级。更新包会先下载到当前用户的应用数据目录，SHA-256 校验通过后，用户点击“退出并升级”，程序才会替换应用文件并自动重启。`Tools`、登录 Cookie、设置与未完成下载任务都在用户数据目录，不会因升级丢失。

Windows 1.1.2 起，更新清单地址完全内置且不在界面展示。软件每次启动自动检查一次；没有新版或检查失败时不会影响使用，发现新版才弹出确认窗口。安装包优先使用内置 aria2 的 8 连接下载，失败后自动切换标准下载。

Windows 1.1.3 起支持文件级增量升级。只有清单中存在与当前版本精确匹配的增量包时才使用；版本不匹配、下载失败、SHA-256 不一致或增量文件校验失败时，会自动改用完整 ZIP。安装前会在用户数据目录生成完整的待替换副本，替换失败则恢复旧程序，设置、Cookie 和下载任务不受影响。

Windows 1.1.0 与 macOS 1.5.7 起共用一个长期不变、可公开访问的 HTTPS 清单地址：

```text
https://github.com/你的用户名/BiliFetch/releases/latest/download/update.json
```

仓库根目录的 `.github/workflows/release.yml` 会在发布时自动写入该地址、测试并构建两个平台、下载上一版完整包进行比较、生成可用的增量包与统一的 `update.json`，然后把完整包、增量包和清单上传到同一个 GitHub Release。完整步骤见根目录的 `GITHUB_RELEASE_GUIDE.md`。

如果不使用自动工作流，也可以手动构建两个平台并生成统一清单：

```bash
node scripts/create-release-manifest.mjs \
  --windows dist/BiliFetch-Windows-x64-1.2.0.zip \
  --windows-url https://你的下载地址/BiliFetch-Windows-x64-1.2.0.zip \
  --macos dist/BiliFetch-macOS-1.5.10.zip \
  --macos-url https://你的下载地址/BiliFetch-macOS-1.5.10.zip \
  --notes release-notes.txt \
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
