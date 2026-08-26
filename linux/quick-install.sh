#!/bin/bash
# ========================================================
# VLESS Chrome Extension — Быстрая установка (Linux)
# Один скрипт: зависимости + xray + установка + регистрация
# ========================================================
set -e

CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
GRAY='\033[0;37m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Проверка контрольных сумм — общая с Linux/macOS установщиками.
. "$PROJECT_DIR/install/common.sh"

INSTALL_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/VLESSChrome"
XRAY_VERSION="${XRAY_VERSION:-}"
if [ -z "$XRAY_VERSION" ]; then
    XRAY_VERSION=$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null | \
        sed -n 's/.*"tag_name":[[:space:]]*"v\([^"]*\)".*/\1/p' | head -n1)
fi
if [ -z "$XRAY_VERSION" ]; then
    XRAY_VERSION="26.3.27"
fi

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  ${BOLD}VLESS Chrome Extension — Быстрая установка${NC}${CYAN}     ║${NC}"
echo -e "${CYAN}║  Linux • v${XRAY_VERSION}                                  ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
echo ""

# ─────────────────────────────────────────────────────────
# Шаг 1: Проверка Python3
# ─────────────────────────────────────────────────────────
echo -e "${BOLD}[1/6] Проверка Python3...${NC}"

if ! command -v python3 &>/dev/null; then
    echo -e "${RED}[FAIL] Python3 не установлен!${NC}"
    echo ""
    echo "Установите Python3 для вашего дистрибутива:"
    echo -e "  ${GRAY}Ubuntu/Debian:${NC}  sudo apt install python3 python3-pip"
    echo -e "  ${GRAY}Fedora:${NC}         sudo dnf install python3 python3-pip"
    echo -e "  ${GRAY}Arch:${NC}           sudo pacman -S python python-pip"
    echo ""
    exit 1
fi
echo -e "${GREEN}[OK] $(python3 --version 2>&1)${NC}"

# ─────────────────────────────────────────────────────────
# Шаг 2: Установка зависимостей Python
# ─────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}[2/6] Установка зависимостей Python...${NC}"

REQ_FILE="$SCRIPT_DIR/requirements.txt"
if [ -f "$REQ_FILE" ]; then
    if python3 -m pip install --user -q -r "$REQ_FILE" 2>/dev/null; then
        echo -e "${GREEN}[OK] psutil установлен${NC}"
    else
        echo -e "${YELLOW}[WARN] Не удалось через pip, пробуем pip3...${NC}"
        pip3 install --user -q psutil 2>/dev/null && \
            echo -e "${GREEN}[OK] psutil установлен через pip3${NC}" || \
            echo -e "${YELLOW}[WARN] psutil не установлен — будет работать без него${NC}"
    fi
else
    python3 -m pip install --user -q psutil 2>/dev/null && \
        echo -e "${GREEN}[OK] psutil установлен${NC}" || \
        echo -e "${YELLOW}[WARN] psutil не установлен${NC}"
fi

# ─────────────────────────────────────────────────────────
# Шаг 3: Создание директории и копирование файлов
# ─────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}[3/6] Установка файлов в $INSTALL_DIR ...${NC}"

mkdir -p "$INSTALL_DIR"

# Модули хоста кроссплатформенные и лежат в одном месте — native-host-python/.
# Все четыре обязательны: native_host.py импортирует остальные три.
SRC_PY="$PROJECT_DIR/native-host-python"
for f in native_host.py parsers.py dpapi_store.py host_ping.py; do
    if [ ! -f "$SRC_PY/$f" ]; then
        echo -e "${RED}  ✗ не найден $SRC_PY/$f${NC}"; exit 1
    fi
    cp "$SRC_PY/$f" "$INSTALL_DIR/$f"
    echo -e "${GREEN}  ✓ $f${NC}"
done

# native-host.sh
if [ -f "$SCRIPT_DIR/native-host.sh" ]; then
    cp "$SCRIPT_DIR/native-host.sh" "$INSTALL_DIR/native-host.sh"
else
    cat > "$INSTALL_DIR/native-host.sh" << 'WRAPPER'
#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$DIR/native_host.py"
WRAPPER
fi
chmod +x "$INSTALL_DIR/native-host.sh"
echo -e "${GREEN}  ✓ native-host.sh${NC}"

# Путь к проекту
echo "$PROJECT_DIR/" > "$INSTALL_DIR/project-path.txt"

# ─────────────────────────────────────────────────────────
# Шаг 4: Скачивание Xray
# ─────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}[4/6] Загрузка Xray-core v${XRAY_VERSION}...${NC}"

# Кэш в bin/ — им пользуется релизный архив (make-release.ps1 кладёт туда
# бинарники заранее), чтобы установка шла вообще без сети. Та же схема, что
# и у Windows-установщика.
CACHE_DIR="$PROJECT_DIR/bin"
if [ ! -f "$INSTALL_DIR/xray" ] && [ -f "$CACHE_DIR/xray" ]; then
    cp "$CACHE_DIR/xray" "$INSTALL_DIR/xray"
    chmod +x "$INSTALL_DIR/xray"
    echo -e "${GREEN}[OK] xray взят из bin/${NC}"
fi
for geo in geoip.dat geosite.dat; do
    if [ ! -f "$INSTALL_DIR/$geo" ] && [ -f "$CACHE_DIR/$geo" ]; then
        cp "$CACHE_DIR/$geo" "$INSTALL_DIR/$geo"
        echo -e "${GREEN}[OK] $geo взят из bin/${NC}"
    fi
done

if [ -f "$INSTALL_DIR/xray" ]; then
    EXISTING_VER=$("$INSTALL_DIR/xray" version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "?")
    echo -e "${GREEN}[OK] xray уже установлен (v${EXISTING_VER})${NC}"
    # В неинтерактивном режиме (релизный архив, CI) вопрос задавать некому.
    if [ "$VLESSCHROME_NONINTERACTIVE" = "1" ] || [ ! -t 0 ]; then
        SKIP_DOWNLOAD=1
    else
        echo -ne "${GRAY}     Переустановить? (y/N): ${NC}"
        read -r REINSTALL
        if [ "$REINSTALL" != "y" ] && [ "$REINSTALL" != "Y" ]; then
            echo -e "${GRAY}     Пропущено${NC}"
            SKIP_DOWNLOAD=1
        fi
    fi
fi

if [ -z "$SKIP_DOWNLOAD" ]; then
    # Определение архитектуры
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)             XRAY_ARCH="64" ;;
        aarch64|arm64)      XRAY_ARCH="arm64-v8a" ;;
        armv7l|armv7)       XRAY_ARCH="arm32-v7a" ;;
        *)
            echo -e "${RED}[FAIL] Неподдерживаемая архитектура: $ARCH${NC}"
            exit 1
            ;;
    esac

    DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-${XRAY_ARCH}.zip"
    ZIP_FILE="$INSTALL_DIR/xray.zip"
    TEMP_DIR="$INSTALL_DIR/xray-temp"

    echo -e "${GRAY}  Arch: ${ARCH} → Xray-linux-${XRAY_ARCH}.zip${NC}"
    echo -e "${GRAY}  URL:  ${DOWNLOAD_URL}${NC}"
    echo ""

    # Скачивание
    DOWNLOAD_OK=0
    if command -v wget &>/dev/null; then
        wget -q --show-progress -O "$ZIP_FILE" "$DOWNLOAD_URL" && DOWNLOAD_OK=1
    elif command -v curl &>/dev/null; then
        curl -L --progress-bar -o "$ZIP_FILE" "$DOWNLOAD_URL" && DOWNLOAD_OK=1
    else
        echo -e "${RED}[FAIL] Не найден wget или curl${NC}"
        echo "  sudo apt install wget"
        exit 1
    fi

    if [ "$DOWNLOAD_OK" -ne 1 ]; then
        echo -e "${RED}[FAIL] Ошибка загрузки${NC}"
        echo -e "${YELLOW}Скачайте вручную: https://github.com/XTLS/Xray-core/releases${NC}"
        exit 1
    fi
    echo -e "${GREEN}[OK] Загружено${NC}"

    # Бинарник получит полный доступ к трафику — качать его без проверки
    # нельзя. Обрыв на 20 МБ даёт «успешно скачанный» битый файл, и заметно
    # это только по контрольной сумме.
    if ! verify_sha256 "$ZIP_FILE" "$DOWNLOAD_URL"; then
        exit 1
    fi

    # Распаковка
    if ! command -v unzip &>/dev/null; then
        echo -e "${RED}[FAIL] unzip не установлен (sudo apt install unzip)${NC}"
        exit 1
    fi

    mkdir -p "$TEMP_DIR"
    unzip -o "$ZIP_FILE" -d "$TEMP_DIR" >/dev/null 2>&1

    if [ -f "$TEMP_DIR/xray" ]; then
        cp "$TEMP_DIR/xray" "$INSTALL_DIR/xray"
        chmod +x "$INSTALL_DIR/xray"
        echo -e "${GREEN}[OK] xray установлен${NC}"
    else
        echo -e "${RED}[FAIL] xray не найден в архиве${NC}"
        rm -rf "$TEMP_DIR" "$ZIP_FILE"
        exit 1
    fi

    # Гео-базы из того же архива — нужны для «российские сайты напрямую»
    for geo in geoip.dat geosite.dat; do
        if [ -f "$TEMP_DIR/$geo" ]; then
            cp "$TEMP_DIR/$geo" "$INSTALL_DIR/$geo"
            echo -e "${GREEN}[OK] $geo установлен${NC}"
        else
            echo -e "${YELLOW}[WARN] $geo не найден — маршрутизация по гео работать не будет${NC}"
        fi
    done

    rm -rf "$TEMP_DIR" "$ZIP_FILE"
fi

# ─────────────────────────────────────────────────────────
# Шаг 5: Создание и регистрация манифеста
# ─────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}[5/6] Регистрация Native Messaging Host...${NC}"

HOST_PATH="$INSTALL_DIR/native-host.sh"
MANIFEST_PATH="$INSTALL_DIR/native-host-manifest.json"
MANIFEST_TEMPLATE="$SCRIPT_DIR/install/native-host-manifest.json"

# Extension ID закреплён полем "key" в extension/manifest.json, поэтому шаблон
# в репозитории уже содержит правильный origin — подставлять руками не нужно.
if [ ! -f "$MANIFEST_TEMPLATE" ]; then
    echo -e "${RED}[FAIL] Шаблон манифеста не найден: $MANIFEST_TEMPLATE${NC}"
    exit 1
fi

if grep -q "EXTENSION_ID_PLACEHOLDER" "$MANIFEST_TEMPLATE"; then
    echo -e "${RED}[FAIL] В шаблоне остался плейсхолдер вместо Extension ID${NC}"
    echo -e "${YELLOW}Запустите в корне проекта:${NC}"
    echo "  python3 install/gen-extension-key.py --manifest extension/manifest.json \\"
    echo "      --host-manifest install/native-host-manifest.json \\"
    echo "      --host-manifest linux/install/native-host-manifest.json"
    exit 1
fi

EXT_ORIGIN=$(python3 -c "
import json
with open('$MANIFEST_TEMPLATE') as f: m = json.load(f)
m['path'] = '$HOST_PATH'
with open('$MANIFEST_PATH', 'w') as f: json.dump(m, f, indent=2)
print(m['allowed_origins'][0])
") || { echo -e "${RED}[FAIL] Не удалось создать манифест${NC}"; exit 1; }
echo -e "${GREEN}  ✓ Манифест создан${NC}"
echo -e "${GRAY}    Extension ID: ${EXT_ORIGIN}${NC}"

# Регистрация во всех Chromium-based браузерах
MANIFEST_NAME="com.vlesschrome.host.json"
declare -A BROWSERS=(
    ["Google Chrome"]="$HOME/.config/google-chrome/NativeMessagingHosts"
    ["Chromium"]="$HOME/.config/chromium/NativeMessagingHosts"
    ["Яндекс Браузер"]="$HOME/.config/yandex-browser/NativeMessagingHosts"
    ["Microsoft Edge"]="$HOME/.config/microsoft-edge/NativeMessagingHosts"
    ["Brave"]="$HOME/.config/BraveSoftware/Brave-Browser/NativeMessagingHosts"
)

for browser in "${!BROWSERS[@]}"; do
    dir="${BROWSERS[$browser]}"
    mkdir -p "$dir"
    cp "$MANIFEST_PATH" "$dir/$MANIFEST_NAME"
    echo -e "${GREEN}  ✓ $browser${NC}"
done

# ─────────────────────────────────────────────────────────
# Шаг 6: Проверка установки
# ─────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}[6/6] Проверка установки...${NC}"

ERRORS=0

[ -f "$INSTALL_DIR/native_host.py" ]   && echo -e "${GREEN}  ✓ native_host.py${NC}"   || { echo -e "${RED}  ✗ native_host.py${NC}"; ERRORS=$((ERRORS+1)); }
[ -x "$INSTALL_DIR/native-host.sh" ]   && echo -e "${GREEN}  ✓ native-host.sh${NC}"   || { echo -e "${RED}  ✗ native-host.sh${NC}"; ERRORS=$((ERRORS+1)); }
[ -x "$INSTALL_DIR/xray" ]             && echo -e "${GREEN}  ✓ xray${NC}"             || { echo -e "${RED}  ✗ xray${NC}"; ERRORS=$((ERRORS+1)); }
[ -s "$MANIFEST_PATH" ]                && echo -e "${GREEN}  ✓ манифест${NC}"         || { echo -e "${RED}  ✗ манифест${NC}"; ERRORS=$((ERRORS+1)); }

for geo in geoip.dat geosite.dat; do
    [ -s "$INSTALL_DIR/$geo" ] && echo -e "${GREEN}  ✓ $geo${NC}" \
        || echo -e "${YELLOW}  ~ $geo (без него «российские сайты напрямую» не работает)${NC}"
done

python3 -c "import psutil" 2>/dev/null && echo -e "${GREEN}  ✓ psutil${NC}"           || echo -e "${YELLOW}  ~ psutil (опционально)${NC}"

echo ""

if [ "$ERRORS" -eq 0 ]; then
    echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  ${GREEN}${BOLD}Установка завершена успешно!${NC}${CYAN}                    ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
else
    echo -e "${RED}Установка завершена с ошибками ($ERRORS)${NC}"
fi

echo ""
echo -e "${YELLOW}ОСТАЛОСЬ СДЕЛАТЬ:${NC}"
echo ""
echo -e "  ${BOLD}1.${NC} Откройте браузер → ${GRAY}chrome://extensions/${NC}"
echo -e "  ${BOLD}2.${NC} Включите ${GRAY}«Режим разработчика»${NC}"
echo -e "  ${BOLD}3.${NC} Нажмите ${GRAY}«Загрузить распакованное расширение»${NC} → ${GRAY}$PROJECT_DIR/extension${NC}"
echo ""
echo -e "${GRAY}Копировать Extension ID и перезапускать браузер не нужно:${NC}"
echo -e "${GRAY}ID закреплён полем «key» в manifest.json.${NC}"
echo ""
echo -e "${GRAY}Логи:       $INSTALL_DIR/native-host.log${NC}"
echo -e "${GRAY}Диагностика: $SCRIPT_DIR/check-connection.sh${NC}"
echo -e "${GRAY}Удаление:    $SCRIPT_DIR/install/uninstall.sh${NC}"
echo ""
echo "Нажмите Enter для выхода..."
read -r
