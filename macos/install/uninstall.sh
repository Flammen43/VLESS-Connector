#!/bin/bash
# ========================================================
# VLESS Chrome Extension — удаление (macOS)
# Совместимо с bash 3.2 (штатный /bin/bash в macOS).
# ========================================================

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GRAY='\033[0;37m'
NC='\033[0m'

# Тот же путь, что и в quick-install.sh и в app_dir_for() хоста.
INSTALL_DIR="$HOME/Library/Application Support/VLESSChrome"
MANIFEST_NAME="com.vlesschrome.host.json"

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}VLESS Chrome — удаление (macOS)${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

# Останавливаем работающий Xray, иначе он переживёт удаление файлов.
if pgrep -f "$INSTALL_DIR/xray" >/dev/null 2>&1; then
    pkill -f "$INSTALL_DIR/xray" 2>/dev/null || true
    echo -e "${GREEN}[OK] Работающий Xray остановлен${NC}"
fi

BROWSER_DIRS="$HOME/Library/Application Support/Google/Chrome|\
$HOME/Library/Application Support/Chromium|\
$HOME/Library/Application Support/Yandex/YandexBrowser|\
$HOME/Library/Application Support/Microsoft Edge|\
$HOME/Library/Application Support/BraveSoftware/Brave-Browser|\
$HOME/Library/Application Support/Vivaldi"

OLD_IFS="$IFS"
set -f
IFS='|'
set -- $BROWSER_DIRS
DIRS=("$@")
IFS="$OLD_IFS"
set +f

removed=0
for dir in "${DIRS[@]}"; do
    manifest="$dir/NativeMessagingHosts/$MANIFEST_NAME"
    if [ -f "$manifest" ]; then
        rm -f "$manifest"
        echo -e "${GREEN}[OK] Снята регистрация: $(basename "$dir")${NC}"
        removed=$((removed + 1))
    fi
done
[ "$removed" -eq 0 ] && echo -e "${GRAY}[--] Регистраций в браузерах не найдено${NC}"

if [ -d "$INSTALL_DIR" ]; then
    echo ""
    echo -e "${YELLOW}Будет удалено: $INSTALL_DIR${NC}"
    echo -e "${GRAY}(вместе с профилями, логами и xray)${NC}"
    printf "Продолжить? (y/N): "
    read -r answer
    case "$answer" in
        y|Y)
            rm -rf "$INSTALL_DIR"
            echo -e "${GREEN}[OK] Каталог удалён${NC}"
            ;;
        *)
            echo -e "${GRAY}[--] Каталог оставлен${NC}"
            ;;
    esac
else
    echo -e "${GRAY}[--] Каталог установки не найден${NC}"
fi

echo ""
echo -e "${CYAN}Готово.${NC}"
echo -e "${GRAY}Не забудьте убрать расширение со страницы chrome://extensions/${NC}"
echo ""
