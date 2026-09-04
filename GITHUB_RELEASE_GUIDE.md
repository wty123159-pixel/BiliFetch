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
4. 计算两个 ZIP 的 SHA-256，生成统一的 `update.json`。
5. 创建 GitHub Release，并上传两个安装包和更新清单。

当前本地构建包还不知道未来仓库用户名，所以源码中的 `Windows/update-channel.json` 暂时留空。不要把这个本地包作为正式的“在线升级起始版”长期分发。仓库创建后，从 Actions 运行第一次正式发布；工作流会把真实仓库地址写进 macOS 与 Windows 安装包。用户只需手动安装这次正式起始版，后续版本就能在软件内升级。

已经安装本地测试包的用户，也可以在“高级设置”中手动填写上面的 `update.json` 地址，不必再次打包。

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

客户端不会接收代码仓库里的源文件，而是读取 Latest Release 中固定名称的 `update.json`。它比较当前平台版本后，下载清单中对应的 ZIP、核对 SHA-256，再退出、替换程序并重新打开；两个平台的账号登录、设置与未完成任务都保存在用户数据目录，不会随程序包替换而删除。

不要删除或改名 `update.json`，也不要把测试版错误设置为 Latest；客户端始终通过 `releases/latest/download/update.json` 找最新版。

## 日常维护建议

- `main` 分支只放通过测试、可发布的代码；大改动建立单独分支，通过 Pull Request 合并。
- 每个问题建一个 Issue，说明复现链接、系统版本、软件版本和日志。
- 每次发布必须让 `scripts/test-all-platforms.sh` 通过，避免只修复一个平台。
- `dist/`、`build/`、`.build/` 和 `node_modules/` 不提交到仓库；成品放 GitHub Releases。
- 不要把登录 Cookie、账号信息、Apple 证书或令牌提交到仓库。签名证书应放到 GitHub Actions Secrets。
- 正式公开分发前，建议给 Windows 程序做代码签名，并使用 Apple Developer ID 对 macOS 应用签名、公证，以减少 SmartScreen 和 Gatekeeper 提示。

## 本地生成统一更新清单

如果不使用 GitHub Actions，也可以在两个 ZIP 构建完成后手动执行：

```bash
node scripts/create-release-manifest.mjs \
  --windows dist/BiliFetch-Windows-x64-1.1.1.zip \
  --windows-url https://你的下载地址/BiliFetch-Windows-x64-1.1.1.zip \
  --macos dist/BiliFetch-macOS-1.5.8.zip \
  --macos-url https://你的下载地址/BiliFetch-macOS-1.5.8.zip \
  --notes Updates/release-notes-1.1.0.md \
  --output dist/update.json
```

把两个 ZIP 与 `update.json` 上传到同一次发布即可。
