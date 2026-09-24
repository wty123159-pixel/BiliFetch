'use strict';
// Internal integration fixture; runs in an isolated Electron profile and hidden
// window, with the production renderer and update transport supplied as inputs.
const { app, BrowserWindow, session } = require('electron');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const { Readable } = require('node:stream');
const { pipeline } = require('node:stream/promises');
const options = JSON.parse(fs.readFileSync(process.env.BILIFETCH_INTEGRATION_CONFIG,'utf8'));
app.setPath('userData',path.join(options.output,'profile'));
app.commandLine.appendSwitch('disable-gpu');
const results=[];
app.whenReady().then(async()=>{
 await session.defaultSession.setProxy({mode:'direct'});
 const renderer=path.join(options.subject,'renderer');
 const html=fs.readFileSync(path.join(renderer,'index.html'),'utf8').replace(/<meta[^>]*Content-Security-Policy[^>]*>/,'').replace(/<script[^>]*src="app.js"[^>]*><\/script>/,'').replace('<link rel="stylesheet" href="style.css">',`<style>${fs.readFileSync(path.join(renderer,'style.css'),'utf8')}</style>`);
 const window=new BrowserWindow({show:false,width:960,height:680,useContentSize:true,webPreferences:{contextIsolation:true,sandbox:true}});
 await window.loadURL('data:text/html;charset=utf-8,'+encodeURIComponent(html));
 await window.webContents.executeJavaScript(`document.querySelector('#captureDialog').showModal(); document.querySelector('#captureStatus').textContent='捕获已开启 · 等待在微信中播放目标视频'; document.querySelector('#captureList').innerHTML=Array.from({length:8},(_,i)=>'<label class="capture-row"><input type="checkbox"><span>测试作品 '+(i+1)+'：这是用于检验长标题自动换行的示例文字<small>作者 · 00:30</small></span></label>').join('');`);
 for(const [width,height] of [[960,680],[720,520],[534,500],[480,640],[534,384]]){
  window.setContentSize(width,height);
  await new Promise(resolve=>setTimeout(resolve,150));
  const layout=await window.webContents.executeJavaScript(`(()=>{const d=document.querySelector('#captureDialog');const visible=id=>{const r=document.querySelector(id).getBoundingClientRect();return r.left>=0&&r.right<=innerWidth&&r.top>=0&&r.bottom<=innerHeight;};return {width:innerWidth,height:innerHeight,noHorizontalOverflow:d.scrollWidth<=d.clientWidth+1,close:visible('#closeCaptureButton'),add:visible('#addCaptureButton'),actions:['#toggleCaptureButton','#captureDiagnosticsButton','#clearCaptureButton'].every(visible),listScrolls:document.querySelector('#captureList').scrollHeight>document.querySelector('#captureList').clientHeight};})()`);
  results.push({test:'layout',...layout});
  assert.equal(layout.noHorizontalOverflow,true,JSON.stringify(layout));
  assert.equal(layout.close&&layout.add&&layout.actions,true,JSON.stringify(layout));
  assert.equal(layout.listScrolls,true,JSON.stringify(layout));
  const png=await window.webContents.capturePage();fs.writeFileSync(path.join(options.output,`capture-${width}x${height}.png`),png.toPNG());
 }
 if(options.network){
  const {net}=require('electron');
  const {UpdateNetwork}=require(path.join(options.subject,'update-network.js'));
  const {validateManifest}=require(path.join(options.subject,'update-core.js'));
  const calls=[];
  const network=new UpdateNetwork({userAgent:'BiliFetch-Integration/1',fetch:async(url,opts)=>{
   calls.push(new URL(url).hostname);
   if(new URL(url).hostname==='github.com')throw new Error('simulated blocked main host');
   return net.fetch(url,opts);
  }});
  const url='https://github.com/wty123159-pixel/BiliFetch/releases/latest/download/update.json';
  const release=await network.manifest(url,payload=>validateManifest(payload,'1.1.6'));
  assert(release.delta,'published delta required for bounded real transfer');
  const asset=release.delta;
  const destination=path.join(options.output,'official-api-download.zip');
  await network.withFallback(asset.url,async source=>{
   const response=await net.fetch(source.url,{headers:source.headers,signal:AbortSignal.timeout(180000)});
   assert(response.ok);await pipeline(Readable.fromWeb(response.body),fs.createWriteStream(destination));
   assert.equal(crypto.createHash('sha256').update(fs.readFileSync(destination)).digest('hex'),asset.sha256);
  });
  results.push({test:'official API real download without proxy',version:release.version,bytes:fs.statSync(destination).size,sha256:asset.sha256,hosts:calls});
 }
 fs.writeFileSync(path.join(options.output,'results.json'),JSON.stringify({ok:true,results},null,2));
 app.exit(0);
}).catch(error=>{
 fs.writeFileSync(path.join(options.output,'results.json'),JSON.stringify({ok:false,results,error:error.stack},null,2));
 console.error(error);app.exit(1);
});
