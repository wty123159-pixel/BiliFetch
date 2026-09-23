"""Offline extraction/dispatch regressions; no user cookies or network."""
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import Mock
from urllib.parse import quote

from yt_dlp import YoutubeDL
from yt_dlp.utils import ExtractorError

ROOT = Path(__file__).resolve().parents[2]
PLUGIN = ROOT / "Shared/yt-dlp-plugins/bilifetch/yt_dlp_plugins/extractor/douyin_share.py"
spec = importlib.util.spec_from_file_location("bilifetch_douyin", PLUGIN)
dy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dy)
ID = "7688293605819075875"
URL = f"https://www.douyin.com/video/{ID}"


def item():
    return {
        "aweme_id": ID, "desc": "回归测试视频",
        "author": {"nickname": "测试作者", "uid": "123"},
        "create_time": 1790000000,
        "video": {
            "width": 1080, "height": 1920, "duration": 12340,
            "cover": {"url_list": ["https://p3.douyinpic.com/fixture.jpg"]},
            "play_addr": {"url_list": ["https://v.example.test/playwm/?id=fixture&ratio=720p"], "width": 720, "height": 1280},
            "bit_rate": [
                {"bit_rate": 4000000, "play_addr": {
                    "url_list": ["https://v.example.test/high.mp4?token=keep%2Fexact"],
                    "width": 1080, "height": 1920, "data_size": 6000000,
                }},
                {"bit_rate": 1500000, "play_addr": {
                    "url_list": ["https://v.example.test/low.mp4"],
                    "width": 720, "height": 1280,
                }},
            ],
        },
    }


def router_html(work=None):
    return "<script>window._ROUTER_DATA = " + json.dumps({
        "loaderData": {"video_(id)/page": {"videoInfoRes": {"item_list": [work or item()]}}}
    }) + ";</script>"


class DouyinShareTests(unittest.TestCase):
    def test_extracts_ids_only_from_platform_urls(self):
        for url in [URL, f"https://www.iesdouyin.com/share/video/{ID}/", f"https://www.douyin.com/?modal_id={ID}"]:
            self.assertEqual(dy.video_id(url), ID)
        for url in [f"https://douyin.com.evil.test/video/{ID}", f"https://www.douyin.com/video/{ID}junk",
                    f"https://www.douyin.com/user/{ID}", f"https://www.douyin.com/note/{ID}"]:
            self.assertIsNone(dy.video_id(url))

    def test_router_json_handles_escaped_slashes_and_braces_in_title(self):
        work = item()
        work["desc"] = '标题包含 } </script-like> 与 "引号"'
        parsed = dy.find_video(dy.page_states(router_html(work)), ID)
        self.assertEqual(parsed["desc"], work["desc"])

    def test_encoded_render_data(self):
        html = '<script type="application/json" id="RENDER_DATA">' + quote(json.dumps({"aweme": {"detail": item()}})) + "</script>"
        self.assertEqual(dy.find_video(dy.page_states(html), ID)["aweme_id"], ID)

    def test_ignores_malformed_data_without_executing_it(self):
        self.assertEqual(list(dy.page_states("<script>window._ROUTER_DATA = alert('x')</script>")), [])

    def test_never_selects_a_recommended_video(self):
        work = item()
        work["aweme_id"] = "999"
        self.assertIsNone(dy.find_video(dy.page_states(router_html(work)), ID))

    def test_formats_preserve_exact_media_urls_and_metadata(self):
        info = dy.video_info(item(), ID, URL)
        self.assertEqual(info["duration"], 12.34)
        self.assertEqual(info["webpage_url"], URL)
        self.assertEqual(info["uploader"], "测试作者")
        self.assertEqual(len(info["formats"]), 3)
        self.assertEqual(info["formats"][0]["height"], 1920)
        self.assertEqual(info["formats"][0]["tbr"], 4000)
        self.assertEqual(info["formats"][0]["filesize"], 6000000)
        self.assertIn("token=keep%2Fexact", info["formats"][0]["url"])
        self.assertIn("/playwm/", info["formats"][-1]["url"])
        self.assertIn("ratio=720p", info["formats"][-1]["url"])
        self.assertEqual(info["http_headers"]["Accept-Encoding"], "identity")

    def test_invalid_media_and_missing_formats_do_not_become_success(self):
        work = item()
        work["video"] = {"play_addr": {"url_list": ["file:///tmp/a.mp4", "javascript:alert(1)"]}}
        self.assertIsNone(dy.video_info(work, ID, URL))

    def test_picture_work_is_not_mistaken_for_a_video(self):
        work = item()
        work["images"] = [{"uri": "picture"}]
        with self.assertRaisesRegex(ExtractorError, "图文作品"):
            dy.video_info(work, ID, URL)

    def test_real_ytdlp_selector_chooses_highest_available_format(self):
        info = dy.video_info(item(), ID, URL)
        with YoutubeDL({"quiet": True, "format": "bv*+ba/b", "check_formats": False}) as ydl:
            result = ydl.process_ie_result(info, download=False)
        self.assertEqual(result["height"], 1920)
        self.assertEqual(result["url"], "https://v.example.test/high.mp4?token=keep%2Fexact")

    def test_short_link_dispatches_to_matching_work(self):
        with YoutubeDL({"quiet": True}) as ydl:
            ie = dy.BiliFetchDouyinIE(ydl)
            ie._download_webpage_handle = Mock(return_value=(router_html(), SimpleNamespace(url=f"https://www.iesdouyin.com/share/video/{ID}/")))
            ie._download_json = Mock(return_value={"status_code": 2154})
            ie._download_webpage = Mock(side_effect=AssertionError("No second fetch is needed"))
            result = ie._real_extract("https://v.douyin.com/V3t4RyEfLUo/")
            self.assertEqual(result["id"], ID)
            self.assertEqual(result["webpage_url"], URL)

    def test_unexpected_redirect_never_becomes_media(self):
        with YoutubeDL({"quiet": True}) as ydl:
            ie = dy.BiliFetchDouyinIE(ydl)
            ie._download_webpage_handle = Mock(return_value=("", SimpleNamespace(url=f"https://evil.test/video/{ID}")))
            with self.assertRaisesRegex(ExtractorError, "未指向有效视频"):
                ie._real_extract("https://v.douyin.com/expired/")

    def test_mobile_feed_needs_no_browser_and_matches_exact_work(self):
        with YoutubeDL({"quiet": True}) as ydl:
            ie = dy.BiliFetchDouyinIE(ydl)
            recommendation = item()
            recommendation["aweme_id"] = "999"
            ie._download_json = Mock(return_value={"status_code": 0, "aweme_list": [recommendation, item()]})
            ie._download_webpage = Mock(side_effect=AssertionError("Feed already returned the work"))
            result = ie._real_extract(URL)
            self.assertEqual(result["id"], ID)
            self.assertEqual(result["http_headers"]["User-Agent"], dy._FEED_UA)
            args = ie._download_json.call_args
            self.assertEqual(args.kwargs["query"], {"aweme_id": ID, "aid": "1128"})
            self.assertNotIn("Cookie", args.kwargs["headers"])
            self.assertIsNone(ydl.params.get("cookiesfrombrowser"))

    def test_missing_work_tries_backup_and_never_returns_recommendations(self):
        with YoutubeDL({"quiet": True}) as ydl:
            ie = dy.BiliFetchDouyinIE(ydl)
            recommendation = item()
            recommendation["aweme_id"] = "999"
            ie._download_json = Mock(side_effect=[
                {"status_code": 0, "aweme_list": [recommendation]},
                {"status_code": 0, "aweme_list": [item()]},
            ])
            result = ie._real_extract(URL)
            self.assertEqual(result["id"], ID)
            self.assertEqual([c.args[0] for c in ie._download_json.call_args_list], list(dy._FEED_ENDPOINTS))

    def test_failed_feed_falls_back_to_anonymous_share_page(self):
        with YoutubeDL({"quiet": True}) as ydl:
            ie = dy.BiliFetchDouyinIE(ydl)
            ie._download_json = Mock(side_effect=[None, {"status_code": 2154, "aweme_list": [item()]}])
            ie._download_webpage = Mock(return_value=router_html())
            self.assertEqual(ie._real_extract(URL)["id"], ID)
            self.assertEqual(ie._download_json.call_count, 2)

    def test_equal_quality_prefers_first_cdn_and_keeps_higher_quality(self):
        work = item()
        work["video"]["bit_rate"][0]["is_h265"] = 1
        work["video"]["bit_rate"][0]["play_addr"]["url_list"].append("https://redirect.example.test/video")
        info = dy.video_info(work, ID, URL)
        with YoutubeDL({"quiet": True, "format": "bv*+ba/b", "check_formats": False}) as ydl:
            result = ydl.process_ie_result(info, download=False)
        self.assertEqual(result["height"], 1920)
        self.assertEqual(result["url"], "https://v.example.test/high.mp4?token=keep%2Fexact")
        self.assertEqual(result["vcodec"], "hevc")

    def test_blocked_page_reports_actionable_failure(self):
        with YoutubeDL({"quiet": True}) as ydl:
            ie = dy.BiliFetchDouyinIE(ydl)
            ie._download_webpage = Mock(return_value="")
            ie._download_json = Mock(return_value={"status_code": 2154})
            with self.assertRaisesRegex(ExtractorError, "BILIFETCH_DOUYIN:.*免登录"):
                ie._real_extract(URL)

    def test_homepage_and_live_are_explicitly_unsupported(self):
        with YoutubeDL({"quiet": True}) as ydl:
            ie = dy.BiliFetchDouyinIE(ydl)
            for url in ["https://www.douyin.com/user/123", "https://live.douyin.com/123"]:
                with self.assertRaisesRegex(ExtractorError, "具体的视频"):
                    ie._real_extract(url)


if __name__ == "__main__":
    unittest.main()
