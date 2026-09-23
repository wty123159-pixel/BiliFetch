# 共享抖音解析器

源文件位于 yt-dlp-plugins/bilifetch/yt_dlp_plugins/extractor/douyin_share.py。
macOS 和 Windows 构建均复制这同一文件到 Resources/resources 下的
yt-dlp-plugins 目录，由已内置的 yt-dlp 加载；Windows 目录必须位于
app.asar 外，外部下载进程才能读取。

先以移动端协议读取公开 feed 接口，再回退备用节点和分享页 JSON。
无需登录或提供 Cookie，不读取浏览器账号，也不回退到要求用户登录的流程。
只解析所请求视频 ID 对应的数据，不执行页面脚本，不选择推荐作品，
不改写水印或清晰度参数。列出接口实际返回的码率与分辨率，由既有
yt-dlp 画质规则选择最高可用格式；同画质优先选择首个 CDN 地址。
视频传输使用 Accept-Encoding: identity，避免 gzip 隐藏文件大小，
使 aria2 能持续计算百分比并保存可续传的分段状态。
当前不实现图集、直播、账号主页和第三方解析服务。

开发测试运行 zsh scripts/test-douyin-extractor.sh。测试依赖与已内置
下载器同版本的 yt-dlp 2026.08.19，仅安装到 .build/douyin-python，
不会成为成品的外部依赖。Tests/Fixtures/share-links.json 是两端共用
的输入回归样例；Tests/Extractor 使用合成页面验证解析、回退与画质选择。
这些离线测试不等于 Windows 真机实测。2026-09-23 已用内置 macOS
下载器免登录下载用户作品 7688293605819075875，并通过 FFprobe 检查。
同一作品的 aria2 中断续传已完成，恢复后的文件 SHA-256 与独立完整
下载一致；实际采集到中间进度。这项验证在 macOS 主机执行，
使用 Windows 参数构造逻辑与 macOS 内置工具，不等于 Windows 真机。

参考 yt-dlp 官方插件接口：https://github.com/yt-dlp/yt-dlp#plugins
移动端接口协议参考：https://github.com/ucmao/media-parser/blob/main/docs/parsers/douyin.md
本实现独立编写，未引入该项目的水印改写、签名或浏览器 Cookie 处理。
