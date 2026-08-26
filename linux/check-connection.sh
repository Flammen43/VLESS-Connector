#!/bin/bash
# ========================================
# Проверка подключения (Linux)
# ========================================

CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
GRAY='\033[0;37m'
NC='\033[0m'

INSTALL_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/VLESSChrome"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}VLESS Chrome — Проверка подключения${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

# --- Python ---
echo "Проверка Python3..."
if command -v python3 &>/dev/null; then
    echo -e "${GREEN}[OK] Python3: $(python3 --version 2>&1)${NC}"
else
    echo -e "${RED}[FAIL] Python3 не установлен${NC}"
fi
echo ""

# --- psutil ---
echo "Проверка psutil..."
if python3 -c "import psutil; print(f'psutil {psutil.__version__}')" 2>/dev/null; then
    echo -e "${GREEN}[OK] psutil установлен${NC}"
else
    echo -e "${YELLOW}[WARN] psutil не установлен (pip3 install psutil)${NC}"
fi
echo ""

# --- xray ---
echo "Проверка xray..."
if [ -f "$INSTALL_DIR/xray" ]; then
    XRAY_VER=$("$INSTALL_DIR/xray" version 2>/dev/null | head -1 || echo "неизвестно")
    echo -e "${GREEN}[OK] xray найден: $INSTALL_DIR/xray${NC}"
    echo -e "${GRAY}     Версия: $XRAY_VER${NC}"
else
    echo -e "${RED}[FAIL] xray не найден в $INSTALL_DIR${NC}"
    echo -e "${YELLOW}Запустите: linux/download-xray.sh${NC}"
fi
echo ""

# --- native-host.sh ---
echo "Проверка native-host.sh..."
if [ -f "$INSTALL_DIR/native-host.sh" ]; then
    if [ -x "$INSTALL_DIR/native-host.sh" ]; then
        echo -e "${GREEN}[OK] native-host.sh найден и исполняемый${NC}"
    else
        echo -e "${YELLOW}[WARN] native-host.sh найден, но НЕ исполняемый${NC}"
        echo -e "${GRAY}     chmod +x $INSTALL_DIR/native-host.sh${NC}"
    fi
else
    echo -e "${RED}[FAIL] native-host.sh не найден${NC}"
fi
echo ""

# --- Манифест ---
echo "Проверка манифеста..."
MANIFEST_PATH="$INSTALL_DIR/native-host-manifest.json"
if [ -f "$MANIFEST_PATH" ] && [ -s "$MANIFEST_PATH" ]; then
    echo -e "${GREEN}[OK] Манифест найден: $MANIFEST_PATH${NC}"
    
    # Extension ID закреплён полем "key" в extension/manifest.json, поэтому его
    # можно посчитать заранее и сверить с тем, что стоит в манифесте хоста.
    EXT_MANIFEST="$PROJECT_DIR/extension/manifest.json"
    ID_CHECK=$(python3 - "$MANIFEST_PATH" "$EXT_MANIFEST" <<'PY' 2>/dev/null
import base64, hashlib, json, sys

host_manifest, ext_manifest = sys.argv[1], sys.argv[2]

origins = json.load(open(host_manifest)).get('allowed_origins') or []
if not origins:
    print('FAIL|В манифесте нет allowed_origins'); raise SystemExit
actual = origins[0].replace('chrome-extension://', '').rstrip('/')
if actual == 'EXTENSION_ID_PLACEHOLDER':
    print('FAIL|В манифесте остался плейсхолдер — запустите quick-install.sh'); raise SystemExit

try:
    key = json.load(open(ext_manifest)).get('key')
except Exception:
    key = None
if not key:
    print(f'WARN|В extension/manifest.json нет поля "key" — ID зависит от пути ({actual})'); raise SystemExit

digest = hashlib.sha256(base64.b64decode(key)).digest()[:16].hex()
expected = ''.join(chr(ord('a') + int(c, 16)) for c in digest)
if expected == actual:
    print(f'OK|Extension ID согласован ({actual})')
else:
    print(f'FAIL|ID в манифесте ({actual}) не совпадает с ключом расширения ({expected})')
PY
    )
    if [ -z "$ID_CHECK" ]; then
        echo -e "${YELLOW}[WARN] Не удалось проверить Extension ID (нужен python3)${NC}"
    else
        case "${ID_CHECK%%|*}" in
            OK)   echo -e "${GREEN}[OK] ${ID_CHECK#*|}${NC}" ;;
            WARN) echo -e "${YELLOW}[WARN] ${ID_CHECK#*|}${NC}" ;;
            *)    echo -e "${RED}[FAIL] ${ID_CHECK#*|}${NC}" ;;
        esac
    fi
else
    echo -e "${RED}[FAIL] Манифест не найден${NC}"
fi
echo ""

# --- Регистрация в браузерах ---
echo "Проверка регистрации в браузерах..."
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
    manifest="$dir/$MANIFEST_NAME"
    if [ -f "$manifest" ]; then
        echo -e "${GREEN}[OK] $browser — зарегистрирован${NC}"
    else
        echo -e "${GRAY}[--] $browser — не зарегистрирован${NC}"
    fi
done

echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}Проверка завершена${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""
echo "Нажмите Enter для выхода..."
read -r
