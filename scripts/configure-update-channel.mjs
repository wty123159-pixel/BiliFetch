#!/usr/bin/env node

import { writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const manifestURLs = process.argv.slice(2);
if (!manifestURLs.length) {
  console.error('用法: node scripts/configure-update-channel.mjs <首选HTTPS清单地址> [备用HTTPS清单地址...]');
  process.exit(2);
}
const parsed = manifestURLs.map((value) => {
  const url = new URL(value);
  if (url.protocol !== 'https:') throw new Error('更新清单地址必须使用 HTTPS。');
  return url.toString();
});
const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const output = path.join(scriptDirectory, '..', 'Windows', 'update-channel.json');
await writeFile(output, `${JSON.stringify({ manifestURL: parsed[0], manifestURLs: [...new Set(parsed)] }, null, 2)}\n`, 'utf8');
console.log(`已配置更新通道: ${parsed.join(' -> ')}`);
