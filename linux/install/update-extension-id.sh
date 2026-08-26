#!/bin/bash
# ========================================
# VLESS Chrome — Обновление Extension ID (Linux)
# ========================================

CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
GRAY='\033[0;37m'
NC='\033[0m'

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}VLESS Chrome — Обновление Extension ID${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

INSTALL_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/VLESSChrome"
MANIFEST_PATH="$INSTALL_DIR/native-host-manifest.json"

if [ ! -f "$MANIFEST_PATH" ] || [ ! -s "$MANIFEST_PATH" ]; then
    echo -e "${RED}[FAIL] Манифест не найден: $MANIFEST_PATH${NC}"
    echo -e "${YELLOW}Сначала запустите install/install.sh${NC}"
    exit 1
fi

echo "Манифест: $MANIFEST_PATH"
echo ""

# Показать текущий ID
CURRENT_ORIGINS=$(python3 -c "
import json
with open('$MANIFEST_PATH') as f:
    m = json.load(f)
print(', '.join(m.get('allowed_origins', [])))
" 2>/dev/null)
echo -e "${GRAY}Текущие origins: $CURRENT_ORIGINS${NC}"
echo ""

# Запрос ID
echo -e "${YELLOW}Введите Extension ID из Chrome/Яндекс Браузера:${NC}"
echo -e "${GRAY}(Скопируйте ID со страницы расширений)${NC}"
echo ""
read -rp "Extension ID: " NEW_ID

# Валидация
NEW_ID=$(echo "$NEW_ID" | xargs)  # trim
if [ -z "$NEW_ID" ]; then
    echo -e "${RED}[FAIL] Extension ID не может быть пустым!${NC}"
    exit 1
fi

if [ ${#NEW_ID} -lt 20 ]; then
    echo -e "${YELLOW}[WARN] ID кажется коротким (${#NEW_ID} символов, обычно 32)${NC}"
    read -rp "Продолжить? (y/n): " CONFIRM
    if [ "$CONFIRM" != "y" ]; then
        exit 1
    fi
fi

echo ""
echo "Обновление манифеста..."

# Обновление через Python
python3 << PYEOF
import json

manifest_path = "$MANIFEST_PATH"
new_id = "$NEW_ID"
new_origin = f"chrome-extension://{new_id}/"

with open(manifest_path, 'r') as f:
    manifest = json.load(f)

# Фильтруем старые origins, добавляем новый
origins = []
for o in manifest.get('allowed_origins', []):
    if o != "chrome-extension://EXTENSION_ID_PLACEHOLDER/" and o != new_origin:
        origins.append(o)
origins.append(new_origin)
manifest['allowed_origins'] = origins

with open(manifest_path, 'w') as f:
    json.dump(manifest, f, indent=2)

print("OK")
PYEOF

if [ $? -eq 0 ]; then
    echo -e "${GREEN}[OK] Манифест обновлён!${NC}"
else
    echo -e "${RED}[FAIL] Ошибка обновления${NC}"
    exit 1
fi

# Копирование обновлённого манифеста во все браузеры
echo ""
echo "Обновление манифестов в браузерах..."

MANIFEST_NAME="com.vlesschrome.host.json"
BROWSER_DIRS=(
    "$HOME/.config/google-chrome/NativeMessagingHosts"
    "$HOME/.config/chromium/NativeMessagingHosts"
    "$HOME/.config/yandex-browser/NativeMessagingHosts"
    "$HOME/.config/microsoft-edge/NativeMessagingHosts"
    "$HOME/.config/BraveSoftware/Brave-Browser/NativeMessagingHosts"
)

for dir in "${BROWSER_DIRS[@]}"; do
    if [ -d "$dir" ]; then
        cp "$MANIFEST_PATH" "$dir/$MANIFEST_NAME"
        browser_name=$(echo "$dir" | sed 's|.*/\(.*\)/NativeMessagingHosts|\1|')
        echo -e "${GREEN}[OK] Обновлено в $browser_name${NC}"
    fi
done

echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}Extension ID обновлён!${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""
echo -e "${GREEN}ID: $NEW_ID${NC}"
echo ""
echo -e "${YELLOW}ВАЖНО: Полностью перезапустите браузер:${NC}"
echo "  1. Закройте все окна Chrome/Яндекс Браузера"
echo "  2. Убедитесь что нет процессов браузера: ps aux | grep chrome"
echo "  3. Запустите браузер заново"
echo ""
echo "Нажмите Enter для выхода..."
read -r
