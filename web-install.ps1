<#
    Бутстрап для установки одной командой:

        irm https://raw.githubusercontent.com/Flammen43/VLESS-Connector/main/web-install.ps1 | iex

    Скачивает архив последнего релиза (внутри уже лежит Xray и гео-базы),
    распаковывает в %LOCALAPPDATA%\Programs\VLESS-Connector и запускает
    установщик оттуда. По умолчанию — вариант с native_host.exe, Python на
    машине не нужен. Сам проект клонировать не нужно.

    Откат на Python-вариант (например, антивирус карантинит exe):
        $env:VLESSCHROME_USE_PYTHON = '1'

    Зеркало вместо GitHub — через переменную окружения, если raw.github
    недоступен:  $env:VLESSCHROME_BASE = 'https://example.com/vless'

    ВАЖНО для правок: скрипт исполняется через iex в сессии пользователя, а
    `exit` внутри iex завершает ВСЮ сессию PowerShell — окно закрывается вместе
    с текстом ошибки, и прочитать её невозможно. Поэтому вся логика живёт в
    функции, выход — через `return`; `exit` допустим только в Wait-OnError и
    только для автоматизации (VLESSCHROME_NONINTERACTIVE=1 или CI), где нужен
    код возврата. Файл должен быть без BOM: он ломает iex.
#>
function Invoke-VlessConnectorInstall {
    # Всё ниже локально для функции и не остаётся в сессии пользователя после
    # iex (раньше ErrorActionPreference='Stop' оставался в ней насовсем).
    $ErrorActionPreference = 'Stop'
    $prevEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $repo      = 'Flammen43/VLESS-Connector'
    $appDir    = "$env:LOCALAPPDATA\Programs\VLESS-Connector"
    $assetMask = 'win-x64'

    function Write-Step($m) { Write-Host ""; Write-Host $m -ForegroundColor White }
    function Write-Ok($m)   { Write-Host "  [OK] $m" -ForegroundColor Green }
    function Write-Fail($m) { Write-Host "  [!!] $m" -ForegroundColor Red }

    # Что делать после сообщения об ошибке.
    #  - Человек за консолью: ждём Enter, иначе при запуске через Win+R или
    #    "powershell -c" окно закрывается сразу вместе с текстом ошибки.
    #  - Автоматизация (CI, GPO, Intune, RMM — VLESSCHROME_NONINTERACTIVE=1):
    #    окна, которое закроется, нет, зато вызывающему нужен код возврата.
    #    Единственное место, где `exit` уместен: он завершает сессию, но здесь
    #    это и требуется. Без него провал установки выглядел бы как успех (код 0).
    function Wait-OnError([int]$ExitCode = 1) {
        if ($env:VLESSCHROME_NONINTERACTIVE -eq '1' -or $env:CI) { exit $ExitCode }
        try { Read-Host "Нажмите Enter, чтобы закрыть" | Out-Null } catch { }
    }

    # Строка «хеш  имя» (формат sha256sum) → ожидаемый SHA-256 файла.
    # Имя ищем точно, затем по маске платформы: зеркало отдаёт
    # vlesschrome-win-x64.zip, а в SHA256SUMS имя содержит версию Xray.
    function Get-ExpectedSha256([string]$SumsText, [string]$FileName, [string]$Mask) {
        $entries = @()
        foreach ($line in ($SumsText -split "`r?`n")) {
            if ($line -match '^\s*([0-9a-fA-F]{64})\s+\*?(\S.*?)\s*$') {
                $entries += [pscustomobject]@{ Hash = $matches[1].ToLower(); Name = $matches[2] }
            }
        }
        $hit = $entries | Where-Object { $_.Name -eq $FileName } | Select-Object -First 1
        if (-not $hit) { $hit = $entries | Where-Object { $_.Name -like "*$Mask*" } | Select-Object -First 1 }
        if ($hit) { return $hit.Hash }
        return $null
    }

    $zip = $null
    try {
        Write-Host "========================================" -ForegroundColor Cyan
        Write-Host " VLESS-Connector — установка из сети" -ForegroundColor Cyan
        Write-Host "========================================" -ForegroundColor Cyan

        # ─── [1/4] Где взять архив ───────────────────────────────
        # Зеркало отдаёт файл по прямому пути, GitHub — через API релизов.
        Write-Step "[1/4] Поиск последнего релиза..."

        $sumsUrl = $null
        $archiveName = $null
        if ($env:VLESSCHROME_BASE) {
            $mirror = $env:VLESSCHROME_BASE.TrimEnd('/')
            $archiveName = "vlesschrome-$assetMask.zip"
            $url = "$mirror/$archiveName"
            $sumsUrl = "$mirror/SHA256SUMS"
            Write-Ok "зеркало: $url"
        } else {
            try {
                $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" `
                    -Headers @{ 'User-Agent' = 'VLESSConnector-installer' } -TimeoutSec 30
            } catch {
                Write-Fail "GitHub недоступен: $($_.Exception.Message)"
                Write-Host "  Скачайте архив вручную: https://github.com/$repo/releases/latest" -ForegroundColor Yellow
                Write-Host "  Либо укажите зеркало: `$env:VLESSCHROME_BASE = '...'" -ForegroundColor Gray
                Wait-OnError; return
            }
            $asset = $rel.assets | Where-Object { $_.name -like "*$assetMask*.zip" } | Select-Object -First 1
            if (-not $asset) {
                Write-Fail "в релизе $($rel.tag_name) нет архива для $assetMask"
                Wait-OnError; return
            }
            $url = $asset.browser_download_url
            $archiveName = $asset.name
            $sums = $rel.assets | Where-Object { $_.name -eq 'SHA256SUMS' } | Select-Object -First 1
            if ($sums) { $sumsUrl = $sums.browser_download_url }
            Write-Ok "$($rel.tag_name): $($asset.name) ($([math]::Round($asset.size/1MB,1)) МБ)"
        }

        # ─── [2/4] Загрузка ──────────────────────────────────────
        Write-Step "[2/4] Загрузка архива..."
        $zip = Join-Path ([IO.Path]::GetTempPath()) "vless-connector-$([guid]::NewGuid().ToString('N')).zip"
        # Загрузка на 30+ МБ регулярно рвётся на полпути. Invoke-WebRequest в PS 5.1
        # не умеет повторять сам, поэтому цикл. Докачки нет — качаем заново.
        $pref = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
        $downloaded = $false
        $lastError = $null
        try {
            foreach ($attempt in 1..4) {
                try {
                    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -TimeoutSec 600
                    $downloaded = $true
                    break
                } catch {
                    $lastError = $_.Exception.Message
                    Remove-Item $zip -Force -ErrorAction SilentlyContinue
                    if ($attempt -lt 4) {
                        Write-Host "  попытка $attempt не удалась, повтор..." -ForegroundColor DarkGray
                        Start-Sleep -Seconds ($attempt * 2)
                    }
                }
            }
        } finally {
            $ProgressPreference = $pref
        }
        if (-not $downloaded) {
            Write-Fail "не удалось скачать: $lastError"
            Write-Host "  Скачайте архив вручную: https://github.com/$repo/releases/latest" -ForegroundColor Yellow
            Wait-OnError; return
        }
        Write-Ok "$([math]::Round((Get-Item $zip).Length/1MB,1)) МБ"

        # Целостность. Архив исполняется целиком (в нём установщик и xray), так
        # что обрыв, подмена на зеркале или порча по дороге недопустимы.
        # Не совпало — стоп. Контрольных сумм нет (старый релиз, зеркало без
        # них) — предупреждаем и идём дальше, чтобы не сломать прежние релизы;
        # VLESSCHROME_REQUIRE_CHECKSUM=1 превращает это в отказ.
        # Ограничение: суммы лежат там же, где архив, так что от взлома самого
        # источника это не защищает, только от порчи и несоответствия файлов.
        $expected = $null
        if ($sumsUrl) {
            try {
                $content = (Invoke-WebRequest -Uri $sumsUrl -UseBasicParsing -TimeoutSec 30).Content
                if ($content -is [byte[]]) { $content = [Text.Encoding]::UTF8.GetString($content) }
                $expected = Get-ExpectedSha256 -SumsText $content -FileName $archiveName -Mask $assetMask
            } catch { }
        }
        if ($expected) {
            $actual = (Get-FileHash -Path $zip -Algorithm SHA256).Hash.ToLower()
            if ($actual -ne $expected) {
                Write-Fail "контрольная сумма не совпала — архив повреждён или подменён, установка прервана"
                Write-Host "  ожидалось $expected" -ForegroundColor Gray
                Write-Host "  получено  $actual" -ForegroundColor Gray
                Wait-OnError; return
            }
            Write-Ok "SHA-256 совпала"
        } elseif ($env:VLESSCHROME_REQUIRE_CHECKSUM -eq '1') {
            Write-Fail "SHA256SUMS недоступен, а VLESSCHROME_REQUIRE_CHECKSUM=1 — установка прервана"
            Wait-OnError; return
        } else {
            Write-Host "  [!] SHA256SUMS не найден или не содержит этот архив — целостность не проверена" -ForegroundColor Yellow
        }

        # ─── [3/4] Распаковка ────────────────────────────────────
        # Каталог перезаписывается целиком: он хранит только распакованный релиз,
        # пользовательские настройки лежат в %LOCALAPPDATA%\VLESSChrome.
        Write-Step "[3/4] Распаковка в $appDir..."
        if (Test-Path $appDir) { Remove-Item $appDir -Recurse -Force }
        New-Item -ItemType Directory -Path $appDir -Force | Out-Null
        Expand-Archive -Path $zip -DestinationPath $appDir -Force

        # В архиве корень может быть вложенной папкой — поднимаем содержимое.
        $inner = Get-ChildItem $appDir
        if ($inner.Count -eq 1 -and $inner[0].PSIsContainer) {
            Get-ChildItem $inner[0].FullName -Force | Move-Item -Destination $appDir -Force
            Remove-Item $inner[0].FullName -Recurse -Force
        }

        # По умолчанию — вариант с native_host.exe: Python на машине не нужен.
        # Раньше здесь всегда звался корневой install.ps1 (нужен Python), и при
        # его отсутствии скрипт печатал "установите Python" и закрывал консоль.
        if ($env:VLESSCHROME_USE_PYTHON) {
            $installer = Join-Path $appDir 'install.ps1'
            $variant = 'Python'
        } else {
            $installer = Join-Path $appDir 'installer\install.ps1'
            $variant = 'exe (без Python)'
        }
        if (-not (Test-Path $installer)) {
            Write-Fail "$installer не найден в архиве"
            Wait-OnError; return
        }
        Write-Ok "готово ($variant)"

        # ─── [4/4] Установка ─────────────────────────────────────
        Write-Step "[4/4] Запуск установщика..."
        # Установщику ставим NONINTERACTIVE, чтобы он не ждал Enter. Прежнее
        # значение возвращаем, а не удаляем переменную: её мог задать сам
        # пользователь (автоматизация), и Wait-OnError ниже должен её увидеть.
        $prevNonInteractive = $env:VLESSCHROME_NONINTERACTIVE
        $env:VLESSCHROME_NONINTERACTIVE = '1'
        $code = 0
        try {
            & $installer
            $code = $LASTEXITCODE
        } finally {
            if ($null -eq $prevNonInteractive) {
                Remove-Item Env:\VLESSCHROME_NONINTERACTIVE -ErrorAction SilentlyContinue
            } else {
                $env:VLESSCHROME_NONINTERACTIVE = $prevNonInteractive
            }
        }
        # `exit` внутри самого установщика (отдельный .ps1) завершает только его.
        if ($code -ne 0) {
            Write-Fail "установщик завершился с кодом $code"
            $global:LASTEXITCODE = $code
            Wait-OnError $code; return
        }

        # install.ps1 уже напечатал, что делать дальше — здесь только открываем
        # папку расширения, чтобы её не искать вручную.
        $extDir = Join-Path $appDir 'extension'
        if (Test-Path $extDir) { Start-Process explorer.exe $extDir }
    } catch {
        # Любая неожиданная ошибка (нет места, антивирус, права) — тоже без
        # закрытия окна и с читаемым текстом.
        Write-Fail "ошибка установки: $($_.Exception.Message)"
        Wait-OnError
    } finally {
        if ($zip) { Remove-Item $zip -Force -ErrorAction SilentlyContinue }
        [Console]::OutputEncoding = $prevEncoding
    }
}

Invoke-VlessConnectorInstall
