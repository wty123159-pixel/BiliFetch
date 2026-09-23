'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const core = require('../core');
const { WeChatCapture } = require('../wechat-capture');
const path = require('node:path');
const fs = require('node:fs/promises');
const os = require('node:os');
const { once } = require('node:events');

const id = 'a'.repeat(32), url = 'https://channels.weixin.qq.com/bilifetch-capture/' + id;
test('WeChat share text and strict internal capture IDs', () => {
  assert.equal(core.weChatCaptureID(url),id);
  assert.equal(core.validateVideoURL('分享作品 https://weixin.qq.com/sph/AcTp5SxKyW'),'https://weixin.qq.com/sph/AcTp5SxKyW');
  for(const bad of ['https://weixin.qq.com/unrelated',url+'?x=1',url.replace('channels.','evil.channels.')]) assert.equal(core.validateVideoURL(bad),null);
});
test('captured download reuses best quality and resume without browser cookies', () => {
  const args = core.buildDownloadArguments({item:{url},destination:'/tmp/video',outputTemplate:'out.%(ext)s',weChatManifest:'/tmp/info.json',
    settings:{quality:'best',engine:'aria2',browser:'chrome',cookieFile:'/tmp/bili-cookies'},
    tools:{ffmpeg:'/tmp/ffmpeg',aria2:'/tmp/aria2'}});
  for(const flag of ['--load-info-json','--continue','--part','bv*+ba/b']) assert.ok(args.includes(flag));
  for(const value of ['--cookies','--cookies-from-browser',url]) assert.ok(!args.includes(value));
  assert.equal(args[args.indexOf('--proxy')+1],'');
  assert.ok(args[args.indexOf('--downloader-args')+1].includes('--all-proxy='));
});
test('capture preview is built from helper records and excludes media secrets', async () => {
  const helper=new WeChatCapture('/unused',path.resolve('/tmp/capture'));
  helper.state=async()=>({captures:[{id,sourceURL:url,title:'当前作品',thumbnail:'',duration:3,decodeKey:'secret',mediaURL:'secret-url'}]});
  const preview=await helper.preview([id,id]);
  assert.equal(preview.items.length,1);
  assert.equal(preview.items[0].url,url);
  assert.ok(!JSON.stringify(preview).includes('secret'));
  await assert.rejects(helper.preview(['b'.repeat(32)]),/重新播放/);
});
test('manifest paths cannot escape the private data directory', async () => {
  const helper=new WeChatCapture('/unused',path.resolve('/tmp/capture'));
  helper.request=async()=>({path:'/tmp/evil.json'});
  await assert.rejects(helper.manifest(id),/路径无效/);
  helper.request=async()=>({path:path.join(helper.directory,'Captures',id+'.info.json')});
  assert.equal(await helper.manifest(id),path.join(helper.directory,'Captures',id+'.info.json'));
});

test('actual capture helper survives app restart without enabling proxy or trusting a certificate', {skip:!process.env.BILIFETCH_CAPTURE_TEST_BIN}, async () => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(),'bilifetch-capture-test-'));
  const helper = new WeChatCapture(process.env.BILIFETCH_CAPTURE_TEST_BIN,directory);
  try {
    await fs.mkdir(path.join(directory,'Captures'));
    await fs.writeFile(path.join(directory,'Captures',id+'.capture.json'),JSON.stringify({
      id,feedId:'fixture',title:'隔离测试作品',author:'测试',thumbnail:'',duration:2,capturedAt:1,
      formats:[{id:'source',url:'https://finder.video.qq.com/fixture.mp4',key:'123456789',encryptedLength:131072,width:1280,height:720}]
    }));
    const state = await helper.state();assert.equal(state.active,false);assert.equal(state.captures.length,1);
    await assert.rejects(fs.stat(path.join(directory,'capture-root.pem')), {code:'ENOENT'});
    const manifest=await helper.manifest(id);
    const first=JSON.parse(await fs.readFile(manifest,'utf8'));
    const close=once(helper.child,'close');await helper.shutdown();await close;
    const second=JSON.parse(await fs.readFile(await helper.manifest(id),'utf8'));
    assert.notEqual(first.formats[0].http_headers.Authorization,second.formats[0].http_headers.Authorization);
    assert.equal(second.id,first.id);
    const diagnostics=await helper.diagnostics();assert.equal(diagnostics.state.active,false);
    assert.ok(!JSON.stringify(diagnostics).includes('123456789'));
    await helper.clear();assert.equal((await helper.state()).captures.length,0);
  } finally {
    if(helper.child){const close=once(helper.child,'close');await helper.shutdown();await close;}
    await fs.rm(directory,{recursive:true,force:true});
  }
});
