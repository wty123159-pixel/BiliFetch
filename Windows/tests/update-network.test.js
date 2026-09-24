'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { UpdateNetwork, githubReleaseAsset, assetAPIURL } = require('../update-network');
const primary = 'https://github.com/owner/repo/releases/latest/download/update.json';
const source = githubReleaseAsset(primary);
const metadata = { tag_name: 'v1', draft: false, assets: [{ name: 'update.json', id: 123, url: `${source.assetPrefix}123`, state: 'uploaded' }] };
const response = value => new Response(JSON.stringify(value), { headers: { 'Content-Type': 'application/json' } });

test('official release URL parsing rejects unrelated and ambiguous sources', () => {
  assert.equal(source.metadataURL, 'https://api.github.com/repos/owner/repo/releases/latest');
  const tagged = githubReleaseAsset('https://github.com/owner/repo/releases/download/v1%2Ftest/My%20App.zip');
  assert.equal(tagged.tag, 'v1/test');
  assert.equal(tagged.name, 'My App.zip');
  assert.equal(tagged.metadataURL, 'https://api.github.com/repos/owner/repo/releases/tags/v1%2Ftest');
  for (const url of ['http://github.com/owner/repo/releases/latest/download/update.json', primary + '?token=x', primary.replace('github.com', 'github.com.evil.test'), primary.replace('github.com', 'user@github.com'), primary.replace('update.json', 'a%2Fb.zip'), primary.replace('latest/download', 'tags/v1')]) assert.equal(githubReleaseAsset(url), null, url);
});
test('asset lookup pins exact official repository, asset name, state and release tag', () => {
  assert.equal(assetAPIURL(source, metadata), source.assetPrefix + '123');
  for (const asset of [ { ...metadata.assets[0], url: 'https://evil.test/file' }, { ...metadata.assets[0], name: 'other.zip' }, { ...metadata.assets[0], state: 'new' } ]) assert.throws(() => assetAPIURL(source, { ...metadata, assets:[asset] }));
  assert.throws(() => assetAPIURL(source, { ...metadata, draft:true }));
  assert.throws(() => assetAPIURL(githubReleaseAsset(primary.replace('latest/download','download/v2')), metadata));
});
test('blocked main host switches to unauthenticated API and remembers successful route', async () => {
  const calls = [];
  const network = new UpdateNetwork({ userAgent:'test', fetch: async(url, options) => {
    calls.push(url);
    assert.equal(options.headers.Authorization, undefined);
    if (url === primary) throw new Error('main host blocked');
    if (url === source.metadataURL) return response(metadata);
    assert.equal(options.headers.Accept, 'application/octet-stream');
    return response({version:'1.0.1'});
  }});
  assert.equal((await network.manifest(primary, x => x)).version, '1.0.1');
  assert.deepEqual(calls, [primary, source.metadataURL, source.assetPrefix+'123']);
  calls.length=0;
  await network.manifest(primary, x => x);
  assert.deepEqual(calls, [source.assetPrefix+'123']);
});
test('invalid main content and failed integrity validation both try the other route', async () => {
  const network = new UpdateNetwork({userAgent:'test',fetch: async()=>response(metadata)});
  const seen=[];
  const result=await network.withFallback(primary,async route=>{
    seen.push(route.officialAPI);
    if(!route.officialAPI) throw new Error('digest mismatch');
    return 'verified package';
  });
  assert.equal(result,'verified package');assert.deepEqual(seen,[false,true]);
});
test('API failure falls back to main address without changing a configured domestic source', async () => {
  const calls=[];
  const network=new UpdateNetwork({userAgent:'test',fetch: async url=>{calls.push(url);return new Response('',{status:429});}});
  network.preferAPI.add(source.repository);
  const result=await network.withFallback(primary,async route=>route.url);
  assert.equal(result,primary);assert.deepEqual(calls,[source.metadataURL]);
  let count=0;
  await assert.rejects(network.withFallback('https://downloads.example.cn/update.json',async()=>{count++;throw new Error('offline')}));
  assert.equal(count,1);
});
test('both routes failing reports failure and never treats API metadata as a package', async () => {
  const network=new UpdateNetwork({userAgent:'test',fetch:async()=>response({assets:[]})});
  let downloads=0;
  await assert.rejects(network.withFallback(primary,async()=>{downloads++;throw new Error('offline')}),/尚未提供/);
  assert.equal(downloads,1);
});
