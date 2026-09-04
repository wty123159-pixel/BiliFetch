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
