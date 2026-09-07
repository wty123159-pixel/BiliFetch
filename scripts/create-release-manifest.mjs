#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { readFile, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';

const pairs = process.argv.slice(2);
const options = {};
for (let index = 0; index < pairs.length; index += 2) options[pairs[index]] = pairs[index + 1];
for (const required of ['--windows', '--windows-url', '--macos', '--macos-url', '--output']) {
  if (!options[required]) {
    console.error('用法: node scripts/create-release-manifest.mjs --windows <zip> --windows-url <https> --macos <zip> --macos-url <https> [--windows-delta <zip> --windows-delta-url <https>] [--macos-delta <zip> --macos-delta-url <https>] [--notes <文件>] [--history <历史文件>] [--previous-manifest <上一版清单>] --output <json>');
    process.exit(2);
  }
}

function requireHTTPS(value, label) {
  const url = new URL(value);
  if (url.protocol !== 'https:') throw new Error(`${label}必须使用 HTTPS。`);
  return url.toString();
}

function versionFrom(file, expression, label) {
  const version = path.basename(file).match(expression)?.[1];
  if (!version) throw new Error(`无法从${label}文件名读取版本号。`);
  return version;
}

async function sha256(file) {
  return new Promise((resolve, reject) => {
    const hash = createHash('sha256');
    const stream = createReadStream(file);
    stream.on('error', reject);
    stream.on('data', (chunk) => hash.update(chunk));
    stream.on('end', () => resolve(hash.digest('hex')));
  });
}

async function artifact(fileArgument, url, expression, label) {
  const file = path.resolve(fileArgument);
  const info = await stat(file);
  return {
    version: versionFrom(file, expression, label),
    url: requireHTTPS(url, `${label}下载地址`),
    sha256: await sha256(file),
    size: info.size
  };
}

async function deltaArtifact(fileArgument, url, expression, label, expectedVersion) {
  if (!fileArgument && !url) return null;
  if (!fileArgument || !url) throw new Error(`${label}增量包文件和下载地址必须同时提供。`);
  const file = path.resolve(fileArgument);
  const match = path.basename(file).match(expression);
  if (!match) throw new Error(`无法从${label}增量包文件名读取版本号。`);
  if (match[2] !== expectedVersion) throw new Error(`${label}增量包目标版本与完整包不一致。`);
  const info = await stat(file);
  return {
    fromVersion: match[1],
    url: requireHTTPS(url, `${label}增量包下载地址`),
    sha256: await sha256(file),
    size: info.size
  };
}

function parseVersion(value, label) {
  const match = String(value || '').trim().replace(/^v/i, '').match(/^(\d+)\.(\d+)\.(\d+)$/);
  if (!match) throw new Error(`${label}版本号格式无效。`);
  return { value: match.slice(1).join('.'), components: match.slice(1).map(Number) };
}

function compareVersions(left, right) {
  const a = parseVersion(left, '更新历史').components;
  const b = parseVersion(right, '更新历史').components;
  for (let index = 0; index < 3; index += 1) {
    if (a[index] !== b[index]) return a[index] - b[index];
  }
  return 0;
}

async function optionalJSON(fileArgument, label) {
  if (!fileArgument) return null;
  try {
    return JSON.parse(await readFile(path.resolve(fileArgument), 'utf8'));
  } catch (error) {
    throw new Error(`无法读取${label}：${error.message}`);
  }
}

function normalizeHistory(value, label) {
  if (value == null) return [];
  if (!Array.isArray(value)) throw new Error(`${label}必须是数组。`);
  return value.map((entry) => {
    const version = parseVersion(entry?.version, label).value;
    const entryNotes = String(entry?.notes || '').trim();
    if (!entryNotes) throw new Error(`${label}中的 v${version} 缺少更新内容。`);
    const publishedAt = String(entry?.publishedAt || '').trim();
    return { version, notes: entryNotes, ...(publishedAt ? { publishedAt } : {}) };
  });
}

function mergedHistory(platform, releaseVersion, currentNotes, publishedAt, seed, previous) {
  const entries = new Map();
  const candidates = [
    ...normalizeHistory(seed?.[platform], `${platform}种子更新历史`),
    ...normalizeHistory(previous?.[platform]?.history, `${platform}上一版更新历史`)
  ];
  for (const entry of candidates) {
    if (compareVersions(entry.version, releaseVersion) <= 0) entries.set(entry.version, entry);
  }
  entries.set(releaseVersion, { version: releaseVersion, notes: currentNotes, publishedAt });
  return [...entries.values()].sort((left, right) => compareVersions(left.version, right.version));
}

function formatHistory(history) {
  return history.map((entry) => `v${entry.version}\n${entry.notes}`).join('\n\n');
}

const windows = await artifact(
  options['--windows'], options['--windows-url'],
  /BiliFetch-Windows-x64-(\d+\.\d+\.\d+)\.zip$/, 'Windows'
);
const macos = await artifact(
  options['--macos'], options['--macos-url'],
  /BiliFetch-macOS-(\d+\.\d+\.\d+)\.zip$/, 'macOS'
);
const windowsDelta = await deltaArtifact(
  options['--windows-delta'], options['--windows-delta-url'],
  /BiliFetch-Windows-x64-delta-(\d+\.\d+\.\d+)-to-(\d+\.\d+\.\d+)\.zip$/, 'Windows', windows.version
);
const macosDelta = await deltaArtifact(
  options['--macos-delta'], options['--macos-delta-url'],
  /BiliFetch-macOS-delta-(\d+\.\d+\.\d+)-to-(\d+\.\d+\.\d+)\.zip$/, 'macOS', macos.version
);
const notes = options['--notes'] ? (await readFile(path.resolve(options['--notes']), 'utf8')).trim() : 'BiliFetch 双平台更新';
if (!notes) throw new Error('本次更新内容不能为空。');
const historySeed = await optionalJSON(options['--history'], '种子更新历史');
const previousManifest = await optionalJSON(options['--previous-manifest'], '上一版更新清单');
const publishedAt = new Date().toISOString();
const windowsHistory = mergedHistory('windows', windows.version, notes, publishedAt, historySeed, previousManifest);
const macosHistory = mergedHistory('macos', macos.version, notes, publishedAt, historySeed, previousManifest);
const manifest = {
  schemaVersion: 3,
  publishedAt,
  version: windows.version,
  // Old Windows clients only understand this top-level field, so keep the
  // complete accumulated Windows history here as a compatibility fallback.
  notes: formatHistory(windowsHistory),
  windows: {
    url: windows.url, sha256: windows.sha256, size: windows.size,
    notes: formatHistory(windowsHistory), history: windowsHistory,
    ...(windowsDelta ? { deltas: [windowsDelta] } : {})
  },
  macos: {
    version: macos.version, url: macos.url, sha256: macos.sha256, size: macos.size,
    notes: formatHistory(macosHistory), history: macosHistory,
    ...(macosDelta ? { deltas: [macosDelta] } : {})
  }
};
const output = path.resolve(options['--output']);
await writeFile(output, `${JSON.stringify(manifest, null, 2)}\n`, 'utf8');
console.log(`${output}\nWindows ${windows.sha256}\nmacOS ${macos.sha256}`);
