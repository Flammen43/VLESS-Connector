#!/bin/bash
# ========================================
# Загрузка Xray-core для Linux
# ========================================
set -e

CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
GRAY='\033[0;37m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/VLESSChrome"

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}Загрузка Xray-core (Linux)${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""

mkdir -p "$INSTALL_DIR"

XRAY_VERSION="${XRAY_VERSION:-}"
if [ -z "$XRAY_VERSION" ]; then
    XRAY_VERSION=$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null | \
        sed -n 's/.*"tag_name":[[:space:]]*"v\([^"]*\)".*/\1/p' | head -n1)
fi
if [ -z "$XRAY_VERSION" ]; then
    XRAY_VERSION="26.3.27"
    echo -e "${YELLOW}[WARN] GitHub API недоступен, используем v${XRAY_VERSION}${NC}"
fi

# Определение архитектуры
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)
        XRAY_ARCH="64"
        ;;
    aarch64|arm64)
        XRAY_ARCH="arm64-v8a"
        ;;
    armv7l|armv7)
        XRAY_ARCH="arm32-v7a"
        ;;
    *)
        echo -e "${RED}[FAIL] Неподдерживаемая архитектура: $ARCH${NC}"
        exit 1
        ;;
esac

DOWNLOAD_URL="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-${XRAY_ARCH}.zip"
ZIP_FILE="$INSTALL_DIR/xray.zip"
TEMP_DIR="$INSTALL_DIR/xray-temp"

echo -e "Загрузка Xray-core v${XRAY_VERSION} (${ARCH})..."
echo -e "${GRAY}URL: $DOWNLOAD_URL${NC}"
echo ""

# Проверка наличия wget или curl
if command -v wget &>/dev/null; then
    wget -q --show-progress -O "$ZIP_FILE" "$DOWNLOAD_URL" && \
        echo -e "${GREEN}[OK] Загрузка завершена${NC}" || {
        echo -e "${RED}[FAIL] Не удалось скачать Xray${NC}"
        echo -e "${YELLOW}Попробуйте скачать вручную с https://github.com/XTLS/Xray-core/releases${NC}"
        exit 1
    }
elif command -v curl &>/dev/null; then
    curl -L --progress-bar -o "$ZIP_FILE" "$DOWNLOAD_URL" && \
        echo -e "${GREEN}[OK] Загрузка завершена${NC}" || {
        echo -e "${RED}[FAIL] Не удалось скачать Xray${NC}"
        echo -e "${YELLOW}Попробуйте скачать вручную с https://github.com/XTLS/Xray-core/releases${NC}"
        exit 1
    }
else
    echo -e "${RED}[FAIL] Не найден wget или curl${NC}"
    echo "Установите: sudo apt install wget"
    exit 1
fi

echo ""
echo "Проверка контрольной суммы..."
DGST_URL="${DOWNLOAD_URL}.dgst"
DGST_FILE="$INSTALL_DIR/xray.zip.dgst"
if command -v sha256sum &>/dev/null || command -v shasum &>/dev/null; then
    DGST_OK=0
    if command -v curl &>/dev/null; then
        if curl -fsSL -o "$DGST_FILE" "$DGST_URL"; then DGST_OK=1; fi
    else
        if wget -q -O "$DGST_FILE" "$DGST_URL"; then DGST_OK=1; fi
    fi
    if [ "$DGST_OK" = "1" ] && [ -s "$DGST_FILE" ]; then
        EXPECTED_HASH=$(grep -i '^SHA2-256' "$DGST_FILE" | sed -n 's/.*=[[:space:]]*\([0-9a-fA-F]\{64\}\).*/\1/p' | head -n1 | tr 'A-F' 'a-f')
        if [ -n "$EXPECTED_HASH" ]; then
            if command -v sha256sum &>/dev/null; then
                ACTUAL_HASH=$(sha256sum "$ZIP_FILE" | awk '{print $1}')
            else
                ACTUAL_HASH=$(shasum -a 256 "$ZIP_FILE" | awk '{print $1}')
            fi
            if [ "$ACTUAL_HASH" != "$EXPECTED_HASH" ]; then
                echo -e "${RED}[FAIL] Контрольная сумма НЕ совпадает!${NC}"
                echo -e "${RED}  Ожидалось: $EXPECTED_HASH${NC}"
                echo -e "${RED}  Получено:  $ACTUAL_HASH${NC}"
                echo -e "${RED}Файл повреждён или подменён — удаляю.${NC}"
                rm -f "$ZIP_FILE" "$DGST_FILE"
                exit 1
            fi
            echo -e "${GREEN}[OK] SHA256 совпадает: $ACTUAL_HASH${NC}"
        else
            echo -e "${YELLOW}[WARN] Не удалось разобрать .dgst — проверка пропущена${NC}"
        fi
    else
        echo -e "${YELLOW}[WARN] Не удалось скачать .dgst для проверки контрольной суммы${NC}"
    fi
    rm -f "$DGST_FILE"
else
    echo -e "${YELLOW}[WARN] Нет sha256sum/shasum — проверка контрольной суммы пропущена${NC}"
fi

echo ""
echo "Распаковка архива..."

# Проверка наличия unzip
if ! command -v unzip &>/dev/null; then
    echo -e "${RED}[FAIL] unzip не установлен${NC}"
    echo "Установите: sudo apt install unzip"
    exit 1
fi

mkdir -p "$TEMP_DIR"
unzip -o "$ZIP_FILE" -d "$TEMP_DIR" >/dev/null 2>&1

if [ -f "$TEMP_DIR/xray" ]; then
    cp "$TEMP_DIR/xray" "$INSTALL_DIR/xray"
    chmod +x "$INSTALL_DIR/xray"
    echo -e "${GREEN}[OK] xray извлечён: $INSTALL_DIR/xray${NC}"
else
    echo -e "${RED}[FAIL] xray не найден в архиве${NC}"
    rm -rf "$TEMP_DIR" "$ZIP_FILE"
    exit 1
fi

# Гео-базы из того же архива — нужны для «российские сайты напрямую»
for geo in geoip.dat geosite.dat; do
    if [ -f "$TEMP_DIR/$geo" ]; then
        cp "$TEMP_DIR/$geo" "$INSTALL_DIR/$geo"
        echo -e "${GREEN}[OK] $geo извлечён${NC}"
    else
        echo -e "${YELLOW}[WARN] $geo не найден в архиве${NC}"
    fi
done

# Очистка
rm -rf "$TEMP_DIR" "$ZIP_FILE"
echo -e "${GREEN}[OK] Временные файлы удалены${NC}"

echo ""
echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN}Загрузка завершена!${NC}"
echo -e "${CYAN}========================================${NC}"
echo ""
echo "xray готов к использованию: $INSTALL_DIR/xray"
echo ""
echo "Нажмите Enter для выхода..."
read -r
