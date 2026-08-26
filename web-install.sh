#!/usr/bin/env bash
# ========================================================
# VLESS-Connector — установка одной командой (Linux/macOS)
#
#   curl -fsSL https://raw.githubusercontent.com/Flammen43/VLESS-Connector/main/web-install.sh | bash
#
# Скачивает архив последнего релиза под текущую платформу (внутри уже
# лежит Xray и гео-базы), распаковывает в ~/.local/share/VLESS-Connector
# и запускает штатный quick-install.sh оттуда.
#
# Зеркало вместо GitHub, если тот недоступен:
#   VLESSCHROME_BASE=https://example.com/vless bash <(curl -fsSL ...)
# ========================================================
set -euo pipefail

REPO="Flammen43/VLESS-Connector"
DEST="${XDG_DATA_HOME:-$HOME/.local/share}/VLESS-Connector"

GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'
YELLOW='\033[1;33m'; GRAY='\033[0;37m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}[OK]${NC} $1"; }
fail() { echo -e "  ${RED}[!!]${NC} $1" >&2; }
step() { echo ""; echo -e "$1"; }

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN} VLESS-Connector — установка из сети${NC}"
echo -e "${CYAN}========================================${NC}"

# ─── [1/5] Платформа ─────────────────────────────────────
step "[1/5] Определение платформы..."
OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS" in
    Linux)  PLATFORM=linux ;;
    Darwin) PLATFORM=macos ;;
    *) fail "неподдерживаемая ОС: $OS"; exit 1 ;;
esac
case "$ARCH" in
    x86_64|amd64)  CPU=x64 ;;
    aarch64|arm64) CPU=arm64 ;;
    *) fail "неподдерживаемая архитектура: $ARCH"; exit 1 ;;
esac
# Сборок macos-x64 и linux-arm64 в релизе может не быть — проверит шаг 2.
MASK="${PLATFORM}-${CPU}"
ok "$OS $ARCH -> $MASK"

for tool in curl unzip; do
    command -v "$tool" >/dev/null 2>&1 || {
        fail "$tool не установлен"
        echo -e "  ${GRAY}Debian/Ubuntu: sudo apt install $tool${NC}"
        echo -e "  ${GRAY}Fedora:        sudo dnf install $tool${NC}"
        exit 1
    }
done

# ─── [2/5] Поиск релиза ──────────────────────────────────
step "[2/5] Поиск последнего релиза..."
if [ -n "${VLESSCHROME_BASE:-}" ]; then
    URL="${VLESSCHROME_BASE%/}/vlesschrome-${MASK}.zip"
    ok "зеркало: $URL"
else
    API="https://api.github.com/repos/$REPO/releases/latest"
    if ! JSON="$(curl -fsSL --connect-timeout 20 "$API" 2>/dev/null)"; then
        fail "GitHub недоступен"
        echo -e "  ${YELLOW}Скачайте вручную: https://github.com/$REPO/releases/latest${NC}"
        echo -e "  ${GRAY}Либо укажите зеркало: VLESSCHROME_BASE=...${NC}"
        exit 1
    fi
    URL="$(echo "$JSON" \
        | sed -n 's/.*"browser_download_url":[[:space:]]*"\([^"]*\)".*/\1/p' \
        | grep -- "-${MASK}-" | head -n1)"
    [ -n "$URL" ] || { fail "в релизе нет архива для $MASK"; exit 1; }
    ok "$(basename "$URL")"
fi

# ─── [3/5] Загрузка ──────────────────────────────────────
step "[3/5] Загрузка архива..."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ZIP="$TMP/release.zip"
# 20+ МБ по неровному каналу регулярно рвётся на полпути, поэтому повторы;
# -C - докачивает с места обрыва, а не начинает заново.
curl -fL --progress-bar --retry 5 --retry-delay 2 --retry-all-errors \n     -C - -o "$ZIP" "$URL" || { fail "не удалось скачать"; exit 1; }
ok "$(du -h "$ZIP" | cut -f1)"

# ─── [4/5] Распаковка ────────────────────────────────────
# Каталог перезаписывается целиком: в нём только распакованный релиз,
# настройки пользователя лежат отдельно, в ~/.config/VLESSChrome.
step "[4/5] Распаковка в $DEST..."
unzip -oq "$ZIP" -d "$TMP/x"
# В архиве один корневой каталог (vlesschrome/) — поднимаем содержимое.
SRC="$TMP/x"
if [ "$(find "$TMP/x" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ]; then
    ONLY="$(find "$TMP/x" -mindepth 1 -maxdepth 1)"
    [ -d "$ONLY" ] && SRC="$ONLY"
fi
rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
mv "$SRC" "$DEST"
chmod +x "$DEST"/*/*.sh "$DEST"/*/*/*.sh 2>/dev/null || true
ok "готово"

# ─── [5/5] Установка ─────────────────────────────────────
INSTALLER="$DEST/$PLATFORM/quick-install.sh"
[ -f "$INSTALLER" ] || { fail "$PLATFORM/quick-install.sh не найден в архиве"; exit 1; }

step "[5/5] Запуск установщика..."
# stdin отдан пайпу от curl, поэтому установщику даём /dev/null: вопрос
# про переустановку он пропустит сам, а финальная пауза не подвиснет.
VLESSCHROME_NONINTERACTIVE=1 bash "$INSTALLER" < /dev/null

echo ""
echo -e "${CYAN}Папка расширения для chrome://extensions:${NC}"
echo -e "${YELLOW}  $DEST/extension${NC}"
