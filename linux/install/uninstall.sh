#!/bin/bash
# ========================================
# VLESS Chrome Extension — Удаление (Linux)
# ========================================

CYAN='\033[0;36m'
GREEN='\033[0;32m'
GRAY='\033[0;37m'
NC='\033[0m'

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}VLESS Chrome Extension — Удаление (Linux)${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

INSTALL_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/VLESSChrome"

# --- Остановка xray ---
echo "Остановка xray..."
pkill -f "xray.*config_.*\.json" 2>/dev/null && \
    echo -e "${GREEN}[OK] Процессы xray остановлены${NC}" || \
    echo -e "${GRAY}[SKIP] Процессы xray не найдены${NC}"
echo ""

# --- Удаление манифестов из браузеров ---
echo "Удаление из браузеров..."

MANIFEST_NAME="com.vlesschrome.host.json"
BROWSER_DIRS=(
    "$HOME/.config/google-chrome/NativeMessagingHosts"
    "$HOME/.config/chromium/NativeMessagingHosts"
    "$HOME/.config/yandex-browser/NativeMessagingHosts"
    "$HOME/.config/microsoft-edge/NativeMessagingHosts"
    "$HOME/.config/BraveSoftware/Brave-Browser/NativeMessagingHosts"
)

for dir in "${BROWSER_DIRS[@]}"; do
    manifest="$dir/$MANIFEST_NAME"
    if [ -f "$manifest" ]; then
        rm -f "$manifest"
        browser_name=$(echo "$dir" | sed 's|.*/\(.*\)/NativeMessagingHosts|\1|')
        echo -e "${GREEN}[OK] Удалено из $browser_name${NC}"
    fi
done
echo ""

# --- Удаление файлов ---
echo "Удаление файлов..."
if [ -d "$INSTALL_DIR" ]; then
    rm -rf "$INSTALL_DIR"
    echo -e "${GREEN}[OK] Удалена директория: $INSTALL_DIR${NC}"
else
    echo -e "${GRAY}[SKIP] Директория не найдена: $INSTALL_DIR${NC}"
fi

echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}Удаление завершено!${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""
echo "Не забудьте удалить расширение из браузера:"
echo "  chrome://extensions/ или browser://extensions/"
echo ""
echo "Нажмите Enter для выхода..."
read -r
