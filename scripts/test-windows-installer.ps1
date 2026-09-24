param([string]$Helper, [string]$Probe)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$Helper = (Resolve-Path -LiteralPath $Helper).ProviderPath
$Probe = (Resolve-Path -LiteralPath $Probe).ProviderPath
$root = Join-Path $env:TEMP ('BiliFetch-install-tests-' + [Guid]::NewGuid())
$utf8 = New-Object Text.UTF8Encoding($false)
function Assert($Condition, [string]$Message) { if (!$Condition) { throw $Message } }
function Read-Status([string]$File) {
  try { return ([IO.File]::ReadAllText($File) | ConvertFrom-Json) } catch { return $null }
}
function Wait-State([string]$File, [string[]]$States) {
  $deadline = [DateTime]::UtcNow.AddSeconds(60)
  do {
    $status = Read-Status $File
    if ($status -and $States -contains $status.state) { return $status }
    Start-Sleep -Milliseconds 100
  } while ([DateTime]::UtcNow -lt $deadline)
  throw "Timed out: $File; $($status | ConvertTo-Json -Compress)"
}
foreach ($scenario in @('normal', 'unicode-brackets', 'temporary-lock', 'permanent-lock', 'bad-startup', 'stale-lock', 'missing-source', 'active-lock')) {
  $base = Join-Path $root $scenario
  $source = Join-Path $base 'source'
  $target = Join-Path $base 'installed'
  if ($scenario -eq 'unicode-brackets') {
    $source = Join-Path $base '下载 [新版]'
    $target = Join-Path $base '宇哥 软件 [1]'
  }
  $updates = Join-Path $base 'Updates'
  foreach ($dir in @($source, $target, $updates)) { [IO.Directory]::CreateDirectory($dir) | Out-Null }
  foreach ($dir in @($source, $target)) { [IO.File]::Copy($Probe, (Join-Path $dir 'app.exe')) }
  [IO.File]::WriteAllText((Join-Path $source 'version.txt'), '1.1.12')
  [IO.File]::WriteAllText((Join-Path $target 'version.txt'), '1.1.10')
  [IO.File]::WriteAllText((Join-Path $target 'old-only.txt'), 'rollback sentinel')
  [IO.File]::WriteAllText((Join-Path $source '[extra].txt'), 'new payload')
  if ($scenario -eq 'bad-startup') { [IO.File]::WriteAllText((Join-Path $source 'version.txt'), 'no-startup') }
  if ($scenario -eq 'missing-source') { [IO.File]::Delete((Join-Path $source 'app.exe')) }
  $attempt = [Guid]::NewGuid().ToString()
  $statusFile = Join-Path $updates "install-$attempt.json"
  $script = Join-Path $updates 'helper.ps1'
  # Windows PowerShell 5.1 needs a BOM for non-ASCII literal UI strings.
  [IO.File]::WriteAllText($script, [IO.File]::ReadAllText($Helper), (New-Object Text.UTF8Encoding($true)))
  $lockFile = Join-Path $updates 'install-update.lock'
  if ($scenario -eq 'stale-lock') {
    [IO.Directory]::CreateDirectory($lockFile) | Out-Null
    [IO.File]::WriteAllText("$lockFile.v2", '')
  }
  $env:BILIFETCH_INSTALL_TEST_UPDATES = $updates
  $old = Start-Process -FilePath (Join-Path $target 'app.exe') -ArgumentList '--wait-for-exit' -PassThru
  $hold = $null
  $retrySeconds = 8
  if ($scenario -eq 'permanent-lock') { $retrySeconds = 1 }
  if ($scenario -eq 'temporary-lock' -or $scenario -eq 'permanent-lock') { $hold = [IO.File]::Open((Join-Path $target 'version.txt'), 'Open', 'Read', 'None') }
  if ($scenario -eq 'active-lock') { $hold = [IO.File]::Open("$lockFile.v2", 'OpenOrCreate', 'ReadWrite', 'None') }
  $args = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script`" -Source `"$source`" -Target `"$target`" -Executable app.exe -ProcessId $($old.Id) -Version 1.1.12 -AttemptId $attempt -StatusFile `"$statusFile`" -LogFile `"$updates\update-install.log`" -LockDirectory `"$lockFile`" -RetrySeconds $retrySeconds -StartupSeconds 5 -Quiet"
  $installer = Start-Process powershell.exe -ArgumentList $args -PassThru -WindowStyle Hidden -RedirectStandardError (Join-Path $updates 'stderr.log')
  try {
    $state = Wait-State $statusFile @('ready', 'failed')
    if ($scenario -eq 'missing-source' -or $scenario -eq 'active-lock') {
      Assert ($state.state -eq 'failed') "$scenario unexpectedly ready"
      Assert (!$old.HasExited) 'Old process exited before installation was ready'
      [IO.File]::WriteAllText((Join-Path $target 'exit.txt'), 'exit')
    } else {
      Assert ($state.state -eq 'ready') "$scenario not ready: $($state.message)"
      if (!$hold) { Assert ([IO.File]::ReadAllText((Join-Path $target 'version.txt')) -eq '1.1.10') 'Changed target before exit' }
      [IO.File]::WriteAllText("$statusFile.commit", 'install')
      [IO.File]::WriteAllText((Join-Path $target 'exit.txt'), 'exit')
      if ($scenario -eq 'temporary-lock') { Start-Sleep -Seconds 3; $hold.Dispose(); $hold = $null }
      $state = Wait-State $statusFile @('installed', 'failed')
    }
    if ($hold) { $hold.Dispose(); $hold = $null }
    Assert ($installer.WaitForExit(15000)) 'Helper did not exit'
    $expectFailure = @('permanent-lock', 'bad-startup', 'missing-source', 'active-lock') -contains $scenario
    if ($expectFailure) {
      Assert ($state.state -eq 'failed') "$scenario did not fail"
      Assert ([IO.File]::ReadAllText((Join-Path $target 'version.txt')) -eq '1.1.10') 'Old version not preserved'
      Assert ([IO.File]::ReadAllText((Join-Path $target 'old-only.txt')) -eq 'rollback sentinel') 'Original directory partially moved/lost'
      Assert ([IO.File]::Exists((Join-Path $target 'app.exe'))) 'Old executable lost'
    } else {
      Assert ($state.state -eq 'installed') "$scenario failed: $($state.message)"
      Assert ([IO.File]::ReadAllText((Join-Path $target 'version.txt')) -eq '1.1.12') 'New version not installed'
      Assert ([IO.File]::ReadAllText((Join-Path $target '[extra].txt')) -eq 'new payload') 'Wildcard filename lost'
      Assert ([IO.File]::ReadAllText((Join-Path $target 'restarted.txt')).StartsWith('1.1.12')) 'New version did not restart'
      Assert (![IO.File]::Exists((Join-Path $target 'old-only.txt'))) 'Old payload survived replacement'
    }
    Write-Output "PASS $scenario : $($state.state)"
  } finally {
    if ($hold) { $hold.Dispose() }
    if (!$old.HasExited) { $old.Kill() }
    if (!$installer.HasExited) { $installer.Kill() }
  }
}
Write-Output "Native Windows installer: 8 scenarios passed. Evidence: $root"
