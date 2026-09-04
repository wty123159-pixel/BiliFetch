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
