#requires -Version 5.1
# Offline integration tests. No installed application or process is modified.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\antigravity-fix.ps1')

function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
}
function New-TestExe([string]$Path, [uint16]$Machine = 0x8664) {
    $null = New-Item -ItemType Directory -Path (Split-Path $Path) -Force
    $bytes = New-Object byte[] 128
    $bytes[0] = 0x4D; $bytes[1] = 0x5A; $bytes[0x3C] = 0x40
    $bytes[0x40] = 0x50; $bytes[0x41] = 0x45
    [BitConverter]::GetBytes($Machine).CopyTo($bytes, 0x44)
    [IO.File]::WriteAllBytes($Path, $bytes)
}
function New-TestPackage([string]$Name, [string[]]$Files) {
    $folder = Join-Path $testRoot ([guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path (Join-Path $folder 'nested')
    foreach ($file in $Files) {
        $value = if ($file -eq 'config.json') {
            '{"proxy":{"host":"127.0.0.1","port":7890,"type":"socks5"},"child_injection":true,"target_processes":["agy.exe","node.exe"],"_version":"test"}'
        } else { "new-$Name-$file" }
        [IO.File]::WriteAllText((Join-Path $folder "nested\$file"), $value)
    }
    $archive = Join-Path $testRoot $Name
    Compress-Archive -Path (Join-Path $folder '*') -DestinationPath $archive
    [pscustomobject]@{ name = $Name; browser_download_url = $archive }
}
function Invoke-RestMethod { param($Uri) $script:requests++; return $script:release }
function Invoke-WebRequest { param($Uri, $OutFile, [switch]$UseBasicParsing) Microsoft.PowerShell.Management\Copy-Item -LiteralPath $Uri -Destination $OutFile -WhatIf:$false }
function Get-Command { param($Name, $CommandType, $ErrorAction) return $null }
function Get-Process { $script:processQueries++; return @() }
function Copy-Item {
    param($LiteralPath, $Destination, [switch]$Force)
    if ($script:failCopy -and $Destination -eq $script:failCopy) {
        $script:failCopy = $null
        throw 'Simulated locked DLL'
    }
    Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('agy-proxy-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
$savedLocal = $env:LOCALAPPDATA
$savedPrograms = $env:ProgramFiles
$savedProgramsX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
try {
    $env:LOCALAPPDATA = Join-Path $testRoot 'local'
    $env:ProgramFiles = Join-Path $testRoot 'programs'
    [Environment]::SetEnvironmentVariable('ProgramFiles(x86)', (Join-Path $testRoot 'programs-x86'))
    $script:requests = 0; $script:processQueries = 0; $script:failCopy = $null
    Install-AntigravityProxy
    Assert ($script:requests -eq 0) 'No installed apps must skip network access'

    $desktop = Join-Path $env:LOCALAPPDATA 'Programs\Antigravity'
    $cli = Join-Path $env:LOCALAPPDATA 'agy\bin'
    $null = New-Item -ItemType Directory -Path $desktop -Force
    Assert (@(Find-ProxyTarget ide).Count -eq 0) 'An empty folder is not an installation'
    New-TestExe (Join-Path $desktop 'Antigravity.exe')
    Assert (@(Find-ProxyTarget ide).Count -eq 1) 'Desktop detected'
    Assert (@(Find-ProxyTarget cli).Count -eq 0) 'Missing CLI skipped'
    New-TestExe (Join-Path $cli 'agy.exe') 0x014C
    Assert ((Get-ExecutableArchitecture (Join-Path $desktop 'Antigravity.exe')) -eq 'x64') 'Desktop PE architecture'
    Assert ((Get-ExecutableArchitecture (Join-Path $cli 'agy.exe')) -eq 'x86') 'CLI PE architecture'
    Assert ((Find-ProxyTarget cli).Directory -eq $cli) 'CLI detected next to agy.exe'
    $failed = $false
    try { Find-ProxyTarget ide (Join-Path $testRoot 'missing') } catch { $failed = $true }
    Assert $failed 'Explicit missing path fails'

    $ideAsset = New-TestPackage 'antigravity-proxy-test-ide-win-x64.zip' @('version.dll','config.json')
    $cliAsset = New-TestPackage 'antigravity-proxy-test-cli-win-x86.zip' @('dbghelp.dll','antigravity_proxy.dll','config.json')
    $script:release = [pscustomobject]@{ tag_name = 'test'; assets = @($cliAsset, $ideAsset) }
    Assert ((Get-ProxyAsset $release ide x64).Asset.name -eq $ideAsset.name) 'Split IDE asset selected'
    $failed = $false
    try { Get-ProxyAsset $release cli x64 } catch { $failed = $true }
    Assert $failed 'Missing architecture fails'

    $oldConfig = '{"proxy":{"host":"localhost","port":12345,"type":"http","username":"test"},"proxy_rules":{"custom":true}}'
    [IO.File]::WriteAllText((Join-Path $cli 'config.json'), $oldConfig)
    [IO.File]::WriteAllText((Join-Path $cli 'version.dll'), 'old-version')
    [IO.File]::WriteAllText((Join-Path $cli 'dbghelp.dll'), 'old-shim')
    Install-AntigravityProxy -WhatIf
    Assert ($script:processQueries -eq 0) 'WhatIf does not touch processes'
    Assert (-not (Test-Path (Join-Path $desktop 'version.dll'))) 'WhatIf does not install DLLs'
    Assert ((Get-Content (Join-Path $cli 'config.json') -Raw) -eq $oldConfig) 'WhatIf preserves config'

    Install-AntigravityProxy
    Assert (Test-Path (Join-Path $desktop 'version.dll')) 'Desktop installed'
    Assert (Test-Path (Join-Path $cli 'antigravity_proxy.dll')) 'CLI new DLL installed'
    Assert (-not (Test-Path (Join-Path $cli 'version.dll'))) 'CLI obsolete DLL removed'
    Assert (-not (Test-Path (Join-Path $desktop 'dbghelp.dll'))) 'No CLI DLL in desktop'
    $config = Get-Content (Join-Path $cli 'config.json') -Raw | ConvertFrom-Json
    Assert ($config.proxy.port -eq 12345 -and $config.proxy.username -eq 'test') 'Existing proxy preserved'
    Assert ($config.child_injection -and $config.target_processes -contains 'agy.exe') 'New config defaults included'
    Assert $config.proxy_rules.custom 'Custom config preserved'
    $desktopConfig = Get-Content (Join-Path $desktop 'config.json') -Raw | ConvertFrom-Json
    Assert ($desktopConfig.proxy.port -eq 10808) 'Fresh install keeps default port'
    $bytes = [IO.File]::ReadAllBytes((Join-Path $cli 'config.json'))
    Assert ($bytes[0] -eq 123) 'JSON has no UTF8 BOM'
    $backup = Get-ChildItem -LiteralPath $cli -Directory -Filter 'proxy-backup-*' | Select-Object -First 1
    Assert ((Get-Content (Join-Path $backup.FullName 'version.dll') -Raw) -eq 'old-version') 'Old DLL backed up'
    Assert ((Get-Content (Join-Path $backup.FullName 'config.json') -Raw) -eq $oldConfig) 'Config backed up'

    $beforeProcesses = $script:processQueries
    $script:release.assets = @($ideAsset, (New-TestPackage 'broken-cli-win-x86.zip' @('dbghelp.dll','config.json')))
    $failed = $false
    try { Install-AntigravityProxy } catch { $failed = $true }
    Assert $failed 'Missing CLI DLL is a hard failure'
    Assert ($script:processQueries -eq $beforeProcesses) 'All archives validated before any app changes'

    $script:release.assets = @($ideAsset, $cliAsset)
    [IO.File]::WriteAllText((Join-Path $cli 'dbghelp.dll'), 'rollback-shim')
    $script:failCopy = Join-Path $cli 'antigravity_proxy.dll'
    $failed = $false
    try { Install-AntigravityProxy } catch { $failed = $true }
    Assert $failed 'Copy error surfaced'
    Assert ((Get-Content (Join-Path $cli 'dbghelp.dll') -Raw) -eq 'rollback-shim') 'Original DLL restored after failed update'

    $legacy = New-TestPackage 'antigravity-proxy-old-win-x86.zip' @('version.dll','dbghelp.dll','config.json')
    $script:release.assets = @($ideAsset, $legacy)
    Assert (Get-ProxyAsset $release cli x86).Legacy 'Legacy archive selected'
    Install-AntigravityProxy
    Assert (Test-Path (Join-Path $cli 'version.dll')) 'Legacy CLI installs version.dll'

    Write-Host 'PASS: discovery, architectures, split/legacy releases, dry run, installation, config, backup, preflight and rollback.' -ForegroundColor Green
} finally {
    $env:LOCALAPPDATA = $savedLocal
    $env:ProgramFiles = $savedPrograms
    [Environment]::SetEnvironmentVariable('ProgramFiles(x86)', $savedProgramsX86)
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $base = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($base, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -match '^agy-proxy-tests-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
