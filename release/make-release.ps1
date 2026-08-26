<#
    Сборка релизного архива: проект + бинарники Xray внутри.

    Смысл: установка на целевой машине идёт БЕЗ СЕТИ. Установщики уже умеют
    брать xray и гео-базы из bin\ вместо загрузки — этот скрипт просто
    наполняет bin\ заранее.

    Архив делается отдельно под каждую платформу: xray для win/linux/macos
    разный, класть все в один архив — это лишние ~60 МБ каждому.

    Примеры:
        .\release\make-release.ps1                      # win-x64
        .\release\make-release.ps1 -Platform macos-arm64
        .\release\make-release.ps1 -Platform all
#>
param(
    [ValidateSet('win-x64', 'linux-x64', 'linux-arm64', 'macos-arm64', 'macos-x64', 'all')]
    [string] $Platform = 'win-x64',

    # Версия Xray. По умолчанию — последняя с GitHub.
    [string] $XrayVersion = '',

    [string] $OutDir = ''
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

$releaseDir = $PSScriptRoot
$projectDir = Split-Path -Parent $releaseDir
if (-not $OutDir) { $OutDir = "$releaseDir\out" }

function Write-Ok($m)   { Write-Host "  [OK] $m"   -ForegroundColor Green }
function Write-Warn($m) { Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Write-Step($m) { Write-Host ""; Write-Host $m -ForegroundColor White }

# Соответствие платформы ассету релиза Xray. Имена сверены со списком
# ассетов: Xray-windows-64.zip, Xray-linux-64.zip, Xray-macos-arm64-v8a.zip...
$XRAY_ASSETS = @{
    'win-x64'     = 'Xray-windows-64.zip'
    'linux-x64'   = 'Xray-linux-64.zip'
    'linux-arm64' = 'Xray-linux-arm64-v8a.zip'
    'macos-arm64' = 'Xray-macos-arm64-v8a.zip'
    'macos-x64'   = 'Xray-macos-64.zip'
}
# Что из проекта не нужно конечному пользователю.
$EXCLUDE_DIRS = @('.git', '__pycache__', '.pytest_cache', 'tests', 'release', 'node_modules')
$GEO_FILES = @('geoip.dat', 'geosite.dat')

function Get-LatestXrayVersion {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try {
        $r = Invoke-RestMethod -Uri 'https://api.github.com/repos/XTLS/Xray-core/releases/latest' `
            -Headers @{ 'User-Agent' = 'VLESSChrome-release' } -TimeoutSec 20
        return $r.tag_name.TrimStart('v')
    } catch {
        throw "Не удалось узнать версию Xray с GitHub: $_"
    }
}

function Get-XrayBundle {
    <#
        Скачивает архив Xray, СВЕРЯЕТ SHA-256 и распаковывает во временную
        папку. Проверка обязательна: бинарник получит полный доступ к трафику,
        а качается по сети.
    #>
    param([string] $Asset, [string] $Version, [string] $CacheDir)

    $zip = Join-Path $CacheDir $Asset
    $url = "https://github.com/XTLS/Xray-core/releases/download/v$Version/$Asset"

    # Ожидаемый размер из API: обрыв соединения даёт «успешно скачанный»
    # обрезанный файл, и без сверки это видно только по контрольной сумме.
    $expectedSize = 0
    try {
        $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/XTLS/Xray-core/releases/latest' `
            -Headers @{ 'User-Agent' = 'VLESSChrome-release' } -TimeoutSec 20
        $a = $rel.assets | Where-Object { $_.name -eq $Asset }
        if ($a) { $expectedSize = $a.size }
    } catch { }

    if ((Test-Path $zip) -and $expectedSize -gt 0 -and (Get-Item $zip).Length -ne $expectedSize) {
        Write-Warn "Кэш $Asset неполный — перекачиваю"
        Remove-Item $zip -Force
    }

    # Сеть до GitHub бывает нестабильной: обрыв на 25 МБ не должен ронять
    # сборку целиком, поэтому несколько попыток.
    $attempt = 0
    while (-not (Test-Path $zip)) {
        $attempt++
        try {
            Write-Host "  Загрузка $Asset (попытка $attempt из 3)..." -ForegroundColor Gray
            Invoke-WebRequest -Uri $url -OutFile $zip -UserAgent 'Mozilla/5.0' -TimeoutSec 600
            if ($expectedSize -gt 0 -and (Get-Item $zip).Length -ne $expectedSize) {
                Remove-Item $zip -Force
                throw "получено $((Get-Item $zip).Length) байт вместо $expectedSize"
            }
        } catch {
            if (Test-Path $zip) { Remove-Item $zip -Force }
            if ($attempt -ge 3) { throw "Не удалось скачать $Asset за 3 попытки: $_" }
            Write-Warn "Загрузка сорвалась ($_), повтор..."
            Start-Sleep -Seconds 3
        }
    }
    if ($attempt -eq 0) { Write-Ok "$Asset уже в кэше" }

    # .dgst лежит рядом с каждым ассетом
    $dgst = "$zip.dgst"
    if (-not (Test-Path $dgst)) {
        try {
            Invoke-WebRequest -Uri "$url.dgst" -OutFile $dgst -UserAgent 'Mozilla/5.0' -TimeoutSec 60
        } catch {
            Write-Warn "Не удалось скачать .dgst — проверка контрольной суммы пропущена"
        }
    }

    if (Test-Path $dgst) {
        $content = Get-Content $dgst -Raw
        $m = [regex]::Match($content, '(?im)^SHA2-256\s*=\s*([0-9a-fA-F]{64})')
        if (-not $m.Success) {
            $m = [regex]::Match($content, '(?im)SHA256\s*\([^)]*\)\s*=\s*([0-9a-fA-F]{64})')
        }
        if ($m.Success) {
            $expected = $m.Groups[1].Value.ToLower()
            $actual = (Get-FileHash -Path $zip -Algorithm SHA256).Hash.ToLower()
            if ($expected -ne $actual) {
                Remove-Item $zip -Force
                throw "Контрольная сумма $Asset не совпала (файл удалён). Ожидалось $expected, получено $actual"
            }
            Write-Ok "SHA-256 совпала"
        } else {
            Write-Warn "Не удалось разобрать .dgst — проверка пропущена"
        }
    }

    $unpack = Join-Path $CacheDir ([System.IO.Path]::GetFileNameWithoutExtension($Asset))
    if (Test-Path $unpack) { Remove-Item $unpack -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $unpack -Force
    return $unpack
}

function New-ZipForwardSlash {
    <#
        Упаковка с '/' в именах записей.

        Ни Compress-Archive, ни ZipFile::CreateFromDirectory тут не годятся:
        в .NET Framework (его использует PowerShell 5.1) оба подставляют
        системный разделитель, то есть '\'. Формат zip требует '/', и хотя
        Windows такие архивы открывает, unzip на Linux/macOS создаёт из них
        один файл с обратными слэшами в имени вместо дерева каталогов —
        кроссплатформенные архивы получались бы нерабочими. Поэтому имена
        записей задаём сами.
    #>
    param([string] $SourceRoot, [string] $Destination)

    Add-Type -AssemblyName System.IO.Compression | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

    $root = (Resolve-Path $SourceRoot).Path.TrimEnd('\')
    $fs = [System.IO.File]::Open($Destination, [System.IO.FileMode]::Create)
    try {
        $zip = New-Object System.IO.Compression.ZipArchive(
            $fs, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($f in Get-ChildItem $SourceRoot -Recurse -File -Force) {
                $rel = $f.FullName.Substring($root.Length + 1) -replace '\\', '/'
                $entry = $zip.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Optimal)
                $dst = $entry.Open()
                try {
                    $src = [System.IO.File]::OpenRead($f.FullName)
                    try { $src.CopyTo($dst) } finally { $src.Dispose() }
                } finally { $dst.Dispose() }
            }
        } finally { $zip.Dispose() }
    } finally { $fs.Dispose() }
}

function New-ReleaseArchive {
    param([string] $Plat, [string] $Version)

    Write-Step "=== $Plat ==="

    $asset = $XRAY_ASSETS[$Plat]
    $cache = "$releaseDir\cache"
    New-Item -ItemType Directory -Force -Path $cache | Out-Null
    $unpack = Get-XrayBundle -Asset $asset -Version $Version -CacheDir $cache

    $stage = "$releaseDir\stage\vlesschrome"
    if (Test-Path "$releaseDir\stage") { Remove-Item "$releaseDir\stage" -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $stage | Out-Null

    # 1. Файлы проекта
    Get-ChildItem $projectDir -Force | ForEach-Object {
        if ($EXCLUDE_DIRS -contains $_.Name) { return }
        if ($_.Name -eq 'vlesschrome-private.pem') { return }  # приватный ключ не раздаём
        Copy-Item $_.FullName -Destination $stage -Recurse -Force
    }

    # Артефакты сборки чужих платформ и мусор внутрь не тащим
    foreach ($junk in @('installer\build', 'bin\xray.exe', 'bin\xray', 'bin\geoip.dat', 'bin\geosite.dat')) {
        $p = Join-Path $stage $junk
        if (Test-Path $p) { Remove-Item $p -Recurse -Force }
    }

    # Shell-скрипты — строго LF. Достаточно один раз отредактировать .sh
    # инструментом, который на Windows пишет CRLF, и установщик на Linux или
    # macOS падает с «bad interpreter: /bin/bash^M». Это уже случилось с
    # quick-install.sh обеих платформ, поэтому нормализуем при сборке, не
    # полагаясь на состояние рабочей копии.
    foreach ($sh in Get-ChildItem $stage -Recurse -Force -Filter '*.sh') {
        $bytes = [System.IO.File]::ReadAllBytes($sh.FullName)
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
        if ($text -match "`r`n") {
            $text = $text -replace "`r`n", "`n"
            [System.IO.File]::WriteAllBytes(
                $sh.FullName, [System.Text.Encoding]::UTF8.GetBytes($text))
            Write-Host "  [FIX] LF: $($sh.Name)" -ForegroundColor DarkYellow
        }
    }

    # EXCLUDE_DIRS отсекает только верхний уровень, а Copy-Item -Recurse
    # приносит вложенный мусор (например native-host-python\__pycache__).
    Get-ChildItem $stage -Recurse -Force -Directory |
        Where-Object { $_.Name -in @('__pycache__', '.pytest_cache') } |
        ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    Get-ChildItem $stage -Recurse -Force -Filter '*.pyc' |
        ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
    # installer\dist имеет смысл только для Windows (это .exe)
    if ($Plat -ne 'win-x64') {
        $d = Join-Path $stage 'installer\dist'
        if (Test-Path $d) { Remove-Item $d -Recurse -Force }
    }

    # 2. Бинарники в bin\ — отсюда их возьмут установщики, без сети
    $binDir = Join-Path $stage 'bin'
    New-Item -ItemType Directory -Force -Path $binDir | Out-Null

    $xrayName = if ($Plat -eq 'win-x64') { 'xray.exe' } else { 'xray' }
    $srcXray = Join-Path $unpack $xrayName
    if (-not (Test-Path $srcXray)) { throw "В архиве $asset нет $xrayName" }
    Copy-Item $srcXray (Join-Path $binDir $xrayName) -Force
    Write-Ok "$xrayName вложен"

    foreach ($geo in $GEO_FILES) {
        $srcGeo = Join-Path $unpack $geo
        if (Test-Path $srcGeo) {
            Copy-Item $srcGeo (Join-Path $binDir $geo) -Force
            Write-Ok "$geo вложен"
        } else {
            Write-Warn "$geo нет в архиве — гео-маршрутизация потребует сети"
        }
    }

    # 3. Упаковка
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $name = "vlesschrome-$Plat-xray$Version.zip"
    $out = Join-Path $OutDir $name
    if (Test-Path $out) { Remove-Item $out -Force }

    New-ZipForwardSlash -SourceRoot (Split-Path -Parent $stage) -Destination $out

    Remove-Item "$releaseDir\stage" -Recurse -Force
    $mb = [math]::Round((Get-Item $out).Length / 1MB, 1)
    Write-Ok "Готово: $name ($mb МБ)"
    return $out
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Сборка релизного архива" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

if (-not $XrayVersion) {
    Write-Step "Определение версии Xray..."
    $XrayVersion = Get-LatestXrayVersion
    Write-Ok "v$XrayVersion"
}

$targets = if ($Platform -eq 'all') { $XRAY_ASSETS.Keys | Sort-Object } else { @($Platform) }
$made = @()
foreach ($t in $targets) { $made += New-ReleaseArchive -Plat $t -Version $XrayVersion }

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Собрано архивов: $($made.Count)" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Cyan
foreach ($m in $made) { Write-Host "  $m" -ForegroundColor Gray }
Write-Host ""
Write-Host "Установка у пользователя (без сети):" -ForegroundColor Yellow
Write-Host "  Windows : распаковать -> installer\install.bat  (или install.bat)"
Write-Host "  Linux   : распаковать -> ./linux/quick-install.sh"
Write-Host "  macOS   : распаковать -> ./macos/quick-install.sh"
Write-Host ""
