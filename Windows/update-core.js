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

function notesForUpgrade(history, currentVersion, releaseVersion, fallback) {
  const cleanFallback = String(fallback || '').trim();
  if (!parseVersion(currentVersion) || !parseVersion(releaseVersion)) return cleanFallback;
  const entries = new Map();
  for (const item of Array.isArray(history) ? history : []) {
    const version = String(item?.version || '').trim().replace(/^v/i, '');
    const notes = String(item?.notes || '').trim();
    if (!parseVersion(version) || !notes) continue;
    if (compareVersions(version, currentVersion) <= 0 || compareVersions(version, releaseVersion) > 0) continue;
    entries.set(version, notes);
  }
  const cleanReleaseVersion = String(releaseVersion).replace(/^v/i, '');
  if (!entries.has(cleanReleaseVersion) && cleanFallback && compareVersions(cleanReleaseVersion, currentVersion) > 0) {
    entries.set(cleanReleaseVersion, cleanFallback);
  }
  const versions = [...entries.keys()].sort(compareVersions);
  if (!versions.length) return cleanFallback;
  return versions.map((version) => `v${version}\n${entries.get(version)}`).join('\n\n');
}

function validateManifest(payload, currentVersion = '') {
  if (!payload || typeof payload !== 'object') throw new Error('更新清单格式无效。');
  if (!parseVersion(payload.version)) throw new Error('更新清单缺少有效版本号。');
  const windows = payload.windows;
  if (!windows || typeof windows !== 'object') throw new Error('更新清单缺少 Windows 下载信息。');
  const sha256 = String(windows.sha256 || '').toLowerCase();
  if (!/^[a-f0-9]{64}$/.test(sha256)) throw new Error('更新包缺少有效的 SHA-256。');
  let delta = null;
  if (parseVersion(currentVersion) && Array.isArray(windows.deltas)) {
    const candidate = windows.deltas.find((item) => (
      item && parseVersion(item.fromVersion) && compareVersions(item.fromVersion, currentVersion) === 0
    ));
    if (candidate) {
      const deltaSHA256 = String(candidate.sha256 || '').toLowerCase();
      if (!/^[a-f0-9]{64}$/.test(deltaSHA256)) throw new Error('增量更新包缺少有效的 SHA-256。');
      delta = {
        fromVersion: String(candidate.fromVersion).replace(/^v/i, ''),
        url: validateHTTPSURL(candidate.url, '增量更新包地址'),
        sha256: deltaSHA256,
        size: Number(candidate.size) || 0
      };
    }
  }
  const rawNotes = String(windows.notes || payload.notes || '');
  const history = Array.isArray(windows.history) ? windows.history : [];
  return {
    version: String(payload.version).replace(/^v/i, ''),
    notes: notesForUpgrade(history, currentVersion, payload.version, rawNotes),
    rawNotes,
    history,
    publishedAt: String(payload.publishedAt || ''),
    url: validateHTTPSURL(windows.url, '更新包地址'),
    sha256,
    size: Number(windows.size) || 0,
    delta
  };
}

function isSafeRelativePath(value) {
  const normalized = String(value || '');
  if (!normalized || normalized.startsWith('/') || normalized.startsWith('\\') || normalized.includes('\\') || normalized.includes('\0')) return false;
  const parts = normalized.split('/');
  return parts.every((part) => part && part !== '.' && part !== '..' && !/^[A-Za-z]:$/.test(part));
}

function validateDeltaPlan(payload, currentVersion, targetVersion) {
  if (!payload || typeof payload !== 'object' || payload.formatVersion !== 1 || payload.platform !== 'windows') {
    throw new Error('增量包格式无效。');
  }
  if (compareVersions(payload.fromVersion, currentVersion) !== 0 || compareVersions(payload.toVersion, targetVersion) !== 0) {
    throw new Error('增量包版本与当前应用不匹配。');
  }
  if (!Array.isArray(payload.files) || !Array.isArray(payload.deletePaths)) throw new Error('增量包文件清单无效。');
  const paths = new Set();
  const files = payload.files.map((file) => {
    const filePath = String(file?.path || '');
    const sha256 = String(file?.sha256 || '').toLowerCase();
    const size = Number(file?.size);
    const mode = file.mode == null ? null : Number(file.mode);
    if (!isSafeRelativePath(filePath) || paths.has(filePath) || !/^[a-f0-9]{64}$/.test(sha256) || !Number.isSafeInteger(size) || size < 0 ||
        (mode !== null && (!Number.isInteger(mode) || mode < 0 || mode > 0o7777))) {
      throw new Error('增量包包含无效文件记录。');
    }
    paths.add(filePath);
    let patch = null;
    if (file.patch) {
      const source = String(file.patch.source || '');
      const baseSha256 = String(file.patch.baseSha256 || '').toLowerCase();
      const dataSha256 = String(file.patch.dataSha256 || '').toLowerCase();
      const baseSize = Number(file.patch.baseSize);
      const dataSize = Number(file.patch.dataSize);
      if (!isSafeRelativePath(source) || !/^[a-f0-9]{64}$/.test(baseSha256) || !/^[a-f0-9]{64}$/.test(dataSha256) ||
          !Number.isSafeInteger(baseSize) || baseSize < 0 || !Number.isSafeInteger(dataSize) || dataSize < 0 || !Array.isArray(file.patch.operations)) {
        throw new Error('增量包包含无效的二进制补丁。');
      }
      let outputSize = 0;
      let nextDataOffset = 0;
      const operations = file.patch.operations.map((operation) => {
        const type = String(operation?.type || '');
        const offset = Number(operation?.offset);
        const length = Number(operation?.length);
        const limit = type === 'copy' ? baseSize : dataSize;
        if (!['copy', 'data'].includes(type) || !Number.isSafeInteger(offset) || offset < 0 || !Number.isSafeInteger(length) || length <= 0 ||
            offset > limit || length > limit - offset || outputSize > Number.MAX_SAFE_INTEGER - length ||
            (type === 'data' && offset !== nextDataOffset)) {
          throw new Error('二进制补丁操作范围无效。');
        }
        outputSize += length;
        if (type === 'data') nextDataOffset += length;
        return { type, offset, length };
      });
      if (outputSize !== size || nextDataOffset !== dataSize) throw new Error('二进制补丁大小不一致。');
      patch = { source, baseSha256, baseSize, dataSha256, dataSize, operations };
    }
    return { path: filePath, sha256, size, mode, patch };
  });
  const deletePaths = payload.deletePaths.map((value) => {
    const filePath = String(value || '');
    if (!isSafeRelativePath(filePath) || paths.has(filePath)) throw new Error('增量包包含不安全的删除路径。');
    paths.add(filePath);
    return filePath;
  });
  return { formatVersion: 1, platform: 'windows', fromVersion: String(payload.fromVersion), toVersion: String(payload.toVersion), files, deletePaths };
}

function createWindowsInstallScript() {
  return [
    'param([string]$Source, [string]$Target, [string]$Executable, [int]$ProcessId, [string]$LogFile, [string]$LockDirectory)',
    "$ErrorActionPreference = 'Stop'",
    '$Backup = "$Target.update-backup"',
    '$HadBackup = $false',
    '$HasLock = $false',
    'try {',
    '  New-Item -ItemType Directory -Path $LockDirectory -ErrorAction Stop | Out-Null',
    '  $HasLock = $true',
    '  Wait-Process -Id $ProcessId -ErrorAction SilentlyContinue',
    '  Start-Sleep -Milliseconds 1200',
    '  if (Test-Path -LiteralPath $Backup) { Remove-Item -LiteralPath $Backup -Recurse -Force }',
    '  if (Test-Path -LiteralPath $Target) {',
    '    Move-Item -LiteralPath $Target -Destination $Backup',
    '    $HadBackup = $true',
    '  }',
    '  New-Item -ItemType Directory -Path $Target -Force | Out-Null',
    "  Copy-Item -Path (Join-Path $Source '*') -Destination $Target -Recurse -Force",
    '  Start-Process -FilePath (Join-Path $Target $Executable)',
    '  Start-Sleep -Milliseconds 800',
    '  Remove-Item -LiteralPath $Backup -Recurse -Force -ErrorAction SilentlyContinue',
    "  'Update installed successfully.' | Out-File -LiteralPath $LogFile -Encoding utf8",
    '} catch {',
    '  $_ | Out-File -LiteralPath $LogFile -Encoding utf8',
    '  if ($HadBackup -and (Test-Path -LiteralPath $Backup)) {',
    '    Remove-Item -LiteralPath $Target -Recurse -Force -ErrorAction SilentlyContinue',
    '    Move-Item -LiteralPath $Backup -Destination $Target -Force',
    '    Start-Process -FilePath (Join-Path $Target $Executable)',
    '  }',
    '} finally {',
    '  if ($HasLock) { Remove-Item -LiteralPath $LockDirectory -Recurse -Force -ErrorAction SilentlyContinue }',
    '  Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue',
    '}'
  ].join('\r\n');
}

module.exports = {
  compareVersions, createWindowsInstallScript, isSafeRelativePath, manifestURLs, notesForUpgrade, parseVersion,
  validateDeltaPlan, validateHTTPSURL, validateManifest
};
