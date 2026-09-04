#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { readFile, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';

const [archiveArgument, downloadURLArgument, notesFileArgument, outputArgument] = process.argv.slice(2);
if (!archiveArgument || !downloadURLArgument) {
  console.error('用法: node create-windows-update-manifest.mjs <zip路径> <HTTPS下载地址> [更新说明文件] [输出JSON]');
  process.exit(2);
}

const archive = path.resolve(archiveArgument);
const downloadURL = new URL(downloadURLArgument);
if (downloadURL.protocol !== 'https:') throw new Error('更新包下载地址必须使用 HTTPS。');
const version = path.basename(archive).match(/BiliFetch-Windows-x64-(\d+\.\d+\.\d+)\.zip$/)?.[1];
if (!version) throw new Error('无法从 ZIP 文件名读取版本号。');

const digest = await new Promise((resolve, reject) => {
  const hash = createHash('sha256');
  const input = createReadStream(archive);
  input.on('error', reject);
  input.on('data', (chunk) => hash.update(chunk));
  input.on('end', () => resolve(hash.digest('hex')));
});
const archiveStat = await stat(archive);
const notes = notesFileArgument ? await readFile(path.resolve(notesFileArgument), 'utf8') : `BiliFetch Windows v${version}`;
const manifest = {
  version,
  publishedAt: new Date().toISOString(),
  notes: notes.trim(),
  windows: { url: downloadURL.toString(), sha256: digest, size: archiveStat.size }
};
const output = path.resolve(outputArgument || path.join(path.dirname(archive), 'windows-update.json'));
await writeFile(output, `${JSON.stringify(manifest, null, 2)}\n`, 'utf8');
console.log(`${output}\nSHA-256 ${digest}`);
