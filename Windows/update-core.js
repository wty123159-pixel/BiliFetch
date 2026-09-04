'use strict';

function parseVersion(value) {
  const match = String(value || '').trim().replace(/^v/i, '').match(/^(\d+)\.(\d+)\.(\d+)(?:[-+].*)?$/);
  if (!match) return null;
  return match.slice(1).map(Number);
}

function compareVersions(left, right) {
  const a = parseVersion(left);
  const b = parseVersion(right);
  if (!a || !b) throw new Error('更新清单中的版本号格式无效。');
  for (let index = 0; index < 3; index += 1) {
    if (a[index] !== b[index]) return a[index] > b[index] ? 1 : -1;
  }
  return 0;
}

function validateHTTPSURL(value, label) {
  let url;
  try { url = new URL(String(value || '').trim()); } catch { throw new Error(`${label}不是有效网址。`); }
  if (url.protocol !== 'https:') throw new Error(`${label}必须使用 HTTPS。`);
  return url.toString();
}

function manifestURLs(channel, fallback) {
  const raw = [
    ...(Array.isArray(channel?.manifestURLs) ? channel.manifestURLs : []),
    channel?.manifestURL,
    fallback
  ];
  const seen = new Set();
  return raw.flatMap((value) => {
    if (!value) return [];
    try {
      const url = validateHTTPSURL(value, '更新清单地址');
      if (seen.has(url)) return [];
      seen.add(url);
      return [url];
    } catch { return []; }
  });
}

function validateManifest(payload) {
  if (!payload || typeof payload !== 'object') throw new Error('更新清单格式无效。');
  if (!parseVersion(payload.version)) throw new Error('更新清单缺少有效版本号。');
  const windows = payload.windows;
  if (!windows || typeof windows !== 'object') throw new Error('更新清单缺少 Windows 下载信息。');
  const sha256 = String(windows.sha256 || '').toLowerCase();
  if (!/^[a-f0-9]{64}$/.test(sha256)) throw new Error('更新包缺少有效的 SHA-256。');
  return {
    version: String(payload.version).replace(/^v/i, ''),
    notes: String(payload.notes || ''),
    publishedAt: String(payload.publishedAt || ''),
    url: validateHTTPSURL(windows.url, '更新包地址'),
    sha256,
    size: Number(windows.size) || 0
  };
}

module.exports = { compareVersions, manifestURLs, parseVersion, validateHTTPSURL, validateManifest };
