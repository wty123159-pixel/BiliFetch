'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const update = require('../update-core');

test('compares semantic versions', () => {
  assert.equal(update.compareVersions('1.2.0', '1.1.9'), 1);
  assert.equal(update.compareVersions('v1.1.0', '1.1.0'), 0);
  assert.equal(update.compareVersions('1.0.9', '1.1.0'), -1);
});

test('requires an HTTPS update feed and signed hash metadata', () => {
  assert.throws(() => update.validateHTTPSURL('http://example.com/update.json', '更新地址'), /HTTPS/);
  const manifest = update.validateManifest({
    version: '1.2.0', notes: '修复封面',
    windows: { url: 'https://example.com/BiliFetch.zip', sha256: 'a'.repeat(64), size: 123 }
  });
  assert.equal(manifest.version, '1.2.0');
  assert.equal(manifest.sha256.length, 64);
});

test('rejects an update manifest without a valid checksum', () => {
  assert.throws(() => update.validateManifest({ version: '1.2.0', windows: { url: 'https://example.com/x.zip', sha256: 'bad' } }), /SHA-256/);
});

test('selects only an exact-version Windows delta and otherwise keeps the full package', () => {
  const payload = {
    version: '1.2.0', notes: '增量更新',
    windows: {
      url: 'https://example.com/full.zip', sha256: 'a'.repeat(64), size: 1000,
      deltas: [{ fromVersion: '1.1.3', url: 'https://example.com/delta.zip', sha256: 'b'.repeat(64), size: 100 }]
    }
  };
  const incremental = update.validateManifest(payload, '1.1.3');
  assert.equal(incremental.delta.fromVersion, '1.1.3');
  assert.equal(incremental.delta.size, 100);
  assert.equal(update.validateManifest(payload, '1.1.2').delta, null);
});

test('validates delta file plans and rejects traversal or version mismatches', () => {
  const plan = update.validateDeltaPlan({
    formatVersion: 1, platform: 'windows', fromVersion: '1.1.3', toVersion: '1.2.0',
    files: [{ path: 'resources/app.asar', sha256: 'c'.repeat(64), size: 42, mode: 420 }],
    deletePaths: ['resources/obsolete.txt']
  }, '1.1.3', '1.2.0');
  assert.equal(plan.files.length, 1);
  assert.equal(update.isSafeRelativePath('../outside'), false);
  assert.throws(() => update.validateDeltaPlan({
    formatVersion: 1, platform: 'windows', fromVersion: '1.1.3', toVersion: '1.2.0',
    files: [{ path: '../outside', sha256: 'c'.repeat(64), size: 42 }], deletePaths: []
  }, '1.1.3', '1.2.0'), /无效文件记录/);
  assert.throws(() => update.validateDeltaPlan({
    formatVersion: 1, platform: 'windows', fromVersion: '1.1.2', toVersion: '1.2.0', files: [], deletePaths: []
  }, '1.1.3', '1.2.0'), /版本/);
  const binary = update.validateDeltaPlan({
    formatVersion: 1, platform: 'windows', fromVersion: '1.1.3', toVersion: '1.2.0',
    files: [{
      path: 'BiliFetch.exe', sha256: 'd'.repeat(64), size: 12,
      patch: {
        source: 'patches/000001.bin', baseSha256: 'e'.repeat(64), baseSize: 20,
        dataSha256: 'f'.repeat(64), dataSize: 4,
        operations: [{ type: 'copy', offset: 0, length: 8 }, { type: 'data', offset: 0, length: 4 }]
      }
    }], deletePaths: []
  }, '1.1.3', '1.2.0');
  assert.equal(binary.files[0].patch.operations.length, 2);
});

test('uses hidden bundled update sources with fallback and no duplicates', () => {
  assert.deepEqual(update.manifestURLs({
    manifestURLs: ['https://mirror.example.com/update.json', 'http://unsafe.example.com/update.json'],
    manifestURL: 'https://mirror.example.com/update.json'
  }, 'https://github.com/example/BiliFetch/releases/latest/download/update.json'), [
    'https://mirror.example.com/update.json',
    'https://github.com/example/BiliFetch/releases/latest/download/update.json'
  ]);
});
