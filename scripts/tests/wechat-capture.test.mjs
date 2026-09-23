import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';

const script = readFileSync(new URL('../../Shared/WeChatCapture/capture.js', import.meta.url),'utf8')
  .replace('__BILIFETCH_ENDPOINT__', JSON.stringify('https://channels.weixin.qq.com/__bilifetch_capture/test'));
const feed = (id) => ({ id, contact:{nickname:'作者'}, objectDesc:{description:'作品 '+id, media:[{
  url:'https://finder.video.qq.com/'+id+'.mp4', decodeKey:'123', width:1080,height:1920,videoPlayLen:20
}]}});
function fixture(options={}) {
  const events = new Map(), videos = [], requests = [], timers = [];
  const document = {visibilityState:'visible',querySelectorAll:()=>videos,
    addEventListener:(name,callback)=>{const list=events.get(name)||[]; list.push(callback);events.set(name,list);}};
  const localFetch=async(url,options)=>{requests.push(JSON.parse(options.body));return{ok:true};};
  const window = {WeixinJSBridge:{invoke(name,args,callback){callback?.(args);return 'native-result';}}};
  if(options.fetch)window.fetch=function(url,...args){return String(url).includes('/__bilifetch_capture/')?localFetch(url,...args):options.fetch.call(this,url,...args);};
  if(options.XMLHttpRequest)window.XMLHttpRequest=options.XMLHttpRequest;
  vm.runInNewContext(script,{window,document,innerWidth:800,innerHeight:600,
    getComputedStyle:element=>({display:'block',visibility:'visible',opacity:'1',...element.style}),
    setTimeout:callback=>timers.push(callback), fetch:localFetch});
  return {window,document,videos,requests,timers,api:window.__BiliFetchCapture,
    dispatch(name,video){for(const callback of events.get(name)||[])callback({target:video});},
    captures(){return requests.filter(event=>event.type==='capture').map(event=>event.feed.id);}};
}
function video(id, extra={}) {
  return {tagName:'VIDEO',currentSrc:'https://finder.video.qq.com/'+id+'.mp4',paused:false,ended:false,readyState:4,currentTime:0,
    getBoundingClientRect:()=>({left:0,top:0,right:500,bottom:500,width:500,height:500}),...extra};
}
function play(f,v) { f.dispatch('playing',v);v.currentTime+=0.5;f.dispatch('timeupdate',v); }

test('detail/recommend/flow preload metadata never creates a capture',()=>{
  const f=fixture();f.api.observe({data:{objectList:['a','b','c'].map(feed)}});assert.deepEqual(f.captures(),[]);
});
test('only the visible playing work is captured among multiple preloads',()=>{
  const f=fixture(),current=video('a'),next=video('b',{getBoundingClientRect:()=>({left:0,top:800,right:500,bottom:1300,width:500,height:500})});
  f.videos.push(current,next);f.api.observe({feedList:['a','b','c'].map(feed)});
  play(f,next);play(f,current);f.api.observe({object:feed('c')});
  assert.deepEqual(f.captures(),['a']);
});
test('paused, hidden, ancestor-hidden and background videos are excluded',()=>{
  for(const mode of ['paused','hidden','ancestor','background']){
    const f=fixture(),v=video('a');f.videos.push(v);f.api.observe(feed('a'));
    if(mode==='paused')v.paused=true;
    if(mode==='hidden')v.style={visibility:'hidden'};
    if(mode==='ancestor')v.parentElement={style:{opacity:'0'}};
    if(mode==='background')f.document.visibilityState='hidden';
    play(f,v);assert.deepEqual(f.captures(),[],mode);
  }
});
test('playing event without advancing frames is insufficient',()=>{
  const f=fixture(),v=video('a');f.videos.push(v);f.api.observe(feed('a'));
  f.dispatch('playing',v);f.timers.forEach(callback=>callback());assert.deepEqual(f.captures(),[]);
  v.currentTime=0.5;f.dispatch('timeupdate',v);assert.deepEqual(f.captures(),['a']);
});
test('overlapping visible players are ambiguous and excluded',()=>{
  const f=fixture(),a=video('a'),b=video('b');f.videos.push(a,b);f.api.observe([feed('a'),feed('b')]);
  play(f,a);play(f,b);assert.deepEqual(f.captures(),[]);
});
test('MSE binds selected feed, not the last returned preload',()=>{
  const f=fixture(),v=video('a',{currentSrc:'blob:active'});f.videos.push(v);
  f.api.trackFlow({value:{currentFeedIndex:0,feeds:[feed('a'),feed('b'),feed('c')]}});
  f.api.observe({objectList:[feed('a'),feed('b'),feed('c')]});play(f,v);
  assert.deepEqual(f.captures(),['a']);
});
test('changing selected index cannot relabel the previous playing MSE blob',()=>{
  const f=fixture(),v=video('a',{currentSrc:'blob:active'}),flow={value:{currentFeedIndex:0,feeds:[feed('a'),feed('b')]}};
  f.videos.push(v);f.api.trackFlow(flow);f.api.observe(flow.value.feeds);play(f,v);
  flow.value.currentFeedIndex=1;f.api.observe(feed('b'));play(f,v);
  assert.deepEqual(f.captures(),['a']);
  v.currentSrc='blob:new';f.dispatch('loadstart',v);play(f,v);
  assert.deepEqual(f.captures(),['a','b']);
});
test('unknown or conflicting MSE identity fails closed',()=>{
  for(const mode of ['unknown','conflict']){
    const f=fixture(),v=video('a',{currentSrc:'blob:active'});f.videos.push(v);f.api.observe([feed('a'),feed('b')]);
    if(mode==='conflict')for(const id of ['a','b'])f.api.trackFlow({value:{currentFeedIndex:0,feeds:[feed(id)]}});
    play(f,v);assert.deepEqual(f.captures(),[]);
  }
});
test('metadata arriving after actual playback still needs matching identity',()=>{
  const f=fixture(),v=video('a');f.videos.push(v);play(f,v);
  f.api.observe(feed('b'));assert.deepEqual(f.captures(),[]);
  f.api.observe(feed('a'));assert.deepEqual(f.captures(),['a']);
});
test('native bridge callbacks and return values are preserved, secret fields omitted',()=>{
  const f=fixture(),v=video('a');f.videos.push(v);
  const value={object:feed('a'),cookie:'secret-cookie',auth:'secret-auth'};
  let received;const result=f.window.WeixinJSBridge.invoke('finderPcFlow',value,data=>{received=data;});
  assert.equal(result,'native-result');assert.equal(received,value);
  play(f,v);assert.deepEqual(f.captures(),['a']);
  assert.equal(JSON.stringify(f.requests).includes('secret-'),false);
});
test('metadata returned through a generic native bridge method is observed',()=>{
  const f=fixture(),v=video('a');f.videos.push(v);
  const value={data:{object:[feed('a'),feed('b')]},accountToken:'private'};
  let received;
  assert.equal(f.window.WeixinJSBridge.invoke('privateCommonApi',value,result=>received=result),'native-result');
  assert.equal(received,value);assert.deepEqual(f.captures(),[]);
  play(f,v);assert.deepEqual(f.captures(),['a']);
  assert.equal(JSON.stringify(f.requests).includes('private'),false);
});
test('native JSON text and snake_case media fields are read without altering the response',()=>{
  const f=fixture(),v=video('a');f.videos.push(v);
  const raw={object:[{id:'a',contact:{nickname:'作者'},object_desc:{description:'目标作品',media:[{
    url:v.currentSrc,decode_key:'18446744073709551615',video_play_len:23,file_size:456,
    spec:[{file_format:'original',video_bitrate:1000}]
  }]}}, {id:'b',object_desc:{media:[{url:'https://finder.video.qq.com/b.mp4'}]}}],account_token:'secret'};
  const result={jsapi_resp:{resp_json:JSON.stringify(raw)}};let received;
  f.window.WeixinJSBridge.invoke('finderH5ExtTransfer',result,r=>received=r);
  assert.equal(received,result);assert.deepEqual(f.captures(),[]);play(f,v);
  assert.deepEqual(f.captures(),['a']);
  const media=f.requests.find(r=>r.type==='capture').feed.media[0];
  assert.equal(media.decodeKey,'18446744073709551615');assert.equal(media.duration,23);
  assert.equal(media.spec[0].fileFormat,'original');assert.equal(JSON.stringify(f.requests).includes('secret'),false);
});
test('the existing page store identifies only its selected MSE work across export alias changes',()=>{
  const f=fixture(),v=video('a',{currentSrc:'blob:selected'});f.videos.push(v);
  const home={isFlowTabActive:true,flowTab:{currentFeedIndex:0,feeds:[feed('a'),feed('b')]}};
  const factory=Object.assign(()=>home,{$id:'home'});
  f.api.attachModule({randomNewMinifiedAlias:factory});play(f,v);
  assert.deepEqual(f.captures(),['a']);
  home.flowTab.currentFeedIndex=1;play(f,v);assert.deepEqual(f.captures(),['a']);
  v.currentSrc='blob:next';f.dispatch('loadstart',v);play(f,v);assert.deepEqual(f.captures(),['a','b']);
});
test('an inactive or ambiguous page store cannot identify an MSE work',()=>{
  for(const mode of ['inactive','ambiguous']){
    const f=fixture(),v=video('a',{currentSrc:'blob:selected'});f.videos.push(v);
    const factory=Object.assign(()=>({isFlowTabActive:mode!=='inactive',flowTab:{currentFeedIndex:0,feeds:[feed('a')]}}),{$id:'home'});
    f.api.attachModule(mode==='ambiguous'?{a:factory,b:Object.assign(()=>null,{$id:'home'})}:{a:factory});play(f,v);
    assert.deepEqual(f.captures(),[],mode);
  }
});
test('repeated events deduplicate, new media credentials refresh same work',()=>{
  const f=fixture(),v=video('a');f.videos.push(v);f.api.observe(feed('a'));play(f,v);play(f,v);
  assert.deepEqual(f.captures(),['a']);
  const updated=feed('a');updated.objectDesc.media[0].decodeKey='456';f.api.observe(updated);
  v.currentTime+=0.5;f.dispatch('timeupdate',v);assert.deepEqual(f.captures(),['a','a']);
});
test('a source change without a new playing event is not a capture',()=>{
  const f=fixture(),v=video('a');f.videos.push(v);f.api.observe([feed('a'),feed('b')]);play(f,v);
  v.currentSrc='https://finder.video.qq.com/b.mp4';f.dispatch('timeupdate',v);
  assert.deepEqual(f.captures(),['a']);play(f,v);assert.deepEqual(f.captures(),['a','b']);
});

test('fetch metadata uses a clone and preserves the original Promise and response',async()=>{
  let cloned=0;
  const value={data:{object:[feed('a'),feed('b')]},cookie:'secret-cookie'};
  const response={url:'https://channels.weixin.qq.com/api/finder',headers:{get:name=>name==='content-type'?'application/json':null},
    clone(){cloned++;return{json:async()=>value};}};
  const promise=Promise.resolve(response);
  const f=fixture({fetch:()=>promise}),v=video('a');f.videos.push(v);
  const result=f.window.fetch(response.url);assert.equal(result,promise);assert.equal(await result,response);
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(cloned,1);assert.deepEqual(f.captures(),[]);
  play(f,v);assert.deepEqual(f.captures(),['a']);
  assert.equal(JSON.stringify(f.requests).includes('secret-cookie'),false);
});

test('XHR metadata observation leaves callbacks and response unchanged',()=>{
  class XHR {
    constructor(){this.listeners=[];this.responseType='json';this.response={object:[feed('a'),feed('b')]};}
    open(method,url){this.url=url;return 'opened';}
    send(){this.listeners.forEach(fn=>fn());return 'sent';}
    addEventListener(name,fn){if(name==='load')this.listeners.push(fn);}
  }
  const f=fixture({XMLHttpRequest:XHR}),v=video('a');f.videos.push(v);
  const xhr=new f.window.XMLHttpRequest(),response=xhr.response;
  let seen=false;xhr.addEventListener('load',()=>{seen=true;});
  assert.equal(xhr.open('GET','/finder/detail'),'opened');assert.equal(xhr.send(),'sent');
  assert.equal(xhr.response,response);assert.equal(seen,true);assert.deepEqual(f.captures(),[]);
  play(f,v);assert.deepEqual(f.captures(),['a']);
});
