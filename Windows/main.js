'use strict';

const { app, BrowserWindow, clipboard, dialog, ipcMain, net, powerMonitor, powerSaveBlocker, shell } = require('electron');
const { spawn } = require('node:child_process');
const crypto = require('node:crypto');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const http = require('node:http');
const https = require('node:https');
const os = require('node:os');
const path = require('node:path');
const { Readable } = require('node:stream');
const extract = require('extract-zip');
const QRCode = require('qrcode');
const core = require('./core');
const updateCore = require('./update-core');

const APP_VERSION = require('./package.json').version;
const DEFAULT_UPDATE_MANIFEST_URL = 'https://github.com/wty123159-pixel/BiliFetch/releases/latest/download/update.json';
const TOOL_URLS = {
  ytdlp: 'https://github.com/yt-dlp/yt-dlp/releases/download/2026.08.19/yt-dlp.exe',
  ffmpeg: 'https://github.com/BtbN/FFmpeg-Builds/releases/download/autobuild-2026-09-02-13-13/ffmpeg-n9.0.1-11-ge47273f4d9-win64-lgpl-shared-9.0.zip',
  aria2: 'https://github.com/aria2/aria2/releases/download/release-1.37.0/aria2-1.37.0-win-64bit-build1.zip'
};

let mainWindow;
let downloadManager;
let saveBlocker = null;
let qrSession = null;
let appUpdater;
const thumbnailCache = new Map();

function userDataPath(...parts) {
  return path.join(app.getPath('userData'), ...parts);
}

function send(channel, payload) {
  if (mainWindow && !mainWindow.isDestroyed()) mainWindow.webContents.send(channel, payload);
}

async function readJSON(file, fallback) {
  try { return JSON.parse(await fsp.readFile(file, 'utf8')); } catch { return fallback; }
}

async function writeJSON(file, value) {
  await fsp.mkdir(path.dirname(file), { recursive: true });
  await fsp.writeFile(file, JSON.stringify(value, null, 2), 'utf8');
}

function splitLines(stream, callback) {
  let pending = '';
  stream.setEncoding('utf8');
  stream.on('data', (chunk) => {
    pending += chunk.replace(/\r/g, '\n');
    const lines = pending.split('\n');
    pending = lines.pop() || '';
    lines.filter(Boolean).forEach(callback);
  });
  stream.on('end', () => { if (pending.trim()) callback(pending.trim()); });
}

function runProcess(executable, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(executable, args, { windowsHide: true, ...options });
    const stdout = [];
    const stderr = [];
    splitLines(child.stdout, (line) => { stdout.push(line); options.onLine?.(line, 'stdout'); });
    splitLines(child.stderr, (line) => { stderr.push(line); options.onLine?.(line, 'stderr'); });
    child.once('error', reject);
    child.once('close', (code) => resolve({ code: code ?? -1, stdout, stderr }));
  });
}

async function executableOnPath(name) {
  if (process.platform !== 'win32') return null;
  try {
    const result = await runProcess('where.exe', [name]);
    return result.code === 0 ? result.stdout[0] : null;
  } catch { return null; }
}

async function locateTools() {
  const candidates = [
    path.join(process.resourcesPath, 'tools'),
    userDataPath('Tools'),
    path.join(path.dirname(process.execPath), 'Tools')
  ];
  const names = { ytdlp: 'yt-dlp.exe', ffmpeg: 'ffmpeg.exe', ffprobe: 'ffprobe.exe', aria2: 'aria2c.exe' };
  const tools = {};
  for (const [key, name] of Object.entries(names)) {
    for (const folder of candidates) {
      const candidate = path.join(folder, name);
      if (await executableIsHealthy(candidate, key)) { tools[key] = candidate; break; }
    }
    if (!tools[key]) {
      const external = await executableOnPath(name);
      if (external && await executableIsHealthy(external, key)) tools[key] = external;
    }
  }
  return tools;
}

async function executableIsHealthy(executable, key) {
  if (!executable || !fs.existsSync(executable)) return false;
  try {
    const argumentsByTool = {
      ytdlp: ['--version'], ffmpeg: ['-version'], ffprobe: ['-version'], aria2: ['--version']
    };
    const result = await runProcess(executable, argumentsByTool[key] || ['--version']);
    return result.code === 0;
  } catch {
    return false;
  }
}

function downloadFile(url, destination, label, onProgress = null) {
  return new Promise((resolve, reject) => {
    const request = (currentURL, redirects = 0) => {
      const transport = currentURL.startsWith('https:') ? https : http;
      transport.get(currentURL, { headers: { 'User-Agent': 'BiliFetch-Windows/1.0' } }, (response) => {
        if ([301, 302, 303, 307, 308].includes(response.statusCode) && response.headers.location && redirects < 10) {
          response.resume();
          request(new URL(response.headers.location, currentURL).toString(), redirects + 1);
          return;
        }
        if (response.statusCode !== 200) {
          response.resume();
          reject(new Error(`${label} 下载失败（HTTP ${response.statusCode}）`));
          return;
        }
        const total = Number(response.headers['content-length']) || 0;
        let received = 0;
        const file = fs.createWriteStream(destination);
        response.on('data', (chunk) => {
          received += chunk.length;
          const progress = { label, percent: total ? Math.round(received / total * 100) : null, received, total };
          if (onProgress) onProgress(progress);
          else send('tools:progress', progress);
        });
        response.pipe(file);
        file.on('finish', () => file.close(resolve));
        file.on('error', reject);
      }).on('error', reject);
    };
    request(url);
  });
}

async function downloadFileWithSystemProxy(url, destination, label, onProgress) {
  const response = await net.fetch(url, {
    cache: 'no-store',
    headers: { 'User-Agent': `BiliFetch-Windows/${APP_VERSION}` }
  });
  if (!response.ok || !response.body) throw new Error(`${label} 下载失败（HTTP ${response.status}）`);
  const total = Number(response.headers.get('content-length')) || 0;
  let received = 0;
  const input = Readable.fromWeb(response.body);
  const output = fs.createWriteStream(destination);
  input.on('data', (chunk) => {
    received += chunk.length;
    onProgress({ label, percent: total ? Math.round(received / total * 100) : null, received, total });
  });
  await new Promise((resolve, reject) => {
    input.once('error', reject);
    output.once('error', reject);
    output.once('finish', resolve);
    input.pipe(output);
  });
}

async function downloadUpdateFile(url, destination, label, onProgress) {
  const tools = await locateTools();
  if (tools.aria2) {
    const argumentsList = [
      '--allow-overwrite=true', '--auto-file-renaming=false', '--continue=true',
      '--file-allocation=none', '--max-connection-per-server=8', '--split=8',
      '--min-split-size=1M', '--max-tries=3', '--retry-wait=2',
      '--connect-timeout=20', '--timeout=30', '--summary-interval=1',
      '--show-console-readout=true', '--console-log-level=warn', '--enable-color=false',
      `--user-agent=BiliFetch-Windows/${APP_VERSION}`,
      `--dir=${path.dirname(destination)}`, `--out=${path.basename(destination)}`,
      '--', url
    ];
    try {
      const result = await runProcess(tools.aria2, argumentsList, {
        onLine(line) {
          const transfer = core.parseProgress(line);
          if (!transfer) return;
          const speed = transfer.speed && !transfer.speed.endsWith('/s') ? `${transfer.speed}/s` : transfer.speed;
          onProgress({ label: speed ? `${label} · ${speed}` : label, percent: transfer.percent });
        }
      });
      if (result.code === 0 && fs.existsSync(destination)) return;
      throw new Error(`aria2 退出代码 ${result.code}`);
    } catch {
      await fsp.rm(destination, { force: true });
      await fsp.rm(`${destination}.aria2`, { force: true });
      onProgress({ label: '多连接下载不可用，正在切换标准下载', percent: null });
    }
  }
  await downloadFileWithSystemProxy(url, destination, label, onProgress);
}

async function findFile(root, fileName) {
  const entries = await fsp.readdir(root, { withFileTypes: true });
  for (const entry of entries) {
    const candidate = path.join(root, entry.name);
    if (entry.isFile() && entry.name.toLowerCase() === fileName.toLowerCase()) return candidate;
    if (entry.isDirectory()) {
      const found = await findFile(candidate, fileName);
      if (found) return found;
    }
  }
  return null;
}

async function prepareTools() {
  const toolDir = userDataPath('Tools');
  const tempDir = await fsp.mkdtemp(path.join(os.tmpdir(), 'bilifetch-tools-'));
  await fsp.mkdir(toolDir, { recursive: true });
  try {
    const ytdlp = path.join(toolDir, 'yt-dlp.exe');
    if (!await executableIsHealthy(ytdlp, 'ytdlp')) await downloadFile(TOOL_URLS.ytdlp, ytdlp, 'yt-dlp');

    if (!await executableIsHealthy(path.join(toolDir, 'ffmpeg.exe'), 'ffmpeg') ||
        !await executableIsHealthy(path.join(toolDir, 'ffprobe.exe'), 'ffprobe')) {
      const archive = path.join(tempDir, 'ffmpeg.zip');
      const unpacked = path.join(tempDir, 'ffmpeg');
      await downloadFile(TOOL_URLS.ffmpeg, archive, 'FFmpeg');
      await extract(archive, { dir: unpacked });
      const ffmpegExecutable = await findFile(unpacked, 'ffmpeg.exe');
      const ffprobeExecutable = await findFile(unpacked, 'ffprobe.exe');
      if (!ffmpegExecutable || !ffprobeExecutable) throw new Error('FFmpeg 压缩包缺少媒体组件。');
      const runtimeDirectory = path.dirname(ffmpegExecutable);
      const runtimeFiles = await fsp.readdir(runtimeDirectory, { withFileTypes: true });
      for (const entry of runtimeFiles) {
        const lower = entry.name.toLowerCase();
        if (entry.isFile() && (lower.endsWith('.dll') || lower === 'ffmpeg.exe' || lower === 'ffprobe.exe')) {
          await fsp.copyFile(path.join(runtimeDirectory, entry.name), path.join(toolDir, entry.name));
        }
      }
    }

    if (!await executableIsHealthy(path.join(toolDir, 'aria2c.exe'), 'aria2')) {
      const archive = path.join(tempDir, 'aria2.zip');
      const unpacked = path.join(tempDir, 'aria2');
      await downloadFile(TOOL_URLS.aria2, archive, 'aria2');
      await extract(archive, { dir: unpacked });
      const found = await findFile(unpacked, 'aria2c.exe');
      if (!found) throw new Error('aria2 压缩包中缺少 aria2c.exe');
      await fsp.copyFile(found, path.join(toolDir, 'aria2c.exe'));
    }
    const tools = await locateTools();
    if (!core.hasCompleteToolset(tools)) throw new Error('组件修复后仍未通过完整性检查。');
    return tools;
  } finally {
    await fsp.rm(tempDir, { recursive: true, force: true });
  }
}

async function cookieArguments(settings = {}) {
  const cookieFile = userDataPath('bilibili-cookies.txt');
  if (fs.existsSync(cookieFile)) return ['--cookies', cookieFile];
  if (settings.browser && settings.browser !== 'none') return ['--cookies-from-browser', settings.browser];
  return [];
}

async function resolveWithBilibiliAPI(validated) {
  const bvid = validated.match(/BV[0-9A-Za-z]+/i)?.[0];
  if (!bvid) return null;
  const endpoint = `https://api.bilibili.com/x/web-interface/view?bvid=${encodeURIComponent(bvid)}`;
  const response = await fetch(endpoint, {
    signal: AbortSignal.timeout(15000),
    headers: {
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124 Safari/537.36',
      Referer: validated,
      Accept: 'application/json'
    }
  });
  if (!response.ok) throw new Error(`B站分集接口返回 HTTP ${response.status}`);
  return core.parseBilibiliViewMetadata(await response.json(), validated);
}

async function resolveCollection(sourceURL, settings = {}, requestID = '') {
  const validated = core.validateBilibiliURL(sourceURL);
  if (!validated) throw new Error('请输入有效的 B 站视频或合集链接。');
  let singleVideoFallback = null;
  const isBVIDVideo = /\/video\/BV[0-9A-Za-z]+/i.test(new URL(validated).pathname);
  const videoHasCollectionContext = isBVIDVideo && core.hasOuterCollectionContext(validated);
  if (isBVIDVideo) {
    send('resolve:progress', { requestID, count: 0, message: '正在读取 B 站分集封面与标题…' });
    try {
      const preview = await resolveWithBilibiliAPI(validated);
      if (preview?.items?.length > 1) return preview;
      if (preview?.items?.length === 1) {
        singleVideoFallback = videoHasCollectionContext ? null : preview;
        send('resolve:progress', { requestID, count: 0, message: '正在确认是否包含完整合集…' });
      }
    } catch (error) {
      send('resolve:progress', { requestID, count: 0, message: `分集接口暂不可用，正在切换 yt-dlp：${error.message}` });
    }
  }
  const tools = await locateTools();
  if (!tools.ytdlp) throw new Error('内置 yt-dlp 异常，请点击“修复组件”。');
  const args = [
    '--ignore-config', '--no-colors', '--newline', '--skip-download',
    '--ignore-no-formats-error', '--yes-playlist', '--no-warnings',
    '--print', '%(.{id,title,webpage_url,original_url,url,thumbnail,duration,playlist,playlist_title,playlist_index,playlist_count})j',
    ...(await cookieArguments(settings)), '--', validated
  ];
  const lines = [];
  const diagnostics = [];
  const result = await runProcess(tools.ytdlp, args, {
    onLine(line, stream) {
      if (stream === 'stdout' && line.trim().startsWith('{')) {
        lines.push(line);
        send('resolve:progress', { requestID, count: lines.length, message: `已读取 ${lines.length} 个视频…` });
      } else if (stream === 'stderr') diagnostics.push(line);
    }
  });
  if (result.code !== 0 || !lines.length) {
    if (singleVideoFallback) {
      send('resolve:progress', { requestID, count: 1, message: '未发现外层合集，已读取当前视频' });
      return singleVideoFallback;
    }
    const detail = diagnostics.slice(-8).join('\n');
    throw new Error(detail || '没有解析到可下载的视频。');
  }
  const preview = core.parsePreviewLines(lines, validated);
  if (videoHasCollectionContext && preview.items.length <= 1) {
    throw new Error('链接带有合集信息，但只解析到当前视频，请稍后重试。');
  }
  return preview;
}

function thumbnailAllowed(url) {
  const host = url.hostname.toLowerCase();
  return ['hdslb.com', 'bilibili.com', 'biliimg.com'].some((allowed) => host === allowed || host.endsWith(`.${allowed}`));
}

async function loadThumbnail(source) {
  const normalized = core.normalizeThumbnailURL(source);
  if (!normalized) return null;
  if (thumbnailCache.has(normalized)) return thumbnailCache.get(normalized);
  const request = (async () => {
    const url = new URL(normalized);
    if (!thumbnailAllowed(url)) throw new Error('缩略图来源不受信任。');
    const response = await fetch(url, {
      signal: AbortSignal.timeout(15000),
      headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124 Safari/537.36',
        Referer: 'https://www.bilibili.com/'
      }
    });
    if (!response.ok) throw new Error(`缩略图返回 HTTP ${response.status}`);
    const contentType = (response.headers.get('content-type') || 'image/jpeg').split(';')[0].toLowerCase();
    if (!contentType.startsWith('image/')) throw new Error('缩略图响应不是图片。');
    const declaredSize = Number(response.headers.get('content-length')) || 0;
    if (declaredSize > 8 * 1024 * 1024) throw new Error('缩略图文件过大。');
    const buffer = Buffer.from(await response.arrayBuffer());
    if (buffer.length > 8 * 1024 * 1024) throw new Error('缩略图文件过大。');
    return `data:${contentType};base64,${buffer.toString('base64')}`;
  })();
  thumbnailCache.set(normalized, request);
  try { return await request; } catch (error) { thumbnailCache.delete(normalized); throw error; }
}

function stopChild(child) {
  if (!child || child.killed) return;
  if (process.platform === 'win32') {
    const killer = spawn('taskkill.exe', ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true });
    killer.on('error', () => child.kill());
  } else child.kill('SIGTERM');
}

function outputTemplateFor(item, count) {
  if (count > 1) {
    const width = Math.max(2, String(count).length);
    return `[${String(item.index).padStart(width, '0')}] %(title).180B [%(id)s].%(ext)s`;
  }
  return '%(title).180B [%(id)s].%(ext)s';
}

class DownloadManager {
  constructor() {
    this.active = new Map();
    this.tasks = [];
    this.preview = null;
    this.destination = '';
    this.settings = {};
    this.paused = false;
    this.pausedForSleep = false;
    this.cancelled = false;
  }

  async start(payload) {
    if (this.active.size) throw new Error('已有下载任务正在运行。');
    const tools = await locateTools();
    if (!tools.ytdlp || !tools.ffmpeg || !tools.ffprobe) throw new Error('内置下载组件异常，请点击“修复组件”。');
    if (payload.settings.engine === 'aria2' && !tools.aria2) throw new Error('内置 aria2 异常，请修复组件或切换标准引擎。');
    this.preview = payload.preview;
    this.destination = payload.destination;
    this.settings = { ...payload.settings, concurrency: Math.max(1, Math.min(5, Number(payload.settings.concurrency) || 3)) };
    this.tools = tools;
    this.paused = false;
    this.pausedForSleep = false;
    this.cancelled = false;
    const selected = new Set(payload.selectedKeys || []);
    this.tasks = this.preview.items.filter((item) => selected.has(item.key)).map((item) => ({
      ...item, status: 'queued', progress: 0, speed: '', retries: 0, error: '', completedPath: ''
    }));
    if (!this.tasks.length) throw new Error('请至少勾选一个视频。');
    this.collectionDestination = this.tasks.length > 1
      ? path.join(this.destination, core.safePathSegment(this.preview.title))
      : this.destination;
    await fsp.mkdir(this.collectionDestination, { recursive: true });
    await this.persist();
    this.enablePowerProtection();
    this.emitAll();
    this.pump();
    return { count: this.tasks.length };
  }

  emitAll() {
    send('downloads:state', { paused: this.paused, tasks: this.tasks, active: this.active.size });
  }

  emitTask(task) {
    send('downloads:task', task);
  }

  async persist() {
    if (!this.preview || this.cancelled) return;
    await writeJSON(userDataPath('unfinished-download.json'), {
      version: 1, preview: this.preview, destination: this.destination, settings: this.settings,
      selectedKeys: this.tasks.filter((task) => task.status !== 'completed').map((task) => task.key)
    });
  }

  enablePowerProtection() {
    if (saveBlocker === null) saveBlocker = powerSaveBlocker.start('prevent-app-suspension');
  }

  disablePowerProtection() {
    if (saveBlocker !== null && powerSaveBlocker.isStarted(saveBlocker)) powerSaveBlocker.stop(saveBlocker);
    saveBlocker = null;
  }

  pump() {
    if (this.paused || this.cancelled) return;
    const available = this.settings.concurrency - this.active.size;
    const queued = this.tasks.filter((task) => task.status === 'queued').slice(0, available);
    queued.forEach((task) => this.runTask(task));
    if (!this.active.size && !this.tasks.some((task) => ['queued', 'downloading', 'retrying'].includes(task.status))) {
      this.finishBatch();
    }
  }

  runTask(task) {
    task.status = task.retries ? 'retrying' : 'downloading';
    task.error = '';
    task.speed = '正在连接…';
    this.emitTask(task);
    const settings = {
      ...this.settings,
      cookieFile: fs.existsSync(userDataPath('bilibili-cookies.txt')) ? userDataPath('bilibili-cookies.txt') : null
    };
    const args = core.buildDownloadArguments({
      item: task, destination: this.collectionDestination, settings, tools: this.tools,
      outputTemplate: outputTemplateFor(task, this.tasks.length)
    });
    const child = spawn(this.tools.ytdlp, args, { windowsHide: true });
    const context = { child, pausing: false, completedPath: '' };
    this.active.set(task.key, context);
    const onLine = (line) => {
      send('downloads:log', `[${task.index}] ${line}`);
      const progress = core.parseProgress(line);
      if (progress) {
        task.progress = progress.percent;
        task.speed = progress.speed || '正在传输…';
        this.emitTask(task);
      }
      const completed = core.parseCompletedPath(line);
      if (completed) context.completedPath = completed;
    };
    splitLines(child.stdout, onLine);
    splitLines(child.stderr, onLine);
    child.once('error', (error) => {
      send('downloads:log', `[${task.index}] 启动失败：${error.message}`);
    });
    child.once('close', async (code) => {
      this.active.delete(task.key);
      if (context.pausing || this.paused || this.cancelled) {
        if (!this.cancelled) { task.status = 'paused'; task.speed = ''; this.emitTask(task); }
        return;
      }
      const verified = await this.verify(context.completedPath);
      if (verified.ok) {
        task.status = 'completed'; task.progress = 100; task.speed = ''; task.completedPath = verified.path;
        await this.cleanupResiduals(verified.path);
      } else {
        task.retries += 1;
        task.error = verified.reason || `下载进程退出（代码 ${code}）`;
        if (task.retries <= 3) {
          task.status = 'retrying'; task.speed = `等待第 ${task.retries} 次重试…`;
          this.emitTask(task);
          setTimeout(() => {
            if (!this.paused && !this.cancelled) { task.status = 'queued'; this.pump(); }
          }, Math.min(8000, task.retries * 2500));
        } else {
          task.status = 'failed'; task.speed = '';
          await this.cleanupFailed(task);
        }
      }
      this.emitTask(task);
      await this.persist();
      this.pump();
    });
  }

  async verify(candidate) {
    if (!candidate || !core.isPlausibleFinalVideo(candidate) || !fs.existsSync(candidate)) {
      return { ok: false, reason: '没有生成可验证的最终视频文件。' };
    }
    try {
      const stat = await fsp.stat(candidate);
      if (stat.size < 1024) return { ok: false, reason: '最终视频文件为空或不完整。' };
      const result = await runProcess(this.tools.ffprobe, [
        '-v', 'error', '-show_entries', 'stream=codec_type', '-of', 'csv=p=0', '--', candidate
      ]);
      const types = new Set(result.stdout.map((line) => line.trim().toLowerCase()));
      if (result.code !== 0 || !types.has('video') || !types.has('audio')) {
        return { ok: false, reason: '合并结果缺少视频轨或音频轨，已保留断点并准备重试。' };
      }
      return { ok: true, path: candidate };
    } catch (error) { return { ok: false, reason: error.message }; }
  }

  async cleanupResiduals(completedPath) {
    const folder = path.dirname(completedPath);
    const stem = path.basename(completedPath, path.extname(completedPath)).toLowerCase();
    for (const name of await fsp.readdir(folder)) {
      const lower = name.toLowerCase();
      const residual = lower.endsWith('.aria2') || lower.endsWith('.part') || lower.includes('.part.');
      if (residual && lower.startsWith(stem)) await fsp.rm(path.join(folder, name), { force: true });
    }
  }

  async cleanupFailed(task) {
    try {
      const width = Math.max(2, String(this.tasks.length).length);
      const episodePrefix = this.tasks.length > 1 ? `[${String(task.index).padStart(width, '0')}] `.toLowerCase() : '';
      for (const name of await fsp.readdir(this.collectionDestination)) {
        const lower = name.toLowerCase();
        if (episodePrefix ? !lower.startsWith(episodePrefix) : !lower.includes(task.id.toLowerCase())) continue;
        const incomplete = lower.endsWith('.aria2') || lower.endsWith('.part') || lower.includes('.part.') || /\.f\d+\.(mp4|m4a|webm)$/.test(lower);
        if (incomplete) await fsp.rm(path.join(this.collectionDestination, name), { force: true });
      }
    } catch { /* cleanup is best effort */ }
  }

  pause(forSleep = false) {
    if (this.paused) return;
    this.paused = true;
    this.pausedForSleep = forSleep;
    for (const [key, context] of this.active) {
      context.pausing = true;
      const task = this.tasks.find((entry) => entry.key === key);
      if (task) { task.status = 'paused'; task.speed = ''; }
      stopChild(context.child);
    }
    this.emitAll();
    this.persist();
  }

  resume(systemResume = false) {
    if (!this.paused || (systemResume && !this.pausedForSleep)) return;
    // Wait until every terminated process has emitted close before relaunching
    // it, otherwise a very quick pause/resume click could duplicate a task.
    if (this.active.size) {
      setTimeout(() => this.resume(systemResume), 250);
      return;
    }
    this.paused = false;
    this.pausedForSleep = false;
    this.tasks.filter((task) => task.status === 'paused').forEach((task) => { task.status = 'queued'; });
    this.emitAll();
    this.pump();
  }

  async cancel() {
    this.cancelled = true;
    this.paused = false;
    for (const context of this.active.values()) { context.pausing = true; stopChild(context.child); }
    this.active.clear();
    this.tasks.forEach((task) => { if (task.status !== 'completed') task.status = 'cancelled'; });
    await fsp.rm(userDataPath('unfinished-download.json'), { force: true });
    this.disablePowerProtection();
    this.emitAll();
  }

  async finishBatch() {
    this.disablePowerProtection();
    const failed = this.tasks.filter((task) => task.status === 'failed').length;
    const completed = this.tasks.filter((task) => task.status === 'completed').length;
    if (!failed) await fsp.rm(userDataPath('unfinished-download.json'), { force: true });
    send('downloads:finished', { completed, failed, destination: this.collectionDestination });
  }
}

async function sha256File(file) {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash('sha256');
    const input = fs.createReadStream(file);
    input.on('error', reject);
    input.on('data', (chunk) => hash.update(chunk));
    input.on('end', () => resolve(hash.digest('hex')));
  });
}

class AppUpdater {
  constructor() {
    this.available = null;
    this.stagedRoot = null;
  }

  async check() {
    const channel = await readJSON(path.join(__dirname, 'update-channel.json'), {});
    const sources = updateCore.manifestURLs(channel, DEFAULT_UPDATE_MANIFEST_URL);
    let lastError = null;
    for (const url of sources) {
      try {
        const response = await net.fetch(url, {
          signal: AbortSignal.timeout(20000),
          cache: 'no-store',
          headers: { 'User-Agent': `BiliFetch-Windows/${APP_VERSION}`, Accept: 'application/json' }
        });
        if (!response.ok) throw new Error(`更新服务器返回 HTTP ${response.status}`);
        const release = updateCore.validateManifest(await response.json());
        const result = {
          configured: true,
          available: updateCore.compareVersions(release.version, APP_VERSION) > 0,
          currentVersion: APP_VERSION,
          release
        };
        this.available = result.available ? release : null;
        return result;
      } catch (error) { lastError = error; }
    }
    throw lastError || new Error('暂时无法连接更新服务器。');
  }

  async download(release = this.available) {
    if (!release) throw new Error('没有可下载的新版本。');
    const checked = updateCore.validateManifest({
      version: release.version,
      notes: release.notes,
      publishedAt: release.publishedAt,
      windows: { url: release.url, sha256: release.sha256, size: release.size }
    });
    const updateDir = userDataPath('Updates', checked.version);
    const archive = path.join(updateDir, 'BiliFetch-update.zip');
    const extracted = path.join(updateDir, 'extracted');
    await fsp.rm(updateDir, { recursive: true, force: true });
    await fsp.mkdir(updateDir, { recursive: true });
    await downloadUpdateFile(checked.url, archive, '应用更新', (progress) => send('update:progress', progress));
    send('update:progress', { label: '正在校验更新包', percent: null });
    const digest = await sha256File(archive);
    if (digest !== checked.sha256) {
      await fsp.rm(updateDir, { recursive: true, force: true });
      throw new Error('更新包 SHA-256 校验失败，已删除可疑文件。');
    }
    await extract(archive, { dir: extracted });
    const executable = await findFile(extracted, 'BiliFetch.exe');
    if (!executable) throw new Error('更新包中没有找到 BiliFetch.exe。');
    this.stagedRoot = path.dirname(executable);
    this.available = checked;
    send('update:progress', { label: '更新包已就绪', percent: 100 });
    return { ready: true, version: checked.version };
  }

  async install() {
    if (!this.stagedRoot || !this.available) throw new Error('请先下载更新包。');
    if (process.platform !== 'win32' || !app.isPackaged) throw new Error('安装更新只能在已打包的 Windows 版本中执行。');
    const hasDownloads = downloadManager?.active.size || downloadManager?.tasks.some((task) => ['queued', 'downloading', 'retrying'].includes(task.status));
    if (hasDownloads) throw new Error('请等待下载任务结束或先取消任务，再安装更新。');
    const target = path.dirname(process.execPath);
    await fsp.access(target, fs.constants.W_OK);
    const helper = userDataPath('Updates', `install-${Date.now()}.ps1`);
    const logFile = userDataPath('Updates', 'update-install.log');
    const script = [
      'param([string]$Source, [string]$Target, [string]$Executable, [int]$ProcessId, [string]$LogFile)',
      "$ErrorActionPreference = 'Stop'",
      'try {',
      '  Wait-Process -Id $ProcessId -ErrorAction SilentlyContinue',
      '  Start-Sleep -Milliseconds 1200',
      "  Copy-Item -Path (Join-Path $Source '*') -Destination $Target -Recurse -Force",
      '  Start-Process -FilePath (Join-Path $Target $Executable)',
      "  'Update installed successfully.' | Out-File -LiteralPath $LogFile -Encoding utf8",
      '} catch {',
      '  $_ | Out-File -LiteralPath $LogFile -Encoding utf8',
      '}',
      'Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue'
    ].join('\r\n');
    await fsp.writeFile(helper, script, 'utf8');
    const child = spawn('powershell.exe', [
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', helper,
      '-Source', this.stagedRoot,
      '-Target', target,
      '-Executable', path.basename(process.execPath),
      '-ProcessId', String(process.pid),
      '-LogFile', logFile
    ], { detached: true, windowsHide: true, stdio: 'ignore' });
    child.unref();
    setTimeout(() => app.quit(), 250);
    return { installing: true };
  }
}

function parseSetCookies(headers) {
  const values = typeof headers.getSetCookie === 'function' ? headers.getSetCookie() : [];
  return values.map((value) => {
    const parts = value.split(';').map((part) => part.trim());
    const [name, ...valueParts] = parts[0].split('=');
    const maxAge = parts.find((part) => /^max-age=/i.test(part));
    const expires = maxAge ? Math.floor(Date.now() / 1000) + Number(maxAge.split('=')[1]) : Math.floor(Date.now() / 1000) + 31536000;
    return { name, value: valueParts.join('='), expires };
  }).filter((cookie) => cookie.name);
}

async function startQRLogin() {
  const response = await fetch('https://passport.bilibili.com/x/passport-login/web/qrcode/generate', { headers: { 'User-Agent': 'Mozilla/5.0' } });
  const body = await response.json();
  if (body.code !== 0) throw new Error(body.message || '无法创建登录二维码。');
  qrSession = { key: body.data.qrcode_key, cookies: parseSetCookies(response.headers) };
  return { image: await QRCode.toDataURL(body.data.url, { width: 260, margin: 1 }), status: '等待扫码' };
}

async function pollQRLogin() {
  if (!qrSession) throw new Error('登录二维码已失效，请重新获取。');
  const endpoint = `https://passport.bilibili.com/x/passport-login/web/qrcode/poll?qrcode_key=${encodeURIComponent(qrSession.key)}`;
  const response = await fetch(endpoint, { headers: { 'User-Agent': 'Mozilla/5.0' } });
  const body = await response.json();
  qrSession.cookies.push(...parseSetCookies(response.headers));
  const code = body.data?.code;
  if (code === 0) {
    const unique = new Map(qrSession.cookies.map((cookie) => [cookie.name, cookie]));
    const lines = ['# Netscape HTTP Cookie File', ...[...unique.values()].map((cookie) => `.bilibili.com\tTRUE\t/\tFALSE\t${cookie.expires}\t${cookie.name}\t${cookie.value}`)];
    await fsp.writeFile(userDataPath('bilibili-cookies.txt'), `${lines.join('\n')}\n`, { mode: 0o600 });
    qrSession = null;
    return { done: true, status: '登录成功' };
  }
  const statuses = { 86038: '二维码已失效', 86090: '已扫码，请在手机上确认', 86101: '等待扫码' };
  return { done: false, expired: code === 86038, status: statuses[code] || body.message || '等待确认' };
}

async function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1280, height: 820, minWidth: 930, minHeight: 650, backgroundColor: '#100d1b',
    title: 'BiliFetch', icon: path.join(__dirname, 'assets', 'icon.png'),
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, nodeIntegration: false, sandbox: true }
  });
  await mainWindow.loadFile(path.join(__dirname, 'renderer', 'index.html'));
}

async function loadSettings() {
  const saved = await readJSON(userDataPath('settings.json'), {});
  const defaults = {
    quality: 'best', engine: 'aria2', concurrency: 3, browser: 'none', subtitles: false
  };
  return Object.fromEntries(Object.keys(defaults).map((key) => [key, saved[key] ?? defaults[key]]));
}

function registerIPC() {
  ipcMain.handle('app:initial', async () => {
    const settings = await loadSettings();
    return {
      version: APP_VERSION, tools: await locateTools(),
      defaultDestination: app.getPath('downloads'), settings,
      unfinished: await readJSON(userDataPath('unfinished-download.json'), null),
      loggedIn: fs.existsSync(userDataPath('bilibili-cookies.txt'))
    };
  });
  ipcMain.handle('clipboard:read', () => clipboard.readText());
  ipcMain.handle('dialog:destination', async () => {
    const result = await dialog.showOpenDialog(mainWindow, { properties: ['openDirectory', 'createDirectory'], title: '选择视频保存位置' });
    return result.canceled ? null : result.filePaths[0];
  });
  ipcMain.handle('tools:prepare', prepareTools);
  ipcMain.handle('tools:status', locateTools);
  ipcMain.handle('settings:save', async (_, settings) => { await writeJSON(userDataPath('settings.json'), settings); return true; });
  ipcMain.handle('resolve:start', (_, payload) => resolveCollection(payload.url, payload.settings, payload.requestID));
  ipcMain.handle('thumbnail:load', (_, source) => loadThumbnail(source));
  ipcMain.handle('downloads:start', (_, payload) => downloadManager.start(payload));
  ipcMain.handle('downloads:pause', () => downloadManager.pause(false));
  ipcMain.handle('downloads:resume', () => downloadManager.resume(false));
  ipcMain.handle('downloads:cancel', () => downloadManager.cancel());
  ipcMain.handle('downloads:reveal', (_, filePath) => { if (filePath) shell.showItemInFolder(filePath); });
  ipcMain.handle('folder:open', (_, folder) => shell.openPath(folder));
  ipcMain.handle('login:start', startQRLogin);
  ipcMain.handle('login:poll', pollQRLogin);
  ipcMain.handle('login:logout', async () => { qrSession = null; await fsp.rm(userDataPath('bilibili-cookies.txt'), { force: true }); return true; });
  ipcMain.handle('update:check', () => appUpdater.check());
  ipcMain.handle('update:download', (_, release) => appUpdater.download(release));
  ipcMain.handle('update:install', () => appUpdater.install());
}

app.whenReady().then(async () => {
  app.setAppUserModelId('com.bilifetch.windows');
  downloadManager = new DownloadManager();
  appUpdater = new AppUpdater();
  registerIPC();
  powerMonitor.on('suspend', () => downloadManager.pause(true));
  powerMonitor.on('resume', () => setTimeout(() => downloadManager.resume(true), 6000));
  await createWindow();
});

app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
app.on('before-quit', () => { if (downloadManager?.active.size) downloadManager.pause(false); });
