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

# Flatpak-браузеры: манифест лежит в песочнице, и ещё там осталось разрешение
# на каталог хоста, выданное установщиком.
# Формат «app-id|каталог профиля». Список общий с quick-install.sh.
FLATPAK_BROWSERS=(
    "com.google.Chrome|google-chrome"
    "org.chromium.Chromium|chromium"
    "com.brave.Browser|BraveSoftware/Brave-Browser"
    "com.microsoft.Edge|microsoft-edge"
    "com.vivaldi.Vivaldi|vivaldi"
    "ru.yandex.Browser|yandex-browser"
)

for entry in "${FLATPAK_BROWSERS[@]}"; do
    app_id="${entry%%|*}"
    profile_dir="${entry#*|}"
    app_root="$HOME/.var/app/$app_id"
    [ -d "$app_root" ] || continue
    manifest="$app_root/config/$profile_dir/NativeMessagingHosts/$MANIFEST_NAME"
    if [ -f "$manifest" ]; then
        rm -f "$manifest"
        echo -e "${GREEN}[OK] Удалено из $app_id (Flatpak)${NC}"
    fi
    if command -v flatpak >/dev/null 2>&1; then
        flatpak override --user --nofilesystem="$INSTALL_DIR" "$app_id" 2>/dev/null \
            && echo -e "${GRAY}     доступ к $INSTALL_DIR отозван${NC}"
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
