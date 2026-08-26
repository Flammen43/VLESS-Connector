[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Continue"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location $scriptDir

function Wait-Exit {
    if ($env:VLESSCHROME_NONINTERACTIVE -eq '1') { Pop-Location; exit $args[0] }
    Pop-Location
    Read-Host "Нажмите Enter для выхода"
    exit $args[0]
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Загрузка Xray-core" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path "bin")) { New-Item -ItemType Directory -Path "bin" | Out-Null }

$fallbackVersion = "26.3.27"
$xrayVersion = $fallbackVersion
$apiUrl = "https://api.github.com/repos/XTLS/Xray-core/releases/latest"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$headers = @{ 'User-Agent' = 'VLESSChrome-xray-downloader' }

try {
    $release = Invoke-RestMethod -Uri $apiUrl -Headers $headers -TimeoutSec 20
    if ($release.tag_name) {
        $xrayVersion = $release.tag_name.TrimStart('v')
        Write-Host "[OK] Latest release: v$xrayVersion" -ForegroundColor Green
    }
} catch {
    Write-Host "[WARN] GitHub API недоступен, используем v$fallbackVersion" -ForegroundColor Yellow
}

$downloadUrl = "https://github.com/XTLS/Xray-core/releases/download/v$xrayVersion/Xray-windows-64.zip"
$zipFile = "bin\xray.zip"
$tempDir = "bin\xray-temp"

Write-Host "Загрузка Xray-core v$xrayVersion..." -ForegroundColor White
Write-Host "URL: $downloadUrl" -ForegroundColor Gray
Write-Host ""

try {
    Invoke-WebRequest -Uri $downloadUrl -OutFile $zipFile -UserAgent 'Mozilla/5.0' -TimeoutSec 120
    Write-Host "[OK] Загрузка завершена" -ForegroundColor Green
} catch {
    Write-Host "[FAIL] Не удалось скачать Xray: $_" -ForegroundColor Red
    Write-Host "Попробуйте скачать вручную с https://github.com/XTLS/Xray-core/releases" -ForegroundColor Yellow
    Wait-Exit 1
}

Write-Host ""
Write-Host "Проверка контрольной суммы..."
$dgstUrl = "$downloadUrl.dgst"
$dgstFile = "bin\xray.zip.dgst"
try {
    Invoke-WebRequest -Uri $dgstUrl -OutFile $dgstFile -Headers $headers -TimeoutSec 30
    $dgstContent = Get-Content $dgstFile -Raw
    $match = [regex]::Match($dgstContent, '(?im)^SHA2-256\s*=\s*([0-9a-fA-F]{64})')
    if (-not $match.Success) {
        $match = [regex]::Match($dgstContent, '(?im)SHA256\s*\([^)]*\)\s*=\s*([0-9a-fA-F]{64})')
    }
    if ($match.Success) {
        $expectedHash = $match.Groups[1].Value.ToLower()
        $actualHash = (Get-FileHash -Path $zipFile -Algorithm SHA256).Hash.ToLower()
        if ($actualHash -ne $expectedHash) {
            Write-Host "[FAIL] Контрольная сумма НЕ совпадает!" -ForegroundColor Red
            Write-Host "  Ожидалось: $expectedHash" -ForegroundColor Red
            Write-Host "  Получено:  $actualHash" -ForegroundColor Red
            Write-Host "Файл повреждён или подменён — удаляю." -ForegroundColor Red
            Remove-Item $zipFile -Force -ErrorAction SilentlyContinue
            Wait-Exit 1
        }
        Write-Host "[OK] SHA256 совпадает: $actualHash" -ForegroundColor Green
    } else {
        Write-Host "[WARN] Не удалось разобрать .dgst — проверка пропущена" -ForegroundColor Yellow
    }
} catch {
    Write-Host "[WARN] Не удалось скачать .dgst для проверки контрольной суммы: $_" -ForegroundColor Yellow
} finally {
    Remove-Item $dgstFile -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Распаковка архива..."
try {
    if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
    Expand-Archive -Path $zipFile -DestinationPath $tempDir -Force

    if (Test-Path "$tempDir\xray.exe") {
        Copy-Item "$tempDir\xray.exe" "bin\xray.exe" -Force
        Write-Host "[OK] xray.exe извлечен: bin\xray.exe" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] xray.exe не найден в архиве" -ForegroundColor Red
        Wait-Exit 1
    }

    # Гео-базы из того же архива — install.bat заберёт их отсюда
    foreach ($geo in @('geoip.dat', 'geosite.dat')) {
        if (Test-Path "$tempDir\$geo") {
            Copy-Item "$tempDir\$geo" "bin\$geo" -Force
            Write-Host "[OK] $geo извлечен: bin\$geo" -ForegroundColor Green
        } else {
            Write-Host "[WARN] $geo не найден в архиве" -ForegroundColor Yellow
        }
    }
} catch {
    Write-Host "[FAIL] Не удалось распаковать архив: $_" -ForegroundColor Red
    Wait-Exit 1
}

Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $zipFile -Force -ErrorAction SilentlyContinue
Write-Host "[OK] Временные файлы удалены" -ForegroundColor Green

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Загрузка завершена!" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "xray.exe готов к использованию: bin\xray.exe"
Wait-Exit 0
