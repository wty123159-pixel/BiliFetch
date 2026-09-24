'use strict';

const { spawn } = require('node:child_process');
const crypto = require('node:crypto');
const path = require('node:path');
const { setTimeout: delay } = require('node:timers/promises');
const fs = process.versions.electron ? require('original-fs') : require('node:fs');
const { createWindowsInstallScript } = require('./update-core');
const io = fs.promises;

async function readStatus(file) {
  try { return JSON.parse((await io.readFile(file, 'utf8')).replace(/^\uFEFF/, '')); }
  catch { return null; } // A read can overlap the helper's small status write.
}

async function startWindowsInstall({ source, target, executable, processId, version, updatesDirectory,
  bootstrapper, spawnImpl = spawn, startupTimeout = 120000, helperArguments = [] }) {
  source = path.resolve(source);
  target = path.resolve(target);
  const relative = path.relative(target, source);
  if (!relative || (!path.isAbsolute(relative) && relative !== '..' && !relative.startsWith(`..${path.sep}`)) ||
      target === path.parse(target).root || path.basename(executable) !== executable) {
    throw new Error('更新源与安装目录无效，原软件未退出。');
  }
  await io.mkdir(updatesDirectory, { recursive: true });
  const attemptId = crypto.randomUUID();
  const statusFile = path.join(updatesDirectory, `install-${attemptId}.json`);
  const helper = path.join(updatesDirectory, `install-${attemptId}.ps1`);
  const logFile = path.join(updatesDirectory, 'update-install.log');
  await io.writeFile(helper, '\uFEFF' + createWindowsInstallScript(), 'utf8');
  await io.writeFile(path.join(updatesDirectory, 'last-install.json'), JSON.stringify({ attemptId }), 'utf8');
  const launcher = path.join(updatesDirectory, `install-${attemptId}.exe`);
  let child;
  let spawnError;
  let exited = null;
  let output;
  try {
    await io.copyFile(bootstrapper, launcher);
    // Capture pre-script errors as well, e.g. execution policy / missing shell.
    // A file handle (not a pipe) lets the installer outlive the Electron parent.
    output = await io.open(`${statusFile}.launcher.log`, 'a');
    child = spawnImpl(launcher, ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', helper,
      '-Source', source, '-Target', target, '-Executable', executable, '-ProcessId', String(processId),
      '-Version', version, '-AttemptId', attemptId, '-StatusFile', statusFile, '-LogFile', logFile,
      '-LockDirectory', path.join(updatesDirectory, 'install-update.lock'), ...helperArguments],
    // Detach the native bootstrapper from libuv's kill-on-parent-exit job.
    // It starts PowerShell hidden WITHOUT DETACHED_PROCESS (which makes
    // PowerShell silently exit on affected Windows installations).
    { detached: true, windowsHide: true, stdio: ['ignore', output.fd, output.fd], cwd: updatesDirectory });
    child.once('error', error => { spawnError = error; });
    child.once('exit', (code, signal) => { exited = { code, signal }; });
    const deadline = Date.now() + startupTimeout;
    while (Date.now() < deadline) {
      if (spawnError) throw spawnError;
      const status = await readStatus(statusFile);
      if (status?.state === 'failed') throw new Error(status.message);
      if (exited) throw new Error(`安装组件提前退出（代码 ${exited.code ?? exited.signal}）。`);
      if (status?.state === 'ready' && status.attemptId === attemptId) {
        await io.writeFile(`${statusFile}.commit`, 'install', 'utf8');
        child.unref();
        return { attemptId, statusFile, logFile };
      }
      await delay(100);
    }
    throw new Error('安装准备超时。');
  } catch (error) {
    await io.writeFile(`${statusFile}.cancel`, 'cancel', 'utf8').catch(() => {});
    await io.appendFile(logFile, `${new Date().toISOString()} [${attemptId}] Launcher: ${error.message}\n`).catch(() => {});
    child?.unref();
    throw new Error(`无法开始安装更新，原软件未退出。${error.message}\n安装日志：${logFile}\n启动日志：${statusFile}.launcher.log`, { cause: error });
  } finally {
    await output?.close();
  }
}

async function acknowledgeWindowsInstall({ argv, version, executable, updatesDirectory }) {
  const match = argv.find(value => /^--bilifetch-update=[0-9a-f-]{36}$/.test(value));
  if (!match) return false;
  const attemptId = match.slice('--bilifetch-update='.length);
  const statusFile = path.join(updatesDirectory, `install-${attemptId}.json`);
  const status = await readStatus(statusFile);
  if (status?.state !== 'launching' || status.attemptId !== attemptId || status.version !== version ||
      path.resolve(status.target, status.executable).toLowerCase() !== path.resolve(executable).toLowerCase()) return false;
  await io.writeFile(`${statusFile}.started`, JSON.stringify({ attemptId, version, executable }), 'utf8');
  return true;
}

module.exports = { acknowledgeWindowsInstall, readStatus, startWindowsInstall };
