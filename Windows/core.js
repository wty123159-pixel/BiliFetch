'use strict';

const path = require('node:path');

const ALLOWED_HOSTS = ['bilibili.com', 'b23.tv', 'bilibili.tv'];
const FINAL_VIDEO_EXTENSIONS = new Set(['.mp4', '.mkv', '.webm', '.flv', '.mov', '.m4v']);

function normalizeThumbnailURL(value) {
  const raw = String(value || '').trim();
  if (!raw) return '';
  try {
    const url = new URL(raw.startsWith('//') ? `https:${raw}` : raw);
    if (!['http:', 'https:'].includes(url.protocol)) return '';
    url.protocol = 'https:';
    return url.toString();
  } catch {
    return '';
  }
}

function validateBilibiliURL(value) {
  try {
    const url = new URL(String(value || '').trim());
    if (!['http:', 'https:'].includes(url.protocol)) return null;
    const host = url.hostname.toLowerCase();
    if (!ALLOWED_HOSTS.some((allowed) => host === allowed || host.endsWith(`.${allowed}`))) return null;
    url.hash = '';
    return url.toString();
  } catch {
    return null;
  }
}

function qualitySelector(quality = 'best') {
  if (quality === 'best') return 'bv*+ba/b';
  const bounds = { p1080: 1080, p720: 720, p480: 480 };
  const value = bounds[quality] || 1080;
  return [
    `bv*[height<=${value}][vcodec^=avc]+ba[acodec^=mp4a]`,
    `bv*[width<=${value}][vcodec^=avc]+ba[acodec^=mp4a]`,
    `bv*[height<=${value}]+ba`,
    `bv*[width<=${value}]+ba`,
    `b[height<=${value}]`,
    `b[width<=${value}]`,
    'bv*+ba/b'
  ].join('/');
}

function safePathSegment(value, fallback = 'BiliFetch') {
  const result = String(value || '')
    .replace(/[<>:"/\\|?*\u0000-\u001f]/g, ' ')
    .replace(/[. ]+$/g, '')
    .replace(/\s+/g, ' ')
    .trim();
  return (result || fallback).slice(0, 100);
}

function canonicalItemURL(entry, sourceURL, index) {
  const sourceBvid = String(sourceURL || '').match(/BV[0-9A-Za-z]+/i)?.[0]?.toLowerCase();
  const candidates = [entry.webpage_url, entry.original_url, entry.url];
  for (const candidate of candidates) {
    const validated = validateBilibiliURL(candidate);
    if (validated) {
      const url = new URL(validated);
      const candidateBvid = url.pathname.match(/BV[0-9A-Za-z]+/i)?.[0]?.toLowerCase();
      if (sourceBvid && candidateBvid === sourceBvid && index > 0 && !url.searchParams.has('p')) {
        url.searchParams.set('p', String(index));
      }
      return url.toString();
    }
  }
  try {
    const source = new URL(sourceURL);
    if (/\/video\/BV[0-9A-Za-z]+/i.test(source.pathname) && index > 0) {
      source.searchParams.set('p', String(index));
    }
    return source.toString();
  } catch {
    return sourceURL;
  }
}

function parsePreviewLines(lines, sourceURL) {
  const parsed = [];
  for (const line of lines) {
    const trimmed = String(line || '').trim();
    if (!trimmed.startsWith('{')) continue;
    try {
      parsed.push(JSON.parse(trimmed));
    } catch {
      // yt-dlp diagnostics may occasionally be interleaved with stdout.
    }
  }
  if (!parsed.length) throw new Error('没有解析到可下载的视频。');

  const seen = new Set();
  const items = [];
  parsed.forEach((entry, offset) => {
    const index = Number(entry.playlist_index) || offset + 1;
    const url = canonicalItemURL(entry, sourceURL, index);
    const identity = `${entry.id || ''}:${index}:${url}`;
    if (seen.has(identity)) return;
    seen.add(identity);
    items.push({
      key: identity,
      id: String(entry.id || `item-${index}`),
      index,
      title: String(entry.title || `第 ${index} 集`),
      url,
      thumbnail: normalizeThumbnailURL(entry.thumbnail),
      duration: Number(entry.duration) || 0,
      selected: true,
      status: 'ready',
      progress: 0,
      speed: '',
      retries: 0,
      error: ''
    });
  });

  const first = parsed[0];
  return {
    sourceURL,
    title: String(first.playlist_title || first.playlist || first.title || 'BiliFetch 下载'),
    items: items.sort((a, b) => a.index - b.index)
  };
}

function parseBilibiliViewMetadata(payload, sourceURL) {
  const data = payload?.data;
  const bvid = String(data?.bvid || sourceURL || '').match(/BV[0-9A-Za-z]+/i)?.[0];
  if (payload?.code !== 0 || !data || !bvid) throw new Error('B站分集接口没有返回有效数据。');
  const pages = Array.isArray(data.pages) && data.pages.length
    ? data.pages
    : [{ page: 1, part: data.title, duration: data.duration, first_frame: data.pic }];
  const items = pages.map((page, offset) => {
    const index = Number(page.page) || offset + 1;
    const url = new URL(`https://www.bilibili.com/video/${bvid}/`);
    url.searchParams.set('p', String(index));
    return {
      key: `${bvid.toLowerCase()}:p${index}`,
      id: bvid,
      index,
      title: String(pages.length === 1 ? data.title : (page.part || `第 ${index} 集`)),
      url: url.toString(),
      thumbnail: normalizeThumbnailURL(page.first_frame || data.pic),
      duration: Number(page.duration) || 0,
      selected: true,
      status: 'ready',
      progress: 0,
      speed: '',
      retries: 0,
      error: ''
    };
  });
  return { sourceURL, title: String(data.title || 'BiliFetch 下载'), items };
}

function isPlausibleFinalVideo(filePath) {
  const lower = String(filePath || '').toLowerCase();
  if (!FINAL_VIDEO_EXTENSIONS.has(path.extname(lower))) return false;
  if (lower.includes('.part')) return false;
  return !/\.f\d+\.(mp4|mkv|webm|flv|mov|m4v)$/.test(lower);
}

function parseProgress(line) {
  const custom = String(line || '').match(/BILIFETCH_PROGRESS:\s*([\d.]+)%\|([^|]*)\|([^|]*)/);
  if (custom) {
    return {
      percent: Math.max(0, Math.min(100, Number(custom[1]) || 0)),
      speed: custom[2].trim() === 'NA' ? '' : custom[2].trim(),
      eta: custom[3].trim() === 'NA' ? '' : custom[3].trim()
    };
  }
  const aria = String(line || '').match(/\((\d+)%\).*?DL:([^\s\]]+)/i);
  if (aria) return { percent: Number(aria[1]), speed: aria[2], eta: '' };
  return null;
}

function parseCompletedPath(line) {
  const marker = 'BILIFETCH_FILE:';
  const offset = String(line || '').indexOf(marker);
  if (offset < 0) return null;
  const payload = String(line).slice(offset + marker.length).trim();
  try {
    return JSON.parse(payload);
  } catch {
    return payload.replace(/^"|"$/g, '');
  }
}

function buildDownloadArguments({ item, destination, settings, tools, outputTemplate }) {
  const args = [
    '--ignore-config', '--no-colors', '--newline', '--continue', '--part',
    '--no-overwrites', '--retries', '8', '--fragment-retries', '8',
    '--concurrent-fragments', '4', '--socket-timeout', '30',
    '--ffmpeg-location', tools.ffmpeg,
    '--format', qualitySelector(settings.quality),
    '--merge-output-format', 'mp4',
    '--paths', destination,
    '--output', outputTemplate,
    '--progress-template', 'download:BILIFETCH_PROGRESS:%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s',
    '--print', 'after_move:BILIFETCH_FILE:%(filepath)j',
    '--no-simulate', '--progress',
    '--no-playlist'
  ];
  if (settings.subtitles) {
    args.push('--write-subs', '--write-auto-subs', '--sub-langs', 'zh-Hans,zh-Hant,zh.*', '--convert-subs', 'srt');
  }
  if (settings.cookieFile) args.push('--cookies', settings.cookieFile);
  else if (settings.browser && settings.browser !== 'none') args.push('--cookies-from-browser', settings.browser);
  if (settings.engine === 'aria2' && tools.aria2) {
    args.push(
      '--downloader', tools.aria2,
      '--downloader-args',
      'aria2c:--continue=true -x 8 -s 8 -k 1M --auto-file-renaming=false --allow-overwrite=false --file-allocation=none --summary-interval=1 --show-console-readout=true --console-log-level=warn --enable-color=false'
    );
  }
  args.push('--', item.url);
  return args;
}

module.exports = {
  buildDownloadArguments,
  isPlausibleFinalVideo,
  normalizeThumbnailURL,
  parseBilibiliViewMetadata,
  parseCompletedPath,
  parsePreviewLines,
  parseProgress,
  qualitySelector,
  safePathSegment,
  validateBilibiliURL
};
