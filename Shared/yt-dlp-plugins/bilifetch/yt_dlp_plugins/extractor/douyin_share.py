"""BiliFetch's public Douyin video/share adapter.

The desktop apps ship this file beside their existing standalone yt-dlp.
Media URLs are used exactly as supplied by the page: no watermark rewriting,
invented quality URLs, signatures, or third-party parsing services.
"""

import json
import re
from urllib.parse import parse_qs, unquote, urlsplit

from yt_dlp.extractor.common import InfoExtractor
from yt_dlp.utils import ExtractorError

__all__ = ["BiliFetchDouyinIE"]

_MOBILE_UA = (
    "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 "
    "Mobile/15E148 Safari/604.1"
)
_FEED_UA = (
    "com.ss.android.ugc.aweme/290101 (Linux; U; Android 10; zh_CN; Pixel 4; "
    "Build/QQ3A.200805.001; Cronet/TTNetVersion:5f9037be 2023-01-13 "
    "QuicVersion:4668bb42 2022-11-21)"
)
_FEED_ENDPOINTS = (
    "https://api5-normal-c-hl.amemv.com/aweme/v1/feed/",
    "https://aweme.snssdk.com/aweme/v1/feed/",
)
_UNAVAILABLE = (
    "BILIFETCH_DOUYIN: 暂时无法免登录读取这条抖音作品。"
    "请稍后重试或重新复制作品分享链接；私密、已删除或受限作品可能无法下载。"
)


def video_id(url):
    parsed = urlsplit(url)
    host = (parsed.hostname or "").lower()
    if not any(host == base or host.endswith("." + base) for base in ("douyin.com", "iesdouyin.com")):
        return None
    match = re.search(r"/(?:share/)?video/(\d+)(?:/|$)", parsed.path)
    if match:
        return match.group(1)
    modal = parse_qs(parsed.query).get("modal_id", [""])[0]
    return modal if re.fullmatch(r"\d+", modal) else None


def page_states(webpage):
    """Decode data, never execute scripts from the remote page."""
    decoder = json.JSONDecoder()
    for match in re.finditer(r"(?:window\.)?_ROUTER_DATA\s*=\s*", webpage):
        try:
            state, _ = decoder.raw_decode(webpage[match.end():])
            yield state
        except (ValueError, RecursionError):
            continue
    for match in re.finditer(
        r'<script\b[^>]*\bid=["\']RENDER_DATA["\'][^>]*>(.*?)</script>',
        webpage, re.DOTALL | re.IGNORECASE,
    ):
        try:
            yield json.loads(unquote(match.group(1).strip()))
        except (ValueError, RecursionError):
            continue


def find_video(states, wanted_id):
    # A page can also contain recommendations. Match the requested work's ID
    # before reading any media URLs; never download a nearby recommendation.
    pending = list(states)
    visited = 0
    while pending and visited < 10000:
        value = pending.pop()
        visited += 1
        if isinstance(value, dict):
            identifier = value.get("aweme_id", value.get("awemeId"))
            if str(identifier) == wanted_id and isinstance(value.get("video"), dict):
                return value
            pending.extend(v for v in value.values() if isinstance(v, (dict, list)))
        elif isinstance(value, list):
            pending.extend(v for v in value if isinstance(v, (dict, list)))
    return None


def _number(value, scale=1):
    try:
        number = float(value) / scale
        return number if 0 <= number < float("inf") else None
    except (TypeError, ValueError, OverflowError):
        return None


def _url(value):
    if not isinstance(value, str):
        return None
    try:
        parsed = urlsplit(value)
        if parsed.scheme in ("http", "https") and parsed.hostname and not parsed.username:
            return value
    except ValueError:
        pass
    return None


def video_info(item, wanted_id, webpage_url, user_agent=_MOBILE_UA):
    if item.get("images") or item.get("aweme_type") in (68, 150):
        raise ExtractorError(
            "BILIFETCH_DOUYIN: 这是一条图文作品；当前支持抖音视频，暂不支持图集或直播。",
            expected=True,
        )
    video = item.get("video") or {}
    formats, seen = [], set()

    def add_address(address, name, bitrate=None, codec=None):
        if not isinstance(address, dict):
            return
        for index, raw in enumerate(address.get("url_list") or []):
            url = _url(raw)
            if not url or url in seen:
                continue
            seen.add(url)
            formats.append({
                "format_id": f"{name}-{index}",
                "url": url,
                "ext": "mp4",
                "width": _number(address.get("width", video.get("width"))),
                "height": _number(address.get("height", video.get("height"))),
                "filesize": _number(address.get("data_size")),
                "tbr": _number(bitrate, 1000),
                "vcodec": codec,
                # Equal-quality URLs are mirrors. Prefer the first CDN address
                # instead of the last redirect API merely sorting last by ID.
                "source_preference": -index,
            })

    # Enumerate only formats actually provided by this work. The existing
    # yt-dlp quality selector chooses the highest available rendition.
    for index, rate in enumerate(video.get("bit_rate") or []):
        if isinstance(rate, dict):
            codec = "hevc" if rate.get("is_h265") == 1 else None
            add_address(rate.get("play_addr"), f"rate-{index}", rate.get("bit_rate"), codec)
    add_address(video.get("play_addr_h264"), "h264", codec="avc1")
    add_address(video.get("play_addr_265"), "h265", codec="hevc")
    add_address(video.get("play_addr"), "play")
    if not formats:
        return None
    covers = (video.get("cover") or video.get("origin_cover") or {}).get("url_list") or []
    author = item.get("author") or {}
    return {
        "id": wanted_id,
        "title": item.get("desc") or f"抖音视频 {wanted_id}",
        "description": item.get("desc"),
        "webpage_url": webpage_url,
        "uploader": author.get("nickname"),
        "uploader_id": str(author.get("uid") or author.get("sec_uid") or ""),
        "timestamp": _number(item.get("create_time")),
        "duration": _number(video.get("duration", item.get("duration")), 1000),
        "thumbnail": next((u for raw in covers if (u := _url(raw))), None),
        "formats": formats,
        # MP4 is already compressed. HTTP gzip hides its content length from
        # aria2, preventing byte-based progress and resumable range requests.
        "http_headers": {
            "User-Agent": user_agent, "Referer": webpage_url, "Accept-Encoding": "identity",
        },
    }


class BiliFetchDouyinIE(InfoExtractor):
    IE_NAME = "BiliFetch:Douyin"
    _VALID_URL = r"https?://(?:[A-Za-z0-9-]+\.)*(?:douyin|iesdouyin)\.com(?:[/?#]|$)"

    def _real_extract(self, url):
        if re.search(r"/(?:share/)?note/", urlsplit(url).path):
            raise ExtractorError(
                "BILIFETCH_DOUYIN: 这是一条图文作品；当前支持抖音视频，暂不支持图集或直播。",
                expected=True,
            )
        identifier = video_id(url)
        webpage = None
        if not identifier:
            if urlsplit(url).hostname != "v.douyin.com":
                raise ExtractorError(
                    "BILIFETCH_DOUYIN: 请分享具体的视频作品，当前不支持作者主页、图集或直播。",
                    expected=True,
                )
            webpage, response = self._download_webpage_handle(
                url, "share", note="正在展开抖音分享链接", headers={"User-Agent": _MOBILE_UA},
            )
            identifier = video_id(response.url)
            if not identifier:
                raise ExtractorError(
                    "BILIFETCH_DOUYIN: 分享链接未指向有效视频，可能已过期或需要验证，请重新复制作品链接。",
                    expected=True,
                )

        canonical = f"https://www.douyin.com/video/{identifier}"
        # Public mobile feed requests do not require account cookies. The
        # response can include recommendations, so require an exact ID match.
        for endpoint in _FEED_ENDPOINTS:
            data = self._download_json(
                endpoint, identifier, note="正在免登录读取抖音作品",
                query={"aweme_id": identifier, "aid": "1128"},
                headers={"User-Agent": _FEED_UA, "Accept": "application/json"},
                fatal=False,
            )
            if not isinstance(data, dict) or data.get("status_code") != 0:
                continue
            item = find_video([data.get("aweme_list")], identifier)
            if item:
                info = video_info(item, identifier, canonical, _FEED_UA)
                if info:
                    return info

        item = find_video(page_states(webpage or ""), identifier)
        if not item:
            share_page = self._download_webpage(
                f"https://www.iesdouyin.com/share/video/{identifier}/", identifier,
                note="正在读取抖音作品页面", headers={"User-Agent": _MOBILE_UA}, fatal=False,
            )
            item = find_video(page_states(share_page or ""), identifier)
        if item:
            info = video_info(item, identifier, canonical)
            if info:
                return info

        raise ExtractorError(_UNAVAILABLE, expected=True)
