$ErrorActionPreference = 'Stop'
$source = Get-Content (Join-Path $PSScriptRoot '../../agent/agent.ps1') -Raw
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$null, [ref]$parseErrors) | Out-Null
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
$handler = 'function Invoke-PowerReply' + ($source.Split(@('function Invoke-PowerReply'), [StringSplitOptions]::None)[1].Split(@('$Hub = $Hub.TrimEnd'), [StringSplitOptions]::None)[0])
$realCommand = '& "$env:SystemRoot\System32\shutdown.exe" /s /t 0'
if (-not $handler.Contains($realCommand)) { throw 'Cannot safely replace OS command in test' }
$handler = $handler.Replace($realCommand, 'Invoke-TestShutdown')
Invoke-Expression $handler
$script:calls = 0
function Invoke-TestShutdown { $script:calls++; $global:LASTEXITCODE = 0 }
$previousLocal = $env:LOCALAPPDATA
$testDir = Join-Path ([IO.Path]::GetTempPath()) ('dm-agent-test-' + [guid]::NewGuid())
$env:LOCALAPPDATA = $testDir
try {
  $Token = 'secret'; $allowShutdown = $true
  $expires = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + 55000
  $h = New-Object Security.Cryptography.HMACSHA256
  $h.Key = [Text.Encoding]::UTF8.GetBytes($Token)
  $sig = -join ($h.ComputeHash([Text.Encoding]::UTF8.GetBytes("device-monitor-cmd-v2:pc:aabbccddeeff:shutdown:${expires}")) | ForEach-Object { $_.ToString('x2') })
  $h.Dispose()
  $c = @{ id='aabbccddeeff'; action='shutdown'; expires=$expires; sig=$sig }
  $reply = @{ commands=@($c) }
  $allowShutdown = $false
  if ($null -ne (Invoke-PowerReply $reply 'pc')) { throw 'Opt in bypassed' }
  $allowShutdown = $true
  if ($null -ne (Invoke-PowerReply $reply 'other')) { throw 'Target binding bypassed' }
  $c.sig = 'bad'
  if ($null -ne (Invoke-PowerReply $reply 'pc')) { throw 'Signature bypassed' }
  if ($script:calls) { throw 'Invalid command executed' }
  $c.sig = $sig
  $result = Invoke-PowerReply $reply 'pc'
  if (-not $result.ok -or $script:calls -ne 1) { throw 'Valid command rejected' }
  if ($null -ne (Invoke-PowerReply $reply 'pc') -or $script:calls -ne 1) { throw 'Replay executed' }
  Write-Output 'Windows agent: opt-in, target binding, signature and replay checks passed (OS command mocked).'
} finally {
  $env:LOCALAPPDATA = $previousLocal
  # The exact temporary directory above is owned by this test.
  if (Test-Path -LiteralPath $testDir) { Remove-Item -LiteralPath $testDir -Recurse -Force }
}
