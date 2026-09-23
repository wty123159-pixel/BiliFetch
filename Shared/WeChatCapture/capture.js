/* BiliFetch local capture adapter. No cookies, chat data or external telemetry. */
(() => {
  'use strict';
  if (window.__BiliFetchCapture) return;
  const endpoint = __BILIFETCH_ENDPOINT__;
  const candidates = new Map();
  const sent = new Map();
  const flows = new Set();
  const playback = new WeakMap();
  const blobOwners = new Map();
  const counters = {bridgeAvailable:0,bridgeCalls:0,bridgeResponses:0,pageStoreReady:0};
  let homeStoreFactory = null;
  const moduleLoads = new Set();
  let lastMetrics = '', lastMetricsTime = 0;
  function reportMetrics() {
    if (Date.now()-lastMetricsTime<1500)return;
    const videos=[...document.querySelectorAll('video')];
    const metrics={candidates:candidates.size,videoElements:videos.length,visiblePlaying:videos.filter(visiblePlaying).length,
      flowReferences:flows.size,msePlayers:videos.filter(v=>(v.currentSrc||v.src||'').startsWith('blob:')).length,...counters};
    const fingerprint=JSON.stringify(metrics);if(fingerprint===lastMetrics)return;
    lastMetrics=fingerprint;lastMetricsTime=Date.now();send({type:'metrics',metrics}).catch(()=>{});
  }
  let lastUnconfirmed = 0;
  function unconfirmed(reason) {
    if (Date.now() - lastUnconfirmed < 10000) return;
    lastUnconfirmed = Date.now();
    send({type:'playback_unconfirmed',reason}).catch(()=>{});
  }
  const text = (v) => typeof v === 'string' ? v : (typeof v === 'number' && Number.isSafeInteger(v) ? String(v) : '');
  const field = (v,name) => v?.[name] ?? v?.[name.replace(/[A-Z]/g,c=>'_'+c.toLowerCase())];
  const mediaURL = (m) => text(m.url) + text(m.urlToken);
  const nativeFetch = window.fetch || fetch;
  const send = (value) => {
    try { return nativeFetch(endpoint, {method:'POST', headers:{'Content-Type':'application/json'}, credentials:'omit', body:JSON.stringify(value)}); } catch { return Promise.reject(new Error('capture unavailable')); }
  };
  function feed(value) {
    const desc=field(value,'objectDesc');
    if (!value || typeof value !== 'object' || !desc || !Array.isArray(desc.media)) return null;
    const media = desc.media.filter(m => m && m.url).slice(0, 12);
    if (!media.length || !text(value.id)) return null;
    // Only copy the fields needed to save the selected video. Never serialize a bridge response wholesale.
    return {id:text(value.id), title:text(desc.description), author:text(value.contact?.nickname),
      media:media.map(m => ({url:text(m.url), urlToken:text(field(m,'urlToken')), decodeKey:text(field(m,'decodeKey')),
        width:Number(m.width)||0, height:Number(m.height)||0, fileSize:Number(field(m,'fileSize'))||0,
        duration:Number(field(m,'videoPlayLen'))||0, coverUrl:text(field(m,'coverUrl')),
        encryptedLength:Number(field(m,'encryptedLength'))||0,
        spec:(Array.isArray(m.spec)?m.spec:[]).slice(0,20).map(s => ({fileFormat:text(field(s,'fileFormat')), url:text(s.url),
          width:Number(s.width)||0, height:Number(s.height)||0, fileSize:Number(field(s,'fileSize'))||0,
          codingFormat:text(field(s,'codingFormat')), videoBitrate:Number(field(s,'videoBitrate'))||0, audioBitrate:Number(field(s,'audioBitrate'))||0}))}))};
  }
  function remember(f) {
    if(!f)return;
    candidates.set(f.id,f);
    while(candidates.size>50)candidates.delete(candidates.keys().next().value);
  }
  function observe(value, kind = '') {
    let visited = 0;
    function visit(v, depth) {
      if (!v || typeof v !== 'object' || depth > 6 || ++visited > 160) return;
      const f = feed(v);
      if (f) {
        remember(f);
        return;
      }
      const json=v.jsapi_resp?.resp_json;
      if(typeof json==='string'&&json.length<=2*1024*1024){try{visit(JSON.parse(json),depth+1);}catch{}}
      if (Array.isArray(v)) v.slice(0,50).forEach(x => visit(x, depth+1));
      else for (const key of ['data','object','feed','feeds','objectList','feedList']) visit(field(v,key),depth+1);
    }
    visit(value,0);
    for (const video of document.querySelectorAll('video')) confirmPlayback(video);
    reportMetrics();
  }
  function visiblePlaying(video) {
    if (document.visibilityState !== 'visible' || video.paused || video.ended || video.readyState < 2) return false;
    const r = video.getBoundingClientRect();
    const style = getComputedStyle(video);
    if (r.width < 40 || r.height < 40 || style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') return false;
    if (typeof video.checkVisibility === 'function' && !video.checkVisibility({checkOpacity:true,checkVisibilityCSS:true})) return false;
    for (let parent = video.parentElement; parent; parent = parent.parentElement) {
      const css = getComputedStyle(parent);
      if (css.display === 'none' || css.visibility === 'hidden' || Number(css.opacity) === 0) return false;
    }
    const width = Math.max(0, Math.min(r.right, innerWidth) - Math.max(r.left, 0));
    const height = Math.max(0, Math.min(r.bottom, innerHeight) - Math.max(r.top, 0));
    return width * height >= Math.min(r.width * r.height, innerWidth * innerHeight) * 0.5;
  }
  function currentFlowID() {
    const ids = new Set();
    const activeFlows=[...flows];
    try {
      const home=homeStoreFactory?.();
      if(home&&home.isFlowTabActive!==false)activeFlows.push(home.flowTab);
    }catch{}
    for (const ref of activeFlows) {
      const flow = ref?.value ?? ref;
      const i = flow?.currentFeedIndex;
      if (!Number.isInteger(i) || !Array.isArray(flow?.feeds)) continue;
      const id = text(flow.feeds[i]?.id);
      if (id) {ids.add(id);remember(feed(flow.feeds[i]));}
    }
    // Ambiguous state must not select the last detail/preload response.
    return ids.size === 1 ? [...ids][0] : '';
  }
  function attachModule(namespace) {
    // Find Pinia's stable store id, not a minifier-dependent export alias.
    const homes=Object.values(namespace).filter(v=>typeof v==='function'&&v.$id==='home');
    if(homes.length===1){homeStoreFactory=homes[0];counters.pageStoreReady=1;}
  }
  function loadPageModule() {
    // Import the exact module already referenced by this page. The module
    // cache shares its existing state; platform scripts remain byte-for-byte
    // unchanged, and no extra platform API requests are issued.
    for(const element of document.querySelectorAll('script[src],link[href]')) {
      try {
        const url=new URL(element.src||element.href,location.href);
        if(url.protocol!=='https:'||url.hostname!=='res.wx.qq.com'||
          !/^\/t\/wx_fed\/finder\/web\/web-finder\/res\/js\/virtual_svg-icons-register\.[A-Za-z0-9_-]+\.js$/.test(url.pathname)||
          moduleLoads.has(url.href))continue;
        moduleLoads.add(url.href);
        import(url.href).then(attachModule).catch(()=>{});
      }catch{}
    }
  }
  function inspectPlayerComponent(video) {
    // Read only exposed player component state. Never rewrite platform bundle
    // bindings: the same "flowTab:x" text can be an object or a destructuring.
    for (let element=video, depth=0;element&&depth<8;element=element.parentElement,depth++) {
      let component=element.__vueParentComponent;
      for(let i=0;component&&i<12;component=component.parent,i++) {
        for(const state of [component.setupState,component.exposed,component.ctx]) {
          if(!state||typeof state!=='object')continue;
          for(const name of ['flowTab','localFlowTab']) {
            const ref=state[name];if(ref&&typeof ref==='object')flows.add(ref);
          }
        }
      }
    }
  }
  function confirmPlayback(video) {
    const session = playback.get(video);
    if (!session || !visiblePlaying(video) || !Number.isFinite(video.currentTime) || video.currentTime < session.time + 0.1) return;
    // A preload player can be running off-screen or overlap during navigation.
    // Never choose between two visible, playing elements.
    if ([...document.querySelectorAll('video')].filter(visiblePlaying).length !== 1) { unconfirmed('multiple_players'); return; }
    const src = video.currentSrc || video.src || '';
    if (src !== session.src) return;
    const matches = [...candidates.values()].filter(f => f.media.some(m => src && mediaURL(m) === src));
    let current = matches.length === 1 ? matches[0] : null;
    // Bind MSE playback once to the selected feed at its playing event. A later
    // preload response/index change cannot re-label an already playing blob.
    if (!current && src.startsWith('blob:') && session.id && session.id === currentFlowID()) current = candidates.get(session.id);
    if (!current) { unconfirmed('identity_unknown'); return; }
    const fingerprint = JSON.stringify(current.media);
    if (sent.get(current.id) === fingerprint) return;
    sent.set(current.id, fingerprint);
    send({type:'capture', feed:current}).then(r => {if (!r.ok) sent.delete(current.id);}).catch(() => sent.delete(current.id));
  }
  window.__BiliFetchCapture = {observe,attachModule, trackFlow(ref) {if (ref && typeof ref === 'object') {flows.add(ref);if(flows.size>20)flows.delete(flows.values().next().value);}return ref;}};
  document.addEventListener('DOMContentLoaded',loadPageModule,{once:true});
  if(document.readyState!=='loading')loadPageModule();
  document.addEventListener('playing', e => {
    const video = e.target;
    if (video?.tagName !== 'VIDEO' || !visiblePlaying(video)) return;
    loadPageModule();
    try {inspectPlayerComponent(video);} catch {}
    const src = video.currentSrc || video.src || '';
    let id = '';
    if (src.startsWith('blob:')) {
      id = currentFlowID();
      if (blobOwners.has(src) && blobOwners.get(src) !== id) id = '';
      else if (id) {
        blobOwners.set(src,id);
        if (blobOwners.size > 100) blobOwners.delete(blobOwners.keys().next().value);
      }
    }
    playback.set(video,{src,id,time:video.currentTime});
    reportMetrics();
    setTimeout(()=>confirmPlayback(video),300);
  }, true);
  document.addEventListener('timeupdate', e => {if(e.target?.tagName === 'VIDEO'){confirmPlayback(e.target);reportMetrics();}},true);
  for (const name of ['emptied','loadstart']) document.addEventListener(name,e=>{if(e.target?.tagName==='VIDEO')playback.delete(e.target);},true);
  // Native bridge responses do not always go through fetch/XHR.
  function hookBridge() {
    const bridge = window.WeixinJSBridge;
    if(!bridge)return;
    counters.bridgeAvailable=1;
    for(const method of ['invoke','_invoke']) {
      const original=bridge[method];
      if(typeof original!=='function'||original.__bilifetch)continue;
      function invoke() {
        counters.bridgeCalls++;
        const args=[...arguments];
        for(let i=0;i<args.length;i++)if(typeof args[i]==='function'){
          const callback=args[i];
          args[i]=function(result){
            counters.bridgeResponses++;
            try{observe(result);}catch{}
            return callback.apply(this,arguments);
          };
        }
        return original.apply(this,args);
      }
      invoke.__bilifetch=true;
      try{bridge[method]=invoke;}catch{}
    }
  }
  hookBridge();
  document.addEventListener('WeixinJSBridgeReady', hookBridge, {once:true});
  window.addEventListener?.('WeixinJSBridgeReady', hookBridge, {once:true});
  // Observe clones of metadata responses without changing the platform's
  // scripts, response body, callbacks, URLs, or returned Promise.
  if (window.fetch) {
    window.fetch = function() {
      const result = nativeFetch.apply(this,arguments);
      result.then(response=>{
        if (!/finder|channel/i.test(response.url||'') || !/json/i.test(response.headers.get('content-type')||'') ||
            Number(response.headers.get('content-length'))>2*1024*1024) return;
        response.clone().json().then(value=>observe(value)).catch(()=>{});
      }).catch(()=>{});
      return result;
    };
  }
  if (window.XMLHttpRequest) {
    const prototype=window.XMLHttpRequest.prototype,open=prototype.open,sendRequest=prototype.send;
    const urls=new WeakMap();
    prototype.open=function(method,url){urls.set(this,String(url));return open.apply(this,arguments);};
    prototype.send=function(){
      this.addEventListener('load',()=>{
        try {
          if(!/finder|channel/i.test(urls.get(this)||''))return;
          if(this.responseType==='json')observe(this.response);
          else if((!this.responseType||this.responseType==='text')&&this.responseText.length<2*1024*1024&&/json/i.test(this.getResponseHeader('content-type')||''))observe(JSON.parse(this.responseText));
        }catch{}
      },{once:true});
      return sendRequest.apply(this,arguments);
    };
  }
  send({type:'page_ready', adapter:2}).catch(() => {});
})();
