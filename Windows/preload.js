'use strict';

const { contextBridge, ipcRenderer } = require('electron');

const on = (channel, callback) => {
  const listener = (_event, payload) => callback(payload);
  ipcRenderer.on(channel, listener);
  return () => ipcRenderer.removeListener(channel, listener);
};

contextBridge.exposeInMainWorld('biliFetch', {
  initial: () => ipcRenderer.invoke('app:initial'),
  readClipboard: () => ipcRenderer.invoke('clipboard:read'),
  chooseDestination: () => ipcRenderer.invoke('dialog:destination'),
  prepareTools: () => ipcRenderer.invoke('tools:prepare'),
  toolStatus: () => ipcRenderer.invoke('tools:status'),
  saveSettings: (settings) => ipcRenderer.invoke('settings:save', settings),
  resolve: (payload) => ipcRenderer.invoke('resolve:start', payload),
  loadThumbnail: (source) => ipcRenderer.invoke('thumbnail:load', source),
  startDownloads: (payload) => ipcRenderer.invoke('downloads:start', payload),
  pauseDownloads: () => ipcRenderer.invoke('downloads:pause'),
  resumeDownloads: () => ipcRenderer.invoke('downloads:resume'),
  cancelDownloads: () => ipcRenderer.invoke('downloads:cancel'),
  reveal: (filePath) => ipcRenderer.invoke('downloads:reveal', filePath),
  openFolder: (folder) => ipcRenderer.invoke('folder:open', folder),
  startLogin: () => ipcRenderer.invoke('login:start'),
  pollLogin: () => ipcRenderer.invoke('login:poll'),
  logout: () => ipcRenderer.invoke('login:logout'),
  checkUpdate: () => ipcRenderer.invoke('update:check'),
  downloadUpdate: (release) => ipcRenderer.invoke('update:download', release),
  installUpdate: () => ipcRenderer.invoke('update:install'),
  onToolProgress: (callback) => on('tools:progress', callback),
  onResolveProgress: (callback) => on('resolve:progress', callback),
  onDownloadState: (callback) => on('downloads:state', callback),
  onDownloadTask: (callback) => on('downloads:task', callback),
  onDownloadLog: (callback) => on('downloads:log', callback),
  onDownloadFinished: (callback) => on('downloads:finished', callback),
  onUpdateProgress: (callback) => on('update:progress', callback)
});
