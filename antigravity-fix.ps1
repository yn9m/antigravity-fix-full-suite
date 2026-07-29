# Принудительно используем TLS 1.2 для работы с API GitHub (нужно для старых версий Windows)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Host "=== Установка Antigravity Proxy (Авто-версия) ===" -ForegroundColor Cyan

# --- Определение архитектуры ---
$is64Bit = ($env:PROCESSOR_ARCHITECTURE -eq 'AMD64') -or ($env:PROCESSOR_ARCHITEW6432 -eq 'AMD64')
$arch = if ($is64Bit) { "x64" } else { "x86" }
Write-Host "Определена архитектура системы: $arch" -ForegroundColor Yellow

# --- Поиск последнего релиза на GitHub ---
Write-Host "Поиск последней версии на GitHub..."
$apiUrl = "https://api.github.com/repos/yuaotian/antigravity-proxy/releases/latest"

try {
    $release = Invoke-RestMethod -Uri $apiUrl
    $version = $release.tag_name
    Write-Host "Найдена последняя версия: $version" -ForegroundColor Green
} catch {
    Write-Host "Ошибка при получении данных с GitHub API. Проверьте интернет или VPN." -ForegroundColor Red
    exit
}

# Ищем ссылку на архив, в названии которого есть наша архитектура (win-x64.zip или win-x86.zip)
$asset = $release.assets | Where-Object { $_.name -match "win-$arch\.zip$" }
if (-not $asset) {
    Write-Host "Ошибка: Архив для архитектуры $arch не найден в релизе $version!" -ForegroundColor Red
    exit
}

$downloadUrl = $asset.browser_download_url
Write-Host "Ссылка для скачивания: $downloadUrl" -ForegroundColor DarkGray

# --- Настройки путей ---
$installFolderAntigravity = "$env:LOCALAPPDATA\Programs\Antigravity"
$installFolderAgy = "$env:LOCALAPPDATA\agy"
$tempZip = "$env:TEMP\antigravity-proxy.zip"
$tempExtract = "$env:TEMP\antigravity-proxy-extracted"

# 1. Закрытие Antigravity и agy
Write-Host "[1/6] Закрытие процессов Antigravity и agy (если запущены)..."
Get-Process -Name "Antigravity" -ErrorAction SilentlyContinue | Stop-Process -Force
Get-Process -Name "agy" -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

if (-Not (Test-Path $installFolderAntigravity)) {
    Write-Host "Папка установки $installFolderAntigravity не найдена! Создаем ее..." -ForegroundColor Yellow
    New-Item -ItemType Directory -Path $installFolderAntigravity | Out-Null
}

if (-Not (Test-Path $installFolderAgy)) {
    Write-Host "Папка установки $installFolderAgy не найдена! Создаем ее..." -ForegroundColor Yellow
    New-Item -ItemType Directory -Path $installFolderAgy | Out-Null
}

# 2. Скачивание архива
Write-Host "[2/6] Скачивание архива..."
Invoke-WebRequest -Uri $downloadUrl -OutFile $tempZip

# 3. Распаковка
Write-Host "[3/6] Распаковка архива..."
if (Test-Path $tempExtract) { Remove-Item -Path $tempExtract -Recurse -Force }
Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force

# 4. Поиск и копирование файлов version.dll и dbghelp.dll
Write-Host "[4/6] Установка DLL файлов..."
$versionDll = Get-ChildItem -Path $tempExtract -Filter "version.dll" -Recurse | Select-Object -First 1
$dbghelpDll = Get-ChildItem -Path $tempExtract -Filter "dbghelp.dll" -Recurse | Select-Object -First 1

if ($versionDll) {
    Copy-Item -Path $versionDll.FullName -Destination "$installFolderAntigravity\version.dll" -Force
    Copy-Item -Path $versionDll.FullName -Destination "$installFolderAgy\version.dll" -Force
} else {
    Write-Host "Ошибка: Файл version.dll не найден в скачанном архиве!" -ForegroundColor Red
    exit
}

if ($dbghelpDll) {
    Copy-Item -Path $dbghelpDll.FullName -Destination "$installFolderAgy\dbghelp.dll" -Force
} else {
    Write-Host "Ошибка: Файл dbghelp.dll не найден в скачанном архиве!" -ForegroundColor Red
    exit
}

# 5. Создание правильного config.json
Write-Host "[5/6] Создание config.json (SOCKS5 127.0.0.1:10808)..."
$configData = @"
{
  "proxy": {
    "host": "127.0.0.1",
    "port": 10808,
    "type": "socks5"
  }
}
"@
Set-Content -Path "$installFolderAntigravity\config.json" -Value $configData -Encoding UTF8
Set-Content -Path "$installFolderAgy\config.json" -Value $configData -Encoding UTF8

# 6. Очистка мусора
Write-Host "[6/6] Очистка временных файлов..."
Remove-Item -Path $tempZip -Force -ErrorAction SilentlyContinue
Remove-Item -Path $tempExtract -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "Установка успешно завершена (Установлена $version для $arch)!" -ForegroundColor Green
Write-Host "Прокси успешно установлены для Antigravity и AGY CLI." -ForegroundColor Green