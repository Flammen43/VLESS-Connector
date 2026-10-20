[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Остановка процессов и честная проверка удаления — общие с установщиками.
. "$PSScriptRoot\common.ps1"

function Exit-Uninstaller($code) {
    if ($env:VLESSCHROME_NONINTERACTIVE -ne '1') { Read-Host "Нажмите Enter для выхода" }
    exit $code
}

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "VLESS Chrome Extension - Удаление" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$installDir = "$env:LOCALAPPDATA\VLESSChrome"
# Сюда ставит web-install.ps1 (установка одной командой): там лежит распакованный
# релиз с папкой extension, ~100 МБ. Клон репозитория или распакованный вручную
# архив в другом месте — пользовательские, их мы не трогаем.
$webAppDir  = "$env:LOCALAPPDATA\Programs\VLESS-Connector"
$problems   = 0

Write-Host "Удаление из реестра..."

$regKeys = @(
    @{ Name="Chrome";          Key="HKCU\Software\Google\Chrome\NativeMessagingHosts\com.vlesschrome.host" },
    @{ Name="Edge";            Key="HKCU\Software\Microsoft\Edge\NativeMessagingHosts\com.vlesschrome.host" },
    @{ Name="Яндекс Браузер";  Key="HKCU\Software\Yandex\YandexBrowser\NativeMessagingHosts\com.vlesschrome.host" },
    @{ Name="Brave";           Key="HKCU\Software\BraveSoftware\Brave-Browser\NativeMessagingHosts\com.vlesschrome.host" },
    @{ Name="Chromium";        Key="HKCU\Software\Chromium\NativeMessagingHosts\com.vlesschrome.host" }
)

foreach ($entry in $regKeys) {
    $r = & reg delete $entry.Key /f 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Удалено из реестра $($entry.Name)" -ForegroundColor Green
    } else {
        Write-Host "[SKIP] Запись в реестре $($entry.Name) не найдена" -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "Удаление файлов..."
if (Test-Path -LiteralPath $installDir) {
    # Только наши процессы — по пути запуска. Раньше глушились ВСЕ xray.exe,
    # включая v2rayN/Nekoray, если они работали.
    $stopped = @(Stop-InstallProcesses -InstallDir $installDir)
    if ($stopped.Count -gt 0) {
        Write-Host "[OK] Остановлено процессов: $($stopped.Count) ($((($stopped | ForEach-Object { $_.ProcessName } | Sort-Object -Unique) -join ', ')))" -ForegroundColor Green
    }

    $res = Remove-DirectoryChecked -Path $installDir
    if ($res.Removed) {
        Write-Host "[OK] Удалена директория: $installDir" -ForegroundColor Green
    } else {
        $problems++
        Write-Host "[FAIL] Не удалось удалить $($res.Remaining) файл(ов) в $installDir" -ForegroundColor Red
        Write-Host "       Закройте браузер и повторите удаление." -ForegroundColor Gray
    }
} else {
    Write-Host "[SKIP] Директория не найдена: $installDir" -ForegroundColor DarkGray
}

# Папка с расширением от установки одной командой. Проверяем маркер (extension\manifest.json),
# чтобы не снести каталог, совпавший по имени случайно.
if (Test-Path -LiteralPath "$webAppDir\extension\manifest.json") {
    $sizeMb = [math]::Round((Get-ChildItem -LiteralPath $webAppDir -Recurse -File -Force -ErrorAction SilentlyContinue |
        Measure-Object -Property Length -Sum).Sum / 1MB)
    $remove = $true
    if ($env:VLESSCHROME_NONINTERACTIVE -ne '1') {
        $answer = Read-Host "Удалить также папку расширения $webAppDir (~$sizeMb МБ, скачана установкой одной командой)? [Y/n]"
        $remove = ($answer -notmatch '^(n|no|н|нет)$')
    }
    if ($remove) {
        $res = Remove-DirectoryChecked -Path $webAppDir
        if ($res.Removed) {
            Write-Host "[OK] Удалена директория: $webAppDir" -ForegroundColor Green
        } else {
            $problems++
            Write-Host "[FAIL] Не удалось удалить $($res.Remaining) файл(ов) в $webAppDir" -ForegroundColor Red
            Write-Host "       Удалите папку вручную после закрытия браузера и этого окна." -ForegroundColor Gray
        }
    } else {
        Write-Host "[SKIP] Папка расширения оставлена: $webAppDir" -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
if ($problems -gt 0) {
    Write-Host "Удаление завершено с ошибками: $problems" -ForegroundColor Red
} else {
    Write-Host "Удаление завершено!" -ForegroundColor Cyan
}
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Не забудьте удалить расширение из браузера:"
Write-Host "  chrome://extensions/ или browser://extensions/"
Write-Host ""
Exit-Uninstaller $(if ($problems -gt 0) { 1 } else { 0 })
