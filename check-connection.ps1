[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$installDir = "$env:LOCALAPPDATA\VLESSChrome"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "VLESS Chrome - Проверка подключения" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "Конфиги Xray (последний изменённый):" -ForegroundColor White
Write-Host "----------------------------------------"
$cfg = Get-ChildItem "$installDir\config_*.json" -ErrorAction SilentlyContinue |
       Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($cfg) {
    Write-Host "Файл: $($cfg.Name)" -ForegroundColor Green
    Get-Content $cfg.FullName
} else {
    Write-Host "Конфиги не найдены" -ForegroundColor Yellow
}
Write-Host ""

Write-Host "Последние 20 строк Xray лога (последний изменённый):" -ForegroundColor White
Write-Host "----------------------------------------"
$xlog = Get-ChildItem "$installDir\xray_*.log" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($xlog) {
    Write-Host "Файл: $($xlog.Name)" -ForegroundColor Green
    Get-Content $xlog.FullName -Tail 20
} else {
    Write-Host "Логи Xray не найдены" -ForegroundColor Yellow
}
Write-Host ""

Write-Host "Последние 10 строк Native Host лога:" -ForegroundColor White
Write-Host "----------------------------------------"
$nhLog = "$installDir\native-host.log"
if (Test-Path $nhLog) {
    Get-Content $nhLog -Tail 10
} else {
    Write-Host "Лог native-host.log не найден" -ForegroundColor Yellow
}
Write-Host ""
Read-Host "Нажмите Enter для выхода"
