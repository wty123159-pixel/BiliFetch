param(
  [string]$Source, [string]$Target, [string]$Executable, [int]$ProcessId,
  [string]$LogFile, [string]$LockDirectory, [string]$StatusFile,
  [string]$AttemptId, [string]$Version, [int]$RetrySeconds = 30,
  [int]$StartupSeconds = 45, [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Candidate = "$Target.update-new-$AttemptId"
$Backup = "$Target.update-backup-$AttemptId"
$CommitFile = "$StatusFile.commit"
$CancelFile = "$StatusFile.cancel"
$ReceiptFile = "$StatusFile.started"
$Lock = $null
$HadBackup = $false
$PlacedNew = $false
$Ready = $false
$NewProcess = $null
$Phase = 'preparing'
$UTF8 = New-Object Text.UTF8Encoding($false)

function Log([string]$Message) {
  [IO.File]::AppendAllText($LogFile, "$(Get-Date -Format o) [$AttemptId] $Message`r`n", $UTF8)
}
function Status([string]$State, [string]$Message = '') {
  $payload = @{ state=$State; phase=$Phase; message=$Message; attemptId=$AttemptId; version=$Version; target=$Target; executable=$Executable; backup=$Backup }
  [IO.File]::WriteAllText($StatusFile, ($payload | ConvertTo-Json -Compress), $UTF8)
  Log "$State/$Phase $Message"
}
function Remove-Directory([string]$Directory) {
  if ([IO.Directory]::Exists($Directory)) { [IO.Directory]::Delete($Directory, $true) }
}
function Move-Directory([string]$From, [string]$To) {
  $deadline = [DateTime]::UtcNow.AddSeconds($RetrySeconds)
  while ($true) {
    try { [IO.Directory]::Move($From, $To); return }
    catch {
      if ([DateTime]::UtcNow -ge $deadline) { throw }
      Start-Sleep -Milliseconds 400
    }
  }
}
function File-Hash([string]$File) {
  $stream = [IO.File]::OpenRead($File)
  $hash = [Security.Cryptography.SHA256]::Create()
  try { return [BitConverter]::ToString($hash.ComputeHash($stream)) }
  finally { $stream.Dispose(); $hash.Dispose() }
}
function Start-App([string]$File, [string]$Arguments = '') {
  # PowerShell's Start-Process resolves WorkingDirectory as a wildcard path.
  # ProcessStartInfo accepts Chinese, spaces and brackets literally.
  $info = New-Object Diagnostics.ProcessStartInfo
  $info.FileName = $File
  $info.WorkingDirectory = $Target
  $info.Arguments = $Arguments
  $info.UseShellExecute = $false
  return [Diagnostics.Process]::Start($info)
}
function Copy-Directory([string]$From, [string]$To) {
  if (([IO.File]::GetAttributes($From) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Update contains a directory link.' }
  [IO.Directory]::CreateDirectory($To) | Out-Null
  foreach ($file in [IO.Directory]::GetFiles($From)) {
    if (([IO.File]::GetAttributes($file) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Update contains a file link.' }
    $destination = [IO.Path]::Combine($To, [IO.Path]::GetFileName($file))
    [IO.File]::Copy($file, $destination, $false)
    if ((File-Hash $file) -ne (File-Hash $destination)) { throw "Copy verification failed: $destination" }
  }
  foreach ($directory in [IO.Directory]::GetDirectories($From)) {
    Copy-Directory $directory ([IO.Path]::Combine($To, [IO.Path]::GetFileName($directory)))
  }
}
try {
  # A kernel file lock is released even after a crash. A leftover file does not
  # permanently block updates, unlike the previous directory-as-lock scheme.
  $Lock = [IO.File]::Open("$LockDirectory.v2", 'OpenOrCreate', 'ReadWrite', 'None')
  Status 'preparing'
  if (![IO.Directory]::Exists($Target) -or ![IO.File]::Exists([IO.Path]::Combine($Source, $Executable))) { throw 'Update source or target is missing.' }
  Copy-Directory $Source $Candidate
  if ([IO.File]::Exists($CancelFile)) { throw 'Installation cancelled before exit.' }
  $Ready = $true
  Status 'ready'
  $deadline = [DateTime]::UtcNow.AddSeconds(30)
  while (![IO.File]::Exists($CommitFile)) {
    if ([IO.File]::Exists($CancelFile) -or [DateTime]::UtcNow -ge $deadline) { throw 'Application did not confirm installation; original files were kept.' }
    Start-Sleep -Milliseconds 100
  }
  $Phase = 'waiting-for-exit'
  Status 'installing'
  $old = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
  if ($old -and !$old.WaitForExit(180000)) { throw 'The old application did not exit.' }
  if ([IO.File]::Exists($CancelFile)) { throw 'Installation cancelled.' }
  $Phase = 'replacing'
  Status 'installing'
  # Directory.Move is an atomic same-volume rename. Move-Item can move part of
  # a directory before throwing when a child file is still locked.
  Move-Directory $Target $Backup
  $HadBackup = $true
  Move-Directory $Candidate $Target
  $PlacedNew = $true
  $Phase = 'starting'
  Status 'launching'
  $NewProcess = Start-App ([IO.Path]::Combine($Target, $Executable)) "--bilifetch-update=$AttemptId"
  $deadline = [DateTime]::UtcNow.AddSeconds($StartupSeconds)
  $confirmed = $false
  while ([DateTime]::UtcNow -lt $deadline) {
    if ([IO.File]::Exists($ReceiptFile)) {
      try {
        $receipt = [IO.File]::ReadAllText($ReceiptFile) | ConvertFrom-Json
        $confirmed = $receipt.attemptId -eq $AttemptId -and $receipt.version -eq $Version -and $receipt.executable -eq [IO.Path]::Combine($Target, $Executable)
      } catch { $confirmed = $false }
      if ($confirmed) { break }
    }
    if ($NewProcess.HasExited) { break }
    Start-Sleep -Milliseconds 150
  }
  if (!$confirmed) { throw 'The new application did not confirm its version and startup.' }
  $Phase = 'complete'
  Status 'installed'
  try { Remove-Directory $Backup } catch { Log "Installed; backup cleanup deferred: $($_.Exception.Message)" }
} catch {
  $failure = $_.Exception.Message
  Log "Failure: $($_ | Out-String)"
  if ($HadBackup) {
    try {
      if ($NewProcess -and !$NewProcess.HasExited) { $NewProcess.Kill(); $NewProcess.WaitForExit(10000) | Out-Null }
      if ($PlacedNew) { Move-Directory $Target $Candidate }
      Move-Directory $Backup $Target
      $HadBackup = $false
      $restart = [IO.Path]::Combine($Target, $Executable)
      # A renamed release may be rolling back to the old BiliFetch.exe entry.
      if (![IO.File]::Exists($restart)) { $restart = [IO.Path]::Combine($Target, 'BiliFetch.exe') }
      Start-App $restart | Out-Null
      $failure += ' Original version restored.'
    } catch {
      if ($HadBackup) { $failure += " Rollback requires recovery from ${Backup}: $($_.Exception.Message)" }
      else { $failure += " Original files restored, but restart failed: $($_.Exception.Message)" }
    }
  }
  Status 'failed' $failure
  if ($Ready -and !$Quiet -and [IO.File]::Exists($CommitFile)) {
    try {
      Add-Type -AssemblyName PresentationFramework
      [Windows.MessageBox]::Show("更新未完成。请查看安装日志；原文件或备份已保留。`n`n$failure`n`n日志：$LogFile", '记住你宇哥 · 更新失败') | Out-Null
    } catch { Log 'Unable to show installation failure dialog.' }
  }
} finally {
  if ($Lock) { $Lock.Dispose() }
  # Never delete the backup on failure. It may be the only recoverable copy.
  try { Remove-Directory $Candidate } catch { Log "Candidate cleanup deferred: $($_.Exception.Message)" }
  foreach ($file in @($CommitFile, $CancelFile, $ReceiptFile, $PSCommandPath)) {
    try { [IO.File]::Delete($file) } catch { }
  }
}
