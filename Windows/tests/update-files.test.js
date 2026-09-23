'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const update = require('../update-files');
const io = update.fs.promises;
const fixtures = path.join(__dirname, 'fixtures');
const digest = (buffer) => crypto.createHash('sha256').update(buffer).digest('hex');

if (process.env.BILIFETCH_ELECTRON_TEST_VERSION) {
  assert.equal(process.versions.electron, process.env.BILIFETCH_ELECTRON_TEST_VERSION,
    'The Electron regression suite must run in the pinned Electron runtime.');
}

async function workspace(t) {
  const root = await io.mkdtemp(path.join(os.tmpdir(), 'bilifetch-update-files-'));
  t.after(() => io.rm(root, { recursive: true, force: true }));
  return root;
}

test('extracts a real ASAR as bytes without disabling Electron archive access', { timeout: 10000 }, async (t) => {
  const root = await workspace(t);
  const target = path.join(root, '用户 更新 files');
  const previousNoAsar = process.noAsar;
  await update.extractArchive(path.join(fixtures, 'full-update.zip'), target);
  const asar = path.join(target, 'BiliFetch-win32-x64/resources/app.asar');
  const expected = await io.readFile(path.join(fixtures, 'app-1.0.1.asar'));
  assert.ok((await io.stat(asar)).isFile());
  assert.deepEqual(await io.readFile(asar), expected);
  assert.equal(await update.sha256File(asar), digest(expected));
  assert.equal(process.noAsar, previousNoAsar);
  assert.equal(await update.findFile(target, 'BiliFetch.exe'), path.join(target, 'BiliFetch-win32-x64/BiliFetch.exe'));
  if (process.versions.electron) {
    assert.ok(fs.statSync(asar).isDirectory());
    assert.equal(JSON.parse(fs.readFileSync(path.join(asar, 'package.json'), 'utf8')).version, '1.0.1');
  }
});

test('does not find an executable inside the virtual ASAR directory', async (t) => {
  const root = await workspace(t);
  await io.copyFile(path.join(fixtures, 'app-1.0.0.asar'), path.join(root, 'app.asar'));
  assert.equal(await update.findFile(root, 'BiliFetch.exe'), null);
});

async function deltaWorkspace(t, binaryPatch, wrongBase = false) {
  const root = await workspace(t);
  const currentRoot = path.join(root, 'installed app');
  const extracted = path.join(root, 'extracted');
  const staged = path.join(root, 'staged app');
  const oldBytes = await io.readFile(path.join(fixtures, 'app-1.0.0.asar'));
  const newBytes = await io.readFile(path.join(fixtures, 'app-1.0.1.asar'));
  await io.mkdir(path.join(currentRoot, 'resources'), { recursive: true });
  await io.writeFile(path.join(currentRoot, 'BiliFetch.exe'), 'MZ fixture');
  await io.writeFile(path.join(currentRoot, 'resources/app.asar'), oldBytes);
  await io.writeFile(path.join(currentRoot, 'keep.txt'), 'keep the unchanged file');
  const payloadName = binaryPatch ? 'patches/app.bin' : 'resources/app.asar';
  const payload = path.join(extracted, 'payload', payloadName);
  await io.mkdir(path.dirname(payload), { recursive: true });
  await io.writeFile(payload, newBytes);
  const file = { path: 'resources/app.asar', sha256: digest(newBytes), size: newBytes.length };
  if (binaryPatch) {
    file.patch = {
      source: payloadName, baseSha256: wrongBase ? '0'.repeat(64) : digest(oldBytes),
      baseSize: oldBytes.length, dataSha256: digest(newBytes), dataSize: newBytes.length,
      operations: [{ type: 'data', offset: 0, length: newBytes.length }]
    };
  }
  await io.writeFile(path.join(extracted, 'delta.json'), JSON.stringify({
    formatVersion: 1, platform: 'windows', fromVersion: '1.0.0', toVersion: '1.0.1',
    files: [file], deletePaths: []
  }));
  return { currentRoot, extracted, staged, oldBytes, newBytes, currentVersion: '1.0.0', targetVersion: '1.0.1' };
}

for (const binaryPatch of [false, true]) {
  test(`stages an ASAR ${binaryPatch ? 'binary patch' : 'file replacement'} and preserves the installed app`, { timeout: 10000 }, async (t) => {
    const fixture = await deltaWorkspace(t, binaryPatch);
    assert.equal(await update.stageDelta(fixture), fixture.staged);
    assert.deepEqual(await io.readFile(path.join(fixture.staged, 'resources/app.asar')), fixture.newBytes);
    assert.deepEqual(await io.readFile(path.join(fixture.currentRoot, 'resources/app.asar')), fixture.oldBytes);
    assert.equal(await io.readFile(path.join(fixture.staged, 'keep.txt'), 'utf8'), 'keep the unchanged file');
  });
}

test('rejects a mismatched ASAR base without changing the installed app', async (t) => {
  const fixture = await deltaWorkspace(t, true, true);
  await assert.rejects(update.stageDelta(fixture), /基础文件或数据校验失败/);
  assert.deepEqual(await io.readFile(path.join(fixture.currentRoot, 'resources/app.asar')), fixture.oldBytes);
});

for (const [name, message] of [
  ['traversal-update.zip', /invalid relative path|不安全|超出/],
  ['symlink-update.zip', /链接或特殊文件/],
  ['duplicate-update.zip', /EEXIST/]
]) {
  test(`rejects unsafe ZIP entries in ${name}`, { timeout: 10000 }, async (t) => {
    const root = await workspace(t);
    await assert.rejects(update.extractArchive(path.join(fixtures, name), path.join(root, 'extract')), message);
    assert.equal(update.fs.existsSync(path.join(root, 'escaped.txt')), false);
  });
}
