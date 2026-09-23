# Third-party components

BiliFetch invokes separately distributed command-line tools and does not modify their source code.

- yt-dlp: <https://github.com/yt-dlp/yt-dlp> (Unlicense; bundled builds also include their own third-party notices)
- FFmpeg 7.1.5: <https://github.com/FFmpeg/FFmpeg/tree/n7.1.5> (LGPL 2.1 or later). Its license text is included in `ThirdPartyLicenses/FFmpeg-COPYING.LGPLv2.1`.
- aria2 1.37.0: <https://github.com/aria2/aria2/releases/tag/release-1.37.0> (GNU GPL version 2 or later). Its license text is included in `ThirdPartyLicenses/aria2-COPYING`; the corresponding source archive and build notes are included in `ThirdPartySource`.

Users are responsible for complying with the licenses of any components they install or redistribute.
# 视频号本机捕获组件

BiliFetch 自行实现页面播放确认、候选过滤、本机代理和下载接入。运行时使用 Go 标准库（BSD 3-Clause，随包提供 Go-LICENSE）。
ISAAC-64 算法依据 Bob Jenkins 1996 年公开领域实现：https://burtleburtle.net/bob/c/isaac64.c 。独立 C 参考向量仅用于测试。
参考过 qiye45/wechatVideoDownload 与 ltaoo/wx_channels_download 的公开行为及协议说明；未打包其软件、证书、私钥或源码。
