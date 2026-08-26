[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "VLESS Chrome Extension - Удаление" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$installDir = "$env:LOCALAPPDATA\VLESSChrome"

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
if (Test-Path $installDir) {
    # Остановить xray если запущен
    Get-Process -Name "xray" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Remove-Item $installDir -Recurse -Force
    Write-Host "[OK] Удалена директория: $installDir" -ForegroundColor Green
} else {
    Write-Host "[SKIP] Директория не найдена: $installDir" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Удаление завершено!" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Не забудьте удалить расширение из браузера:"
Write-Host "  chrome://extensions/ или browser://extensions/"
Write-Host ""
Read-Host "Нажмите Enter для выхода"
