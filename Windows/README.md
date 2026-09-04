# BiliFetch for Windows

支持 Windows 10/11 x64。粘贴 B 站视频、合集或多 P 链接后，先解析封面和标题并勾选分集，再开始下载。

## 使用

1. 解压整个 `BiliFetch-Windows-x64-1.1.0.zip`，不要只复制其中的 `BiliFetch.exe`。
2. 双击 `BiliFetch.exe`。
3. 首次运行点击“准备组件”，软件会把 yt-dlp、FFmpeg、FFprobe 和 aria2 放入当前用户的 BiliFetch 数据目录，不需要管理员权限。
4. 粘贴链接并等待分集预览，选择保存位置和需要的分集，然后点击“开始下载”。

应用关闭或系统睡眠时会保留 `.part`/`.aria2` 断点。重新打开后会恢复未完成列表，点击“开始下载”即可续传。每个任务失败会自动重试三次；只有 FFprobe 确认最终文件同时包含视频轨和音频轨时才标记成功。

## 开发构建

在 macOS 或 Windows 安装 Node.js 20+ 与 pnpm，然后从仓库根目录运行：

```bash
./scripts/build-windows.sh
```

构建结果位于 `dist/BiliFetch-Windows-x64-1.1.0.zip`。

## 在线升级发布

Windows 1.1.0 起支持便携版应用内升级。更新包会先下载到当前用户的应用数据目录，SHA-256 校验通过后，用户点击“退出并升级”，程序才会替换应用文件并自动重启。`Tools`、登录 Cookie、设置与未完成下载任务都在用户数据目录，不会因升级丢失。

Windows 1.1.0 与 macOS 1.5.7 起共用一个长期不变、可公开访问的 HTTPS 清单地址：

```text
https://github.com/你的用户名/BiliFetch/releases/latest/download/update.json
```

仓库根目录的 `.github/workflows/release.yml` 会在发布时自动写入该地址、测试并构建两个平台、计算校验值、生成统一的 `update.json`，然后将两个 ZIP 和清单上传到同一个 GitHub Release。完整步骤见根目录的 `GITHUB_RELEASE_GUIDE.md`。

如果不使用自动工作流，也可以手动构建两个平台并生成统一清单：

```bash
node scripts/create-release-manifest.mjs \
  --windows dist/BiliFetch-Windows-x64-1.2.0.zip \
  --windows-url https://你的下载地址/BiliFetch-Windows-x64-1.2.0.zip \
  --macos dist/BiliFetch-macOS-1.5.8.zip \
  --macos-url https://你的下载地址/BiliFetch-macOS-1.5.8.zip \
  --notes release-notes.txt \
  --output dist/update.json
```

把两个 ZIP 与 `update.json` 上传到同一次发布。所有启用了自动检查的客户端会收到各自平台的新版提示。

1.0.0 本身没有升级客户端，因此现有 1.0.0 用户需要手动换到 1.1.0 一次；从 1.1.0 开始可直接在软件内升级。

## 第三方组件

- yt-dlp：Unlicense
- FFmpeg：GPL 构建，具体许可随其构建包提供
- aria2：GPL-2.0-or-later
- Electron：MIT

仅下载你有权保存的内容。本工具不绕过会员、付费、DRM、私密内容或平台访问控制。
