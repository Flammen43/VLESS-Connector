[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "SilentlyContinue"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "VLESS Chrome Extension - Проверка установки" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$installDir = "$env:LOCALAPPDATA\VLESSChrome"
$errorCount = 0
$warningCount = 0
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location $scriptDir

function Write-Ok($msg)   { Write-Host "  ✅ $msg" -ForegroundColor Green }
function Write-Fail($msg) { Write-Host "  ❌ $msg" -ForegroundColor Red }
function Write-Warn($msg) { Write-Host "  ⚠️  $msg" -ForegroundColor Yellow }
function Write-Info($msg) { Write-Host "  ℹ️  $msg" -ForegroundColor DarkCyan }

# [1/8] Python
# Ищем так же, как install.ps1: заглушка из WindowsApps открывает Microsoft Store
# вместо интерпретатора, и Get-Command её находит — это ложноположительный результат.
Write-Host "[1/8] Проверка Python..." -ForegroundColor White

function Resolve-PythonExe {
    $candidates = @()
    foreach ($name in @('python', 'py')) {
        $cmds = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmds) {
            if ($cmds -is [System.Array]) { $candidates += $cmds } else { $candidates += @($cmds) }
        }
    }
    $real = $candidates | Where-Object { $_.Source -and ($_.Source -notmatch 'WindowsApps') } | Select-Object -First 1
    if ($real) { return $real.Source }
    if (Get-Command py -ErrorAction SilentlyContinue) { return 'py -3' }
    return $null
}

$pyExe = Resolve-PythonExe
if ($pyExe) {
    if ($pyExe -match '\s') { $ver = & cmd /c "$pyExe --version" } else { $ver = & $pyExe --version }
    Write-Ok "Python найден: $pyExe ($ver)"
} else {
    Write-Fail "Python НЕ найден (или только заглушка из Microsoft Store)"
    Write-Host "       Установите Python с https://python.org с галочкой 'Add to PATH'" -ForegroundColor Gray
    $errorCount++
}
Write-Host ""

# [2/8] Исходники (bin\ больше не нужен: install.bat ставит прямо из native-host-python\)
Write-Host "[2/8] Проверка исходников проекта..." -ForegroundColor White
foreach ($f in @("native_host.py", "parsers.py", "dpapi_store.py", "host_ping.py")) {
    if (Test-Path "native-host-python\$f") {
        Write-Ok "$f найден"
    } else {
        Write-Fail "$f НЕ найден в native-host-python\"
        $errorCount++
    }
}
Write-Host ""

# [3/8] Установленные файлы
Write-Host "[3/8] Проверка установленных файлов..." -ForegroundColor White
if (-not (Test-Path $installDir)) {
    Write-Fail "Директория установки НЕ существует: $installDir"
    Write-Host "       Запустите install.bat" -ForegroundColor Gray
    $errorCount++
} else {
    Write-Ok "Директория установки: $installDir"
    foreach ($f in @("native_host.py", "native-host.bat", "xray.exe", "native-host-manifest.json")) {
        if (Test-Path "$installDir\$f") {
            Write-Ok "$f установлен"
        } else {
            Write-Fail "$f НЕ установлен"
            $errorCount++
        }
    }

    # Версия xray раньше нигде не показывалась, и устаревший бинарник можно
    # было опознать только по тексту ошибки при неудачном подключении:
    # у одного пользователя так остался 1.8.7 без поддержки транспорта xhttp.
    $xrayExe = "$installDir\xray.exe"
    if (Test-Path $xrayExe) {
        $installed = $null
        try {
            $line = & $xrayExe version 2>$null | Select-Object -First 1
            $m = [regex]::Match([string] $line, 'Xray\s+(\d+\.\d+\.\d+)')
            if ($m.Success) { $installed = $m.Groups[1].Value }
        } catch { }

        if (-not $installed) {
            Write-Warn "Не удалось определить версию xray.exe (файл повреждён?)"
            $warningCount++
        } else {
            $latest = $null
            try {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/XTLS/Xray-core/releases/latest" `
                    -Headers @{ 'User-Agent' = 'VLESSChrome-check' } -TimeoutSec 15
                if ($rel.tag_name) { $latest = $rel.tag_name.TrimStart('v') }
            } catch { }

            if (-not $latest) {
                Write-Ok "Версия xray: $installed (последнюю проверить не удалось)"
            } elseif ($installed -eq $latest) {
                Write-Ok "Версия xray: $installed (актуальна)"
            } else {
                Write-Warn "Версия xray: $installed, доступна $latest"
                Write-Host "       Старые сборки не знают новых транспортов (xhttp и др.)." -ForegroundColor Gray
                Write-Host "       Обновить: install.bat" -ForegroundColor Gray
                $warningCount++
            }
        }
    }
}
Write-Host ""

# [4/8] Extension ID
# ID задан полем "key" в extension\manifest.json, поэтому его можно вычислить
# заранее и сверить с тем, что реально прописано в манифесте native host.
Write-Host "[4/8] Проверка Extension ID..." -ForegroundColor White

function Get-ExtensionIdFromKey($base64Key) {
    $der = [Convert]::FromBase64String($base64Key)
    $sha = [System.Security.Cryptography.SHA256]::Create().ComputeHash($der)
    $hex = -join ($sha[0..15] | ForEach-Object { $_.ToString('x2') })
    return -join ($hex.ToCharArray() | ForEach-Object {
        [char]([int][char]'a' + [Convert]::ToInt32($_.ToString(), 16))
    })
}

$manifestPath = "$installDir\native-host-manifest.json"
$expectedId = $null
if (Test-Path "extension\manifest.json") {
    $extManifest = Get-Content "extension\manifest.json" -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($extManifest.key) {
        $expectedId = Get-ExtensionIdFromKey $extManifest.key
        Write-Ok "ID закреплён ключом: $expectedId"
    } else {
        Write-Warn "В extension\manifest.json нет поля 'key' — ID будет зависеть от пути"
        Write-Host "       Запустите: py -3 install\gen-extension-key.py --manifest extension\manifest.json --host-manifest install\native-host-manifest.json" -ForegroundColor Gray
        $warningCount++
    }
}

if (-not (Test-Path $manifestPath)) {
    Write-Fail "Манифест native host не найден"
    Write-Host "       Запустите install.bat" -ForegroundColor Gray
    $errorCount++
} else {
    $content = Get-Content $manifestPath -Raw -Encoding UTF8
    $ids = [regex]::Matches($content, 'chrome-extension://([^/]+)/')
    if ($ids.Count -eq 0) {
        Write-Fail "В манифесте нет allowed_origins"
        $errorCount++
    }
    foreach ($id in $ids) {
        $actual = $id.Groups[1].Value
        if ($actual -eq "EXTENSION_ID_PLACEHOLDER") {
            Write-Fail "В манифесте остался плейсхолдер"
            Write-Host "       Запустите install.bat" -ForegroundColor Gray
            $errorCount++
        } elseif ($expectedId -and $actual -ne $expectedId) {
            Write-Fail "ID в манифесте не совпадает с ключом расширения"
            Write-Host "       В манифесте: $actual" -ForegroundColor Gray
            Write-Host "       Ожидается:   $expectedId" -ForegroundColor Gray
            Write-Host "       Запустите install.bat и перезапустите браузер" -ForegroundColor Gray
            $errorCount++
        } else {
            Write-Ok "Манифест native host согласован ($actual)"
        }
    }
}
Write-Host ""

# [5/8] Реестр
Write-Host "[5/8] Проверка реестра Windows..." -ForegroundColor White
$regPath = "HKCU:\Software\Google\Chrome\NativeMessagingHosts\com.vlesschrome.host"
$regVal = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
if ($regVal) {
    Write-Ok "Native Messaging Host зарегистрирован в Chrome"
    Write-Host "       Путь: $($regVal.'(default)')" -ForegroundColor Gray
} else {
    Write-Fail "Native Messaging Host НЕ зарегистрирован в Chrome"
    Write-Host "       Запустите install.bat" -ForegroundColor Gray
    $errorCount++
}
Write-Host ""

# [6/8] Расширение
Write-Host "[6/8] Проверка файлов расширения..." -ForegroundColor White
foreach ($f in @("manifest.json", "popup.html", "popup.js", "background.js")) {
    if (Test-Path "extension\$f") {
        Write-Ok "$f найден"
    } else {
        Write-Fail "$f НЕ найден"
        $errorCount++
    }
}
if (Test-Path "extension\icons\icon128.png") {
    Write-Ok "Иконки найдены"
} else {
    Write-Warn "Иконки НЕ найдены"
    $warningCount++
}
Write-Host ""

# [7/8] Логи
Write-Host "[7/8] Проверка логов..." -ForegroundColor White
$nhLog = Get-Item "$installDir\native-host.log" -ErrorAction SilentlyContinue
if ($nhLog) {
    Write-Ok "native-host.log ($($nhLog.Length) байт, изменен $($nhLog.LastWriteTime.ToString('dd.MM.yyyy HH:mm')))"
} else {
    Write-Info "native-host.log еще не создан (нормально, если расширение не запускалось)"
}

$xrayLogs = Get-ChildItem "$installDir\xray_*.log" -ErrorAction SilentlyContinue
if ($xrayLogs) {
    $latest = $xrayLogs | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    Write-Ok "Логов Xray: $($xrayLogs.Count). Последний: $($latest.Name) ($($latest.Length) байт)"
} else {
    Write-Info "Логи Xray еще не созданы"
}
Write-Host ""

# [8/8] Процессы
Write-Host "[8/8] Проверка процессов Xray..." -ForegroundColor White
$procs = Get-Process -Name "xray" -ErrorAction SilentlyContinue
if ($procs) {
    Write-Warn "Запущено процессов xray.exe: $($procs.Count)"
    foreach ($p in $procs) {
        Write-Host "       PID: $($p.Id), Память: $([math]::Round($p.WorkingSet64/1MB, 1)) MB" -ForegroundColor Gray
    }
} else {
    Write-Ok "Процессы xray.exe не запущены"
}
Write-Host ""

# Итоги
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Результаты проверки" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if ($errorCount -gt 0) {
    Write-Host "❌ НАЙДЕНО $errorCount ОШИБОК" -ForegroundColor Red
    Write-Host ""
    Write-Host "Рекомендуемые действия:" -ForegroundColor Yellow
    Write-Host "  1. Запустите install.bat в корне проекта"
    Write-Host "  2. Запустите эту проверку снова"
} elseif ($warningCount -gt 0) {
    Write-Host "⚠️  Есть $warningCount предупреждений" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Установка в целом корректна, но есть моменты требующие внимания."
} else {
    Write-Host "✅ ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ" -ForegroundColor Green
    Write-Host ""
    Write-Host "Установка выполнена корректно." -ForegroundColor Green
    Write-Host ""
    Write-Host "Следующие шаги:"
    Write-Host "  1. Откройте Chrome: chrome://extensions/"
    Write-Host "  2. Включите 'Режим разработчика'"
    Write-Host "  3. Загрузите папку extension"
    Write-Host ""
    Write-Host "Копировать Extension ID и перезапускать браузер не нужно:" -ForegroundColor Gray
    Write-Host "ID закреплён полем 'key' в manifest.json." -ForegroundColor Gray
}

Pop-Location
Write-Host ""
Read-Host "Нажмите Enter для выхода"
