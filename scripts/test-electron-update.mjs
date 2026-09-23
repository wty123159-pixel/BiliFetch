#!/usr/bin/env node

import { spawn } from 'node:child_process';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const require = createRequire(path.join(root, 'Windows/package.json'));

function run(executable, args, env = process.env) {
  return new Promise((resolve, reject) => {
    const child = spawn(executable, args, { cwd: root, env, stdio: 'inherit' });
    child.once('error', reject);
    child.once('close', (code) => code === 0 ? resolve() : reject(new Error(`Electron 更新测试退出代码 ${code}`)));
  });
}

let executable = process.env.BILIFETCH_ELECTRON_BIN;
if (!executable) {
  try { executable = require('electron'); }
  catch {
    // pnpm may leave Electron's installation script pending. Use the pinned
    // package's own checksum-verified installer; it reuses its download cache.
    await run(process.execPath, [require.resolve('electron/install.js')]);
    executable = require('electron');
  }
}
await run(executable, ['--test', path.join(root, 'Windows/tests/update-files.test.js')], {
  ...process.env,
  ELECTRON_RUN_AS_NODE: '1',
  BILIFETCH_ELECTRON_TEST_VERSION: require('electron/package.json').version
});
