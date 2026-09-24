# 2026-09-24 修复与验证记录

## 交付范围

基于提交 `67d7006b712ea5066abb6e3dc84a22e0048fed15` 继续修改；当前公开基线为 `v2026.09.23-3`。本次软件版本为 macOS **1.5.17 / Build 27**、Windows **1.1.11**。建议发布 Tag **v2026.09.24**，尚未提交、推送或创建 Release。`dist/update.json` 是本地待发布清单，里面的新 Tag 下载地址需要正式发布后才生效。

1. Windows 代理改用原生 WinINet 接口，避免 PowerShell 混合输出破坏 JSON 解析。用户诊断中的“无法读取系统代理设置”对应旧版 JSON 解析失败；原报告没有保存失败输出，不能断言用户那一次的具体干扰内容。在本机 Windows 11 虚拟机观察到了 PowerShell 首次模块加载将 CLIXML 进度写入 stderr 的现象，旧版合并 stdout/stderr 的方式确实易受影响。
2. 无外部代理直接联网；默认自动检测不再拒绝捕获。保存完整网络状态，开启时使用动态空闲端口，关闭、部分失败及重启恢复时还原。兼容历史恢复记录，保留主动 PAC 和认证代理的明确限制。
3. 捕获窗口改为按可用宽高排版，文字换行、按钮完整显示、作品列表独立滚动。
4. 两端更新清单和更新文件均增加官方 GitHub Release API 备用通道；严格匹配仓库、Tag 与同名文件，匿名访问，无内置令牌或公共代理，保留 SHA-256、增量回退、累计更新说明及自有 HTTPS 更新源配置。
5. Windows 主程序改为“记住你宇哥.exe”，PE 名称及多尺寸图标与源资产一致。保留小型 BiliFetch.exe 兼容入口。ZIP 中文文件名显式 UTF-8，发布包根目录及应用数据路径不变。首次改名需要将主程序作为新文件分发，所以本次 Windows 增量包较大，仍小于完整包。

## 已执行验证

- macOS 26.2 ARM64：163 项 Swift 检查；新增 Swift 更新传输测试覆盖主地址不可达、API 头、缓存、资产验证失败及拒绝草稿。通过真实 URLSession 禁用代理并模拟主地址不可达，成功取得已发布更新清单。
- Go 竞态测试通过；共享代理配置覆盖直连、自动检测、任意代理端口、独立 HTTP/HTTPS、IPv6、旧记录恢复、部分失败回滚和外部变更。
- 双平台总检查通过：17 项 Python 解析测试、31 项共享 Node 检查、72 项 Windows Node 测试（71 通过、1 项需 Electron 的检查跳过），另在真实 Electron 44 运行时执行 13 项更新/ASAR/捕获组件测试，全部通过。
- macOS 上 Electron 实际渲染与 Windows 11 ARM64 虚拟机上的 x64 Electron 均检查 960×680、720×520、534×500、480×640、534×384 五种可用窗口尺寸。未发生横向溢出，关闭、捕获、诊断、清空和加入按钮可见，作品列表能独立滚动。列表使用测试数据，并非微信捕获实测。
- 两种 Electron 环境均将该测试会话设置为直连，并人为阻断主下载域名；通过官方 API 真实下载 6,446,940 字节已发布增量包，SHA-256 为 `2718527c55b1530eb78b33440517751ccea3818b2497a40e7c8d61e501a7f277`，一致。
- Windows 11 10.0.26200.9457 ARM64 虚拟机：运行 x64 Go 组件，真实调用 WinINet，验证默认自动检测、纯直连、临时代理启用及恢复。测试不安装系统证书；原代理状态已恢复。Windows 环境缺少 C 编译器及 macOS 媒体工具的两项共享测试按条件跳过。
- Windows 旧版兼容入口已实际启动新的中文文件名程序并完成五种尺寸的渲染检查。Windows 解压后读取 ProductName、FileDescription、OriginalFilename 与 FileVersion，分别为“记住你宇哥”、“记住你宇哥”、“记住你宇哥.exe”、1.1.11。构建逐字节核对主程序与兼容入口的 16/32/48/256 尺寸图标资源。
- macOS 通用应用编译、完整签名校验通过；Windows x64 成品构建通过。两个增量包从已公开的上一版本完整 ZIP 生成，生成过程实际重建并比较所有文件、模式和哈希。

## 异常及边界

本轮两次带媒体集成的总检查曾在原 30 秒上限处结束，首次两种下载方式超时、第二次 aria2 超时；单项复跑通过。另行计时发现内置 yt-dlp 仅执行 `--version` 需要约 24.19 秒。因此将这项本地集成测试的启动加下载总上限改为 90 秒，软件网络超时保持独立，最终总检查通过。最初失败和分项复跑日志均保留；耗时变长的系统底层原因未进一步确定。

下载历史完整包用于生成增量时，直连 curl 遇到 HTTP/2 framing 错误和大文件超时；最终通过本机既有开发代理获取历史基线，并匹配公开清单 SHA-256。这与上面的无代理 6.4 MB 实际下载测试分开记录，不能宣称所有大陆网络或所有大文件下载已通过。用户暂未提供国内服务器，所以备用通道仍依赖 GitHub 官方基础设施；旧版若完全连不上更新入口，需先手动安装本次完整包一次。

未在 Windows 微信账号完成目标作品播放、捕获、完整下载、用户电脑休眠恢复和原地升级重启验收；Windows ARM64 虚拟机运行 x64 程序也不等同于 Windows x64 物理机。此前 macOS 的真实作品下载属于历史验证，本次没有重新下载账号作品。去水印、快手、迅雷 SDK 与后台解析账号未加入。

## 本地成品

- `/Users/santoswang/.codex/.chatgpt-projects/g-p-6aa2778237748191a7f4ec682a4ee073/BiliFetch/dist/BiliFetch-Windows-x64-1.1.11.zip` — 228,246,412 bytes；SHA-256 `611acda6eca733911c4a92e565d6e30121aa9acaa7596fa35f1e73c9628f8a80`。
- `/Users/santoswang/.codex/.chatgpt-projects/g-p-6aa2778237748191a7f4ec682a4ee073/BiliFetch/dist/BiliFetch-Windows-x64-delta-1.1.10-to-1.1.11.zip` — 113,630,481 bytes；SHA-256 `b426807b85594ce273cdafe5819b13a8f03fa68d2f5536bdd0f42503d06369ab`。
- `/Users/santoswang/.codex/.chatgpt-projects/g-p-6aa2778237748191a7f4ec682a4ee073/BiliFetch/dist/BiliFetch-macOS-1.5.17.zip` — 54,551,758 bytes；SHA-256 `6410b5753df320d615382a6ee4399ebd8d013d1ac122b8c7fae68ade29742945`。
- `/Users/santoswang/.codex/.chatgpt-projects/g-p-6aa2778237748191a7f4ec682a4ee073/BiliFetch/dist/BiliFetch-macOS-delta-1.5.16-to-1.5.17.zip` — 8,089,335 bytes；SHA-256 `484f9e678a416a196eddf6d9991b1da52589e5c3754a7e37b623d51f7dfad62c`。

详细日志和渲染截图：`.build/windows-network-fix/`。更新清单：`dist/update.json`。

便捷交付目录：`/Users/santoswang/Downloads/记住你宇哥-2026-09-24`（与 dist 成品逐一核对一致）。

测试结束后已关闭临时文件传输服务，将 Windows 虚拟机恢复为原来的停止状态。宿主 macOS 的系统代理设置未变更。
