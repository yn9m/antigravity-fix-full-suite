# Antigravity Fix Full Suite

Автоматический скрипт установки прокси для **Antigravity 2.0** и **Antigravity CLI (`agy`)**.

## Описание

Скрипт автоматически скачивает последний релиз `antigravity-proxy` с GitHub, определяет архитектуру системы (x64/x86) и устанавливает необходимые DLL-библиотеки и файлы конфигурации:

- **Antigravity 2.0** (`%LOCALAPPDATA%\Programs\Antigravity`):
  - `version.dll`
  - `config.json`
- **Antigravity CLI (`agy`)** (`%LOCALAPPDATA%\agy`):
  - `version.dll`
  - `dbghelp.dll`
  - `config.json`

## Использование

Запустите скрипт в PowerShell:

```powershell
.\antigravity-fix.ps1
```

## Конфигурация по умолчанию

По умолчанию скрипт настраивает SOCKS5 прокси на `127.0.0.1:10808`.
