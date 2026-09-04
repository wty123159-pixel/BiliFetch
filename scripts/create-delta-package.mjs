#!/usr/bin/env node

import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { chmod, copyFile, mkdir, mkdtemp, readFile, readdir, readlink, rm, stat, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';

const pairs = process.argv.slice(2);
const options = {};
for (let index = 0; index < pairs.length; index += 2) options[pairs[index]] = pairs[index + 1];
for (const required of ['--platform', '--from', '--to', '--output']) {
  if (!options[required]) {
    console.error('用法: node scripts/create-delta-package.mjs --platform <macos|windows> --from <旧版完整ZIP> --to <新版完整ZIP> --output <增量ZIP>');
    process.exit(2);
  }
}

const platform = options['--platform'];
if (!['macos', 'windows'].includes(platform)) throw new Error('平台必须是 macos 或 windows。');
const fromArchive = path.resolve(options['--from']);
const toArchive = path.resolve(options['--to']);
const output = path.resolve(options['--output']);
const versionExpression = platform === 'macos'
  ? /BiliFetch-macOS-(\d+\.\d+\.\d+)\.zip$/
  : /BiliFetch-Windows-x64-(\d+\.\d+\.\d+)\.zip$/;
const expectedRootName = platform === 'macos' ? 'BiliFetch.app' : 'BiliFetch-win32-x64';

function versionFrom(file) {
  const version = path.basename(file).match(versionExpression)?.[1];
  if (!version) throw new Error(`无法从完整包文件名读取 ${platform} 版本号：${path.basename(file)}`);
  return version;
}

function run(executable, argumentsList) {
  return new Promise((resolve, reject) => {
    const child = spawn(executable, argumentsList, { stdio: 'inherit' });
    child.once('error', reject);
    child.once('close', (code) => code === 0 ? resolve() : reject(new Error(`${path.basename(executable)} 退出代码 ${code}`)));
  });
}

function sha256(file) {
  return new Promise((resolve, reject) => {
    const hash = createHash('sha256');
    const stream = createReadStream(file);
    stream.once('error', reject);
    stream.on('data', (chunk) => hash.update(chunk));
    stream.once('end', () => resolve(hash.digest('hex')));
  });
}

async function findDirectory(root, name) {
  const entries = await readdir(root, { withFileTypes: true });
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const candidate = path.join(root, entry.name);
    if (entry.name === name) return candidate;
    const nested = await findDirectory(candidate, name);
    if (nested) return nested;
  }
  return null;
}

async function inventory(root, current = root, result = new Map()) {
  const entries = await readdir(current, { withFileTypes: true });
  for (const entry of entries) {
    const absolute = path.join(current, entry.name);
    const relative = path.relative(root, absolute).split(path.sep).join('/');
    if (entry.isDirectory()) {
      await inventory(root, absolute, result);
    } else if (entry.isFile()) {
      const info = await stat(absolute);
      result.set(relative, { absolute, sha256: await sha256(absolute), size: info.size, mode: info.mode & 0o777 });
    } else if (entry.isSymbolicLink()) {
      const target = await readlink(absolute);
      result.set(relative, { absolute, symlink: target, sha256: createHash('sha256').update(`symlink:${target}`).digest('hex'), size: 0, mode: 0 });
    } else {
      throw new Error(`不支持的文件类型：${relative}`);
    }
  }
  return result;
}

function appendOperation(operations, type, offset, length) {
  const previous = operations.at(-1);
  if (previous?.type === type && previous.offset + previous.length === offset) {
    previous.length += length;
  } else {
    operations.push({ type, offset, length });
  }
}

async function createBinaryPatch(oldEntry, newEntry) {
  if (!oldEntry || oldEntry.symlink || newEntry.symlink || Math.max(oldEntry.size, newEntry.size) < 1024 * 1024) return null;
  const [oldData, newData] = await Promise.all([readFile(oldEntry.absolute), readFile(newEntry.absolute)]);
  const blockSize = 64 * 1024;
  const oldBlocks = new Map();
  for (let offset = 0; offset < oldData.length; offset += blockSize) {
    const length = Math.min(blockSize, oldData.length - offset);
    const block = oldData.subarray(offset, offset + length);
    const key = `${length}:${createHash('sha256').update(block).digest('hex')}`;
    const offsets = oldBlocks.get(key) || [];
    offsets.push(offset);
    oldBlocks.set(key, offsets);
  }

  const operations = [];
  const dataParts = [];
  let dataOffset = 0;
  for (let offset = 0; offset < newData.length; offset += blockSize) {
    const length = Math.min(blockSize, newData.length - offset);
    const block = newData.subarray(offset, offset + length);
    const key = `${length}:${createHash('sha256').update(block).digest('hex')}`;
    const candidates = oldBlocks.get(key) || [];
    const expectedOffset = operations.at(-1)?.type === 'copy'
      ? operations.at(-1).offset + operations.at(-1).length
      : -1;
    const copyOffset = candidates.includes(expectedOffset) ? expectedOffset : candidates[0];
    if (copyOffset !== undefined && oldData.subarray(copyOffset, copyOffset + length).equals(block)) {
      appendOperation(operations, 'copy', copyOffset, length);
    } else {
      dataParts.push(block);
      appendOperation(operations, 'data', dataOffset, length);
      dataOffset += length;
    }
  }
  const patchData = Buffer.concat(dataParts);
  const estimatedSize = patchData.length + Buffer.byteLength(JSON.stringify(operations)) + 512;
  if (estimatedSize >= newData.length * 0.9) return null;
  return {
    data: patchData,
    metadata: {
      baseSha256: oldEntry.sha256,
      baseSize: oldEntry.size,
      dataSha256: createHash('sha256').update(patchData).digest('hex'),
      dataSize: patchData.length,
      operations
    }
  };
}

async function applyAndVerify(plan, deltaRoot, oldRoot, newFiles) {
  const reconstructed = path.join(path.dirname(deltaRoot), 'reconstructed', path.basename(oldRoot));
  await mkdir(path.dirname(reconstructed), { recursive: true });
  await run('/usr/bin/ditto', [oldRoot, reconstructed]);
  for (const relative of plan.deletePaths) {
    await rm(path.join(reconstructed, ...relative.split('/')), { recursive: true, force: true });
  }
  for (const file of plan.files) {
    const destination = path.join(reconstructed, ...file.path.split('/'));
    await mkdir(path.dirname(destination), { recursive: true });
    if (file.patch) {
      const [base, data] = await Promise.all([
        readFile(destination),
        readFile(path.join(deltaRoot, 'payload', ...file.patch.source.split('/')))
      ]);
      const chunks = file.patch.operations.map((operation) => {
        const source = operation.type === 'copy' ? base : data;
        return source.subarray(operation.offset, operation.offset + operation.length);
      });
      await writeFile(destination, Buffer.concat(chunks));
    } else {
      await rm(destination, { recursive: true, force: true });
      await copyFile(path.join(deltaRoot, 'payload', ...file.path.split('/')), destination);
    }
    await chmod(destination, file.mode);
  }
  const reconstructedFiles = await inventory(reconstructed);
  assertMatchingInventory(reconstructedFiles, newFiles);
  if (platform === 'macos' && newFiles.has('Contents/_CodeSignature/CodeResources')) {
    await run('/usr/bin/codesign', ['--verify', '--deep', '--strict', reconstructed]);
  }
}

function assertMatchingInventory(actual, expected) {
  if (actual.size !== expected.size) throw new Error(`增量验证文件数量不一致：${actual.size} != ${expected.size}`);
  for (const [relative, expectedEntry] of expected) {
    const actualEntry = actual.get(relative);
    if (!actualEntry || actualEntry.sha256 !== expectedEntry.sha256 || actualEntry.mode !== expectedEntry.mode || actualEntry.symlink !== expectedEntry.symlink) {
      throw new Error(`增量验证不一致：${relative}`);
    }
  }
}

const fromVersion = versionFrom(fromArchive);
const toVersion = versionFrom(toArchive);
if (fromVersion === toVersion) throw new Error('旧版与新版版本号相同，不能生成增量包。');

const temp = await mkdtemp(path.join(os.tmpdir(), 'bilifetch-delta-'));
try {
  const oldExtracted = path.join(temp, 'old');
  const newExtracted = path.join(temp, 'new');
  const deltaRoot = path.join(temp, 'delta');
  await Promise.all([mkdir(oldExtracted), mkdir(newExtracted), mkdir(path.join(deltaRoot, 'payload'), { recursive: true })]);
  await run('/usr/bin/ditto', ['-x', '-k', fromArchive, oldExtracted]);
  await run('/usr/bin/ditto', ['-x', '-k', toArchive, newExtracted]);
  const oldRoot = await findDirectory(oldExtracted, expectedRootName);
  const newRoot = await findDirectory(newExtracted, expectedRootName);
  if (!oldRoot || !newRoot) throw new Error(`完整包中没有找到 ${expectedRootName}。`);

  const [oldFiles, newFiles] = await Promise.all([inventory(oldRoot), inventory(newRoot)]);
  const files = [];
  for (const [relative, entry] of newFiles) {
    const oldEntry = oldFiles.get(relative);
    if (oldEntry?.sha256 === entry.sha256 && oldEntry?.mode === entry.mode) continue;
    if (entry.symlink) throw new Error(`新版包含发生变化的符号链接，暂不能制作安全增量包：${relative}`);
    const binaryPatch = await createBinaryPatch(oldEntry, entry);
    let patch = null;
    if (binaryPatch) {
      const source = `patches/${String(files.length).padStart(6, '0')}.bin`;
      const destination = path.join(deltaRoot, 'payload', ...source.split('/'));
      await mkdir(path.dirname(destination), { recursive: true });
      await writeFile(destination, binaryPatch.data);
      patch = { source, ...binaryPatch.metadata };
    } else {
      const destination = path.join(deltaRoot, 'payload', ...relative.split('/'));
      await mkdir(path.dirname(destination), { recursive: true });
      await copyFile(entry.absolute, destination);
      await chmod(destination, entry.mode);
    }
    files.push({ path: relative, sha256: entry.sha256, size: entry.size, mode: entry.mode, ...(patch ? { patch } : {}) });
  }
  const deletePaths = [...oldFiles.keys()].filter((relative) => !newFiles.has(relative)).sort();
  files.sort((left, right) => left.path.localeCompare(right.path));
  const plan = { formatVersion: 1, platform, fromVersion, toVersion, files, deletePaths };
  await writeFile(path.join(deltaRoot, 'delta.json'), `${JSON.stringify(plan, null, 2)}\n`, 'utf8');
  await applyAndVerify(plan, deltaRoot, oldRoot, newFiles);

  await mkdir(path.dirname(output), { recursive: true });
  await rm(output, { force: true });
  await run('/usr/bin/ditto', ['-c', '-k', '--norsrc', '--noextattr', deltaRoot, output]);
  const [deltaInfo, fullInfo] = await Promise.all([stat(output), stat(toArchive)]);
  if (deltaInfo.size >= fullInfo.size) {
    await rm(output, { force: true });
    console.log(JSON.stringify({ created: false, reason: 'delta-not-smaller', platform, fromVersion, toVersion, changedFiles: files.length, deletedFiles: deletePaths.length }));
  } else {
    console.log(JSON.stringify({ created: true, platform, fromVersion, toVersion, output, size: deltaInfo.size, changedFiles: files.length, deletedFiles: deletePaths.length }));
  }
} finally {
  await rm(temp, { recursive: true, force: true });
}
