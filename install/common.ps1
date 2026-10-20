# ============================================================
# Общая логика установщиков. Подключается через dot-source:
#
#     . "$projectDir\install\common.ps1"
#
# Появился потому, что install.ps1 (Python-вариант) и
# installer\install.ps1 (вариант с native_host.exe) содержали ~150 строк
# дословно скопированной логики: загрузка Xray и гео-баз, генерация
# манифеста, регистрация в браузерах. Правка в одном месте молча
# расходилась с другим.
#
# Оба установщика отличаются ровно одним: что писать в "path" манифеста —
# native-host.bat или native_host.exe. Всё остальное общее.
# ============================================================

$FallbackXrayVersion = "26.3.27"
$GeoFiles = @('geoip.dat', 'geosite.dat')

# Счётчик ошибок. При dot-source переменная и функции попадают в область
# видимости вызывающего скрипта, поэтому обе стороны видят один экземпляр.
$script:VlessErrors = 0

function Write-Ok($m)   { Write-Host "  [OK] $m"   -ForegroundColor Green }
function Write-Warn($m) { Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Write-Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:VlessErrors++ }
function Write-Step($m) { Write-Host ""; Write-Host $m -ForegroundColor White }
function Get-VlessErrors { return $script:VlessErrors }

function Write-Utf8NoBom($path, $text) {
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding $false))
}

function Remove-FileQuiet($path) {
    # -ErrorAction SilentlyContinue не спасает от ошибок привязки параметров
    # (в этом окружении Remove-Item спотыкается о короткие пути вида
    # C:\Users\ACBFA~1.BAR), а такая ошибка ломала возврат значения из
    # вызывающей функции. Глушим явно.
    if (-not $path) { return }
    try { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } catch { }
}

function Remove-DirQuiet($path) {
    if (-not $path) { return }
    try { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

function Remove-DirectoryChecked {
    <#
        Удаляет каталог и ЧЕСТНО сообщает результат. Remove-Item с
        SilentlyContinue молчит о занятых файлах, и «Удалено» печаталось даже
        тогда, когда половина каталога осталась на диске.

        Возвращает объект: Existed (был ли каталог), Removed (исчез ли
        полностью), Remaining (сколько файлов осталось).
    #>
    param([Parameter(Mandatory)] [string] $Path, [int] $Attempts = 3, [int] $DelayMs = 400)
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Existed = $false; Removed = $true; Remaining = 0 }
    }
    for ($i = 1; $i -le $Attempts; $i++) {
        Remove-DirQuiet $Path
        if (-not (Test-Path -LiteralPath $Path)) { break }
        if ($i -lt $Attempts) { Start-Sleep -Milliseconds $DelayMs }
    }
    $gone = -not (Test-Path -LiteralPath $Path)
    $left = 0
    if (-not $gone) {
        $left = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue).Count
    }
    return [pscustomobject]@{ Existed = $true; Removed = $gone; Remaining = $left }
}

# ─── Обновление поверх запущенного хоста ─────────────────────────────────
#
# Windows не даёт удалить или заменить файлы, которые использует работающий
# процесс. При переустановке во время активного подключения это бьёт сразу
# в двух местах: в _internal\ (DLL и .pyd native_host.exe) и в xray.exe.
# Проверено на копии: Remove-Item -Recurse по _internal оставил 11 файлов из
# 31 (13 не удалились), старый хост продолжал жить, а ЛЮБОЙ новый запуск —
# а расширение запускает хост на каждый ping/stop/status — завершался без
# ответа. Установка оказывалась испорчена до повторного запуска установщика.
#
# Поэтому: (1) останавливаем наши процессы, (2) новую версию сначала
# целиком копируем рядом, (3) меняем местами быстрым переименованием. Если
# что-то пошло не так до обмена — старая версия остаётся нетронутой.

function Get-InstallProcesses {
    <#
        Процессы, запущенные ИЗ каталога установки.

        Отбор строго по пути, а не по имени: у пользователя могут работать
        другие xray (v2rayN, Nekoray, служба), их трогать нельзя. Путь чужих
        процессов недоступен без прав — такие молча пропускаются.
    #>
    param(
        [Parameter(Mandatory)] [string] $InstallDir,
        [string[]] $Names = @('native_host', 'xray')
    )
    $dir = ([IO.Path]::GetFullPath($InstallDir)).TrimEnd('\') + '\'
    foreach ($p in @(Get-Process -Name $Names -ErrorAction SilentlyContinue)) {
        $path = $null
        try { $path = $p.Path } catch { }
        if ($path -and $path.StartsWith($dir, [StringComparison]::OrdinalIgnoreCase)) { $p }
    }
}

function Stop-InstallProcesses {
    <#
        Останавливает процессы из каталога установки и ЖДЁТ, пока они реально
        исчезнут: Stop-Process возвращается раньше, чем освобождаются файлы.
        Возвращает список остановленных процессов (пустой — ничего не было).
    #>
    param(
        [Parameter(Mandatory)] [string] $InstallDir,
        [string[]] $Names = @('native_host', 'xray'),
        [int] $TimeoutSec = 8
    )
    $procs = @(Get-InstallProcesses -InstallDir $InstallDir -Names $Names)
    if ($procs.Count -eq 0) { return @() }

    foreach ($p in $procs) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { }
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (@(Get-InstallProcesses -InstallDir $InstallDir -Names $Names).Count -eq 0) { break }
        Start-Sleep -Milliseconds 200
    }
    return $procs
}

function Move-WithRetry {
    # Переименование может на мгновение упереться в антивирус или индексатор,
    # которые ещё держат только что освобождённые файлы.
    param([string] $From, [string] $To, [bool] $IsDirectory, [int] $Attempts = 10, [int] $DelayMs = 300)
    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            if ($IsDirectory) { [IO.Directory]::Move($From, $To) }
            else { Move-Item -LiteralPath $From -Destination $To -Force -ErrorAction Stop }
            return
        } catch {
            if ($i -eq $Attempts) { throw }
            Start-Sleep -Milliseconds $DelayMs
        }
    }
}

function Install-DirectoryAtomic {
    <#
        Заменяет каталог Target содержимым Source так, чтобы при любом сбое
        до обмена Target остался прежним.

        Порядок: копия в Target.new -> Target в Target.old -> Target.new в
        Target -> удаление Target.old. Единственное «опасное» окно — между
        двумя переименованиями, это миллисекунды, и при сбое второго первое
        откатывается.
    #>
    param([Parameter(Mandatory)] [string] $Source, [Parameter(Mandatory)] [string] $Target)

    $new = "$Target.new"
    $old = "$Target.old"

    # Остатки прошлого оборванного запуска. Если оборвало ровно между двумя
    # переименованиями, Target отсутствует, а прежняя версия лежит в .old —
    # возвращаем её, иначе потеряем рабочую установку.
    if ((Test-Path -LiteralPath $old) -and -not (Test-Path -LiteralPath $Target)) {
        Move-WithRetry -From $old -To $Target -IsDirectory $true
    }
    Remove-DirQuiet $new
    Remove-DirQuiet $old

    try {
        Copy-Item -LiteralPath $Source -Destination $new -Recurse -Force -ErrorAction Stop
    } catch {
        Remove-DirQuiet $new
        throw
    }

    if (Test-Path -LiteralPath $Target) {
        try {
            Move-WithRetry -From $Target -To $old -IsDirectory $true
        } catch {
            Remove-DirQuiet $new
            throw "каталог занят и не может быть заменён ($Target): $($_.Exception.Message)"
        }
    }
    try {
        Move-WithRetry -From $new -To $Target -IsDirectory $true
    } catch {
        # Вернуть всё, как было: лучше старая версия, чем никакой.
        if (Test-Path -LiteralPath $old) { try { Move-WithRetry -From $old -To $Target -IsDirectory $true } catch { } }
        Remove-DirQuiet $new
        throw
    }
    Remove-DirQuiet $old
}

function Install-FileAtomic {
    <# То же для одного файла: копия рядом, затем перенос поверх прежнего. #>
    param([Parameter(Mandatory)] [string] $Source, [Parameter(Mandatory)] [string] $Target)

    $new = "$Target.new"
    Remove-FileQuiet $new
    try {
        Copy-Item -LiteralPath $Source -Destination $new -Force -ErrorAction Stop
        Move-WithRetry -From $new -To $Target -IsDirectory $false
    } catch {
        Remove-FileQuiet $new
        throw
    }
}

function Install-NativeHostExe {
    <#
        Ставит собранный native_host.exe (+ _internal\) в каталог установки,
        в том числе поверх запущенного. Бросает исключение при неудаче; к
        этому моменту прежняя версия либо на месте, либо уже заменена целиком.
    #>
    param([Parameter(Mandatory)] [string] $DistDir, [Parameter(Mandatory)] [string] $InstallDir)

    $stopped = @(Stop-InstallProcesses -InstallDir $InstallDir)
    if ($stopped.Count -gt 0) {
        $names = ($stopped | ForEach-Object { $_.ProcessName } | Sort-Object -Unique) -join ', '
        Write-Warn "Остановлено запущенное: $names — активное подключение разорвано, после установки подключитесь заново"
    }
    Install-DirectoryAtomic -Source "$DistDir\_internal" -Target "$InstallDir\_internal"
    Install-FileAtomic -Source "$DistDir\native_host.exe" -Target "$InstallDir\native_host.exe"
}

function Install-XrayBinary {
    <# Заменяет xray.exe, при необходимости остановив наш работающий xray. #>
    param([Parameter(Mandatory)] [string] $Source, [Parameter(Mandatory)] [string] $InstallDir)

    $stopped = @(Stop-InstallProcesses -InstallDir $InstallDir -Names @('xray'))
    if ($stopped.Count -gt 0) {
        Write-Warn "Остановлен работающий xray.exe — активное подключение разорвано, подключитесь заново"
    }
    Install-FileAtomic -Source $Source -Target "$InstallDir\xray.exe"
}

function Resolve-PythonExe {
    <#
        Ищет НАСТОЯЩИЙ интерпретатор.

        Get-Command часто находит только App Execution Alias из WindowsApps —
        заглушку, которую Windows сама кладёт на PATH. При вызове через
        `cmd /c "..."` она работает, а вот при PowerShell-сплаттинге
        (& $cmd @args -m ...) не пробрасывает аргументы во вложенный
        интерпретатор: вместо модуля запускается интерактивный Python,
        который в безоконном процессе виснет в бесконечном цикле
        (WinError 123/6 в pyrepl). Поэтому при отсутствии обычного python
        на PATH берём путь из реестра, куда себя прописывает установщик
        с python.org, а не полагаемся на алиас.
    #>
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
        foreach ($v in (Get-ChildItem $hive -ErrorAction SilentlyContinue | Sort-Object PSChildName -Descending)) {
            $ip = Get-ItemProperty -Path "$($v.PSPath)\InstallPath" -ErrorAction SilentlyContinue
            if (-not $ip.'(default)') { continue }
            $exe = Join-Path $ip.'(default)'.TrimEnd('\') 'python.exe'
            if (Test-Path $exe) { return $exe }
        }
    }
    return $null
}

function Get-XrayVersion {
    <#
        Версия установленного xray, либо $null.

        `xray version` печатает первой строкой:
            Xray 26.3.27 (Xray, Penetrates Everything.) d2758a0 (go1.26.1 ...)
    #>
    param([string] $Path)

    if (-not $Path -or -not (Test-Path $Path)) { return $null }
    try {
        $out = & $Path version 2>$null | Select-Object -First 1
        $m = [regex]::Match([string] $out, 'Xray\s+(\d+\.\d+\.\d+)')
        if ($m.Success) { return $m.Groups[1].Value }
    } catch {
        # Битый или несовместимый бинарник — считаем версию неизвестной,
        # тогда вызывающий код просто перекачает его заново.
    }
    return $null
}

function Get-LatestXrayVersion {
    <#
        Последняя версия Xray с GitHub, либо $null при недоступности API.
        $null означает «не знаю» — обновление в этом случае не навязываем,
        чтобы отсутствие сети не ломало установку.
    #>
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/XTLS/Xray-core/releases/latest" `
            -Headers @{ 'User-Agent' = 'VLESSChrome-installer' } -TimeoutSec 20
        if ($release.tag_name) { return $release.tag_name.TrimStart('v') }
    } catch {
        Write-Warn "GitHub API недоступен — проверка версии Xray пропущена"
    }
    return $null
}

function Test-Sha256FromDgst {
    <#
        Сверяет файл с контрольной суммой из .dgst, лежащего рядом с архивом
        в релизе Xray.

        $false возвращается ТОЛЬКО при реальном несовпадении — файл при этом
        удаляется, продолжать нельзя. Если .dgst недоступен или не разобрался,
        возвращаем $true с предупреждением: рвать установку из-за
        недоступности вспомогательного файла неправильно.
    #>
    param(
        [Parameter(Mandatory)] [string] $File,
        [Parameter(Mandatory)] [string] $Url
    )

    # Итог считаем в переменную и возвращаем один раз в конце: любая ошибка
    # внутри try уводила управление в finally мимо `return $false`, и функция
    # отдавала пустоту — то есть подменённый архив проходил как исправный.
    $verdict = $true
    $dgst = "$File.dgst"

    try {
        Invoke-WebRequest -Uri "$Url.dgst" -OutFile $dgst `
            -UserAgent 'Mozilla/5.0' -TimeoutSec 60
    } catch {
        Write-Warn "Не удалось скачать .dgst — проверка контрольной суммы пропущена"
        Remove-FileQuiet $dgst
        return $true
    }

    try {
        $content = Get-Content $dgst -Raw
        $m = [regex]::Match($content, '(?im)^SHA2-256\s*=\s*([0-9a-fA-F]{64})')
        if (-not $m.Success) {
            $m = [regex]::Match($content, '(?im)SHA256\s*\([^)]*\)\s*=\s*([0-9a-fA-F]{64})')
        }
        if (-not $m.Success) {
            Write-Warn "Не удалось разобрать .dgst — проверка пропущена"
        } else {
            $expected = $m.Groups[1].Value.ToLower()
            $actual = (Get-FileHash -Path $File -Algorithm SHA256).Hash.ToLower()
            if ($actual -ne $expected) {
                Write-Host "  [FAIL] Контрольная сумма НЕ совпадает!" -ForegroundColor Red
                Write-Host "         Ожидалось: $expected" -ForegroundColor Red
                Write-Host "         Получено:  $actual" -ForegroundColor Red
                $verdict = $false
            } else {
                Write-Ok "SHA-256 совпадает"
            }
        }
    } catch {
        # Не смогли проверить — это не повод считать файл подменённым,
        # но и молчать нельзя.
        Write-Warn "Проверка контрольной суммы не выполнена: $_"
    }

    Remove-FileQuiet $dgst
    if (-not $verdict) { Remove-FileQuiet $File }
    return $verdict
}

function Install-XrayAndGeo {
    <#
        Обеспечивает наличие xray.exe и гео-баз в каталоге установки.

        Источники по убыванию приоритета: уже установленное -> кэш в bin\
        (его наполняет download-xray.bat) -> загрузка архива с GitHub.
        Гео-базы едут в том же архиве, отдельной загрузки не требуется.
    #>
    param(
        [Parameter(Mandatory)] [string] $ProjectDir,
        [Parameter(Mandatory)] [string] $InstallDir
    )

    # Последнюю версию узнаём заранее: от неё зависит не только загрузка, но
    # и решение, не устарел ли уже установленный бинарник.
    $script:LatestXrayVersion = Get-LatestXrayVersion

    $xrayTarget = "$InstallDir\xray.exe"
    $geoMissing = @($GeoFiles | Where-Object { -not (Test-Path "$InstallDir\$_") })

    # Раньше проверялось только наличие файла, и установленный однажды xray
    # не обновлялся никогда. У пользователя так остался 1.8.7 (2023 год), а
    # его сервер использовал транспорт xhttp, которого в той версии нет —
    # подключение падало с «unknown transport protocol: xhttp».
    $installedVersion = Get-XrayVersion $xrayTarget
    $xrayMissing = -not (Test-Path $xrayTarget)
    $needXray = $xrayMissing
    $replaceFailed = $false

    if (-not $needXray -and $installedVersion -and $LatestXrayVersion `
            -and $installedVersion -ne $LatestXrayVersion) {
        Write-Warn "xray.exe устарел: v$installedVersion, доступна v$LatestXrayVersion"
        $needXray = $true
    }

    if ($needXray -and (Test-Path "$ProjectDir\bin\xray.exe")) {
        $cached = Get-XrayVersion "$ProjectDir\bin\xray.exe"
        # Когда файла нет вовсе, годится любой кэш — лучше рабочий бинарник,
        # чем ничего. А если мы пришли сюда из-за устаревшей версии, кэш
        # обязан быть проверяемо свежим: иначе «обновление» подсунуло бы
        # такой же старый или битый файл, и ошибка вернулась бы к пользователю.
        $cacheOk = if ($xrayMissing) {
            $true
        } else {
            $cached -and $LatestXrayVersion -and $cached -eq $LatestXrayVersion
        }
        if ($cacheOk) {
            try {
                Install-XrayBinary -Source "$ProjectDir\bin\xray.exe" -InstallDir $InstallDir
                Write-Ok "xray.exe взят из bin\$(if ($cached) { " (v$cached)" })"
            } catch {
                # Качать заново бессмысленно: упёрлись не в отсутствие файла, а в
                # невозможность его заменить.
                Write-Fail "Не удалось заменить xray.exe: $($_.Exception.Message)"
                $replaceFailed = $true
            }
            $needXray = $false
        } else {
            Write-Host "  Кэш в bin\ не подходит$(if ($cached) { " (v$cached)" } else { ' (версия не читается)' }) — качаю" -ForegroundColor Gray
        }
    }
    if (-not $needXray -and -not $replaceFailed) {
        $v = Get-XrayVersion $xrayTarget
        Write-Ok "xray.exe установлен$(if ($v) { " (v$v)" })"
    }

    foreach ($geo in @($geoMissing)) {
        if (Test-Path "$ProjectDir\bin\$geo") {
            Copy-Item "$ProjectDir\bin\$geo" "$InstallDir\$geo" -Force
            Write-Ok "$geo взят из bin\"
        }
    }
    $geoMissing = @($GeoFiles | Where-Object { -not (Test-Path "$InstallDir\$_") })

    # Качаем, если не хватает хоть чего-то: у прежних установок есть xray.exe,
    # но нет гео-баз — им тоже нужен архив.
    if (-not ($needXray -or $geoMissing.Count -gt 0)) {
        Write-Ok "Гео-базы на месте"
        return
    }

    if (-not $needXray) {
        Write-Host "  Гео-базы отсутствуют ($($geoMissing -join ', ')) — нужен архив" -ForegroundColor Gray
    }

    # Версию уже выяснили выше, до решения об обновлении.
    $xrayVersion = if ($LatestXrayVersion) { $LatestXrayVersion } else { $FallbackXrayVersion }

    $zip = "$InstallDir\xray.zip"
    $tmp = "$InstallDir\xray-temp"
    Write-Host "  Загрузка Xray-core v$xrayVersion (~25 МБ)..." -ForegroundColor Gray
    try {
        $xrayUrl = "https://github.com/XTLS/Xray-core/releases/download/v$xrayVersion/Xray-windows-64.zip"
        Invoke-WebRequest -Uri $xrayUrl -OutFile $zip -UserAgent 'Mozilla/5.0' -TimeoutSec 300

        # Бинарник получит полный доступ к трафику — распаковывать его без
        # проверки нельзя. Обрыв на 25 МБ даёт «успешно скачанный» битый файл,
        # и заметно это только по контрольной сумме.
        if (-not (Test-Sha256FromDgst -File $zip -Url $xrayUrl)) {
            Write-Fail "Архив Xray повреждён или подменён — установка прервана"
            return
        }

        if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
        Expand-Archive -Path $zip -DestinationPath $tmp -Force

        if ($needXray) {
            if (Test-Path "$tmp\xray.exe") {
                try {
                    Install-XrayBinary -Source "$tmp\xray.exe" -InstallDir $InstallDir
                    Write-Ok "xray.exe v$xrayVersion установлен"
                } catch {
                    Write-Fail "Не удалось заменить xray.exe: $($_.Exception.Message)"
                }
            } else {
                Write-Fail "xray.exe не найден в архиве"
            }
        }

        foreach ($geo in $GeoFiles) {
            if (Test-Path "$tmp\$geo") {
                Copy-Item "$tmp\$geo" "$InstallDir\$geo" -Force
                $mb = [math]::Round((Get-Item "$InstallDir\$geo").Length / 1MB, 1)
                Write-Ok "$geo обновлён ($mb МБ)"
            } else {
                Write-Warn "$geo не найден в архиве — маршрутизация по гео работать не будет"
            }
        }
    } catch {
        Write-Fail "Не удалось скачать Xray: $_"
        Write-Host "       Скачайте вручную с https://github.com/XTLS/Xray-core/releases" -ForegroundColor Gray
        Write-Host "       и распакуйте xray.exe, geoip.dat, geosite.dat в $InstallDir" -ForegroundColor Gray
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
    }
}

function Register-NativeHost {
    <#
        Пишет манифест native host и регистрирует его во всех
        Chromium-браузерах пользователя.

        HostPath — единственное, чем отличаются два установщика:
        native-host.bat (Python) либо native_host.exe (PyInstaller).

        Возвращает @{ Origin; OriginChanged } либо $null, если продолжать
        нельзя (нет шаблона / в нём остался плейсхолдер).
    #>
    param(
        [Parameter(Mandatory)] [string] $Template,
        [Parameter(Mandatory)] [string] $InstallDir,
        [Parameter(Mandatory)] [string] $HostPath
    )

    if (-not (Test-Path $Template)) {
        Write-Fail "Шаблон манифеста не найден: $Template"
        return $null
    }

    # Шаблон в репозитории — единственный источник Extension ID
    # (его проставляет install\gen-extension-key.py).
    $manifest = Get-Content $Template -Raw -Encoding UTF8 | ConvertFrom-Json
    $manifest.path = $HostPath -replace '\\', '/'
    $extOrigin = $manifest.allowed_origins[0]

    if ($extOrigin -match 'EXTENSION_ID_PLACEHOLDER') {
        Write-Fail "В шаблоне остался плейсхолдер вместо Extension ID"
        Write-Host "       Запустите: py -3 install\gen-extension-key.py --manifest extension\manifest.json --host-manifest install\native-host-manifest.json" -ForegroundColor Gray
        return $null
    }

    $manifestPath = "$InstallDir\native-host-manifest.json"
    $originChanged = $false
    if (Test-Path $manifestPath) {
        try {
            $old = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($old.allowed_origins[0] -ne $extOrigin) { $originChanged = $true }
        } catch { $originChanged = $true }
    }

    Write-Utf8NoBom $manifestPath ($manifest | ConvertTo-Json -Depth 10)
    Write-Ok "Манифест: $manifestPath"
    Write-Host "       path -> $(Split-Path -Leaf $HostPath)" -ForegroundColor Gray
    Write-Host "       Extension ID: $($extOrigin -replace 'chrome-extension://|/','')" -ForegroundColor Gray

    $browsers = @(
        @{ Name="Chrome";         Key="HKCU:\Software\Google\Chrome\NativeMessagingHosts\com.vlesschrome.host" },
        @{ Name="Edge";           Key="HKCU:\Software\Microsoft\Edge\NativeMessagingHosts\com.vlesschrome.host" },
        @{ Name="Яндекс Браузер"; Key="HKCU:\Software\Yandex\YandexBrowser\NativeMessagingHosts\com.vlesschrome.host" },
        @{ Name="Brave";          Key="HKCU:\Software\BraveSoftware\Brave-Browser\NativeMessagingHosts\com.vlesschrome.host" },
        @{ Name="Chromium";       Key="HKCU:\Software\Chromium\NativeMessagingHosts\com.vlesschrome.host" }
    )

    $registered = 0
    foreach ($b in $browsers) {
        try {
            if (-not (Test-Path $b.Key)) { New-Item -Path $b.Key -Force | Out-Null }
            Set-ItemProperty -Path $b.Key -Name "(default)" -Value $manifestPath -Force -ErrorAction Stop
            Write-Ok $b.Name
            $registered++
        } catch {
            $regKey = $b.Key -replace '^HKCU:\\', 'HKCU\'
            & reg add $regKey /ve /t REG_SZ /d $manifestPath /f | Out-Null
            if ($LASTEXITCODE -eq 0) { Write-Ok $b.Name; $registered++ }
            else { Write-Host "  [SKIP] $($b.Name)" -ForegroundColor DarkGray }
        }
    }
    if ($registered -eq 0) { Write-Fail "Не удалось зарегистрировать ни в одном браузере" }

    return @{ Origin = $extOrigin; OriginChanged = $originChanged }
}
