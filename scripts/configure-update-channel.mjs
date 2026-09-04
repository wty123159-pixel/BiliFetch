#!/usr/bin/env node

import { writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const manifestURL = process.argv[2];
if (!manifestURL) {
  console.error('用法: node scripts/configure-update-channel.mjs <HTTPS固定清单地址>');
  process.exit(2);
}
const parsed = new URL(manifestURL);
if (parsed.protocol !== 'https:') throw new Error('更新清单地址必须使用 HTTPS。');
const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const output = path.join(scriptDirectory, '..', 'Windows', 'update-channel.json');
await writeFile(output, `${JSON.stringify({ manifestURL: parsed.toString() }, null, 2)}\n`, 'utf8');
console.log(`已配置更新通道: ${parsed}`);
