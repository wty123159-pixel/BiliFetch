# 视频号本机播放捕获

macOS SwiftUI 与 Windows Electron 共用独立 Go 组件。默认关闭；用户确认后，为当前用户信任本机生成的专用证书，并临时设置系统 HTTP/HTTPS 代理。开启时读取原代理，按原地址和端口接续转发；本机捕获端口自动分配。关闭捕获、正常退出和应用内升级前恢复原设置，异常中断后在下次启动恢复。主动 PAC 脚本、需要认证或多组冲突代理尚待适配；Windows 默认自动检测及无代理状态可直接启用，不强制关闭用户原代理。

## 只收录实际播放的作品

1. 详情、推荐和预加载响应只建立有界候选表，收到数据不生成捕获记录。
2. 需要 playing 事件、播放时间前进、页面及视频可见；同时存在多个可见播放器时不选择。
3. 普通媒体要求播放地址唯一匹配；MSE/blob 还需要播放器当前作品索引，在 playing 事件时绑定，后续预加载或索引变化不能给旧 blob 改作品身份。
4. 无法确认身份时跳过并记录诊断，不选择最近返回的推荐作品兜底。
5. 捕获列表默认不勾选，用户选择后加入现有下载队列。

桥返回的 jsapi_resp.resp_json 按受限字段解析，兼容原始 snake_case 与页面整理后的 camelCase。通过页面已经引用的模块及 Pinia 的 home 标识读取当前作品，不依赖压缩后的导出别名，也不替换微信 JavaScript 内容。

2026-09-23 已在 macOS 26.2、微信 4.1.9 真机验证：页面正常显示和播放，24 条候选中只收录当前 1 条作品；用户确认捕获正确。实际下载 165.8 秒作品，最高明示档位 720×1280、HEVC + AAC；FFprobe 检查完整媒体包，并用 macOS AVFoundation 完整解码视频与音频。此前默认 CDN 地址仅返回 576×1024，现已避免把上传原件尺寸误标成默认下载画质。Windows 仅完成共享组件测试、交叉编译、Electron 运行时和安装包结构验证，未做 Windows 真机微信播放、下载或网络恢复实测。单例不代表所有微信版本和作品均兼容。

## 数据与下载

- 只对 channels.weixin.qq.com、res.wx.qq.com 建立本机 TLS 转发；仅在视频号 HTML 加入独立捕获脚本，微信原 JavaScript 保持不变。其他 HTTPS 流量保持隧道转发。
- 只保存作品标题、封面、ID、平台明示的画质与媒体还原参数，不保存聊天、Cookie、账号密码或整份桥响应。
- 页面上报凭据与本机控制、下载凭据分离。捕获数据只放在用户应用数据目录 WeChatCapture/Captures，macOS 使用 0700/0600 权限。
- 每次下载重新生成私有 yt-dlp info JSON；媒体经本机随机端口提供，原 CDN 参数不进入 UI 或诊断报告。
- ISAAC64 前缀还原支持非整块 Range 偏移；沿用 yt-dlp/aria2、最高可用画质、进度、续传、FFprobe 校验，不修改水印参数。
- 优先使用平台 spec 明示的最高可用档位；未指定档位的 CDN 默认地址只作为低优先级备用，不把上传原件的尺寸或文件大小当成该地址的实际结果。适配器 2 兼容读取适配器 1 的捕获记录。
- 暂不支持图集、直播或访问受限内容。分享短链用于引导打开捕获入口，不承诺匿名直链解析。

## 构建与验证

Go 1.27.1 或更新版本，零外部 Go 模块。GO_BIN 可指定编译器，本地也可使用 .build/toolchains/go/bin/go。

- `zsh scripts/build-wechat-capture.sh all`：macOS 双架构及 Windows x64。
- `zsh scripts/build-wechat-capture.sh test`：竞态、隔离 TLS、代理、媒体测试及 Windows 交叉编译。
- `node --test scripts/tests/wechat-capture.test.mjs`：播放确认、预加载排除。
- BILIFETCH_TEST_ROOT 与 BILIFETCH_TEST_MEDIA 启用内置下载器本地媒体续传测试，不连接微信或修改系统信任。
- Electron 测试覆盖子进程、本机接口、重启后下载凭据刷新及既有 ASAR 更新链路。

真实系统测试须取得用户对证书信任与临时代理的授权。关闭捕获只恢复代理，证书仍留在本机。测试证书应按精确指纹移除，不按模糊名称批量删除。

本次真机测试结束后已核实 HTTP/HTTPS/SOCKS 回到原设置，恢复记录已移除，测试证书已按 SHA-256 指纹从当前用户钥匙串删除。诊断导出不包含媒体 URL、还原参数或账号凭据。可选静态资源诊断只保存公开脚本及去查询参数的资源位置，默认关闭，交付包不包含本机诊断数据。

参考来源：
- https://github.com/qiye45/wechatVideoDownload （用户提供的软件行为参考）
- https://github.com/ltaoo/wx_channels_download （播放器接口结构参考，未打包其源码或二进制）
- https://burtleburtle.net/bob/c/isaac64.c （Bob Jenkins，Public Domain；独立 C 向量核对）
- https://github.com/actions/setup-go （构建环境）

### 2026-09-24 Windows 代理修复

Windows 改为原生 WinINet `InternetQueryOptionW` / `InternetSetOptionW`，不再通过 PowerShell 合并输出解析代理 JSON。保存和恢复手动代理、绕过列表、PAC 地址和自动检测标志；默认自动检测只在捕获期间暂时关闭，停止时恢复。支持旧版恢复记录，包括干净系统没有注册表代理键时省略的空记录。现存代理端口动态读取，捕获使用空闲端口，不固定为 7897。

已在 Windows 11 ARM64 虚拟机运行 x64 组件，实际验证原生读取、直连模式、自动检测、启用、停止和异常恢复记录；未在 Windows 微信账号完成播放捕获与下载验收。详细测试和成品哈希见 `Updates/validation-2026-09-24.md`。
