'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fixtures = require('../../Tests/Fixtures/share-links.json');
const core = require('../core');

for (const fixture of fixtures) {
  test('shared link fixture: ' + fixture.name, () => {
    assert.equal(core.validateVideoURL(fixture.input), fixture.expected);
  });
}
for (const fixture of require('../../Tests/Fixtures/thumbnail-hosts.json')) {
  test('shared thumbnail fixture: ' + fixture.name, () => {
    assert.equal(core.thumbnailReferer(fixture.url), fixture.referer);
  });
}

test('Douyin never uses Bilibili collection classification or login cookies', () => {
  const url = 'https://www.douyin.com/video/7688293605819075875?p=2&season_id=1';
  assert.equal(core.hasOuterCollectionContext(url), false);
  assert.equal(core.validateBilibiliURL(url), null);
  assert.deepEqual(core.cookieArguments({ cookieFile: 'bilibili.txt', browser: 'chrome' }, url),
    []);
  assert.deepEqual(core.cookieArguments({ cookieFile: 'bilibili.txt', browser: 'none' }, url), []);
  assert.deepEqual(core.cookieArguments({ cookieFile: 'bilibili.txt', browser: 'chrome' }, 'https://b23.tv/test'),
    ['--cookies', 'bilibili.txt']);
});

test('Douyin preview retains the canonical work URL and selected state', () => {
  const url = 'https://www.douyin.com/video/7688293605819075875';
  const preview = core.parsePreviewLines([JSON.stringify({
    id: '7688293605819075875', title: '测试作品', webpage_url: url,
    duration: 12, thumbnail: 'https://p3.douyinpic.com/test.jpg'
  })], 'https://v.douyin.com/V3t4RyEfLUo/');
  assert.equal(preview.items.length, 1);
  assert.equal(preview.items[0].url, url);
  assert.equal(preview.items[0].selected, true);
  assert.equal(preview.items[0].duration, 12);
});

test('Douyin download keeps resume, quality, validation output and bundled parser', () => {
  const args = core.buildDownloadArguments({
    item: { url: 'https://www.douyin.com/video/7688293605819075875' },
    destination: 'D:\\Videos', outputTemplate: '%(title)s.%(ext)s',
    settings: { quality: 'best', engine: 'aria2', cookieFile: 'bilibili.txt', browser: 'edge' },
    tools: { ffmpeg: 'ffmpeg.exe', aria2: 'aria2c.exe', pluginDirectory: 'D:\\BiliFetch\\resources\\yt-dlp-plugins' }
  });
  for (const flag of ['--continue', '--part', '--no-playlist', '--no-plugin-dirs', '--plugin-dirs', '--progress-template', '--print']) {
    assert.ok(args.includes(flag), flag);
  }
  assert.equal(args[args.indexOf('--format') + 1], 'bv*+ba/b');
  assert.equal(args[args.indexOf('--merge-output-format') + 1], 'mp4');
  assert.equal(args.includes('--cookies-from-browser'), false);
  assert.equal(args.includes('--cookies'), false);
  assert.deepEqual(core.pluginArguments('https://b23.tv/a', 'plugins'), []);
});

test('Douyin verification failures are explicit and do not suggest Bilibili login', () => {
  const url = 'https://v.douyin.com/example/';
  assert.equal(core.friendlyResolveError('ERROR: BILIFETCH_DOUYIN: 请重新分享\nlog', url), '请重新分享');
  assert.match(core.friendlyResolveError('Fresh cookies', url), /免登录/);
  assert.doesNotMatch(core.friendlyResolveError('Fresh cookies', url), /扫码|浏览器/);
});
