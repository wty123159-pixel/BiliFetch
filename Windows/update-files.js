'use strict';

// Updates contain app.asar itself. Electron's normal fs APIs expose that file
// as a virtual directory, so all staging I/O must use the real filesystem.
const fs = process.versions.electron ? require('original-fs') : require('node:fs');
const fsp = fs.promises;
const crypto = require('node:crypto');
const path = require('node:path');
const { pipeline } = require('node:stream/promises');
const yauzl = require('yauzl');
const updateCore = require('./update-core');

async function findFile(root, fileName) {
  for (const entry of await fsp.readdir(root, { withFileTypes: true })) {
    const candidate = path.join(root, entry.name);
    if (entry.isFile() && entry.name.toLowerCase() === fileName.toLowerCase()) return candidate;
    if (entry.isDirectory()) {
      const found = await findFile(candidate, fileName);
      if (found) return found;
    }
  }
  return null;
}

async function extractArchive(archive, destination) {
  await fsp.mkdir(destination, { recursive: true });
  const root = await fsp.realpath(destination);
  const zip = await new Promise((resolve, reject) => {
    yauzl.open(archive, { lazyEntries: true, strictFileNames: true, validateEntrySizes: true },
      (error, value) => error ? reject(error) : resolve(value));
  });

  async function extractEntry(entry) {
    if (entry.fileName.startsWith('__MACOSX/')) return;
    const name = entry.fileName.replace(/\/$/, '');
    const target = safeUpdateChild(root, name);
    const type = (entry.externalFileAttributes >>> 16) & 0o170000;
    const isDirectory = entry.fileName.endsWith('/') || type === 0o040000;
    if (type && type !== 0o040000 && type !== 0o100000) {
      throw new Error('更新包包含不支持的链接或特殊文件。');
    }
    const parent = path.dirname(target);
    await fsp.mkdir(parent, { recursive: true });
    const relativeParent = path.relative(root, await fsp.realpath(parent));
    if (path.isAbsolute(relativeParent) || relativeParent.split(path.sep).includes('..')) {
      throw new Error('更新包文件超出解压目录。');
    }
    const mode = ((entry.externalFileAttributes >>> 16) & 0o777) || (isDirectory ? 0o755 : 0o644);
    if (isDirectory) {
      await fsp.mkdir(target, { recursive: true, mode });
      return;
    }
    const input = await new Promise((resolve, reject) => {
      zip.openReadStream(entry, (error, value) => error ? reject(error) : resolve(value));
    });
    await pipeline(input, fs.createWriteStream(target, { flags: 'wx', mode, fs }));
  }

  await new Promise((resolve, reject) => {
    let failure = null;
    let ended = false;
    const fail = (error) => { failure ||= error; zip.close(); };
    zip.on('error', fail);
    zip.once('end', () => { ended = true; });
    // Waiting for close also releases the ZIP handle before a Windows retry
    // removes the failed staging directory.
    zip.once('close', () => {
      if (failure) reject(failure);
      else if (!ended) reject(new Error('更新包解压意外中断。'));
      else resolve();
    });
    zip.on('entry', (entry) => {
      extractEntry(entry).then(() => { if (!failure) zip.readEntry(); }, fail);
    });
    zip.readEntry();
  });
}

async function sha256File(file) {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash('sha256');
    const input = fs.createReadStream(file, { fs });
    input.on('error', reject);
    input.on('data', (chunk) => hash.update(chunk));
    input.on('end', () => resolve(hash.digest('hex')));
  });
}

function safeUpdateChild(root, relativePath) {
  if (!updateCore.isSafeRelativePath(relativePath)) throw new Error('增量包包含不安全的文件路径。');
  const normalizedRoot = path.resolve(root);
  const candidate = path.resolve(normalizedRoot, ...relativePath.split('/'));
  if (!candidate.startsWith(`${normalizedRoot}${path.sep}`)) throw new Error('增量包文件超出应用目录。');
  return candidate;
}

async function applyBinaryUpdatePatch(patch, dataFile, baseFile) {
  const [baseInfo, dataInfo] = await Promise.all([fsp.stat(baseFile), fsp.stat(dataFile)]);
  if (!baseInfo.isFile() || !dataInfo.isFile() || baseInfo.size !== patch.baseSize || dataInfo.size !== patch.dataSize ||
      await sha256File(baseFile) !== patch.baseSha256 || await sha256File(dataFile) !== patch.dataSha256) {
    throw new Error('二进制补丁的基础文件或数据校验失败。');
  }
  const temporary = `${baseFile}.bilifetch-patch-${Date.now()}-${crypto.randomBytes(4).toString('hex')}`;
  let baseHandle;
  let dataHandle;
  let outputHandle;
  try {
    try {
      baseHandle = await fsp.open(baseFile, 'r');
      dataHandle = await fsp.open(dataFile, 'r');
      outputHandle = await fsp.open(temporary, 'wx');
      const buffer = Buffer.allocUnsafe(1024 * 1024);
      for (const operation of patch.operations) {
        const input = operation.type === 'copy' ? baseHandle : dataHandle;
        let position = operation.offset;
        let remaining = operation.length;
        while (remaining > 0) {
          const count = Math.min(remaining, buffer.length);
          const { bytesRead } = await input.read(buffer, 0, count, position);
          if (bytesRead !== count) throw new Error('二进制补丁数据不完整。');
          await outputHandle.write(buffer, 0, bytesRead, null);
          position += bytesRead;
          remaining -= bytesRead;
        }
      }
      await outputHandle.sync();
    } finally {
      await Promise.allSettled([baseHandle?.close(), dataHandle?.close(), outputHandle?.close()]);
    }
    await fsp.rm(baseFile, { force: true });
    await fsp.rename(temporary, baseFile);
  } catch (error) {
    await fsp.rm(temporary, { force: true });
    throw error;
  }
}

async function stageDelta({ extracted, currentRoot, currentVersion, targetVersion, staged, executableName = 'BiliFetch.exe' }) {
  const planFile = await findFile(extracted, 'delta.json');
  if (!planFile) throw new Error('增量包缺少 delta.json。');
  const plan = updateCore.validateDeltaPlan(JSON.parse(await fsp.readFile(planFile, 'utf8')), currentVersion, targetVersion);
  const payload = path.join(path.dirname(planFile), 'payload');
  await fsp.rm(staged, { recursive: true, force: true });
  await fsp.mkdir(path.dirname(staged), { recursive: true });
  await fsp.cp(currentRoot, staged, { recursive: true, force: true, errorOnExist: false });

  for (const relativePath of plan.deletePaths) {
    await fsp.rm(safeUpdateChild(staged, relativePath), { recursive: true, force: true });
  }
  for (const file of plan.files) {
    const destination = safeUpdateChild(staged, file.path);
    await fsp.mkdir(path.dirname(destination), { recursive: true });
    if (file.patch) {
      const patchData = safeUpdateChild(payload, file.patch.source);
      await applyBinaryUpdatePatch(file.patch, patchData, destination);
    } else {
      const source = safeUpdateChild(payload, file.path);
      const sourceInfo = await fsp.stat(source);
      if (!sourceInfo.isFile() || sourceInfo.size !== file.size || await sha256File(source) !== file.sha256) {
        throw new Error(`增量文件校验失败：${file.path}`);
      }
      await fsp.rm(destination, { recursive: true, force: true });
      await fsp.copyFile(source, destination);
    }
    const destinationInfo = await fsp.stat(destination);
    if (!destinationInfo.isFile() || destinationInfo.size !== file.size || await sha256File(destination) !== file.sha256) {
      throw new Error(`应用增量后文件校验失败：${file.path}`);
    }
  }
  const executable = path.join(staged, executableName);
  const executableInfo = await fsp.stat(executable);
  if (!executableInfo.isFile()) throw new Error('增量更新未生成有效的 BiliFetch.exe。');
  return staged;
}

module.exports = { fs, extractArchive, findFile, sha256File, stageDelta };
