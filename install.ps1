[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

# ============================================================
# VLESS Chrome Extension — установка одним скриптом
# Заменяет связку build-python + download-xray + install-python.
# Extension ID зафиксирован полем "key" в manifest.json, поэтому
# копировать его вручную и перезапускать браузер больше не нужно.
# ============================================================

$projectDir = $PSScriptRoot
$installDir = "$env:LOCALAPPDATA\VLESSChrome"
$srcDir     = "$projectDir\native-host-python"
$template   = "$projectDir\install\native-host-manifest.json"

# Логирование, поиск Python, загрузка Xray с гео-базами и регистрация в
# браузерах — общие с installer\install.ps1 (вариант с native_host.exe).
. "$projectDir\install\common.ps1"

function Exit-Installer($code) {
    if ($env:VLESSCHROME_NONINTERACTIVE -ne '1') { Read-Host "Нажмите Enter для выхода" }
    exit $code
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " VLESS Chrome Extension — установка" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# ─── [1/6] Python ────────────────────────────────────────────
# Resolve-PythonExe живёт в install\common.ps1: в PATH первым часто стоит
# заглушка из WindowsApps, открывающая Microsoft Store, поэтому настоящий
# интерпретатор ищется в том числе через реестр.
Write-Step "[1/6] Поиск Python..."

$pyExe = Resolve-PythonExe
if (-not $pyExe) {
    Write-Fail "Python не найден"
    Write-Host ""
    Write-Host "Установите Python 3.7+ с https://www.python.org/downloads/" -ForegroundColor Yellow
    Write-Host "При установке отметьте 'Add Python to PATH'." -ForegroundColor Yellow
    Write-Host "Либо, если есть winget:  winget install Python.Python.3.12" -ForegroundColor Gray
    Exit-Installer 1
}
Write-Ok "Python: $pyExe"

# ─── [2/6] Зависимости ───────────────────────────────────────
Write-Step "[2/6] Установка зависимостей..."
$reqFile = "$srcDir\requirements.txt"
if (Test-Path $reqFile) {
    try {
        # Оператор вызова сам корректно передаёт путь с пробелами —
        # обходной путь через cmd /c больше не нужен.
        & $pyExe -m pip install -q -r $reqFile | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Ok "psutil установлен" }
        else { Write-Warn "psutil не установлен — хост будет работать через taskkill" }
    } catch {
        Write-Warn "pip недоступен — хост будет работать через taskkill"
    }
} else {
    Write-Warn "requirements.txt не найден"
}

# ─── [3/6] Копирование файлов ────────────────────────────────
Write-Step "[3/6] Копирование в $installDir ..."

if (-not (Test-Path "$srcDir\native_host.py")) {
    Write-Fail "Не найден $srcDir\native_host.py — проект повреждён?"
    Exit-Installer 1
}
if (-not (Test-Path $installDir)) { New-Item -ItemType Directory -Path $installDir -Force | Out-Null }

foreach ($f in Get-ChildItem "$srcDir\*.py") {
    Copy-Item $f.FullName "$installDir\$($f.Name)" -Force
    Write-Ok $f.Name
}

# Обёртка с явным путём к интерпретатору — Chrome запускает хост без PATH-контекста.
# Путь всегда в кавычках: раньше ветка для пути с пробелом их не ставила (она
# писалась под 'py -3'), и при установке Python в C:\Program Files\... получался
# неработающий .bat. Теперь Resolve-PythonExe всегда возвращает полный путь.
$batPath = "$installDir\native-host.bat"
# VLESSCHROME_APP_DIR — каталог самого хоста. На Windows песочниц нет, но
# держим одинаково со всеми платформами: путь к данным задаётся явно, а не
# выводится из переменных окружения браузера.
$batContent = "@echo off`r`nset `"VLESSCHROME_APP_DIR=%~dp0`"`r`n`"$pyExe`" `"%~dp0native_host.py`""
Write-Utf8NoBom $batPath $batContent
Write-Ok "native-host.bat"

Write-Utf8NoBom "$installDir\project-path.txt" "$projectDir\"

# ─── [4/6] Xray и гео-базы ───────────────────────────────────
Write-Step "[4/6] Проверка Xray..."
$xrayTarget = "$installDir\xray.exe"
Install-XrayAndGeo -ProjectDir $projectDir -InstallDir $installDir

# ─── [5/6] Манифест native host ──────────────────────────────
Write-Step "[5/6] Регистрация Native Messaging Host..."

# Отличие от exe-варианта ровно одно: в "path" идёт native-host.bat.
$reg = Register-NativeHost -Template $template -InstallDir $installDir -HostPath $batPath
if (-not $reg) { Exit-Installer 1 }
$originChanged = $reg.OriginChanged

# ─── [6/6] Самопроверка ──────────────────────────────────────
Write-Step "[6/6] Проверка установки..."
foreach ($f in @("native_host.py", "parsers.py", "dpapi_store.py", "host_ping.py", "native-host.bat", "native-host-manifest.json")) {
    if (Test-Path "$installDir\$f") { Write-Ok $f } else { Write-Fail "$f отсутствует" }
}
if (Test-Path $xrayTarget) { Write-Ok "xray.exe" } else { Write-Fail "xray.exe отсутствует" }
foreach ($geo in $GeoFiles) {
    if (Test-Path "$installDir\$geo") {
        Write-Ok $geo
    } else {
        Write-Warn "$geo отсутствует — «российские сайты напрямую» работать не будет"
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
if ((Get-VlessErrors) -gt 0) {
    Write-Host " Установка завершена с ошибками: $(Get-VlessErrors)" -ForegroundColor Red
} else {
    Write-Host " Установка завершена успешно" -ForegroundColor Green
}
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "ОСТАЛОСЬ 2 ШАГА:" -ForegroundColor Yellow
Write-Host ""
Write-Host "  1. Откройте  chrome://extensions/  и включите «Режим разработчика»"
Write-Host "  2. «Загрузить распакованное расширение» → выберите папку:"
Write-Host "     $projectDir\extension" -ForegroundColor Cyan
Write-Host ""
if ($originChanged) {
    Write-Host "ВНИМАНИЕ: Extension ID изменился с прошлой установки." -ForegroundColor Yellow
    Write-Host "Полностью перезапустите браузер, иначе останется старая привязка." -ForegroundColor Yellow
    Write-Host ""
} else {
    Write-Host "Перезапускать браузер не нужно: ID расширения задан заранее." -ForegroundColor Gray
    Write-Host ""
}
Write-Host "Диагностика: check-installation.bat" -ForegroundColor Gray
Write-Host "Удаление:    install\uninstall.bat" -ForegroundColor Gray
Write-Host ""

Exit-Installer $(if ((Get-VlessErrors) -gt 0) { 1 } else { 0 })
