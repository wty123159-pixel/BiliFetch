'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const core = require('../core');

test('only accepts Bilibili and b23 links', () => {
  assert.match(core.validateBilibiliURL('https://www.bilibili.com/video/BV1abc123'), /^https:\/\/www\.bilibili\.com/);
  assert.match(core.validateBilibiliURL('https://b23.tv/abc'), /^https:\/\/b23\.tv/);
  assert.equal(core.validateBilibiliURL('file:///Windows/System32/cmd.exe'), null);
  assert.equal(core.validateBilibiliURL('https://bilibili.com.example.org/video/x'), null);
});

test('detects outer collection context without treating every BV link as a collection', () => {
  assert.equal(core.hasOuterCollectionContext('https://www.bilibili.com/video/BV1abc123'), false);
  assert.equal(
    core.hasOuterCollectionContext('https://www.bilibili.com/video/BV1abc123?spm_id_from=333.788.videopod.sections'),
    true
  );
  assert.equal(core.hasOuterCollectionContext('https://space.bilibili.com/12/lists/34?type=season'), true);
  assert.equal(core.hasOuterCollectionContext('https://www.bilibili.com/video/BV1abc123?season_id=42'), true);
});

test('parses every mixed collection entry without filtering by format', () => {
  const lines = [
    JSON.stringify({ id: 'BV1x', title: '第一集 FLV', webpage_url: 'https://www.bilibili.com/video/BV1x?p=1', playlist_title: '合集', playlist_index: 1 }),
    JSON.stringify({ id: 'BV1x', title: '第二集 MP4', webpage_url: 'https://www.bilibili.com/video/BV1x?p=2', playlist_title: '合集', playlist_index: 2 })
  ];
  const preview = core.parsePreviewLines(lines, 'https://www.bilibili.com/video/BV1x');
  assert.equal(preview.items.length, 2);
  assert.equal(preview.items.every((item) => item.selected), true);
  assert.equal(preview.items[1].index, 2);
});

test('normalizes Bilibili thumbnails and keeps each multi-part cover distinct', () => {
  assert.equal(core.normalizeThumbnailURL('//i0.hdslb.com/a.jpg'), 'https://i0.hdslb.com/a.jpg');
  assert.equal(core.normalizeThumbnailURL('http://i1.hdslb.com/b.jpg'), 'https://i1.hdslb.com/b.jpg');
  const preview = core.parseBilibiliViewMetadata({
    code: 0,
    data: {
      bvid: 'BV1KJsLekEfA', title: '测试合集', pic: 'http://i0.hdslb.com/cover.jpg',
      pages: [
        { page: 1, part: '第一集', duration: 10, first_frame: 'http://i1.hdslb.com/one.jpg' },
        { page: 2, part: '第二集', duration: 20, first_frame: 'http://i2.hdslb.com/two.jpg' }
      ]
    }
  }, 'https://www.bilibili.com/video/BV1KJsLekEfA');
  assert.equal(preview.items.length, 2);
  assert.equal(preview.items[0].thumbnail, 'https://i1.hdslb.com/one.jpg');
  assert.equal(preview.items[1].thumbnail, 'https://i2.hdslb.com/two.jpg');
  assert.match(preview.items[1].url, /[?&]p=2/);
});

test('expands the outer UGC collection carried by a single BV response', () => {
  const preview = core.parseBilibiliViewMetadata({
    code: 0,
    data: {
      bvid: 'BVseason01', title: '当前视频', pic: 'http://i0.hdslb.com/main.jpg',
      pages: [{ page: 1, part: '当前视频', duration: 10 }],
      ugc_season: {
        title: '完整 UGC 合集', cover: 'http://i0.hdslb.com/season.jpg',
        sections: [{ episodes: [
          { bvid: 'BVseason01', title: '合集第一集', arc: { pic: 'http://i1.hdslb.com/one.jpg', duration: 10 } },
          { bvid: 'BVseason02', title: '合集第二集', arc: { pic: 'http://i2.hdslb.com/two.jpg', duration: 20 } }
        ] }]
      }
    }
  }, 'https://www.bilibili.com/video/BVseason01');
  assert.equal(preview.title, '完整 UGC 合集');
  assert.equal(preview.items.length, 2);
  assert.equal(preview.items[1].title, '合集第二集');
  assert.match(preview.items[1].url, /BVseason02/);
  assert.match(preview.items[1].thumbnail, /^https:/);
});

test('prefers the opened BV parts when it also belongs to an outer UGC collection', () => {
  const preview = core.parseBilibiliViewMetadata({
    code: 0,
    data: {
      bvid: 'BVnested', title: '当前多P合集', pic: 'http://i0.hdslb.com/main.jpg',
      pages: [
        { page: 1, part: '分P一', duration: 10 },
        { page: 2, part: '分P二', duration: 20 }
      ],
      ugc_season: {
        title: '外层合集',
        sections: [{ episodes: [
          { bvid: 'BVnested', title: '外层第一集' },
          { bvid: 'BVother', title: '外层第二集' }
        ] }]
      }
    }
  }, 'https://www.bilibili.com/video/BVnested');
  assert.equal(preview.title, '当前多P合集');
  assert.equal(preview.items.length, 2);
  assert.match(preview.items[1].url, /[?&]p=2/);
});

test('uses a fallback-rich selector for bounded qualities', () => {
  const selector = core.qualitySelector('p1080');
  assert.match(selector, /height<=1080/);
  assert.match(selector, /width<=1080/);
  assert.match(selector, /bv\*\+ba\/b$/);
});

test('rejects intermediate video-only files as final output', () => {
  assert.equal(core.isPlausibleFinalVideo('video.f30106.mp4'), false);
  assert.equal(core.isPlausibleFinalVideo('video.mp4.part'), false);
  assert.equal(core.isPlausibleFinalVideo('video.mp4'), true);
  assert.equal(core.isPlausibleFinalVideo('audio.m4a'), false);
});

test('parses yt-dlp and aria2 progress lines', () => {
  assert.deepEqual(core.parseProgress('BILIFETCH_PROGRESS: 42.5%|3.2MiB/s|00:10'), { percent: 42.5, speed: '3.2MiB/s', eta: '00:10' });
  assert.deepEqual(core.parseProgress('[#abc 20MiB/100MiB(20%) CN:8 DL:5.0MiB]'), { percent: 20, speed: '5.0MiB', eta: '' });
});

test('download arguments enable resume, fixed merge, cookies and aria2', () => {
  const args = core.buildDownloadArguments({
    item: { url: 'https://www.bilibili.com/video/BV1x?p=1' }, destination: 'D:\\Video',
    settings: { quality: 'best', engine: 'aria2', browser: 'edge', subtitles: false },
    tools: { ffmpeg: 'ffmpeg.exe', aria2: 'aria2c.exe' }, outputTemplate: '%(title)s.%(ext)s'
  });
  assert.ok(args.includes('--continue'));
  assert.ok(args.includes('--no-simulate'));
  assert.ok(args.includes('--merge-output-format'));
  assert.ok(args.includes('mp4'));
  assert.ok(args.includes('--cookies-from-browser'));
  assert.ok(args.includes('aria2c.exe'));
  assert.equal(args.at(-1), 'https://www.bilibili.com/video/BV1x?p=1');
});

test('requires every bundled command-line component', () => {
  assert.equal(core.hasCompleteToolset({
    ytdlp: 'yt-dlp.exe', ffmpeg: 'ffmpeg.exe', ffprobe: 'ffprobe.exe', aria2: 'aria2c.exe'
  }), true);
  assert.equal(core.hasCompleteToolset({
    ytdlp: 'yt-dlp.exe', ffmpeg: 'ffmpeg.exe', ffprobe: 'ffprobe.exe'
  }), false);
});
