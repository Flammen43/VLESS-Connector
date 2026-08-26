[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "VLESS Chrome - Обновление Extension ID" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

$installDir = "$env:LOCALAPPDATA\VLESSChrome"
$manifestPath = "$installDir\native-host-manifest.json"

# Проверка пустого файла
if ((Test-Path $manifestPath) -and (Get-Item $manifestPath).Length -eq 0) {
    Remove-Item $manifestPath -Force
}

if (-not (Test-Path $manifestPath)) {
    Write-Host "[FAIL] Манифест не найден: $manifestPath" -ForegroundColor Red
    Write-Host "Сначала запустите install.bat" -ForegroundColor Yellow
    Write-Host ""
    Read-Host "Нажмите Enter"; exit 1
}

Write-Host "Манифест: $manifestPath"
Write-Host ""

# Показать текущий ID
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
$currentOrigins = $manifest.allowed_origins -join ", "
Write-Host "Текущие origins: $currentOrigins" -ForegroundColor Gray
Write-Host ""

# Запрос ID
Write-Host "Введите Extension ID из Chrome/Яндекс Браузера:" -ForegroundColor Yellow
Write-Host "(Скопируйте ID со страницы расширений)" -ForegroundColor Gray
Write-Host ""
$newId = Read-Host "Extension ID"

# Валидация
$newId = $newId.Trim()
if (-not $newId) {
    Write-Host "[FAIL] Extension ID не может быть пустым!" -ForegroundColor Red
    Read-Host "Нажмите Enter"; exit 1
}

if ($newId.Length -lt 20) {
    Write-Host "[WARN] ID кажется коротким ($($newId.Length) символов, обычно 32)" -ForegroundColor Yellow
    $confirm = Read-Host "Продолжить? (y/n)"
    if ($confirm -ne 'y') { exit 1 }
}

Write-Host ""
Write-Host "Обновление манифеста..."

try {
    $newOrigin = "chrome-extension://$newId/"
    $origins = @()

    if ($manifest.allowed_origins) {
        foreach ($o in $manifest.allowed_origins) {
            if ($o -ne "chrome-extension://EXTENSION_ID_PLACEHOLDER/" -and $o -ne $newOrigin) {
                $origins += $o
            }
        }
    }
    $origins += $newOrigin
    $manifest.allowed_origins = $origins

    $manifest | ConvertTo-Json -Depth 10 | Set-Content $manifestPath

    Write-Host "[OK] Манифест обновлен!" -ForegroundColor Green
} catch {
    Write-Host "[FAIL] Ошибка обновления: $_" -ForegroundColor Red
    Read-Host "Нажмите Enter"; exit 1
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Extension ID обновлен!" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "ID: $newId" -ForegroundColor Green
Write-Host ""
Write-Host "ВАЖНО: Полностью перезапустите браузер:" -ForegroundColor Yellow
Write-Host "  1. Закройте все окна Chrome/Яндекс Браузера"
Write-Host "  2. Диспетчер задач (Ctrl+Shift+Esc) → завершите все процессы браузера"
Write-Host "  3. Запустите браузер заново"
Write-Host ""
Read-Host "Нажмите Enter для выхода"
