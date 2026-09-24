'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const os = require('node:os');
const path = require('node:path');
const { EventEmitter } = require('node:events');
const { spawn } = require('node:child_process');
const { setTimeout: delay } = require('node:timers/promises');
const fs = process.versions.electron ? require('original-fs') : require('node:fs');
const io = fs.promises;
const { startWindowsInstall, acknowledgeWindowsInstall, readStatus } = require('../update-installer');

async function fixture(t) {
  const root = await io.mkdtemp(path.join(os.tmpdir(), 'bilifetch-installer-'));
  t.after(() => io.rm(root, { recursive: true, force: true, maxRetries: 20, retryDelay: 100 }));
  const bootstrapper = process.env.BILIFETCH_INSTALL_LAUNCHER || path.join(root, 'fixture-bootstrapper.exe');
  if (!process.env.BILIFETCH_INSTALL_LAUNCHER) await io.writeFile(bootstrapper, 'unused test bootstrapper');
  return { source: path.join(root, 'source'), target: path.join(root, 'target'), executable: 'app.exe',
    processId: process.pid, version: '1.1.12', updatesDirectory: path.join(root, 'Updates'), startupTimeout: 500, bootstrapper };
}

test('a missing installer executable rejects without reporting ready', async t => {
  const options = await fixture(t);
  await assert.rejects(startWindowsInstall({ ...options, bootstrapper: path.join(options.target, 'missing.exe') }), /原软件未退出.*ENOENT/);
  const { attemptId } = JSON.parse(await io.readFile(path.join(options.updatesDirectory, 'last-install.json')));
  assert.equal(await io.readFile(path.join(options.updatesDirectory, `install-${attemptId}.json.cancel`), 'utf8'), 'cancel');
});

test('a helper that never becomes ready is cancelled, never committed', async t => {
  const options = await fixture(t);
  const child = new EventEmitter(); child.unref = () => {};
  await assert.rejects(startWindowsInstall({ ...options, spawnImpl: () => child, startupTimeout: 20 }), /准备超时/);
  const names = await io.readdir(options.updatesDirectory);
  assert(names.some(name => name.endsWith('.cancel')));
  assert(!names.some(name => name.endsWith('.commit')));
});

test('preparation failures are surfaced while the original application stays open', async t => {
  const options = await fixture(t);
  const child = new EventEmitter(); child.unref = () => {};
  const spawnImpl = (_shell, args) => {
    fs.writeFileSync(args[args.indexOf('-StatusFile') + 1], JSON.stringify({ state: 'failed', message: 'Access denied' }));
    return child;
  };
  await assert.rejects(startWindowsInstall({ ...options, spawnImpl }), /Access denied/);
});

test('only a matching ready response permits the old application to exit', async t => {
  const options = await fixture(t);
  const child = new EventEmitter(); child.unref = () => {};
  const result = await startWindowsInstall({ ...options, spawnImpl: (_shell, args) => {
    fs.writeFileSync(args[args.indexOf('-StatusFile') + 1], JSON.stringify({ state: 'ready', attemptId: args[args.indexOf('-AttemptId') + 1] }));
    return child;
  } });
  assert.equal(await io.readFile(`${result.statusFile}.commit`, 'utf8'), 'install');
});

test('startup confirmation requires the expected version and executable path', async t => {
  const options = await fixture(t);
  await io.mkdir(options.updatesDirectory);
  const attemptId = '12345678-1234-1234-1234-123456789abc';
  const file = path.join(options.updatesDirectory, `install-${attemptId}.json`);
  await io.writeFile(file, JSON.stringify({ state: 'launching', attemptId, version: options.version, target: options.target, executable: options.executable }));
  const args = { argv: [`--bilifetch-update=${attemptId}`], version: options.version, executable: path.join(options.target, options.executable), updatesDirectory: options.updatesDirectory };
  assert.equal(await acknowledgeWindowsInstall({ ...args, version: '1.1.10' }), false);
  assert.equal(await acknowledgeWindowsInstall({ ...args, executable: path.join(options.source, options.executable) }), false);
  assert.equal(await acknowledgeWindowsInstall(args), true);
  assert.equal((await readStatus(`${file}.started`)).version, options.version);
});

test('rejects an update source inside the directory about to be replaced', async t => {
  const options = await fixture(t);
  await assert.rejects(startWindowsInstall({ ...options, source: path.join(options.target, 'staged') }), /目录无效/);
});

test('hidden Windows PowerShell actually executes preflight instead of silently exiting', { skip: process.platform !== 'win32' || !process.env.BILIFETCH_INSTALL_LAUNCHER }, async t => {
  const options = await fixture(t);
  await assert.rejects(startWindowsInstall({ ...options, startupTimeout: 15000 }), /Update source or target is missing/);
});

test('native installer survives its Node or Electron parent exiting and confirms restart', {
  skip: process.platform !== 'win32' || !process.env.BILIFETCH_INSTALL_LAUNCHER || !process.env.BILIFETCH_INSTALL_PROBE
}, async t => {
  const options = { ...await fixture(t), startupTimeout: 20000, helperArguments: ['-Quiet'] };
  await io.mkdir(options.source);
  await io.mkdir(options.target);
  for (const dir of [options.source, options.target]) await io.copyFile(process.env.BILIFETCH_INSTALL_PROBE, path.join(dir, 'app.exe'));
  await io.writeFile(path.join(options.source, 'version.txt'), options.version);
  await io.writeFile(path.join(options.target, 'version.txt'), '1.1.10');
  const old = spawn(path.join(options.target, 'app.exe'), ['--wait-for-exit'], { windowsHide: true, stdio: 'ignore' });
  t.after(() => old.kill());
  options.processId = old.pid;
  const preparedFile = path.join(path.dirname(options.source), 'prepared.json');
  const controller = spawn(process.execPath, ['-e', `
    const fs=require('node:fs');
    require(${JSON.stringify(require.resolve('../update-installer'))}).startWindowsInstall(${JSON.stringify(options)})
      .then(result=>{
        fs.writeFileSync(${JSON.stringify(preparedFile)},JSON.stringify(result));
        fs.writeFileSync(${JSON.stringify(path.join(options.target, 'exit.txt'))},'exit');
        process.exit(0);
      }).catch(error=>{console.error(error);process.exit(1);});
  `], { windowsHide: true, env: { ...process.env, BILIFETCH_INSTALL_TEST_UPDATES: options.updatesDirectory }, stdio: ['ignore', 'ignore', 'pipe'] });
  let stderr = '';
  controller.stderr.on('data', chunk => { stderr += chunk; });
  assert.equal(await new Promise((resolve, reject) => { controller.once('error', reject); controller.once('exit', resolve); }), 0, stderr);
  const prepared = JSON.parse(await io.readFile(preparedFile, 'utf8'));
  let state;
  const deadline = Date.now() + 30000;
  do {
    state = await readStatus(prepared.statusFile);
    if (['installed', 'failed'].includes(state?.state)) break;
    await delay(100);
  } while (Date.now() < deadline);
  assert.equal(state?.state, 'installed', JSON.stringify(state));
  assert.equal(await io.readFile(path.join(options.target, 'version.txt'), 'utf8'), options.version);
  assert.match(await io.readFile(path.join(options.target, 'restarted.txt'), 'utf8'), /^1\.1\.12/);
  // The probe exits after two seconds; release its Windows executable handle.
  await delay(2300);
});
