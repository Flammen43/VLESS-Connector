# VLESS Chrome Extension

Chrome расширение для подключения к VLESS прокси через 3X-UI сервер. Работает только в Chrome, изолируя трафик браузера от остальных приложений.

## ⚡ Быстрый старт (2 минуты)

```cmd
# 1. Установите всё одной командой
install.bat

# 2. Загрузите расширение в Chrome
chrome://extensions/ → "Режим разработчика" → "Загрузить распакованное" → выбрать папку extension

# 3. Проверьте установку (по желанию)
check-installation.bat
```

Копировать Extension ID и перезапускать браузер не нужно: ID закреплён полем
`key` в манифесте расширения, поэтому установщик прописывает его заранее.

**📘 Подробная инструкция:** [INSTALL_GUIDE.md](INSTALL_GUIDE.md)  
**🔧 Проблемы:** [TROUBLESHOOTING.md](TROUBLESHOOTING.md)

## Возможности

- ✅ Подключение к VLESS серверам через VLESS URL
- ✅ Профили WireGuard (вставка `.conf` или загрузка файла)
- ✅ Автоматический запуск и управление Xray-core
- ✅ Изоляция прокси только для Chrome (остальные приложения работают напрямую)
- ✅ Российские сайты в обход VPN — отключаемый переключатель в popup
- ✅ Поддержка различных транспортов (TCP, WebSocket, gRPC, HTTP/2)
- ✅ Поддержка TLS и Reality
- ✅ Динамический локальный SOCKS-порт (не фиксированный 10808)
- ✅ Шифрование сохранённых ключей через Windows DPAPI
- ✅ Удобный UI для управления подключением
- ✅ Статистика времени работы

## Архитектура

```
Chrome Browser
    ↓
Chrome Extension (UI + Proxy API)
    ↓
Native Messaging Host (Python)
    ↓
Xray-core Process
    ↓
VLESS / WireGuard Server
```

- **Chrome Extension** - управление интерфейсом и настройкой прокси
- **Native Messaging Host** - Python скрипт - посредник между расширением и Xray
- **Xray-core** - клиент для подключения к VLESS серверу

## Требования

- **Windows 10/11** — основная платформа
- **Linux** — см. [linux/README.md](linux/README.md)
- **macOS** (Apple Silicon и Intel) — см. [macos/README.md](macos/README.md)
- Google Chrome (или Chromium-based браузер)
- Python 3.7+ — **не нужен**, если ставить через
  [installer/](installer/README.md) (вариант с собранным `native_host.exe`)
- VLESS сервер (например, 3X-UI) и/или WireGuard `.conf`

### Два способа установки (Windows)

| Команда | Native host | Python на машине |
|---|---|---|
| `install.bat` | `native_host.py` | нужен |
| `installer\install.bat` | `native_host.exe` | **не нужен** |

Оба ставят одно и то же в `%LOCALAPPDATA%\VLESSChrome`, используют один
Extension ID и одну запись в реестре — переключаться между ними можно в любую
сторону. Подробности и компромисс с антивирусом: [installer/README.md](installer/README.md).

## Тесты

```cmd
pip install -r requirements-dev.txt
pytest
```

## 🚀 Быстрая установка

**⚡ Для пользователей - см. [INSTALL_GUIDE.md](INSTALL_GUIDE.md) - подробная инструкция с картинками**

### Шаг 1: Скачать проект

**Способ A — одна команда (рекомендуется).** Скачает релиз под вашу
платформу и сразу запускает установку — шаг 2 выполнять не нужно.

Windows (PowerShell):

```powershell
irm https://raw.githubusercontent.com/Flammen43/VLESS-Connector/main/web-install.ps1 | iex
```

Linux и macOS:

```bash
curl -fsSL https://raw.githubusercontent.com/Flammen43/VLESS-Connector/main/web-install.sh | bash
```

Проект ляжет в `%LOCALAPPDATA%\Programs\VLESS-Connector` или
`~/.local/share/VLESS-Connector`. Если GitHub недоступен — укажите зеркало
через переменную `VLESSCHROME_BASE`.

**Способ B — готовый архив вручную.** Возьмите ZIP под свою платформу
на странице [последнего релиза](https://github.com/Flammen43/VLESS-Connector/releases/latest)
и распакуйте:

| Платформа | Архив |
|---|---|
| Windows x64 | `vlesschrome-win-x64-*.zip` |
| Linux x64 | `vlesschrome-linux-x64-*.zip` |
| Linux ARM64 | `vlesschrome-linux-arm64-*.zip` |
| macOS Apple Silicon | `vlesschrome-macos-arm64-*.zip` |
| macOS Intel | `vlesschrome-macos-x64-*.zip` |

Внутри уже лежит Xray-core и гео-базы, поэтому установка идёт без сети
и шаг с загрузкой Xray пропускается.

**Способ C — клонировать репозиторий.** Нужен git; Xray установщик скачает сам:

```bash
git clone https://github.com/Flammen43/VLESS-Connector.git
cd VLESS-Connector
```

### Шаг 2: Установка

Запустите `install.bat` в корне проекта:

```cmd
install.bat
```

Скрипт сделает всё сам:
- поставит зависимости Python (`psutil`);
- скачает Xray-core, если его ещё нет;
- скопирует файлы в `%LOCALAPPDATA%\VLESSChrome\`;
- создаст манифест Native Messaging Host с готовым Extension ID;
- зарегистрирует хост в Chrome, Edge, Яндекс Браузере, Brave и Chromium;
- проверит, что всё встало.

Отдельного шага сборки больше нет — установщик ставит модули прямо из
`native-host-python\`. Скачать Xray заранее можно через `download-xray.bat`,
но обычно это не нужно.

### Шаг 3: Загрузка расширения в Chrome

1. Откройте `chrome://extensions/`
2. Включите **«Режим разработчика»**
3. Нажмите **«Загрузить распакованное расширение»**
4. Выберите папку `extension` из проекта

Готово. **Копировать Extension ID и перезапускать Chrome не нужно** — ID
закреплён полем `key` в `extension/manifest.json` и одинаков на всех машинах,
поэтому манифест native host уже содержит правильный `allowed_origins`.

### Проверка

```cmd
check-installation.bat
```

Показывает состояние Python, файлов, реестра и сверяет Extension ID в манифесте
с ключом расширения.

## Использование

### 1. Получение VLESS URL

Получите VLESS URL из вашего 3X-UI панели. Формат:

```
vless://uuid@server.com:443?encryption=none&security=tls&type=tcp&host=server.com&sni=server.com#MyServer
```

### 2. Подключение

1. Кликните на иконку расширения в Chrome
2. Вставьте VLESS URL в поле
3. Нажмите **"Подключить"**
4. Дождитесь статуса "Подключено"

### 3. Проверка подключения

Проверьте ваш IP:
- Откройте [https://ifconfig.me](https://ifconfig.me)
- IP должен совпадать с IP вашего VLESS сервера

### 4. Отключение

Кликните на иконку расширения и нажмите **"Отключить"**.

### WireGuard

1. В popup выберите вкладку **WireGuard**
2. Вставьте содержимое `.conf` или нажмите **Загрузить .conf**
3. Подключите профиль как обычно

Xray поднимает SOCKS5 на **свободном** порту `127.0.0.1` (не 10808). Расширение подхватывает порт из ответа native host.

DNS из секции `[Interface]` Xray не использует — резолв идёт через Chrome.

На Windows сохранённые VLESS URL и WG-конфиги шифруются DPAPI (привязка к текущему пользователю Windows).

## Поддерживаемые параметры VLESS URL

| Параметр | Описание | Значения | По умолчанию |
|----------|----------|----------|--------------|
| `encryption` | Шифрование | `none` | `none` |
| `security` | Безопасность | `tls`, `reality`, `none` | `tls` |
| `type` | Транспорт | `tcp`, `ws`, `grpc`, `h2` | `tcp` |
| `host` | Host заголовок | домен | адрес сервера |
| `path` | Путь (для WS/gRPC) | `/path` | `/` |
| `sni` | SNI для TLS | домен | адрес сервера |
| `alpn` | ALPN протокол | `h2`, `http/1.1` | `h2,http/1.1` |
| `fp` | TLS fingerprint | `chrome`, `firefox`, `safari` | `chrome` |

### Примеры VLESS URL

**TCP + TLS:**
```
vless://uuid@example.com:443?security=tls&type=tcp&sni=example.com#MyServer
```

**WebSocket + TLS:**
```
vless://uuid@example.com:443?security=tls&type=ws&path=/path&host=example.com&sni=example.com#MyServer
```

**gRPC + TLS:**
```
vless://uuid@example.com:443?security=tls&type=grpc&serviceName=grpcService&sni=example.com#MyServer
```

## Устранение неполадок

### Расширение не подключается

1. **Проверьте логи Native Host:**
   ```
   %LOCALAPPDATA%\VLESSChrome\native-host.log
   ```

2. **Проверьте логи Xray:**
   ```
   %LOCALAPPDATA%\VLESSChrome\xray_<clientId>.log
   ```

3. **Проверьте конфиг Xray:**
   ```
   %LOCALAPPDATA%\VLESSChrome\config_<clientId>.json
   ```
   После отключения файл очищается (секреты не хранятся plaintext).

### "Native host has exited"

- Проверьте, что Extension ID в манифесте совпадает с реальным ID расширения
- Перезапустите Chrome
- Проверьте, что `native-host.bat` и `native_host.py` находятся в правильной директории

### "Failed to start proxy"

- Native host сам выбирает свободный порт; конфликт 10808 больше не актуален
- Проверьте, что Xray не запущен в другом месте
- Проверьте логи `xray_<clientId>.log`

### Xray не запускается

- Убедитесь, что `xray.exe` находится в `%LOCALAPPDATA%\VLESSChrome\`
- Проверьте, не блокирует ли антивирус или файрвол
- Добавьте исключение для `xray.exe` в Windows Defender

### Расширение не видит Native Host

1. Проверьте реестр:
   ```cmd
   reg query "HKCU\Software\Google\Chrome\NativeMessagingHosts\com.vlesschrome.host"
   ```

2. Путь должен указывать на:
   ```
   %LOCALAPPDATA%\VLESSChrome\native-host-manifest.json
   ```

## Удаление

Запустите `install\uninstall.bat`:

```cmd
cd install
uninstall.bat
```

Затем удалите расширение из Chrome (`chrome://extensions/`).

## Структура проекта

```
VLESSCHROME/
├── extension/              # Chrome Extension
│   ├── manifest.json       # Манифест расширения
│   ├── popup.html          # UI popup
│   ├── popup.js            # Логика popup
│   ├── background.js       # Service Worker
│   ├── styles.css          # Стили
│   └── icons/              # Иконки
├── native-host-python/     # Native Messaging Host (общий для Windows и Linux)
│   └── native_host.py      # Основной скрипт
├── tests/                  # pytest (парсеры, DPAPI, конфиг, протокол, уборка)
├── install/                # Вспомогательные скрипты
│   ├── common.ps1              # Общая логика обоих установщиков
│   ├── gen-extension-key.py    # Одноразовая генерация постоянного Extension ID
│   ├── uninstall.bat           # Удаление
│   └── native-host-manifest.json  # Шаблон манифеста (в нём зашит Extension ID)
├── installer/              # Установка без Python (native_host.exe)
│   ├── build.bat               # Сборка exe — только для разработчика
│   ├── install.bat             # Установка из собранного dist/
│   └── dist/                   # Результат сборки (не в репозитории)
├── linux/                  # Установка и диагностика под Linux
├── macos/                  # Установка под macOS (Apple Silicon и Intel)
├── install.bat             # ← Установка одной командой (нужен Python)
├── check-installation.bat  # Диагностика
├── download-xray.bat       # Загрузка Xray и гео-баз отдельно (обычно не нужна)
└── README.md               # Документация
```

## Безопасность

⚠️ **ВАЖНО:**

- Не публикуйте VLESS URL в открытых источниках
- Используйте только доверенные VLESS серверы
- Регулярно обновляйте Xray-core
- Не храните конфиги с паролями в Git

## Лицензия

MIT License

## Поддержка

При возникновении проблем:
1. Проверьте раздел "Устранение неполадок"
2. Изучите логи (`native-host.log`, `xray.log`)
3. Создайте Issue на GitHub с описанием проблемы и логами

## Благодарности

- [Xray-core](https://github.com/XTLS/Xray-core) - VLESS клиент
- [3X-UI](https://github.com/MHSanaei/3x-ui) - панель управления VLESS серверами

## 📋 Changelog

### v1.1.0 (2026-08-24)

**Маршрутизация:**
- ✅ Переключатель «Российские сайты — напрямую»: трафик к RU-адресам идёт мимо
  туннеля (`geosite:category-ru`, `geoip:ru`), локальная сеть — тоже
  (`geoip:private`). Выключен по умолчанию, переключение переподключает Xray.
- ✅ Гео-базы `geoip.dat` и `geosite.dat` ставятся автоматически — они лежат
  в том же архиве Xray, дополнительной загрузки нет (+29 МБ к установке)
- 🐛 **Исправлено:** IP для гео-правил брался из системного DNS. Для доменов,
  заблокированных провайдером (например, rutracker.org, nnmclub.to), это
  подставной адрес-заглушка — и он оказывался «российским», из-за чего
  правило уводило такие сайты мимо VPN прямиком в блокировку провайдера.
  Резолвинг для гео-правил переведён на DoH (1.1.1.1 / 8.8.8.8, системный DNS
  остаётся запасным вариантом); проверено на живом Xray — ранее
  блокировавшиеся сайты открываются, sberbank.ru/gosuslugi.ru как шли
  напрямую, так и идут

**Установка:**
- ✅ Постоянный Extension ID через поле `key` — копировать ID и перезапускать
  браузер больше не нужно (`install/gen-extension-key.py`)
- ✅ Установка одной командой: `install.bat` вместо связки
  `build-python` → `download-xray` → `install-python` → `update-extension-id`
- ✅ Регистрация в Brave и Chromium (раньше только Chrome, Edge, Яндекс)
- ✅ `check-installation.bat` сверяет ID в манифесте с ключом расширения
- ✅ Страница настройки предупреждает, если загружена копия без `key`
- 🗑️ Удалены `build-python.bat`/`install-python.bat` и собранные копии
  в `bin/*.py` — заменены единым `install.bat`, ставящим модули напрямую
  из `native-host-python/`
- 🗑️ Удалены побайтовые дубликаты `linux/native_host.py`, `parsers.py`,
  `dpapi_store.py`, `host_ping.py` — Linux-установщики берут их из общего
  `native-host-python/`
- 🐛 Диагностика Linux (`check-connection.sh`, `debug-native-host.sh`)
  сверяла Extension ID только по наличию плейсхолдера — чужой или устаревший
  ID проходил как норму. Теперь ID пересчитывается из ключа расширения и
  сверяется явно, как в Windows-диагностике
- 🐛 `debug-native-host.sh` определял «Windows-версию» `native_host.py` по
  строке `LOCALAPPDATA`, которая есть и в кроссплатформенной версии —
  проверка проваливалась на любой исправной Linux-установке

**Native host:**
- 🐛 Native-сообщение читалось одним `read()`; на длинном payload (например,
  WireGuard `.conf`) пайп мог отдать данные несколькими порциями, JSON
  обрывался, и хост падал посреди сессии. Чтение переведено на дочитывание
  до полного размера сообщения
- 🐛 Устранена гонка выбора SOCKS-порта: между освобождением сокета и
  стартом Xray порт мог перехватить другой процесс. Добавлена проверка
  занятости прямо перед запуском и до 3 попыток с новым портом
- 🐛 При недоступном/незарегистрированном native host расширение висело
  в состоянии «Подключение...» до 45 секунд — таймаут ожидания не был
  подписан на обрыв канала (`onDisconnect`). Теперь ошибка приходит сразу
- ⚡ Шифрование/расшифровка секретов профилей переведено на пакетный вызов
  (`protectSecrets`/`unprotectSecrets`) — один запуск native host на весь
  список профилей вместо запуска процесса на каждый профиль при открытии
  popup; есть откат на старые поштучные команды для уже установленного
  старого хоста

**UI:**
- 🎨 Тумблер подключения и блок «Сервер / Время работы» объединены в одну
  карточку — при включённой гео-опции popup требовал прокрутки, чтобы
  увидеть подвал (573px против лимита в 600px). Уплотнены шапка и список
  профилей. Худший случай (8 профилей + активное соединение + ошибка) —
  492px, с запасом

**Установка без Python:**
- ✅ `installer\install.bat` ставит собранный `native_host.exe` — на целевой
  машине Python не нужен вовсе. Сборка (`installer\build.bat`, нужен только
  разработчику) сама проверяет результат настоящим обменом по протоколу
  native messaging. Режим `--onedir`, а не `--onefile`: последний
  распаковывается заново при каждом запуске (~340мс против ~110мс), а
  `ping`/`stop` поднимают новый процесс на каждое действие в popup
- ⚠️ Собранный exe не подписан — возможны ложные срабатывания антивирусов;
  откат на Python-вариант всегда доступен (`install.bat` в корне)

**macOS:**
- ✅ Поддержка macOS (Apple Silicon и Intel) — папка [macos/](macos/README.md).
  Архитектура определяется автоматически, гео-базы едут в том же архиве Xray
- ✅ Снимается карантин Gatekeeper с `xray` — без этого неподписанный бинарник
  не запускается, и подключение падало бы без внятной причины
- ✅ Данные хоста лежат в `~/Library/Application Support/VLESSChrome`
  (не в `~/.config`, как на Linux), манифесты браузеров — рядом. Путь
  зафиксирован тестом, чтобы скрипты и хост не разошлись
- ✅ Скрипты совместимы с bash 3.2 — штатным `/bin/bash` в macOS: без
  `declare -A`, `mapfile` и `${var,,}` из bash 4
- ⚠️ Написано и проверено статически; на живой macOS-машине не запускалось

**Сопровождение:**
- ♻️ Общая логика установщиков вынесена в `install\common.ps1` (загрузка Xray
  и гео-баз, манифест, регистрация в браузерах): `install.ps1` 285 → 142
  строк, `installer\install.ps1` 356 → 207. Отличие свелось к одной строке —
  что попадает в `path` манифеста
- 🐛 `Resolve-PythonExe` больше не откатывается на заглушку из WindowsApps:
  при вызове через PowerShell-сплаттинг она не пробрасывает аргументы и
  зависает в интерактивном REPL. Настоящий интерпретатор ищется через реестр
- 🐛 В генерации `native-host.bat` путь к интерпретатору теперь всегда в
  кавычках. Прежняя ветка для пути с пробелом их не ставила (писалась под
  `py -3`), из-за чего установка Python в `C:\Program Files\...` давала
  неработающий `.bat`
- 🧹 Файлы брошенных профилей (`config_*.json`, `xray_*.log`, `xray_*.pid`)
  убираются при подключении: не текущий профиль, без живого xray и не
  тронутые 7 дней. Раньше копились навсегда
- 🐛 Тесты больше не трогают настоящий `%LOCALAPPDATA%\VLESSChrome` — часть
  из них работала с реальным каталогом и даже проходила за счёт установленного
  там `xray.exe` вместо заглушки
- 🔒 Из тестовых данных убран похожий на настоящий ключ WireGuard и реальный
  IP сервера — заменены на очевидно фиктивные
- 🐛 `linux/install/install.sh` не ставил гео-базы: на нём «российские сайты
  напрямую» молча не работали

**Исправления:**
- ✅ Исправлен путь в манифесте (native-host.bat вместо .exe)
- ✅ Унифицированы имена лог-файлов (native-host.log)

**Новые возможности:**
- ✅ Скрипт ручной правки Extension ID (`update-extension-id.bat`, запасной путь)
- ✅ Скрипт проверки установки (`check-installation.bat`)
- ✅ Улучшенная обработка ошибок в popup

**Документация:**
- ✅ Добавлена подробная инструкция установки ([INSTALL_GUIDE.md](INSTALL_GUIDE.md))
- ✅ Добавлено руководство по устранению неполадок ([TROUBLESHOOTING.md](TROUBLESHOOTING.md))
- ✅ Оптимизирована структура документации

### v1.0.4 (2026-08-17)

- ✅ Kill-switch: если Xray/SOCKS умер при закрытом popup — прокси снимается (~2 тика keep-alive)

### v1.0.3 (2026-08-17)

- ✅ WireGuard `.conf` (вставка и загрузка файла)
- ✅ Динамический SOCKS-порт
- ✅ DPAPI для секретов в `chrome.storage` (Windows)
- ✅ pytest для парсеров
- ✅ Исправлена гонка `onDisconnect` (`isConnected: true`)

### v1.0.2 (2026-08-17)

- ✅ Поддержка WireGuard через Xray outbound

### v1.0.0 (2026-01-30)

- 🎉 Первый релиз
- ✅ Поддержка VLESS протокола
- ✅ Native Messaging Host на Python
- ✅ Автоматическое управление Xray
- ✅ UI для управления подключением
- ✅ Поддержка TCP, WebSocket, gRPC, HTTP/2
- ✅ Поддержка TLS и Reality
