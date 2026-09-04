# BiliFetch GitHub 仓库与双平台发布指南

## 第一次创建仓库

1. 注册并登录 GitHub，打开 <https://github.com/new>。
2. Repository name 填写 `BiliFetch`，建议先选 `Private` 测试；准备公开发布时再改为 `Public`。私有仓库的 Release 需要登录授权，普通客户端无法匿名检查更新，所以正式更新通道必须来自公开仓库或公开服务器。
3. 因为本地已经有完整工程，不要勾选自动创建 README、`.gitignore` 或 License，避免第一次推送产生冲突。
4. 点击 Create repository，记下页面显示的仓库地址，例如 `https://github.com/你的用户名/BiliFetch.git`。
5. 在终端进入本工程并执行：

```bash
git init -b main
git add .
git commit -m "Initial BiliFetch macOS and Windows release"
git remote add origin https://github.com/你的用户名/BiliFetch.git
git push -u origin main
```

也可以安装 GitHub Desktop，选择 “Add an Existing Repository from your Local Drive”，然后点击 Publish repository。

## 第一次启用在线更新

仓库内已经包含 `.github/workflows/release.yml`。它会自动完成：

1. 把更新通道写成固定地址：
   `https://github.com/你的用户名/BiliFetch/releases/latest/download/update.json`
2. 同时运行 macOS 与 Windows 测试。
3. 同时构建两个平台的 ZIP。
4. 下载 Latest Release 中上一版的两个完整包，与新版逐文件比较；变化很少的大文件会生成块级二进制补丁。只要增量包确实更小，就为两个平台各生成一个增量 ZIP。
5. 计算完整包和增量包的 SHA-256，生成向旧客户端兼容的统一 `update.json`。
6. 创建 GitHub Release，并上传完整包、可用的增量包和更新清单。

Actions 会把真实仓库地址直接写进 macOS 与 Windows 安装包。更新地址不会显示在软件界面，也不需要用户填写；软件会在每次启动时检查一次，有新版才提示。

如果 Actions 提示无权创建 Release，请到仓库 `Settings → Actions → General → Workflow permissions`，确认工作流具有读写权限。组织账号的权限也可能由组织管理员统一限制。

## 以后发布新版

1. 修改 Windows 的 `Windows/package.json` 版本号。
2. 修改 macOS 的 `scripts/build-app.sh` 中 `APP_VERSION` 与 `APP_BUILD`。
3. 把本次改动同时检查两个平台，更新发布说明。
4. 提交并推送：

```bash
git add .
git commit -m "Release: describe the changes"
git push
```

5. 打开 GitHub 仓库的 `Actions` 页面，选择 `Build and release macOS + Windows`，点击 `Run workflow`。
6. Tag 建议填写日期，例如 `v2026.09.05`；Notes 填写用户能看懂的更新内容。
7. 工作流全部变绿后，GitHub 的 Releases 页面会出现新版。已经配置更新通道的客户端会在下次启动时检查到它。

客户端不会接收代码仓库里的源文件，而是读取 Latest Release 中固定名称的 `update.json`。它比较当前平台版本后，优先选择 `fromVersion` 与本机版本完全一致的增量 ZIP；没有对应增量包，或增量下载、SHA-256、文件校验、应用过程失败时，会自动改下完整 ZIP。准备完成后才退出并替换程序，失败会恢复旧应用。两个平台的账号登录、设置与未完成任务都保存在用户数据目录，不会随程序包替换而删除。

macOS 1.5.10 与 Windows 1.1.3 是首批能读取增量信息的客户端。因此旧版本第一次升级到它们仍会下载完整包；它们发布之后，再发布更高版本时才会开始明显减少更新下载量。每次 Release 都必须保留完整 ZIP，它既服务旧客户端，也是增量失败时的自动兜底。

如果主要用户无法稳定访问 GitHub，应把两个 ZIP 和 `update.json` 同步到国内对象存储或 CDN（例如阿里云 OSS、腾讯云 COS）。`Windows/update-channel.json` 支持 `manifestURLs` 数组，可以把国内清单放在第一位、GitHub 放在第二位，两个平台会依次尝试。只要清单中的安装包地址仍指向 GitHub，aria2 只能改善“可以访问但速度慢”的情况，不能解决网络完全不可达。

不要删除或改名 `update.json`，也不要把测试版错误设置为 Latest；客户端始终通过 `releases/latest/download/update.json` 找最新版。

## 日常维护建议

- `main` 分支只放通过测试、可发布的代码；大改动建立单独分支，通过 Pull Request 合并。
- 每个问题建一个 Issue，说明复现链接、系统版本、软件版本和日志。
- 每次发布必须让 `scripts/test-all-platforms.sh` 通过，避免只修复一个平台。
- `dist/`、`build/`、`.build/` 和 `node_modules/` 不提交到仓库；成品放 GitHub Releases。
- 不要把登录 Cookie、账号信息、Apple 证书或令牌提交到仓库。签名证书应放到 GitHub Actions Secrets。
- 正式公开分发前，建议给 Windows 程序做代码签名，并使用 Apple Developer ID 对 macOS 应用签名、公证，以减少 SmartScreen 和 Gatekeeper 提示。

## 本地生成统一更新清单

如果不使用 GitHub Actions，先保留上一版与新版的完整 ZIP，然后分别生成增量包：

```bash
node scripts/create-delta-package.mjs \
  --platform macos \
  --from previous/BiliFetch-macOS-1.5.10.zip \
  --to dist/BiliFetch-macOS-1.5.11.zip \
  --output dist/BiliFetch-macOS-delta-1.5.10-to-1.5.11.zip

node scripts/create-delta-package.mjs \
  --platform windows \
  --from previous/BiliFetch-Windows-x64-1.1.3.zip \
  --to dist/BiliFetch-Windows-x64-1.1.4.zip \
  --output dist/BiliFetch-Windows-x64-delta-1.1.3-to-1.1.4.zip
```

如果增量 ZIP 不比完整包小，脚本会自动放弃该增量包。存在增量包时，再把它们一并写入更新清单：

```bash
node scripts/create-release-manifest.mjs \
  --windows dist/BiliFetch-Windows-x64-1.1.4.zip \
  --windows-url https://你的下载地址/BiliFetch-Windows-x64-1.1.4.zip \
  --windows-delta dist/BiliFetch-Windows-x64-delta-1.1.3-to-1.1.4.zip \
  --windows-delta-url https://你的下载地址/BiliFetch-Windows-x64-delta-1.1.3-to-1.1.4.zip \
  --macos dist/BiliFetch-macOS-1.5.11.zip \
  --macos-url https://你的下载地址/BiliFetch-macOS-1.5.11.zip \
  --macos-delta dist/BiliFetch-macOS-delta-1.5.10-to-1.5.11.zip \
  --macos-delta-url https://你的下载地址/BiliFetch-macOS-delta-1.5.10-to-1.5.11.zip \
  --notes Updates/release-notes-2026-09-05-2.md \
  --output dist/update.json
```

把完整 ZIP、实际生成的增量 ZIP 与 `update.json` 上传到同一次发布。没有生成某个平台的增量包时，删掉该平台的两个 `--*-delta` 参数；客户端会自动使用完整包。
