import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { copyFile, mkdir, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const script = path.join(repository, 'scripts/prepare-windows-tools.sh');
const releaseName = 'BiliFetch-Windows-x64-1.1.6.zip';
const originalName = 'ffmpeg-n9.0.1-11-ge47273f4d9-win64-lgpl-shared-9.0.zip';
const files = [
  'ffmpeg.exe', 'ffprobe.exe', 'avcodec-63.dll', 'avdevice-63.dll',
  'avfilter-12.dll', 'avformat-63.dll', 'avutil-61.dll', 'swresample-7.dll', 'swscale-10.dll'
];
const sha256 = (data) => createHash('sha256').update(data).digest('hex');

async function fixture(t, omittedFile) {
  const root = await mkdtemp(path.join(os.tmpdir(), 'bilifetch tools test '));
  t.after(() => rm(root, { recursive: true, force: true }));
  const archiveRoot = path.join(root, 'release');
  const toolsDir = path.join(archiveRoot, 'BiliFetch-win32-x64/resources/tools');
  const originalRoot = path.join(root, 'original');
  const originalBin = path.join(originalRoot, 'ffmpeg/bin');
  await Promise.all([
    mkdir(toolsDir, { recursive: true }), mkdir(originalBin, { recursive: true }),
    mkdir(path.join(root, 'cache')), mkdir(path.join(root, 'build/previous-release'), { recursive: true })
  ]);
  for (const name of files) {
    const contents = `pinned FFmpeg bytes: ${name}`;
    await writeFile(path.join(originalBin, name), contents);
    if (name !== omittedFile) await writeFile(path.join(toolsDir, name), contents);
  }
  await writeFile(path.join(toolsDir, 'yt-dlp.exe'), 'old yt-dlp must not be restored');
  await writeFile(path.join(toolsDir, 'unrelated.dll'), 'unrelated library must not be restored');
  await writeFile(path.join(archiveRoot, 'BiliFetch-win32-x64/resources/app.asar'), 'old app must not be restored');
  const releaseZip = path.join(root, 'release.zip');
  const originalZip = path.join(root, 'original.zip');
  for (const [cwd, output] of [[archiveRoot, releaseZip], [originalRoot, originalZip]]) {
    const result = spawnSync('/usr/bin/zip', ['-qr', output, '.'], { cwd, encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
  }
  return {
    root, releaseZip, originalZip,
    releaseHash: sha256(await readFile(releaseZip)), originalHash: sha256(await readFile(originalZip)),
    cachedRelease: path.join(root, 'cache', releaseName),
    cachedOriginal: path.join(root, 'cache', originalName),
    previousRelease: path.join(root, 'build/previous-release', releaseName)
  };
}

function prepare(f, { download = f.releaseZip, expected = f.releaseHash } = {}) {
  return spawnSync('/bin/zsh', ['-c', `
    source "$1"
    PROJECT_DIR="$2"
    CACHE_DIR="$2/cache"
    FFMPEG_RELEASE_URL="$3"
    FFMPEG_RELEASE_SHA256="$4"
    FFMPEG_SHA256="$5"
    mkdir -p "$TEMP_DIR/ffmpeg"
    prepare_ffmpeg
    cp -R "$TEMP_DIR/ffmpeg" "$2/output"
  `, '--', script, f.root, pathToFileURL(download).href, expected, f.originalHash], {
    encoding: 'utf8', timeout: 30000
  });
}

async function assertRestored(f, result) {
  assert.equal(result.status, 0, result.stdout + result.stderr);
  const output = path.join(f.root, 'output/BiliFetch-win32-x64/resources/tools');
  assert.deepEqual((await readdir(output)).sort(), [...files].sort());
  for (const name of files) {
    assert.equal(await readFile(path.join(output, name), 'utf8'), `pinned FFmpeg bytes: ${name}`);
  }
  await assert.rejects(readFile(path.join(f.root, 'output/BiliFetch-win32-x64/resources/app.asar')));
}

test('prepares FFmpeg from a cold cache without depending on the expired upstream URL', async (t) => {
  const f = await fixture(t);
  await assertRestored(f, prepare(f));
  assert.equal(sha256(await readFile(f.cachedRelease)), f.releaseHash);
});

test('reuses the verified previous release already downloaded by the workflow', async (t) => {
  const f = await fixture(t);
  await copyFile(f.releaseZip, f.previousRelease);
  const result = prepare(f, { download: path.join(f.root, 'unavailable.zip') });
  await assertRestored(f, result);
  assert.match(result.stdout, /复用已下载的历史发布包/);
});

test('uses a verified recovery cache while offline', async (t) => {
  const f = await fixture(t);
  await copyFile(f.releaseZip, f.cachedRelease);
  await assertRestored(f, prepare(f, { download: path.join(f.root, 'unavailable.zip') }));
});

test('continues to accept the checksum-pinned original archive cache', async (t) => {
  const f = await fixture(t);
  await copyFile(f.originalZip, f.cachedOriginal);
  const result = prepare(f, { download: path.join(f.root, 'unavailable.zip') });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  for (const name of files) {
    assert.equal(await readFile(path.join(f.root, 'output/ffmpeg/bin', name), 'utf8'), `pinned FFmpeg bytes: ${name}`);
  }
  await assert.rejects(readFile(f.cachedRelease));
});

test('replaces corrupt caches and rejects an unverified previous release', async (t) => {
  const f = await fixture(t);
  for (const destination of [f.cachedOriginal, f.cachedRelease, `${f.cachedRelease}.aria2`, f.previousRelease]) {
    await writeFile(destination, 'corrupt');
  }
  await assertRestored(f, prepare(f));
  assert.equal(sha256(await readFile(f.cachedRelease)), f.releaseHash);
  await assert.rejects(readFile(`${f.cachedRelease}.aria2`));
});

test('stops before extraction when a downloaded recovery archive has the wrong checksum', async (t) => {
  const f = await fixture(t);
  const result = prepare(f, { expected: '0'.repeat(64) });
  assert.notEqual(result.status, 0);
  assert.match(result.stdout, /校验失败/);
  await assert.rejects(readdir(path.join(f.root, 'output')));
});

test('fails instead of packaging an archive that lacks a required shared library', async (t) => {
  const f = await fixture(t, 'avcodec-63.dll');
  const result = prepare(f);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /avcodec-63\.dll/);
  await assert.rejects(readdir(path.join(f.root, 'output')));
});

test('fails clearly when no valid cache or downloadable recovery release is available', async (t) => {
  const f = await fixture(t);
  const result = prepare(f, { download: path.join(f.root, 'unavailable.zip') });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /curl:/);
  await assert.rejects(readdir(path.join(f.root, 'output')));
});
