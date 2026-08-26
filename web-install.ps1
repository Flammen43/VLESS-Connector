<#
    Бутстрап для установки одной командой:

        irm https://raw.githubusercontent.com/Flammen43/VLESS-Connector/main/web-install.ps1 | iex

    Скачивает архив последнего релиза (внутри уже лежит Xray и гео-базы),
    распаковывает в %LOCALAPPDATA%\Programs\VLESS-Connector и запускает
    обычный install.ps1 оттуда. Сам проект клонировать не нужно.

    Зеркало вместо GitHub — через переменную окружения, если raw.github
    недоступен:  $env:VLESSCHROME_BASE = 'https://example.com/vless'
#>
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$repo      = 'Flammen43/VLESS-Connector'
$appDir    = "$env:LOCALAPPDATA\Programs\VLESS-Connector"
$assetMask = 'win-x64'

function Write-Step($m) { Write-Host ""; Write-Host $m -ForegroundColor White }
function Write-Ok($m)   { Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Fail($m) { Write-Host "  [!!] $m" -ForegroundColor Red }

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " VLESS-Connector — установка из сети" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

# ─── [1/4] Где взять архив ───────────────────────────────────
# Зеркало отдаёт файл по прямому пути, GitHub — через API релизов.
Write-Step "[1/4] Поиск последнего релиза..."

if ($env:VLESSCHROME_BASE) {
    $url = "$($env:VLESSCHROME_BASE.TrimEnd('/'))/vlesschrome-$assetMask.zip"
    Write-Ok "зеркало: $url"
} else {
    try {
        $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" `
            -Headers @{ 'User-Agent' = 'VLESSConnector-installer' } -TimeoutSec 30
    } catch {
        Write-Fail "GitHub недоступен: $($_.Exception.Message)"
        Write-Host "  Скачайте архив вручную: https://github.com/$repo/releases/latest" -ForegroundColor Yellow
        Write-Host "  Либо укажите зеркало: `$env:VLESSCHROME_BASE = '...'" -ForegroundColor Gray
        exit 1
    }
    $asset = $rel.assets | Where-Object { $_.name -like "*$assetMask*.zip" } | Select-Object -First 1
    if (-not $asset) { Write-Fail "в релизе $($rel.tag_name) нет архива для $assetMask"; exit 1 }
    $url = $asset.browser_download_url
    Write-Ok "$($rel.tag_name): $($asset.name) ($([math]::Round($asset.size/1MB,1)) МБ)"
}

# ─── [2/4] Загрузка ──────────────────────────────────────────
Write-Step "[2/4] Загрузка архива..."
$zip = Join-Path ([IO.Path]::GetTempPath()) "vless-connector-$([guid]::NewGuid().ToString('N')).zip"
try {
    $pref = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -TimeoutSec 600
    $ProgressPreference = $pref
} catch {
    Write-Fail "не удалось скачать: $($_.Exception.Message)"
    exit 1
}
Write-Ok "$([math]::Round((Get-Item $zip).Length/1MB,1)) МБ"

# ─── [3/4] Распаковка ────────────────────────────────────────
# Каталог перезаписывается целиком: он хранит только распакованный релиз,
# пользовательские настройки лежат в %LOCALAPPDATA%\VLESSChrome.
Write-Step "[3/4] Распаковка в $appDir..."
try {
    if (Test-Path $appDir) { Remove-Item $appDir -Recurse -Force }
    New-Item -ItemType Directory -Path $appDir -Force | Out-Null
    Expand-Archive -Path $zip -DestinationPath $appDir -Force

    # В архиве корень может быть вложенной папкой — поднимаем содержимое.
    $inner = Get-ChildItem $appDir
    if ($inner.Count -eq 1 -and $inner[0].PSIsContainer) {
        Get-ChildItem $inner[0].FullName -Force | Move-Item -Destination $appDir -Force
        Remove-Item $inner[0].FullName -Recurse -Force
    }
} finally {
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
}

$installer = Join-Path $appDir 'install.ps1'
if (-not (Test-Path $installer)) { Write-Fail "install.ps1 не найден в архиве"; exit 1 }
Write-Ok "готово"

# ─── [4/4] Установка ─────────────────────────────────────────
Write-Step "[4/4] Запуск установщика..."
$env:VLESSCHROME_NONINTERACTIVE = '1'
& $installer
$code = $LASTEXITCODE
Remove-Item Env:\VLESSCHROME_NONINTERACTIVE -ErrorAction SilentlyContinue
if ($code -ne 0) { exit $code }

# install.ps1 уже напечатал, что делать дальше — здесь только открываем
# папку расширения, чтобы её не искать вручную.
$extDir = Join-Path $appDir 'extension'
if (Test-Path $extDir) { Start-Process explorer.exe $extDir }
