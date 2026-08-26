#!/bin/bash
# ========================================
# VLESS Chrome Extension — Установка (Linux)
# ========================================
set -e

CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
GRAY='\033[0;37m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LINUX_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_DIR="$(dirname "$LINUX_DIR")"

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}VLESS Chrome Extension — Установка (Linux)${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

# --- Проверка Python3 ---
if ! command -v python3 &>/dev/null; then
    echo -e "${RED}[FAIL] Python3 не установлен!${NC}"
    echo -e "${YELLOW}Установите Python3:${NC}"
    echo "  Ubuntu/Debian: sudo apt install python3 python3-pip"
    echo "  Fedora:        sudo dnf install python3 python3-pip"
    echo "  Arch:          sudo pacman -S python python-pip"
    exit 1
fi
echo -e "${GREEN}[OK] Python3 найден${NC}"
python3 --version
echo ""

# --- Установка зависимостей Python ---
echo "Установка зависимостей Python..."
REQ_FILE="$LINUX_DIR/requirements.txt"
if [ -f "$REQ_FILE" ]; then
    if python3 -m pip install --user -q -r "$REQ_FILE" 2>&1; then
        echo -e "${GREEN}[OK] Зависимости Python установлены${NC}"
    else
        echo -e "${YELLOW}[WARN] Не удалось установить зависимости${NC}"
        echo -e "${GRAY}Попробуйте вручную: pip3 install psutil${NC}"
    fi
else
    echo -e "${YELLOW}[WARN] requirements.txt не найден${NC}"
fi
echo ""

# --- Директория установки ---
INSTALL_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/VLESSChrome"
echo "Установка в: $INSTALL_DIR"
echo ""

mkdir -p "$INSTALL_DIR"
echo -e "${GREEN}[OK] Директория создана: $INSTALL_DIR${NC}"

# --- Копирование файлов ---
echo ""
echo "Копирование файлов..."

# Модули хоста кроссплатформенные и лежат в одном месте — native-host-python/.
# Все четыре обязательны: native_host.py импортирует остальные три.
SRC_PY="$PROJECT_DIR/native-host-python"
for f in native_host.py parsers.py dpapi_store.py host_ping.py; do
    if [ ! -f "$SRC_PY/$f" ]; then
        echo -e "${RED}[FAIL] Не найден $SRC_PY/$f${NC}"
        exit 1
    fi
    cp "$SRC_PY/$f" "$INSTALL_DIR/$f"
    echo -e "${GREEN}[OK] $f скопирован${NC}"
done

# native-host.sh (обёртка)
if [ -f "$LINUX_DIR/native-host.sh" ]; then
    cp "$LINUX_DIR/native-host.sh" "$INSTALL_DIR/native-host.sh"
    chmod +x "$INSTALL_DIR/native-host.sh"
    echo -e "${GREEN}[OK] native-host.sh скопирован и сделан исполняемым${NC}"
else
    # Создаём обёртку на месте
    cat > "$INSTALL_DIR/native-host.sh" << 'WRAPPER'
#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$DIR/native_host.py"
WRAPPER
    chmod +x "$INSTALL_DIR/native-host.sh"
    echo -e "${GREEN}[OK] native-host.sh создан${NC}"
fi

# xray (бинарник)
if [ -f "$INSTALL_DIR/xray" ]; then
    echo -e "${GREEN}[OK] xray уже установлен${NC}"
elif [ -f "$LINUX_DIR/xray" ]; then
    cp "$LINUX_DIR/xray" "$INSTALL_DIR/xray"
    chmod +x "$INSTALL_DIR/xray"
    echo -e "${GREEN}[OK] xray скопирован${NC}"
else
    echo -e "${YELLOW}[WARN] xray не найден. Запустите download-xray.sh для загрузки${NC}"
fi

# Гео-базы — нужны для «российские сайты напрямую». Как и xray, этот скрипт
# их не качает, а берёт из linux/ (туда их кладёт download-xray.sh).
# Без них опция молча не сработает, поэтому предупреждаем явно.
for geo in geoip.dat geosite.dat; do
    if [ -f "$INSTALL_DIR/$geo" ]; then
        echo -e "${GREEN}[OK] $geo уже установлен${NC}"
    elif [ -f "$LINUX_DIR/$geo" ]; then
        cp "$LINUX_DIR/$geo" "$INSTALL_DIR/$geo"
        echo -e "${GREEN}[OK] $geo скопирован${NC}"
    else
        echo -e "${YELLOW}[WARN] $geo не найден — «российские сайты напрямую» работать не будет${NC}"
        echo -e "${GRAY}     Запустите download-xray.sh (он качает и базы тоже)${NC}"
    fi
done

# --- Манифест Native Messaging Host ---
echo ""
echo "Создание манифеста Native Messaging Host..."

HOST_PATH="$INSTALL_DIR/native-host.sh"
MANIFEST_INSTALLED="$INSTALL_DIR/native-host-manifest.json"
MANIFEST_TEMPLATE="$SCRIPT_DIR/native-host-manifest.json"

# Шаблон в репозитории — единственный источник Extension ID. ID закреплён полем
# "key" в extension/manifest.json (см. install/gen-extension-key.py), поэтому он
# одинаков на всех машинах и подставлять его вручную больше не нужно.
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

python3 -c "
import json
with open('$MANIFEST_TEMPLATE') as f: m = json.load(f)
m['path'] = '$HOST_PATH'
with open('$MANIFEST_INSTALLED', 'w') as f: json.dump(m, f, indent=2)
print(m['allowed_origins'][0])
" > /tmp/vlesschrome-origin.$$ || {
    echo -e "${RED}[FAIL] Не удалось создать манифест${NC}"; exit 1
}
EXT_ORIGIN=$(cat /tmp/vlesschrome-origin.$$); rm -f /tmp/vlesschrome-origin.$$
echo -e "${GREEN}[OK] Манифест создан: $MANIFEST_INSTALLED${NC}"
echo -e "${GRAY}     Extension ID: ${EXT_ORIGIN}${NC}"

# --- Регистрация в браузерах ---
echo ""
echo "Регистрация Native Messaging Host в браузерах..."

# Chrome
CHROME_NMH_DIR="$HOME/.config/google-chrome/NativeMessagingHosts"
mkdir -p "$CHROME_NMH_DIR"
cp "$MANIFEST_INSTALLED" "$CHROME_NMH_DIR/com.vlesschrome.host.json"
echo -e "${GREEN}[OK] Зарегистрировано в Google Chrome${NC}"

# Chromium
CHROMIUM_NMH_DIR="$HOME/.config/chromium/NativeMessagingHosts"
mkdir -p "$CHROMIUM_NMH_DIR"
cp "$MANIFEST_INSTALLED" "$CHROMIUM_NMH_DIR/com.vlesschrome.host.json"
echo -e "${GREEN}[OK] Зарегистрировано в Chromium${NC}"

# Yandex Browser
YANDEX_NMH_DIR="$HOME/.config/yandex-browser/NativeMessagingHosts"
mkdir -p "$YANDEX_NMH_DIR"
cp "$MANIFEST_INSTALLED" "$YANDEX_NMH_DIR/com.vlesschrome.host.json"
echo -e "${GREEN}[OK] Зарегистрировано в Яндекс Браузере${NC}"

# Edge
EDGE_NMH_DIR="$HOME/.config/microsoft-edge/NativeMessagingHosts"
mkdir -p "$EDGE_NMH_DIR"
cp "$MANIFEST_INSTALLED" "$EDGE_NMH_DIR/com.vlesschrome.host.json"
echo -e "${GREEN}[OK] Зарегистрировано в Microsoft Edge${NC}"

# Brave
BRAVE_NMH_DIR="$HOME/.config/BraveSoftware/Brave-Browser/NativeMessagingHosts"
mkdir -p "$BRAVE_NMH_DIR"
cp "$MANIFEST_INSTALLED" "$BRAVE_NMH_DIR/com.vlesschrome.host.json"
echo -e "${GREEN}[OK] Зарегистрировано в Brave${NC}"

# Сохранение пути проекта
echo "$PROJECT_DIR/" > "$INSTALL_DIR/project-path.txt"
echo -e "${GREEN}[OK] Путь к проекту сохранён${NC}"

echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}Установка завершена!${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""
echo -e "${YELLOW}СЛЕДУЮЩИЕ ШАГИ:${NC}"
echo "  1. Откройте браузер → страница расширений"
echo "  2. Включите 'Режим разработчика'"
echo "  3. Загрузите папку: $PROJECT_DIR/extension"
echo "  4. Скопируйте Extension ID"
echo "  5. Запустите linux/install/update-extension-id.sh"
echo "  6. Перезапустите браузер"
echo ""
if [ ! -f "$INSTALL_DIR/xray" ]; then
    echo -e "${YELLOW}ВНИМАНИЕ: xray не установлен! Запустите linux/download-xray.sh${NC}"
    echo ""
fi
echo "Нажмите Enter для выхода..."
read -r
