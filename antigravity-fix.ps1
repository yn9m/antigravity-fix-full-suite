#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$AntigravityPath,
    [string]$AgyPath
)

function Find-ProxyTarget {
    param([string]$Kind, [string]$ExplicitPath)
    $executables = if ($Kind -eq 'ide') { @('Antigravity.exe', 'Antigravity IDE.exe') } else { @('agy.exe') }
    $candidates = @()
    if ($ExplicitPath) {
        $candidates = @($ExplicitPath)
    } elseif ($Kind -eq 'ide') {
        foreach ($root in @($env:LOCALAPPDATA, $env:ProgramFiles, [Environment]::GetEnvironmentVariable('ProgramFiles(x86)'))) {
            if (-not $root) { continue }
            if ($root -eq $env:LOCALAPPDATA) { $root = Join-Path $root 'Programs' }
            $candidates += Join-Path $root 'Antigravity'
            $candidates += Join-Path $root 'Antigravity IDE'
        }
    } else {
        $candidates += Join-Path $env:LOCALAPPDATA 'agy\bin'
        $candidates += Join-Path $env:LOCALAPPDATA 'agy'
        $command = Get-Command agy.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) { $candidates += Split-Path -Parent $command.Source }
    }
    foreach ($directory in ($candidates | Select-Object -Unique)) {
        foreach ($exe in $executables) {
            $path = Join-Path $directory $exe
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                [pscustomobject]@{
                    Kind = $Kind
                    Directory = (Resolve-Path -LiteralPath $directory).ProviderPath
                    Executable = (Resolve-Path -LiteralPath $path).ProviderPath
                }
                break
            }
        }
    }
    if ($ExplicitPath -and -not ($executables | Where-Object { Test-Path -LiteralPath (Join-Path $ExplicitPath $_) -PathType Leaf })) {
        throw "В папке '$ExplicitPath' не найден $($executables -join ' или ')."
    }
}

function Get-ExecutableArchitecture {
    param([string]$Path)
    $reader = [IO.BinaryReader]::new([IO.File]::OpenRead($Path))
    try {
        if ($reader.ReadUInt16() -ne 0x5A4D) { throw "Некорректный EXE: $Path" }
        $reader.BaseStream.Position = 0x3C
        $offset = $reader.ReadInt32()
        $reader.BaseStream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x4550) { throw "Некорректный PE-заголовок: $Path" }
        switch ($reader.ReadUInt16()) {
            0x8664 { return 'x64' }
            0x014C { return 'x86' }
            default { throw "Архитектура EXE не поддерживается релизами прокси: $Path" }
        }
    } finally { $reader.Dispose() }
}

function Get-ProxyAsset {
    param($Release, [string]$Kind, [string]$Architecture)
    $assets = @($Release.assets | Where-Object { $_.name -match "-$Kind-win-$Architecture\.zip$" })
    $legacy = $false
    if ($assets.Count -eq 0) {
        # Older releases used a single archive for both applications.
        $assets = @($Release.assets | Where-Object {
            $_.name -match "-win-$Architecture\.zip$" -and $_.name -notmatch '-(ide|cli)-win-'
        })
        $legacy = $true
    }
    if ($assets.Count -ne 1) {
        throw "В релизе $($Release.tag_name) ожидался один архив для $Kind/$Architecture, найдено: $($assets.Count)."
    }
    [pscustomobject]@{ Asset = $assets[0]; Legacy = $legacy }
}

function Merge-ProxyConfig {
    param($Defaults, $Existing)
    foreach ($property in $Existing.PSObject.Properties) {
        if ($property.Name -in @('_build', '_version', '_comment')) { continue }
        $defaultProperty = $Defaults.PSObject.Properties[$property.Name]
        if ($defaultProperty -and $defaultProperty.Value -is [pscustomobject] -and $property.Value -is [pscustomobject]) {
            Merge-ProxyConfig $defaultProperty.Value $property.Value
        } else {
            $Defaults | Add-Member -MemberType NoteProperty -Name $property.Name -Value $property.Value -Force
        }
    }
}

function Install-AntigravityProxy {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$AntigravityPath, [string]$AgyPath)
    $ErrorActionPreference = 'Stop'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Write-Host '=== Установка прокси для Antigravity и CLI ===' -ForegroundColor Cyan
    $targets = @()
    foreach ($kind in 'ide', 'cli') {
        $explicit = if ($kind -eq 'ide') { $AntigravityPath } else { $AgyPath }
        $found = @(Find-ProxyTarget $kind $explicit)
        if ($found.Count -eq 0) { Write-Host "$kind не установлен — пропускаем." }
        $targets += $found
    }
    if ($targets.Count -eq 0) {
        Write-Host 'Antigravity и CLI не найдены. При нестандартной установке укажите -AntigravityPath и/или -AgyPath.'
        return
    }
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/yuaotian/antigravity-proxy/releases/latest'
    Write-Host "Последний релиз: $($release.tag_name)"
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('antigravity-proxy-' + [guid]::NewGuid().ToString('N'))
    # WhatIf validates downloaded packages without changing installed applications.
    $null = New-Item -ItemType Directory -Path $tempRoot -WhatIf:$false
    try {
        $plans = @()
        $packages = @{}
        foreach ($target in $targets) {
            $arch = Get-ExecutableArchitecture $target.Executable
            $package = Get-ProxyAsset $release $target.Kind $arch
            $asset = $package.Asset
            Write-Host "$($target.Kind): $($target.Directory) ($arch), архив $($asset.name)"
            if (-not $packages.ContainsKey($asset.name)) {
                $extract = Join-Path $tempRoot ([guid]::NewGuid().ToString('N'))
                $zip = "$extract.zip"
                Invoke-WebRequest -UseBasicParsing -Uri $asset.browser_download_url -OutFile $zip
                Expand-Archive -LiteralPath $zip -DestinationPath $extract -WhatIf:$false
                $packages[$asset.name] = $extract
            }
            $required = @('version.dll', 'config.json')
            $obsolete = @()
            if ($target.Kind -eq 'cli') {
                if ($package.Legacy) {
                    $required = @('dbghelp.dll', 'version.dll', 'config.json')
                } else {
                    $required = @('dbghelp.dll', 'antigravity_proxy.dll', 'config.json')
                    $obsolete = @('version.dll')
                }
            }
            $files = @{}
            foreach ($name in $required) {
                $matches = @(Get-ChildItem -LiteralPath $packages[$asset.name] -Filter $name -File -Recurse)
                if ($matches.Count -ne 1) { throw "Архив $($asset.name): ожидался один $name, найдено $($matches.Count)." }
                $files[$name] = $matches[0].FullName
            }
            $config = Get-Content -LiteralPath $files['config.json'] -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($config -isnot [pscustomobject] -or $config.proxy -isnot [pscustomobject]) {
                throw "Некорректный config.json в $($asset.name)."
            }
            $config.proxy.host = '127.0.0.1'
            $config.proxy.port = 10808
            $config.proxy.type = 'socks5'
            $existingConfig = Join-Path $target.Directory 'config.json'
            if (Test-Path -LiteralPath $existingConfig -PathType Leaf) {
                $existing = Get-Content -LiteralPath $existingConfig -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($existing -isnot [pscustomobject]) { throw "Некорректный config.json: $existingConfig" }
                Merge-ProxyConfig $config $existing
            }
            $plans += [pscustomobject]@{
                Target = $target; Files = $files; Obsolete = $obsolete
                Config = ($config | ConvertTo-Json -Depth 100)
            }
        }
        # Validate all packages and configs before stopping processes or replacing files.
        foreach ($plan in $plans) {
            $target = $plan.Target
            if (-not $PSCmdlet.ShouldProcess($target.Directory, "Установить прокси $($release.tag_name), сохранить резервную копию и закрыть процессы этой установки")) { continue }
            $prefix = $target.Directory.TrimEnd('\') + '\'
            Get-Process | Where-Object {
                $processPath = $_.Path
                $processPath -and $processPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
            } | ForEach-Object {
                Stop-Process -Id $_.Id -Force -ErrorAction Stop
                Wait-Process -Id $_.Id -Timeout 10 -ErrorAction SilentlyContinue
            }
            $backup = Join-Path $target.Directory ('proxy-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            $null = New-Item -ItemType Directory -Path $backup
            $changedNames = @($plan.Files.Keys) + @($plan.Obsolete)
            $savedNames = @()
            foreach ($name in $changedNames) {
                $destination = Join-Path $target.Directory $name
                if (Test-Path -LiteralPath $destination -PathType Leaf) {
                    Copy-Item -LiteralPath $destination -Destination (Join-Path $backup $name)
                    $savedNames += $name
                }
            }
            try {
                foreach ($name in $plan.Files.Keys) {
                    if ($name -eq 'config.json') { continue }
                    Copy-Item -LiteralPath $plan.Files[$name] -Destination (Join-Path $target.Directory $name) -Force
                }
                # Set-Content UTF8 in Windows PowerShell 5.1 emits a BOM.
                [IO.File]::WriteAllText((Join-Path $target.Directory 'config.json'), $plan.Config, [Text.UTF8Encoding]::new($false))
                foreach ($name in $plan.Obsolete) {
                    $path = Join-Path $target.Directory $name
                    if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
                }
            } catch {
                foreach ($name in $changedNames) {
                    $destination = Join-Path $target.Directory $name
                    if ($name -in $savedNames) {
                        Copy-Item -LiteralPath (Join-Path $backup $name) -Destination $destination -Force
                    } elseif (Test-Path -LiteralPath $destination -PathType Leaf) {
                        Remove-Item -LiteralPath $destination -Force
                    }
                }
                throw
            }
            Write-Host "Готово: $($target.Directory). Резервная копия: $backup" -ForegroundColor Green
        }
    } finally {
        # Remove only this run's unique temporary directory after checking its absolute path.
        $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
        if ($resolvedTemp.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolvedTemp) -match '^antigravity-proxy-[a-f0-9]{32}$') {
            Remove-Item -LiteralPath $resolvedTemp -Recurse -Force -WhatIf:$false
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try { Install-AntigravityProxy @PSBoundParameters }
    catch { Write-Error "Не удалось установить прокси: $_" -ErrorAction Continue; exit 1 }
}
