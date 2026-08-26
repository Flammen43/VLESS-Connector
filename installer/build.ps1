[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

# ============================================================
# Сборка native_host.exe — для РАЗРАБОТЧИКА, не для конечного пользователя.
#
# Заворачивает native-host-python\ через PyInstaller в один каталог
# (--onedir), чтобы install.ps1 в этой же папке мог поставить хост без
# Python на машине пользователя. Результат: installer\dist\native_host\.
#
# --onedir, а не --onefile: --onefile распаковывает себя во временную
# папку заново при КАЖДОМ запуске (~340мс на вызов и ~2с на первый запуск
# после сборки) — а ping/stop дёргают новый процесс native host на каждое
# действие в popup. --onedir стартует за ~110мс, ощутимо быстрее даже
# обычного `python native_host.py` на этой машине (~215мс).
# ============================================================

$installerDir = $PSScriptRoot
$projectDir   = Split-Path -Parent $installerDir
$srcDir       = "$projectDir\native-host-python"
$distDir      = "$installerDir\dist"
$buildDir     = "$installerDir\build"

function Write-Ok($m)   { Write-Host "  [OK] $m"   -ForegroundColor Green }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red }

function Exit-Build($code) {
    if ($env:VLESSCHROME_NONINTERACTIVE -ne '1') { Read-Host "Нажмите Enter для выхода" }
    exit $code
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Сборка native_host.exe" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# ─── Python + PyInstaller (нужны только здесь, у пользователя — нет) ──
Write-Host ""
Write-Host "[1/3] Поиск Python и PyInstaller..." -ForegroundColor White

function Resolve-PythonExe {
    # Get-Command часто находит только App Execution Alias из WindowsApps
    # (заглушка, которую сама Windows подставляет на PATH). Раньше в этом
    # случае мы падали на 'py -3' и звали его через PowerShell-сплаттинг
    # (& $cmd @arr -m ...) — этот launcher-алиас в таком вызове НЕ пробрасывает
    # аргументы во вложенный интерпретатор: вместо `-m PyInstaller --version`
    # запускается голый интерактивный Python, который тут же виснет в
    # бесконечном цикле (баг pyrepl в безоконном процессе, WinError 123/6
    # на getheightwidth). Воспроизведено многократно на этой машине.
    #
    # Реестр, куда себя прописывает обычный установщик python.org, даёт
    # прямой путь к настоящему python.exe в обход алиаса — без сплаттинга
    # и его подводных камней.
    $candidates = @()
    foreach ($name in @('python', 'py')) {
        $cmds = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmds) {
            if ($cmds -is [System.Array]) { $candidates += $cmds } else { $candidates += @($cmds) }
        }
    }
    $real = $candidates | Where-Object { $_.Source -and ($_.Source -notmatch 'WindowsApps') } | Select-Object -First 1
    if ($real) { return $real.Source }

    foreach ($hive in @('HKCU:\Software\Python\PythonCore', 'HKLM:\SOFTWARE\Python\PythonCore')) {
        if (-not (Test-Path $hive)) { continue }
        $versions = Get-ChildItem $hive -ErrorAction SilentlyContinue | Sort-Object PSChildName -Descending
        foreach ($v in $versions) {
            $ip = Get-ItemProperty -Path "$($v.PSPath)\InstallPath" -ErrorAction SilentlyContinue
            if (-not $ip.'(default)') { continue }
            $exe = Join-Path $ip.'(default)'.TrimEnd('\') 'python.exe'
            if (Test-Path $exe) { return $exe }
        }
    }
    return $null
}

$pyExe = Resolve-PythonExe
if (-not $pyExe) {
    Write-Fail "Python не найден (ни на PATH, ни в реестре PythonCore)"
    Write-Host "Сборка exe — задача разработчика, нужен настоящий Python 3.8+" -ForegroundColor Yellow
    Write-Host "(не алиас Microsoft Store)." -ForegroundColor Yellow
    Exit-Build 1
}
Write-Ok "Python: $pyExe"

& $pyExe -m PyInstaller --version | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  PyInstaller не найден, устанавливаю..." -ForegroundColor Gray
    & $pyExe -m pip install -q pyinstaller
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Не удалось установить PyInstaller"
        Exit-Build 1
    }
}
Write-Ok "PyInstaller готов"

# ─── Сборка ────────────────────────────────────────────────────
Write-Host ""
Write-Host "[2/3] Сборка (--onedir)..." -ForegroundColor White

if (-not (Test-Path "$srcDir\native_host.py")) {
    Write-Fail "Не найден $srcDir\native_host.py"
    Exit-Build 1
}

if (Test-Path $distDir)  { Remove-Item $distDir  -Recurse -Force }
if (Test-Path $buildDir) { Remove-Item $buildDir -Recurse -Force }

Push-Location $srcDir
try {
    & $pyExe -m PyInstaller --onedir --noconsole --name native_host `
        --distpath $distDir --workpath $buildDir --specpath $buildDir -y `
        native_host.py
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "PyInstaller завершился с ошибкой"
        Pop-Location
        Exit-Build 1
    }
} finally {
    Pop-Location
}

$exePath = "$distDir\native_host\native_host.exe"
if (-not (Test-Path $exePath)) {
    Write-Fail "native_host.exe не появился после сборки"
    Exit-Build 1
}
Write-Ok "native_host.exe собран"

# ─── Проверка: настоящий обмен по протоколу native messaging ──
Write-Host ""
Write-Host "[3/3] Проверка протокола..." -ForegroundColor White

$checkScript = @'
import json, struct, subprocess, sys, time
exe = sys.argv[1]
p = subprocess.Popen([exe], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                      stderr=subprocess.PIPE, creationflags=subprocess.CREATE_NO_WINDOW)
time.sleep(0.3)
if p.poll() is not None:
    print("DEAD:" + p.stderr.read().decode("utf-8", "replace")[:300]); sys.exit(1)
body = json.dumps({"id": 1, "action": "status", "clientId": "build-check"}).encode()
p.stdin.write(struct.pack("=I", len(body)) + body); p.stdin.flush()
raw = p.stdout.read(4)
if len(raw) < 4:
    print("NO_RESPONSE"); sys.exit(1)
n = struct.unpack("=I", raw)[0]
resp = json.loads(p.stdout.read(n).decode("utf-8"))
p.stdin.close(); p.wait(timeout=5)
print("OK:" + json.dumps(resp))
'@
$checkFile = "$buildDir\_check_protocol.py"
[System.IO.File]::WriteAllText($checkFile, $checkScript, (New-Object System.Text.UTF8Encoding $false))
$result = & $pyExe $checkFile $exePath
if ($result -match '^OK:') {
    Write-Ok "Протокол работает: $($result.Substring(3))"
} else {
    Write-Fail "Собранный exe не отвечает по протоколу native messaging: $result"
    Exit-Build 1
}

$size = [math]::Round((Get-ChildItem $distDir -Recurse | Measure-Object -Property Length -Sum).Sum / 1MB, 1)

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Сборка готова: $exePath" -ForegroundColor Green
Write-Host " Размер: $size МБ" -ForegroundColor Gray
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Дальше: installer\install.bat" -ForegroundColor Yellow
Write-Host ""

Exit-Build 0
