'use strict';

// Official release-asset API only: no public relay, embedded token or TLS bypass.
function githubReleaseAsset(value) {
  let url;
  try { url = new URL(value); } catch { return null; }
  if (url.protocol !== 'https:' || url.hostname !== 'github.com' || url.port || url.username || url.password || url.search || url.hash) return null;
  const parts = url.pathname.split('/').slice(1);
  if (parts.length !== 6 || parts[2] !== 'releases') return null;
  const [owner, repository] = parts;
  if (![owner, repository].every(part => /^[\w.-]+$/.test(part) && part !== '.' && part !== '..')) return null;
  const latest = parts[3] === 'latest' && parts[4] === 'download';
  if (!latest && parts[3] !== 'download') return null;
  let tag, name;
  try { tag = decodeURIComponent(parts[4]); name = decodeURIComponent(parts[5]); } catch { return null; }
  if (!name || /[\\/\x00-\x1f]/.test(name)) return null;
  const base = `https://api.github.com/repos/${owner}/${repository}/releases`;
  return { repository: `${owner}/${repository}`, name, latest, tag,
    metadataURL: latest ? `${base}/latest` : `${base}/tags/${encodeURIComponent(tag)}`,
    assetPrefix: `${base}/assets/` };
}

function assetAPIURL(source, release) {
  if (!release || release.draft || (!source.latest && release.tag_name !== source.tag)) throw new Error('官方备用通道返回了不匹配的版本。');
  const asset = release.assets?.find(item => item?.name === source.name && item.state === 'uploaded');
  const id = asset?.id;
  if (!Number.isSafeInteger(id) || id <= 0 || asset.url !== `${source.assetPrefix}${id}`) throw new Error('官方备用通道尚未提供此更新文件。');
  return asset.url;
}

class UpdateNetwork {
  constructor({ fetch, userAgent, timeoutMS = 10000 }) {
    this.fetch = fetch;
    this.userAgent = userAgent;
    this.timeoutMS = timeoutMS;
    this.metadata = new Map();
    this.preferAPI = new Set();
  }
  async json(url, accept = 'application/json') {
    const response = await this.fetch(url, {
      signal: AbortSignal.timeout(this.timeoutMS), cache: 'no-store',
      headers: { 'User-Agent': this.userAgent, Accept: accept }
    });
    if (!response.ok) { await response.body?.cancel(); throw new Error(`更新服务返回 HTTP ${response.status}`); }
    return response.json();
  }
  async apiSource(source) {
    let cached = this.metadata.get(source.metadataURL);
    if (!cached || Date.now() - cached.time > 60000) {
      cached = { time: Date.now(), release: await this.json(source.metadataURL, 'application/vnd.github+json') };
      this.metadata.set(source.metadataURL, cached);
    }
    return { url: assetAPIURL(source, cached.release), headers: { Accept: 'application/octet-stream' }, officialAPI: true };
  }
  async withFallback(url, operation) {
    const github = githubReleaseAsset(url);
    const order = github && this.preferAPI.has(github.repository) ? ['api', 'primary'] : ['primary', 'api'];
    let lastError;
    for (const route of order) {
      if (route === 'api' && !github) continue;
      try {
        const source = route === 'api' ? await this.apiSource(github) : { url, headers: {}, officialAPI: false };
        const result = await operation(source);
        if (github) {
          if (route === 'api') this.preferAPI.add(github.repository);
          else this.preferAPI.delete(github.repository);
        }
        return result;
      } catch (error) { lastError = error; }
    }
    throw lastError || new Error('暂时无法连接更新服务器。');
  }
  manifest(url, validate) {
    return this.withFallback(url, async source => validate(await this.json(source.url, source.headers.Accept)));
  }
}
module.exports = { UpdateNetwork, githubReleaseAsset, assetAPIURL };
