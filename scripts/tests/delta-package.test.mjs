import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { spawn } from 'node:child_process';
import { copyFile, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const generator = path.join(repository, 'scripts', 'create-delta-package.mjs');
const manifestGenerator = path.join(repository, 'scripts', 'create-release-manifest.mjs');

function run(executable, argumentsList) {
  return new Promise((resolve, reject) => {
    const child = spawn(executable, argumentsList, { stdio: ['ignore', 'pipe', 'pipe'] });
    let output = '';
    let error = '';
    child.stdout.on('data', (chunk) => { output += chunk; });
    child.stderr.on('data', (chunk) => { error += chunk; });
    child.once('error', reject);
    child.once('close', (code) => code === 0 ? resolve(output) : reject(new Error(error || `退出代码 ${code}`)));
  });
}

async function findFile(root, name) {
  const entries = await readdir(root, { withFileTypes: true });
  for (const entry of entries) {
    const candidate = path.join(root, entry.name);
    if (entry.isFile() && entry.name === name) return candidate;
    if (entry.isDirectory()) {
      const nested = await findFile(candidate, name);
      if (nested) return nested;
    }
  }
  return null;
}

for (const platform of ['macos', 'windows']) {
  test(`creates a compatible ${platform} file-level delta`, async () => {
    const temp = await mkdtemp(path.join(os.tmpdir(), `bilifetch-${platform}-delta-test-`));
    try {
      const rootName = platform === 'macos' ? 'BiliFetch.app' : 'BiliFetch-win32-x64';
      const oldRoot = path.join(temp, 'old', rootName);
      const newRoot = path.join(temp, 'new', rootName);
      await Promise.all([mkdir(oldRoot, { recursive: true }), mkdir(newRoot, { recursive: true })]);
      const shared = path.join(temp, 'shared.bin');
      await writeFile(shared, randomBytes(2 * 1024 * 1024));
      const oldLarge = randomBytes(4 * 1024 * 1024);
      const newLarge = Buffer.from(oldLarge);
      newLarge.fill(0x5a, 2 * 1024 * 1024, 2 * 1024 * 1024 + 32);
      await Promise.all([
        copyFile(shared, path.join(oldRoot, 'shared.bin')),
        copyFile(shared, path.join(newRoot, 'shared.bin')),
        writeFile(path.join(oldRoot, 'changed.txt'), 'old'),
        writeFile(path.join(newRoot, 'changed.txt'), 'new'),
        writeFile(path.join(oldRoot, 'obsolete.txt'), 'remove me'),
        writeFile(path.join(newRoot, 'added.txt'), 'add me'),
        writeFile(path.join(oldRoot, 'large.bin'), oldLarge),
        writeFile(path.join(newRoot, 'large.bin'), newLarge)
      ]);
      const oldArchive = path.join(temp, platform === 'macos' ? 'BiliFetch-macOS-1.0.0.zip' : 'BiliFetch-Windows-x64-1.0.0.zip');
      const newArchive = path.join(temp, platform === 'macos' ? 'BiliFetch-macOS-1.0.1.zip' : 'BiliFetch-Windows-x64-1.0.1.zip');
      const deltaArchive = path.join(temp, platform === 'macos' ? 'BiliFetch-macOS-delta-1.0.0-to-1.0.1.zip' : 'BiliFetch-Windows-x64-delta-1.0.0-to-1.0.1.zip');
      await run('/usr/bin/ditto', ['-c', '-k', '--keepParent', oldRoot, oldArchive]);
      await run('/usr/bin/ditto', ['-c', '-k', '--keepParent', newRoot, newArchive]);
      const generatorOutput = await run(process.execPath, [generator, '--platform', platform, '--from', oldArchive, '--to', newArchive, '--output', deltaArchive]);
      assert.equal(JSON.parse(generatorOutput.trim()).created, true);

      const unpacked = path.join(temp, 'delta-unpacked');
      await mkdir(unpacked);
      await run('/usr/bin/ditto', ['-x', '-k', deltaArchive, unpacked]);
      const planFile = await findFile(unpacked, 'delta.json');
      assert.ok(planFile);
      const plan = JSON.parse(await readFile(planFile, 'utf8'));
      assert.equal(plan.platform, platform);
      assert.equal(plan.fromVersion, '1.0.0');
      assert.equal(plan.toVersion, '1.0.1');
      assert.deepEqual(plan.files.map((file) => file.path), ['added.txt', 'changed.txt', 'large.bin']);
      assert.deepEqual(plan.deletePaths, ['obsolete.txt']);
      assert.equal(await readFile(path.join(path.dirname(planFile), 'payload', 'changed.txt'), 'utf8'), 'new');
      const largeEntry = plan.files.find((file) => file.path === 'large.bin');
      assert.ok(largeEntry.patch);
      const patchData = await readFile(path.join(path.dirname(planFile), 'payload', largeEntry.patch.source));
      const reconstructed = Buffer.concat(largeEntry.patch.operations.map((operation) => {
        const source = operation.type === 'copy' ? oldLarge : patchData;
        return source.subarray(operation.offset, operation.offset + operation.length);
      }));
      assert.deepEqual(reconstructed, newLarge);
    } finally {
      await rm(temp, { recursive: true, force: true });
    }
  });
}

test('writes backward-compatible full assets and optional deltas to update.json', async () => {
  const temp = await mkdtemp(path.join(os.tmpdir(), 'bilifetch-delta-manifest-test-'));
  try {
    const windows = path.join(temp, 'BiliFetch-Windows-x64-1.1.4.zip');
    const windowsDelta = path.join(temp, 'BiliFetch-Windows-x64-delta-1.1.3-to-1.1.4.zip');
    const macos = path.join(temp, 'BiliFetch-macOS-1.5.11.zip');
    const macosDelta = path.join(temp, 'BiliFetch-macOS-delta-1.5.10-to-1.5.11.zip');
    const output = path.join(temp, 'update.json');
    await Promise.all([
      writeFile(windows, 'windows full'), writeFile(windowsDelta, 'windows delta'),
      writeFile(macos, 'mac full'), writeFile(macosDelta, 'mac delta')
    ]);
    await run(process.execPath, [
      manifestGenerator,
      '--windows', windows, '--windows-url', 'https://example.com/windows-full.zip',
      '--windows-delta', windowsDelta, '--windows-delta-url', 'https://example.com/windows-delta.zip',
      '--macos', macos, '--macos-url', 'https://example.com/macos-full.zip',
      '--macos-delta', macosDelta, '--macos-delta-url', 'https://example.com/macos-delta.zip',
      '--output', output
    ]);
    const manifest = JSON.parse(await readFile(output, 'utf8'));
    assert.equal(manifest.schemaVersion, 2);
    assert.equal(manifest.windows.url, 'https://example.com/windows-full.zip');
    assert.equal(manifest.windows.deltas[0].fromVersion, '1.1.3');
    assert.equal(manifest.macos.version, '1.5.11');
    assert.equal(manifest.macos.deltas[0].fromVersion, '1.5.10');
  } finally {
    await rm(temp, { recursive: true, force: true });
  }
});
