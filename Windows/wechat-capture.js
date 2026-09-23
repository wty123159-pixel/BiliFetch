'use strict';

const { spawn } = require('node:child_process');
const http = require('node:http');
const path = require('node:path');

class WeChatCapture {
  constructor(executable, directory) {
    this.executable = executable;
    this.directory = path.resolve(directory);
    this.child = null;
    this.ready = null;
    this.starting = null;
  }
  async ensureReady() {
    if (this.ready && this.child?.exitCode === null) return;
    if (this.starting) return this.starting;
    this.starting = new Promise((resolve, reject) => {
      const child = spawn(this.executable, ['--data-dir', this.directory], { windowsHide: true, stdio: ['pipe', 'pipe', 'pipe'] });
      this.child = child;
      let output = '', errors = '', settled = false;
      const finish = (error) => {
        if (settled) return;
        settled = true; clearTimeout(timeout);
        if (error) { child.stdin.end(); reject(error); } else resolve();
      };
      const timeout = setTimeout(() => finish(new Error('视频号捕获组件启动超时，请重试。')), 20000);
      child.stderr.on('data', chunk => { if (errors.length < 16384) errors += chunk; });
      child.stdout.on('data', chunk => {
        output += chunk;
        if (!output.includes('\n') && output.length < 16384) return;
        try {
          const ready = JSON.parse(output.split('\n')[0]);
          const url = new URL(ready.baseURL);
          if (ready.event !== 'ready' || url.protocol !== 'http:' || url.hostname !== '127.0.0.1' || !url.port || !/^[a-f0-9]{64}$/.test(ready.token)) throw new Error();
          this.ready = ready; finish();
        } catch { finish(new Error('视频号捕获组件返回了无效的启动信息。')); }
      });
      child.on('error', () => finish(new Error('无法启动视频号捕获组件，请重新安装完整版本。')));
      child.on('close', () => {
        if (this.child === child) { this.ready = null; this.child = null; }
        let error = '视频号捕获组件已退出。';
        try { error = JSON.parse(errors).error || error; } catch {}
        finish(new Error(error));
      });
      child.stdin.on('error', () => {});
    }).finally(() => { this.starting = null; });
    return this.starting;
  }
  async request(route, method = 'GET', value) {
    await this.ensureReady();
    const body = value === undefined ? null : Buffer.from(JSON.stringify(value));
    return new Promise((resolve, reject) => {
      const request = http.request(new URL(route, this.ready.baseURL), {
        method, agent: false, headers: { Authorization: 'Bearer ' + this.ready.token,
          ...(body ? { 'Content-Type':'application/json', 'Content-Length':body.length } : {}) }
      }, response => {
        let output = '';
        response.setEncoding('utf8');
        response.on('data', chunk => {
          output += chunk;
          if (output.length > 4 * 1024 * 1024) request.destroy(new Error('捕获响应过大。'));
        });
        response.on('error', reject);
        response.on('end', () => {
          try {
            const result = JSON.parse(output);
            if (response.statusCode !== 200) throw new Error(result.error || '捕获操作失败，请导出诊断报告。');
            resolve(result);
          } catch (error) { reject(error); }
        });
      });
      request.setTimeout(55000, () => request.destroy(new Error('捕获操作超时，请检查系统授权提示。')));
      request.on('error', reject);
      request.end(body);
    });
  }
  state() { return this.request('/api/state'); }
  start() { return this.request('/api/start', 'POST', { consent:true }); }
  async stop() { if (this.child) return this.request('/api/stop', 'POST'); }
  clear() { return this.request('/api/clear', 'POST'); }
  diagnostics() { return this.request('/api/diagnostics'); }
  async manifest(id) {
    if (!/^[a-f0-9]{32}$/.test(id)) throw new Error('捕获作品标识无效。');
    const result = await this.request('/api/manifest/' + id);
    const expected = path.join(this.directory, 'Captures', id + '.info.json');
    if (path.resolve(result.path) !== expected) throw new Error('捕获下载信息的路径无效。');
    return expected;
  }
  async preview(ids) {
    if (!Array.isArray(ids) || !ids.length || ids.length > 200 || ids.some(id => !/^[a-f0-9]{32}$/.test(id))) throw new Error('请选择已捕获的作品。');
    const state = await this.state();
    const items = [...new Set(ids)].map((id, index) => {
      const video = state.captures.find(entry => entry.id === id);
      if (!video) throw new Error('捕获记录已不存在，请在微信重新播放作品。');
      return { key:'wechat:' + id, id, index:index+1, title:video.title, url:video.sourceURL,
        thumbnail:video.thumbnail, duration:video.duration, selected:true, status:'ready', progress:0 };
    });
    return { sourceURL:items[0].url, title:'视频号 · 已播放作品', items };
  }
  async shutdown() {
    await this.stop();
    this.child?.stdin.end();
  }
}
module.exports = { WeChatCapture };
