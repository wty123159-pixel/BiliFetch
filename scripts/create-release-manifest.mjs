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
    console.error('用法: node scripts/create-release-manifest.mjs --windows <zip> --windows-url <https> --macos <zip> --macos-url <https> [--notes <文件>] --output <json>');
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

const windows = await artifact(
  options['--windows'], options['--windows-url'],
  /BiliFetch-Windows-x64-(\d+\.\d+\.\d+)\.zip$/, 'Windows'
);
const macos = await artifact(
  options['--macos'], options['--macos-url'],
  /BiliFetch-macOS-(\d+\.\d+\.\d+)\.zip$/, 'macOS'
);
const notes = options['--notes'] ? (await readFile(path.resolve(options['--notes']), 'utf8')).trim() : 'BiliFetch 双平台更新';
const manifest = {
  schemaVersion: 1,
  publishedAt: new Date().toISOString(),
  version: windows.version,
  notes,
  windows: { url: windows.url, sha256: windows.sha256, size: windows.size },
  macos: { version: macos.version, url: macos.url, sha256: macos.sha256, size: macos.size }
};
const output = path.resolve(options['--output']);
await writeFile(output, `${JSON.stringify(manifest, null, 2)}\n`, 'utf8');
console.log(`${output}\nWindows ${windows.sha256}\nmacOS ${macos.sha256}`);
