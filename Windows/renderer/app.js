'use strict';

const $ = (selector) => document.querySelector(selector);
const state = {
  preview: null, destination: '', settings: {}, tasks: new Map(), downloading: false,
  paused: false, logs: [], pollTimer: null, version: '', updateRelease: null,
  thumbnailCache: new Map(), thumbnailObserver: null
};

const statusText = {
  ready: '待下载', queued: '排队中', downloading: '下载中', retrying: '正在重试',
  paused: '已暂停', completed: '已完成', failed: '永久失败', cancelled: '已取消'
};

function setNotice(message, type = '') {
  $('#notice').textContent = message;
  $('#notice').className = `notice ${type}`.trim();
}

function formatDuration(seconds) {
  const value = Math.max(0, Math.round(Number(seconds) || 0));
  const h = Math.floor(value / 3600);
  const m = Math.floor(value % 3600 / 60);
  const s = value % 60;
  return h ? `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}` : `${m}:${String(s).padStart(2, '0')}`;
}

function toolsReady(tools) { return Boolean(tools?.ytdlp && tools?.ffmpeg && tools?.ffprobe && tools?.aria2); }

function updateToolStatus(tools) {
  const ready = toolsReady(tools);
  $('#toolStatus').className = `status-pill ${ready ? 'ready' : 'warning'}`;
  $('#toolStatus').innerHTML = `<i></i>${ready ? '内置组件就绪' : '内置组件异常'}`;
  $('#prepareButton').textContent = '修复组件';
  $('#prepareButton').classList.toggle('hidden', ready);
}

function readSettings() {
  return {
    quality: $('#quality').value,
    engine: $('#engine').value,
    concurrency: Number($('#concurrency').value),
    browser: $('#browser').value,
    subtitles: $('#subtitles').checked
  };
}

function applySettings(settings) {
  state.settings = {
    quality: 'best', engine: 'aria2', concurrency: 3, browser: 'none', subtitles: false,
    ...settings
  };
  $('#quality').value = state.settings.quality;
  $('#engine').value = state.settings.engine;
  $('#concurrency').value = state.settings.concurrency;
  $('#concurrencyValue').textContent = state.settings.concurrency;
  $('#browser').value = state.settings.browser;
  $('#subtitles').checked = state.settings.subtitles;
}

function selectedItems() {
  return state.preview?.items.filter((item) => item.selected) || [];
}

function updateSelectionSummary() {
  if (!state.preview) return;
  const selected = selectedItems().length;
  $('#selectedCount').textContent = `已选择 ${selected} / ${state.preview.items.length}`;
  $('#startButton').disabled = !selected || !state.destination || state.downloading;
}

function cardClass(task) {
  const active = ['downloading', 'retrying'].includes(task.status) ? 'active' : '';
  return `video-card ${task.status || 'ready'} ${active}`;
}

function cardMarkup(item) {
  const task = state.tasks.get(item.key) || item;
  const progress = Math.round(task.progress || 0);
  const image = item.thumbnail
    ? `<img class="pending" data-thumbnail="${escapeAttribute(item.thumbnail)}" alt=""><div class="thumb-placeholder">▶</div>`
    : '<div class="thumb-placeholder">▶</div>';
  return `<article class="${cardClass(task)}" data-key="${escapeAttribute(item.key)}">
    <div class="thumb-wrap"><input class="card-check" type="checkbox" ${item.selected ? 'checked' : ''} ${state.downloading ? 'disabled' : ''}>${image}<span class="duration">${formatDuration(item.duration)}</span></div>
    <div class="card-body"><div class="card-title" title="${escapeAttribute(item.title)}">${escapeHTML(item.index + '. ' + item.title)}</div>
      <div class="card-meta"><span class="task-status">${statusText[task.status] || '待下载'}</span><span>${escapeHTML(task.error || '')}</span></div>
      <div class="progress-line"><strong>${progress}%</strong><div class="progress-track"><div class="progress-bar" style="width:${progress}%"></div></div></div>
      <div class="speed">${escapeHTML(task.speed || '')}</div>
    </div></article>`;
}

function escapeHTML(value) {
  return String(value ?? '').replace(/[&<>'"]/g, (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;' }[char]));
}
function escapeAttribute(value) { return escapeHTML(value); }

function revealThumbnail(image, dataURL) {
  if (!image.isConnected) return;
  image.addEventListener('load', () => {
    image.classList.remove('pending');
    image.nextElementSibling?.classList.add('hidden');
  }, { once: true });
  image.src = dataURL;
}

async function hydrateThumbnail(image) {
  const source = image.dataset.thumbnail;
  if (!source || image.dataset.loading) return;
  image.dataset.loading = 'true';
  try {
    let dataURL = state.thumbnailCache.get(source);
    if (!dataURL) {
      dataURL = await window.biliFetch.loadThumbnail(source);
      if (dataURL) state.thumbnailCache.set(source, dataURL);
    }
    if (dataURL) revealThumbnail(image, dataURL);
  } catch {
    image.dataset.loading = '';
  }
}

function observeThumbnails() {
  if (!state.thumbnailObserver) {
    state.thumbnailObserver = new IntersectionObserver((entries) => {
      entries.filter((entry) => entry.isIntersecting).forEach((entry) => {
        state.thumbnailObserver.unobserve(entry.target);
        hydrateThumbnail(entry.target);
      });
    }, { root: $('.scroll-region'), rootMargin: '300px' });
  }
  document.querySelectorAll('img[data-thumbnail]').forEach((image) => state.thumbnailObserver.observe(image));
}

function renderPreview() {
  const hasPreview = Boolean(state.preview?.items?.length);
  $('#emptyState').classList.toggle('hidden', hasPreview);
  $('#collectionHeader').classList.toggle('hidden', !hasPreview);
  $('#selectAllButton').disabled = !hasPreview || state.downloading;
  $('#selectNoneButton').disabled = !hasPreview || state.downloading;
  if (!hasPreview) { $('#videoGrid').innerHTML = ''; updateSelectionSummary(); return; }
  $('#collectionTitle').textContent = state.preview.title;
  $('#collectionCount').textContent = `共 ${state.preview.items.length} 个视频 · 分集区域可独立上下滚动`;
  $('#videoGrid').innerHTML = state.preview.items.map(cardMarkup).join('');
  document.querySelectorAll('.video-card').forEach((card) => {
    card.querySelector('.card-check').addEventListener('change', (event) => {
      const item = state.preview.items.find((entry) => entry.key === card.dataset.key);
      if (item) item.selected = event.target.checked;
      updateSelectionSummary();
    });
  });
  observeThumbnails();
  updateSelectionSummary();
}

function patchTask(task) {
  state.tasks.set(task.key, task);
  if (!state.preview) return;
  const item = state.preview.items.find((entry) => entry.key === task.key);
  const existing = document.querySelector(`.video-card[data-key="${CSS.escape(task.key)}"]`);
  if (!item || !existing) return;
  existing.className = cardClass(task);
  existing.querySelector('.task-status').textContent = statusText[task.status] || '待下载';
  existing.querySelector('.card-meta > span:last-child').textContent = task.error || '';
  const progress = Math.round(task.progress || 0);
  existing.querySelector('.progress-line strong').textContent = `${progress}%`;
  existing.querySelector('.progress-bar').style.width = `${progress}%`;
  existing.querySelector('.speed').textContent = task.speed || '';
}

function updateControls() {
  $('#pauseButton').classList.toggle('hidden', !state.downloading);
  $('#cancelButton').classList.toggle('hidden', !state.downloading);
  $('#pauseButton').textContent = state.paused ? '继续' : '暂停';
  $('#startButton').classList.toggle('hidden', state.downloading);
  $('#sourceURL').disabled = state.downloading;
  $('#resolveButton').disabled = state.downloading;
  $('#destinationButton').disabled = state.downloading;
  updateSelectionSummary();
}

async function resolveLink() {
  const url = $('#sourceURL').value.trim();
  if (!url) { setNotice('请先粘贴 B 站链接。', 'error'); return; }
  $('#resolveButton').disabled = true;
  $('#resolveButton').textContent = '正在解析…';
  setNotice('正在获取合集信息，请稍候…');
  try {
    state.settings = readSettings();
    const preview = await window.biliFetch.resolve({ url, settings: state.settings });
    state.preview = preview;
    state.tasks.clear();
    preview.items.forEach((item) => state.tasks.set(item.key, item));
    renderPreview();
    setNotice(`解析完成：已获取 ${preview.items.length} 个视频，默认全部勾选。`, 'success');
  } catch (error) {
    setNotice(`解析失败：${error.message}`, 'error');
  } finally {
    $('#resolveButton').disabled = false;
    $('#resolveButton').textContent = '解析链接';
  }
}

async function startDownloads() {
  if (!state.preview || !state.destination) return;
  state.settings = readSettings();
  await window.biliFetch.saveSettings(state.settings);
  try {
    const selectedKeys = selectedItems().map((item) => item.key);
    await window.biliFetch.startDownloads({ preview: state.preview, selectedKeys, destination: state.destination, settings: state.settings });
    state.downloading = true;
    state.paused = false;
    $('#batchProgress').classList.add('hidden');
    setNotice(`已建立 ${selectedKeys.length} 个任务，同时下载 ${state.settings.concurrency} 个。`);
    updateControls();
    renderPreview();
  } catch (error) { setNotice(`无法开始下载：${error.message}`, 'error'); }
}

async function prepareTools() {
  $('#prepareButton').disabled = true;
  setNotice('正在修复 yt-dlp、FFmpeg 和 aria2；正常完整包无需执行此操作。');
  try {
    const tools = await window.biliFetch.prepareTools();
    updateToolStatus(tools);
    setNotice('组件修复完成。', 'success');
  } catch (error) { setNotice(`组件准备失败：${error.message}`, 'error'); }
  finally { $('#prepareButton').disabled = false; }
}

async function beginLogin() {
  $('#loginDialog').showModal();
  $('#qrImage').removeAttribute('src');
  $('#qrStatus').textContent = '正在生成二维码…';
  try {
    const result = await window.biliFetch.startLogin();
    $('#qrImage').src = result.image;
    $('#qrStatus').textContent = result.status;
    clearInterval(state.pollTimer);
    state.pollTimer = setInterval(async () => {
      try {
        const poll = await window.biliFetch.pollLogin();
        $('#qrStatus').textContent = poll.status;
        if (poll.done || poll.expired) {
          clearInterval(state.pollTimer); state.pollTimer = null;
          if (poll.done) {
            $('#loginStatus').textContent = '已扫码登录；可下载账号有权访问的最高画质。';
            $('#loginButton').textContent = '退出登录';
            setTimeout(() => $('#loginDialog').close(), 800);
          }
        }
      } catch (error) { $('#qrStatus').textContent = error.message; clearInterval(state.pollTimer); }
    }, 1800);
  } catch (error) { $('#qrStatus').textContent = error.message; }
}

async function checkForUpdates(manual = true) {
  $('#updateButton').disabled = true;
  if (manual) setNotice('正在检查新版本…');
  try {
    const result = await window.biliFetch.checkUpdate();
    if (!result.available) {
      if (manual) setNotice(`当前 v${result.currentVersion} 已是最新版本。`, 'success');
      return;
    }
    state.updateRelease = result.release;
    $('#newVersion').textContent = `v${result.release.version}`;
    $('#versionComparison').textContent = `当前版本 v${result.currentVersion}`;
    $('#updateNotes').textContent = result.release.notes || '本次更新暂无说明。';
    $('#updateStatus').textContent = '可以下载更新包；下载任务和组件不会丢失。';
    $('#updateProgress').classList.add('hidden');
    $('#updateProgressBar').style.width = '0%';
    $('#downloadUpdateButton').classList.remove('hidden');
    $('#installUpdateButton').classList.add('hidden');
    $('#updateDialog').showModal();
    $('#updateButton').textContent = `可更新 v${result.release.version}`;
  } catch (error) {
    if (manual) setNotice(`检查更新失败：${error.message}`, 'error');
  } finally { $('#updateButton').disabled = false; }
}

async function downloadUpdate() {
  if (!state.updateRelease) return;
  $('#downloadUpdateButton').disabled = true;
  $('#laterUpdateButton').disabled = true;
  $('#updateProgress').classList.remove('hidden');
  $('#updateStatus').textContent = '正在下载更新包…';
  try {
    await window.biliFetch.downloadUpdate(state.updateRelease);
    $('#downloadUpdateButton').classList.add('hidden');
    $('#installUpdateButton').classList.remove('hidden');
    $('#laterUpdateButton').disabled = false;
    $('#updateStatus').textContent = '更新包已下载并通过 SHA-256 校验。';
  } catch (error) {
    $('#downloadUpdateButton').disabled = false;
    $('#laterUpdateButton').disabled = false;
    $('#updateStatus').textContent = `更新下载失败：${error.message}`;
  }
}

async function installUpdate() {
  $('#installUpdateButton').disabled = true;
  $('#updateStatus').textContent = '正在准备退出并升级…';
  try { await window.biliFetch.installUpdate(); }
  catch (error) { $('#installUpdateButton').disabled = false; $('#updateStatus').textContent = `无法安装更新：${error.message}`; }
}

function bindEvents() {
  $('#pasteButton').addEventListener('click', async () => { $('#sourceURL').value = await window.biliFetch.readClipboard(); resolveLink(); });
  $('#resolveButton').addEventListener('click', resolveLink);
  $('#sourceURL').addEventListener('keydown', (event) => { if (event.key === 'Enter') resolveLink(); });
  $('#destinationButton').addEventListener('click', async () => {
    const value = await window.biliFetch.chooseDestination();
    if (value) { state.destination = value; $('#destinationPath').textContent = value; updateSelectionSummary(); }
  });
  $('#prepareButton').addEventListener('click', prepareTools);
  $('#updateButton').addEventListener('click', () => checkForUpdates(true));
  $('#advancedButton').addEventListener('click', () => $('#advancedDialog').showModal());
  $('#concurrency').addEventListener('input', () => { $('#concurrencyValue').textContent = $('#concurrency').value; });
  $('#saveSettingsButton').addEventListener('click', () => { state.settings = readSettings(); window.biliFetch.saveSettings(state.settings); });
  $('#selectAllButton').addEventListener('click', () => { state.preview.items.forEach((item) => { item.selected = true; }); renderPreview(); });
  $('#selectNoneButton').addEventListener('click', () => { state.preview.items.forEach((item) => { item.selected = false; }); renderPreview(); });
  $('#startButton').addEventListener('click', startDownloads);
  $('#pauseButton').addEventListener('click', async () => { state.paused ? await window.biliFetch.resumeDownloads() : await window.biliFetch.pauseDownloads(); });
  $('#cancelButton').addEventListener('click', async () => { await window.biliFetch.cancelDownloads(); state.downloading = false; updateControls(); renderPreview(); setNotice('下载任务已取消；断点文件会保留，重新解析后可继续。'); });
  $('#openFolderButton').addEventListener('click', () => window.biliFetch.openFolder($('#openFolderButton').dataset.folder));
  $('#loginButton').addEventListener('click', () => $('#loginButton').textContent === '退出登录' ? window.biliFetch.logout().then(() => { $('#loginButton').textContent = '扫码登录'; $('#loginStatus').textContent = '未扫码登录；仍会默认下载当前可用最高画质。'; }) : beginLogin());
  $('#closeLoginButton').addEventListener('click', () => { clearInterval(state.pollTimer); state.pollTimer = null; $('#loginDialog').close(); });
  $('#closeUpdateButton').addEventListener('click', () => $('#updateDialog').close());
  $('#laterUpdateButton').addEventListener('click', () => $('#updateDialog').close());
  $('#downloadUpdateButton').addEventListener('click', downloadUpdate);
  $('#installUpdateButton').addEventListener('click', installUpdate);

  window.biliFetch.onToolProgress(({ label, percent }) => setNotice(`正在准备 ${label}${percent === null ? '…' : `：${percent}%`}`));
  window.biliFetch.onResolveProgress(({ message }) => setNotice(message));
  window.biliFetch.onDownloadTask(patchTask);
  window.biliFetch.onDownloadState((payload) => { state.paused = payload.paused; state.downloading = payload.tasks.some((task) => !['completed', 'failed', 'cancelled'].includes(task.status)); payload.tasks.forEach((task) => state.tasks.set(task.key, task)); updateControls(); renderPreview(); });
  window.biliFetch.onDownloadLog((line) => { state.logs.push(line); if (state.logs.length > 600) state.logs.shift(); $('#logOutput').textContent = state.logs.join('\n'); });
  window.biliFetch.onDownloadFinished((result) => {
    state.downloading = false; state.paused = false; updateControls(); renderPreview();
    $('#batchProgress').classList.remove('hidden');
    $('#batchSummary').textContent = result.failed ? `完成 ${result.completed} 个，失败 ${result.failed} 个。失败项目需重新解析后重试。` : `全部 ${result.completed} 个视频已完成并通过音视频轨检查。`;
    $('#openFolderButton').dataset.folder = result.destination;
    setNotice(result.failed ? '部分任务未完成，请在高级设置中查看日志。' : '所有任务下载完成。', result.failed ? 'error' : 'success');
  });
  window.biliFetch.onUpdateProgress(({ label, percent }) => {
    $('#updateStatus').textContent = percent === null ? label : `${label}：${percent}%`;
    if (percent !== null) $('#updateProgressBar').style.width = `${percent}%`;
  });
}

async function initialize() {
  bindEvents();
  const initial = await window.biliFetch.initial();
  state.version = initial.version;
  $('#appVersion').textContent = `当前 v${initial.version}`;
  applySettings(initial.settings);
  updateToolStatus(initial.tools);
  state.destination = initial.defaultDestination || '';
  $('#destinationPath').textContent = state.destination || '尚未选择';
  if (initial.loggedIn) { $('#loginStatus').textContent = '已扫码登录；可下载账号有权访问的最高画质。'; $('#loginButton').textContent = '退出登录'; }
  if (initial.unfinished?.preview) {
    state.preview = initial.unfinished.preview;
    state.destination = initial.unfinished.destination || '';
    $('#sourceURL').value = state.preview.sourceURL || '';
    $('#destinationPath').textContent = state.destination || '尚未选择';
    const unfinished = new Set(initial.unfinished.selectedKeys || []);
    state.preview.items.forEach((item) => { item.selected = unfinished.has(item.key); item.status = 'ready'; item.progress = 0; });
    state.preview.items.forEach((item) => state.tasks.set(item.key, item));
    applySettings({ ...initial.settings, ...(initial.unfinished.settings || {}) });
    renderPreview();
    setNotice('已恢复上次未完成任务，请检查勾选项目后点击“开始下载”续传。');
  }
  setTimeout(() => checkForUpdates(false), 1800);
}

initialize().catch((error) => setNotice(`初始化失败：${error.message}`, 'error'));
