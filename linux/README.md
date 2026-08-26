# VLESS Chrome Extension — Установка на Linux

## Требования

- Python 3.6+ (`python3 --version`)
- pip3 (`python3 -m pip --version`)
- wget или curl
- unzip
- Chromium-based браузер (Chrome, Chromium, Яндекс Браузер, Edge, Brave)

### Установка зависимостей (Ubuntu/Debian)

```bash
sudo apt update
sudo apt install python3 python3-pip wget unzip
```

### Установка зависимостей (Fedora)

```bash
sudo dnf install python3 python3-pip wget unzip
```

### Установка зависимостей (Arch)

```bash
sudo pacman -S python python-pip wget unzip
```

---

## Быстрая установка

```bash
# 1. Сделать скрипты исполняемыми
chmod +x linux/*.sh linux/install/*.sh

# 2. Установить всё одной командой (зависимости + Xray + регистрация)
./linux/quick-install.sh

# 3. Загрузить расширение в браузер
#    Откройте chrome://extensions/
#    Включите "Режим разработчика"
#    Нажмите "Загрузить распакованное расширение"
#    Выберите папку extension/
```

Копировать Extension ID и перезапускать браузер не нужно: ID закреплён полем
`key` в `extension/manifest.json`, поэтому манифест native host уже содержит
правильный `allowed_origins`.

---

## Описание файлов

| Файл | Описание |
|------|----------|
| `native-host-python/` | Модули Native Messaging Host — общие для Linux и Windows |
| `linux/native-host.sh` | Обёртка для запуска native_host.py |
| `linux/requirements.txt` | Зависимости Python (psutil) |
| `linux/download-xray.sh` | Скрипт загрузки Xray-core |
| `linux/check-connection.sh` | Проверка установки |
| `linux/install/install.sh` | Скрипт установки |
| `linux/install/uninstall.sh` | Скрипт удаления |
| `linux/quick-install.sh` | Установка одной командой |
| `linux/install/update-extension-id.sh` | Ручная правка Extension ID (запасной путь) |
| `linux/install/native-host-manifest.json` | Шаблон манифеста (в нём зашит Extension ID) |

---

## Пути на Linux

| Компонент | Путь |
|-----------|------|
| Конфиги и данные | `~/.config/VLESSChrome/` |
| Xray бинарник | `~/.config/VLESSChrome/xray` |
| Логи | `~/.config/VLESSChrome/native-host.log` |
| Манифест Chrome | `~/.config/google-chrome/NativeMessagingHosts/com.vlesschrome.host.json` |
| Манифест Chromium | `~/.config/chromium/NativeMessagingHosts/com.vlesschrome.host.json` |
| Манифест Яндекс | `~/.config/yandex-browser/NativeMessagingHosts/com.vlesschrome.host.json` |
| Манифест Edge | `~/.config/microsoft-edge/NativeMessagingHosts/com.vlesschrome.host.json` |
| Манифест Brave | `~/.config/BraveSoftware/Brave-Browser/NativeMessagingHosts/com.vlesschrome.host.json` |

---

## Различия с Windows

| Windows | Linux |
|---------|-------|
| `%LOCALAPPDATA%\VLESSChrome` | `~/.config/VLESSChrome` |
| `xray.exe` | `xray` |
| `native-host.bat` | `native-host.sh` |
| Реестр Windows | JSON файлы в `NativeMessagingHosts/` |
| `.bat` скрипты | `.sh` скрипты |
| PowerShell `.ps1` | Bash `.sh` |
| `subprocess.CREATE_NO_WINDOW` | Не требуется |

---

## Устранение неполадок

### Расширение не подключается к Native Host

```bash
# Проверка установки
./linux/check-connection.sh

# Проверка логов
cat ~/.config/VLESSChrome/native-host.log

# Проверка манифеста
cat ~/.config/google-chrome/NativeMessagingHosts/com.vlesschrome.host.json

# Проверка прав на исполнение
ls -la ~/.config/VLESSChrome/native-host.sh
ls -la ~/.config/VLESSChrome/xray
```

### Xray не запускается

```bash
# Проверка прав
chmod +x ~/.config/VLESSChrome/xray

# Ручной запуск для проверки
~/.config/VLESSChrome/xray version

# Проверка логов xray
cat ~/.config/VLESSChrome/xray_default.log
```

### Permission denied

```bash
# Сделать все скрипты исполняемыми
chmod +x linux/*.sh linux/install/*.sh
chmod +x ~/.config/VLESSChrome/native-host.sh
chmod +x ~/.config/VLESSChrome/xray
```

---

## Удаление

```bash
./linux/install/uninstall.sh
```

Не забудьте также удалить расширение из браузера: `chrome://extensions/`
