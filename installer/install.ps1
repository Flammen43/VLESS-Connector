[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

# ============================================================
# VLESS Chrome Extension — установка БЕЗ Python на машине пользователя.
#
# Альтернатива корневому install.bat: вместо python + native_host.py
# ставит native_host.exe, собранный заранее через installer\build.bat
# (PyInstaller --onedir). Тот же %LOCALAPPDATA%\VLESSChrome, тот же
# Extension ID из install\native-host-manifest.json — просто другой
# бинарник за манифестом. Второй раз регистрировать расширение в Chrome
# не нужно, если оно уже загружено.
#
# Ставит поверх текущей установки: если раньше стоял python-вариант,
# native_host.exe его заменит (тот же ключ реестра, тот же путь в
# манифесте). Откат — обычный install.bat из корня проекта.
#
# ВАЖНО (компромисс): собранный exe не подписан сертификатом.
# Антивирусы иногда ложно реагируют на неподписанные PyInstaller-сборки.
# Если после установки Chrome/антивирус блокирует native_host.exe —
# используйте python-вариант (install.bat в корне проекта).
# ============================================================

$installerDir = $PSScriptRoot
$projectDir   = Split-Path -Parent $installerDir
$installDir   = "$env:LOCALAPPDATA\VLESSChrome"
$distSrc      = "$installerDir\dist\native_host"
$template     = "$projectDir\install\native-host-manifest.json"

# Логирование, загрузка Xray с гео-базами и регистрация в браузерах — общие
# с корневым install.ps1 (Python-вариант). Отличие ровно одно: что попадает
# в "path" манифеста.
. "$projectDir\install\common.ps1"

function Exit-Installer($code) {
    if ($env:VLESSCHROME_NONINTERACTIVE -ne '1') { Read-Host "Нажмите Enter для выхода" }
    exit $code
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " VLESS Chrome — установка (без Python)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# ─── [1/5] Собранный exe ──────────────────────────────────────
Write-Step "[1/5] Проверка сборки..."

$exeSrc = "$distSrc\native_host.exe"
if (-not (Test-Path $exeSrc)) {
    Write-Fail "native_host.exe не найден: $exeSrc"
    Write-Host ""
    Write-Host "Сначала соберите его (нужен Python только на этом шаге):" -ForegroundColor Yellow
    Write-Host "  installer\build.bat" -ForegroundColor Cyan
    Exit-Installer 1
}
$exeSize = [math]::Round((Get-ChildItem $distSrc -Recurse | Measure-Object -Property Length -Sum).Sum / 1MB, 1)
Write-Ok "native_host.exe найден ($exeSize МБ)"

# ─── [2/5] Копирование ────────────────────────────────────────
Write-Step "[2/5] Копирование в $installDir ..."

if (-not (Test-Path $installDir)) { New-Item -ItemType Directory -Path $installDir -Force | Out-Null }

# Если раньше стоял python-вариант — его .bat/.py остаются на диске, но
# манифест на них больше не укажет. Не удаляем сами: вдруг понадобится
# откатиться, да и xray.exe/гео-базы/логи ниже общие для обеих сборок.
$exeTarget = "$installDir\native_host.exe"
try {
    if (Test-Path "$installDir\_internal") { Remove-Item "$installDir\_internal" -Recurse -Force }
    Copy-Item "$distSrc\_internal" "$installDir\_internal" -Recurse -Force
    Copy-Item $exeSrc $exeTarget -Force
    Write-Ok "native_host.exe + _internal\"
} catch {
    Write-Fail "Не удалось скопировать: $_"
    Write-Host "       Если сейчас есть активное VPN-подключение — отключите его и повторите." -ForegroundColor Gray
    Exit-Installer 1
}

Write-Utf8NoBom "$installDir\project-path.txt" "$projectDir\"

# ─── [3/5] Xray и гео-базы ─────────────────────────────────────
Write-Step "[3/5] Проверка Xray..."
$xrayTarget = "$installDir\xray.exe"
Install-XrayAndGeo -ProjectDir $projectDir -InstallDir $installDir

# ─── [4/5] Манифест native host ────────────────────────────────
Write-Step "[4/5] Регистрация Native Messaging Host..."

# Отличие от Python-варианта ровно одно: в "path" идёт native_host.exe.
$reg = Register-NativeHost -Template $template -InstallDir $installDir -HostPath $exeTarget
if (-not $reg) { Exit-Installer 1 }
$originChanged = $reg.OriginChanged

# ─── [5/5] Самопроверка: настоящий обмен по протоколу ─────────
Write-Step "[5/5] Проверка установленного хоста..."

foreach ($f in @("native_host.exe", "_internal", "native-host-manifest.json")) {
    if (Test-Path "$installDir\$f") { Write-Ok $f } else { Write-Fail "$f отсутствует" }
}
if (Test-Path $xrayTarget) { Write-Ok "xray.exe" } else { Write-Fail "xray.exe отсутствует" }
foreach ($geo in $GeoFiles) {
    if (Test-Path "$installDir\$geo") { Write-Ok $geo }
    else { Write-Warn "$geo отсутствует — «российские сайты напрямую» работать не будет" }
}

# Не просто «файл существует» — реально запускаем и говорим с ним по
# протоколу native messaging, как это делает Chrome.
$checkScript = @'
import json, struct, subprocess, sys, time
exe = sys.argv[1]
try:
    p = subprocess.Popen([exe], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, creationflags=subprocess.CREATE_NO_WINDOW)
except Exception as e:
    print("SPAWN_FAIL:" + str(e)); sys.exit(1)
time.sleep(0.3)
if p.poll() is not None:
    print("DEAD:" + p.stderr.read().decode("utf-8", "replace")[:300]); sys.exit(1)
body = json.dumps({"id": 1, "action": "status", "clientId": "install-check"}).encode()
p.stdin.write(struct.pack("=I", len(body)) + body); p.stdin.flush()
raw = p.stdout.read(4)
if len(raw) < 4:
    print("NO_RESPONSE"); sys.exit(1)
n = struct.unpack("=I", raw)[0]
resp = json.loads(p.stdout.read(n).decode("utf-8"))
p.stdin.close(); p.wait(timeout=5)
print("OK:" + json.dumps(resp))
'@
# Эта проверка необязательна (Python пользователю в принципе не нужен) —
# ничто внутри нижнего блока не должно ронять установку, которая к этому
# моменту уже реально завершена. PATH здесь часто даёт только App Execution
# Alias из WindowsApps: в неинтерактивном вызове (в т.ч. внутри Start-Job)
# он не пробрасывает аргументы во вложенный интерпретатор и вместо запуска
# скрипта зависает в интерактивном REPL — поэтому сначала ищем настоящий
# python.exe через реестр (см. installer\build.ps1) и оборачиваем весь блок
# в try/catch: что бы ни случилось на стороне Python, эта проверка может
# только промолчать, не более.
$pyCheckExe = Resolve-PythonExe

if ($pyCheckExe) {
    $checkFile = Join-Path $env:TEMP "vlesschrome_install_check.py"
    Write-Utf8NoBom $checkFile $checkScript

    $result = $null
    $checkRan = $false
    try {
        $job = Start-Job -ScriptBlock {
            param($exe, $file, $target)
            & $exe $file $target 2>&1 | Out-String
        } -ArgumentList $pyCheckExe, $checkFile, $exeTarget

        $checkRan = [bool](Wait-Job $job -Timeout 10)
        if ($checkRan) { $result = Receive-Job $job -ErrorAction SilentlyContinue }
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
    } catch {
        $checkRan = $false
    } finally {
        # -ErrorAction SilentlyContinue не спасает от ошибок биндинга параметров
        # (в этом окружении Remove-Item иногда бросает их даже на «путь не
        # существует») — а ошибка в finally минует внешний catch и роняет
        # установку целиком. Глушим explicitly, это только временный файл.
        try { Remove-Item $checkFile -Force -ErrorAction SilentlyContinue } catch {}
    }

    if ($result -match 'OK:') {
        Write-Ok "Протокол native messaging отвечает"
    } elseif (-not $checkRan) {
        Write-Warn "Проверка протокола пропущена (окружение PowerShell помешало её выполнить — на установку не влияет)"
    } else {
        Write-Fail "native_host.exe не отвечает по протоколу: $result"
        Write-Host "       Похоже на блокировку антивирусом — проверьте карантин." -ForegroundColor Gray
    }
} else {
    Write-Warn "Python не найден — пропускаю проверку протокола (это нормально, он тут не нужен)"
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
Write-Host "Если антивирус заблокирует native_host.exe — откатитесь на Python:" -ForegroundColor Gray
Write-Host "  install.bat (в корне проекта)" -ForegroundColor Gray
Write-Host ""
Write-Host "Диагностика: check-installation.bat (в корне проекта)" -ForegroundColor Gray
Write-Host "Удаление:    install\uninstall.bat (в корне проекта)" -ForegroundColor Gray
Write-Host ""

Exit-Installer $(if ((Get-VlessErrors) -gt 0) { 1 } else { 0 })
