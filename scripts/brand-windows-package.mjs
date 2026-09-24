#!/usr/bin/env node
import fs from 'node:fs/promises';
import path from 'node:path';
import { createRequire } from 'node:module';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
const require = createRequire(new URL('../Windows/package.json', import.meta.url));
const { NtExecutable, NtExecutableResource, Resource, Data } = require('resedit');
const root = fileURLToPath(new URL('..', import.meta.url));
const directory = path.join(root, 'build/windows/BiliFetch-win32-x64');
const oldName = path.join(directory, 'BiliFetch.exe');
const displayName = '记住你宇哥';
const name = `${displayName}.exe`;
const main = path.join(directory, name);
await fs.rename(oldName, main);
const icon = Data.IconFile.from(await fs.readFile(path.join(root, 'Windows/assets/icon.ico')));
const executable = NtExecutable.from(await fs.readFile(path.join(root, 'build/wechat-capture/legacy-launcher.exe')));
const resources = NtExecutableResource.from(executable);
Resource.IconGroupEntry.replaceIconsForResource(resources.entries, 1, 1033, icon.icons.map(item => item.data));
const version = require('../Windows/package.json').version;
const info = Resource.VersionInfo.createEmpty();
info.setFileVersion(...version.split('.').map(Number));
info.setProductVersion(...version.split('.').map(Number));
info.setStringValues({lang:1033,codepage:1200}, {
 CompanyName:displayName, FileDescription:`${displayName}（旧版更新兼容入口）`,
 FileVersion:version, InternalName:'BiliFetchLauncher', OriginalFilename:'BiliFetch.exe',
 ProductName:displayName, ProductVersion:version
});
info.outputToResourceEntries(resources.entries);
resources.outputResource(executable);
await fs.writeFile(oldName,Buffer.from(executable.generate()));
// Fail packaging if Explorer's embedded icons or labels don't match the source.
const digest = data => createHash('sha256').update(Buffer.from(data)).digest('hex');
for (const file of [main,oldName]) {
 const res=NtExecutableResource.from(NtExecutable.from(await fs.readFile(file)));
 const embedded=new Set(res.entries.filter(entry=>entry.type===3).map(entry=>digest(entry.bin)));
 if (!icon.icons.every(item=>embedded.has(digest(item.data.generate())))) throw new Error(`程序图标不匹配：${path.basename(file)}`);
 const versions=Resource.VersionInfo.fromEntries(res.entries);
 if (!versions.some(item=>item.getAllLanguagesForStringValues().some(lang=>item.getStringValues(lang).ProductName===displayName))) throw new Error('程序名称没有写入 Windows 资源');
}
console.log(`Windows 主程序：${name}；图标和名称资源已核对；保留旧版更新兼容入口。`);
