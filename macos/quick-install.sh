#!/bin/bash
# ========================================================
# VLESS Chrome Extension — установка (macOS, Apple Silicon и Intel)
# Один скрипт: зависимости + xray с гео-базами + регистрация
#
# Совместимость с bash 3.2: в macOS до сих пор /bin/bash версии 3.2,
# поэтому здесь нет ассоциативных массивов (declare -A), mapfile и
# ${var,,} — они появились только в bash 4.
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

SRC_PY="$PROJECT_DIR/native-host-python"
MANIFEST_TEMPLATE="$SCRIPT_DIR/install/native-host-manifest.json"

# Должно совпадать с app_dir_for() в native_host.py, иначе хост не найдёт
# свои файлы. Путь зафиксирован тестом test_app_dir_on_macos_ignores_xdg.
INSTALL_DIR="$HOME/Library/Application Support/VLESSChrome"

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  ${BOLD}VLESS Chrome Extension — установка (macOS)${NC}${CYAN}      ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
echo ""

# ─────────────────────────────────────────────────────────
# Шаг 1: Python 3
# ─────────────────────────────────────────────────────────
echo -e "${BOLD}[1/6] Проверка Python 3...${NC}"

PY=""
for candidate in python3 /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    if command -v "$candidate" &>/dev/null; then
        # На macOS /usr/bin/python3 может быть заглушкой Command Line Tools,
        # которая при вызове открывает диалог установки. Проверяем, что
        # интерпретатор реально запускается.
        if "$candidate" -c 'import sys' &>/dev/null; then
            PY="$(command -v "$candidate")"
            break
        fi
    fi
done

if [ -z "$PY" ]; then
    echo -e "${RED}[FAIL] Рабочий Python 3 не найден${NC}"
    echo ""
    echo "Установите одним из способов:"
    echo -e "  ${GRAY}brew install python3${NC}"
    echo -e "  ${GRAY}xcode-select --install${NC}   (Command Line Tools)"
    echo -e "  ${GRAY}https://www.python.org/downloads/macos/${NC}"
    exit 1
fi
echo -e "${GREEN}[OK] $("$PY" --version 2>&1)  ($PY)${NC}"

# ─────────────────────────────────────────────────────────
# Шаг 2: Зависимости
# ─────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}[2/6] Установка зависимостей...${NC}"

# --break-system-packages нужен на новых сборках Python (PEP 668), но есть
# не везде — пробуем сначала без него.
if "$PY" -m pip install --user -q -r "$SCRIPT_DIR/requirements.txt" 2>/dev/null; then
    echo -e "${GREEN}[OK] psutil установлен${NC}"
elif "$PY" -m pip install --user -q --break-system-packages -r "$SCRIPT_DIR/requirements.txt" 2>/dev/null; then
    echo -e "${GREEN}[OK] psutil установлен${NC}"
else
    echo -e "${YELLOW}[WARN] psutil не установлен — хост будет работать без него${NC}"
    echo -e "${GRAY}     (остановка Xray пойдёт через kill, это допустимо)${NC}"
fi

# ─────────────────────────────────────────────────────────
# Шаг 3: Копирование файлов
# ─────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}[3/6] Установка в $INSTALL_DIR ...${NC}"

mkdir -p "$INSTALL_DIR"

# Модули хоста кроссплатформенные и лежат в одном месте.
# Все четыре обязательны: native_host.py импортирует остальные три.
for f in native_host.py parsers.py dpapi_store.py host_ping.py; do
    if [ ! -f "$SRC_PY/$f" ]; then
        echo -e "${RED}  ✗ не найден $SRC_PY/$f${NC}"
        exit 1
    fi
    cp "$SRC_PY/$f" "$INSTALL_DIR/$f"
    echo -e "${GREEN}  ✓ $f${NC}"
done

# Обёртка с явным путём к интерпретатору: Chrome запускает хост без PATH.
sed "s|__PYTHON__|\"$PY\"|" "$SCRIPT_DIR/native-host.sh" > "$INSTALL_DIR/native-host.sh"
chmod +x "$INSTALL_DIR/native-host.sh"
echo -e "${GREEN}  ✓ native-host.sh${NC}"

echo "$PROJECT_DIR/" > "$INSTALL_DIR/project-path.txt"

# ─────────────────────────────────────────────────────────
# Шаг 4: Xray и гео-базы
# ─────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}[4/6] Проверка Xray...${NC}"

ARCH="$(uname -m)"
case "$ARCH" in
    arm64)   XRAY_ASSET="Xray-macos-arm64-v8a.zip" ;;
    x86_64)  XRAY_ASSET="Xray-macos-64.zip" ;;
    *)
        echo -e "${RED}[FAIL] Неподдерживаемая архитектура: $ARCH${NC}"
        exit 1
        ;;
esac
echo -e "${GRAY}  Архитектура: $ARCH -> $XRAY_ASSET${NC}"

# Кэш в bin/ — им пользуется релизный архив (make-release.ps1 кладёт туда
# бинарники заранее), чтобы установка шла вообще без сети. Та же схема, что
# и у Windows-установщика.
CACHE_DIR="$PROJECT_DIR/bin"
if [ ! -x "$INSTALL_DIR/xray" ] && [ -f "$CACHE_DIR/xray" ]; then
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

NEED_DOWNLOAD=0
[ -x "$INSTALL_DIR/xray" ] || NEED_DOWNLOAD=1
for geo in geoip.dat geosite.dat; do
    [ -f "$INSTALL_DIR/$geo" ] || NEED_DOWNLOAD=1
done

if [ "$NEED_DOWNLOAD" -eq 0 ]; then
    echo -e "${GREEN}[OK] xray и гео-базы уже на месте${NC}"
else
    XRAY_VERSION="${XRAY_VERSION:-}"
    if [ -z "$XRAY_VERSION" ]; then
        XRAY_VERSION=$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null | \
            sed -n 's/.*"tag_name":[[:space:]]*"v\([^"]*\)".*/\1/p' | head -n1)
    fi
    [ -z "$XRAY_VERSION" ] && XRAY_VERSION="26.3.27"

    URL="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/${XRAY_ASSET}"
    TMP_DIR="$INSTALL_DIR/xray-temp"
    ZIP="$INSTALL_DIR/xray.zip"

    echo -e "${GRAY}  Загрузка Xray-core v${XRAY_VERSION} (~19 МБ)...${NC}"
    if ! curl -fL --progress-bar -o "$ZIP" "$URL"; then
        echo -e "${RED}[FAIL] Не удалось скачать Xray${NC}"
        echo -e "${YELLOW}Скачайте вручную: https://github.com/XTLS/Xray-core/releases${NC}"
        rm -f "$ZIP"
        exit 1
    fi

    # Бинарник получит полный доступ к трафику — качать его без проверки
    # нельзя. Обрыв на 19 МБ даёт «успешно скачанный» битый файл, и заметно
    # это только по контрольной сумме.
    if ! verify_sha256 "$ZIP" "$URL"; then
        exit 1
    fi

    rm -rf "$TMP_DIR"
    mkdir -p "$TMP_DIR"
    unzip -oq "$ZIP" -d "$TMP_DIR"

    if [ -f "$TMP_DIR/xray" ]; then
        cp "$TMP_DIR/xray" "$INSTALL_DIR/xray"
        chmod +x "$INSTALL_DIR/xray"
        echo -e "${GREEN}[OK] xray установлен${NC}"
    else
        echo -e "${RED}[FAIL] xray не найден в архиве${NC}"
        rm -rf "$TMP_DIR" "$ZIP"
        exit 1
    fi

    # Гео-базы едут в том же архиве — отдельной загрузки не требуется.
    for geo in geoip.dat geosite.dat; do
        if [ -f "$TMP_DIR/$geo" ]; then
            cp "$TMP_DIR/$geo" "$INSTALL_DIR/$geo"
            echo -e "${GREEN}[OK] $geo установлен${NC}"
        else
            echo -e "${YELLOW}[WARN] $geo не найден — «российские сайты напрямую» работать не будет${NC}"
        fi
    done

    rm -rf "$TMP_DIR" "$ZIP"
fi

# Gatekeeper метит всё скачанное карантином, и неподписанный xray просто не
# запустится. Снимаем метку — иначе подключение молча падает.
if xattr -p com.apple.quarantine "$INSTALL_DIR/xray" &>/dev/null; then
    xattr -dr com.apple.quarantine "$INSTALL_DIR/xray" 2>/dev/null || true
    echo -e "${GREEN}[OK] Снят карантин Gatekeeper с xray${NC}"
fi

# ─────────────────────────────────────────────────────────
# Шаг 5: Манифест и регистрация
# ─────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}[5/6] Регистрация Native Messaging Host...${NC}"

if [ ! -f "$MANIFEST_TEMPLATE" ]; then
    echo -e "${RED}[FAIL] Шаблон манифеста не найден: $MANIFEST_TEMPLATE${NC}"
    exit 1
fi

if grep -q "EXTENSION_ID_PLACEHOLDER" "$MANIFEST_TEMPLATE"; then
    echo -e "${RED}[FAIL] В шаблоне остался плейсхолдер вместо Extension ID${NC}"
    echo -e "${YELLOW}Запустите в корне проекта:${NC}"
    echo "  python3 install/gen-extension-key.py --manifest extension/manifest.json \\"
    echo "      --host-manifest macos/install/native-host-manifest.json"
    exit 1
fi

HOST_PATH="$INSTALL_DIR/native-host.sh"
MANIFEST_PATH="$INSTALL_DIR/native-host-manifest.json"

EXT_ORIGIN=$("$PY" - "$MANIFEST_TEMPLATE" "$MANIFEST_PATH" "$HOST_PATH" <<'PYEOF'
import json, sys
template, target, host_path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(template, encoding='utf-8') as f:
    m = json.load(f)
m['path'] = host_path
with open(target, 'w', encoding='utf-8') as f:
    json.dump(m, f, indent=2, ensure_ascii=False)
print(m['allowed_origins'][0])
PYEOF
) || { echo -e "${RED}[FAIL] Не удалось создать манифест${NC}"; exit 1; }

echo -e "${GREEN}  ✓ Манифест создан${NC}"
echo -e "${GRAY}    Extension ID: ${EXT_ORIGIN}${NC}"

# Пути манифестов на macOS — в ~/Library/Application Support, а не в
# ~/.config, как на Linux. Параллельные массивы вместо declare -A: bash 3.2.
BROWSER_NAMES="Google Chrome|Chromium|Яндекс Браузер|Microsoft Edge|Brave|Vivaldi"
BROWSER_DIRS="$HOME/Library/Application Support/Google/Chrome|\
$HOME/Library/Application Support/Chromium|\
$HOME/Library/Application Support/Yandex/YandexBrowser|\
$HOME/Library/Application Support/Microsoft Edge|\
$HOME/Library/Application Support/BraveSoftware/Brave-Browser|\
$HOME/Library/Application Support/Vivaldi"

# Разбиение неквотированное (иначе не разделится по '|'), поэтому на время
# глушим подстановку имён файлов: путь приходит из $HOME и теоретически может
# содержать * или ?.
OLD_IFS="$IFS"
set -f
IFS='|'
set -- $BROWSER_NAMES
NAMES=("$@")
set -- $BROWSER_DIRS
DIRS=("$@")
IFS="$OLD_IFS"
set +f

i=0
while [ $i -lt ${#NAMES[@]} ]; do
    nmh_dir="${DIRS[$i]}/NativeMessagingHosts"
    mkdir -p "$nmh_dir"
    cp "$MANIFEST_PATH" "$nmh_dir/com.vlesschrome.host.json"
    echo -e "${GREEN}  ✓ ${NAMES[$i]}${NC}"
    i=$((i + 1))
done

# ─────────────────────────────────────────────────────────
# Шаг 6: Проверка
# ─────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}[6/6] Проверка установки...${NC}"

ERRORS=0
for f in native_host.py parsers.py dpapi_store.py host_ping.py; do
    [ -f "$INSTALL_DIR/$f" ] && echo -e "${GREEN}  ✓ $f${NC}" || { echo -e "${RED}  ✗ $f${NC}"; ERRORS=$((ERRORS+1)); }
done
[ -x "$INSTALL_DIR/native-host.sh" ] && echo -e "${GREEN}  ✓ native-host.sh${NC}" || { echo -e "${RED}  ✗ native-host.sh${NC}"; ERRORS=$((ERRORS+1)); }
[ -x "$INSTALL_DIR/xray" ]           && echo -e "${GREEN}  ✓ xray${NC}"           || { echo -e "${RED}  ✗ xray${NC}"; ERRORS=$((ERRORS+1)); }
[ -s "$MANIFEST_PATH" ]              && echo -e "${GREEN}  ✓ манифест${NC}"       || { echo -e "${RED}  ✗ манифест${NC}"; ERRORS=$((ERRORS+1)); }
for geo in geoip.dat geosite.dat; do
    [ -f "$INSTALL_DIR/$geo" ] && echo -e "${GREEN}  ✓ $geo${NC}" \
        || echo -e "${YELLOW}  ~ $geo (гео-маршрутизация будет отключена)${NC}"
done

# Не «файл на месте», а настоящий обмен по протоколу native messaging —
# ровно так, как это делает Chrome.
if "$PY" - "$INSTALL_DIR/native-host.sh" <<'PYEOF'
import json, struct, subprocess, sys, time
host = sys.argv[1]
p = subprocess.Popen([host], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.PIPE)
time.sleep(0.3)
if p.poll() is not None:
    print(p.stderr.read().decode('utf-8', 'replace')[:300]); sys.exit(1)
body = json.dumps({'id': 1, 'action': 'status', 'clientId': 'install-check'}).encode()
p.stdin.write(struct.pack('=I', len(body)) + body); p.stdin.flush()
raw = p.stdout.read(4)
if len(raw) < 4:
    sys.exit(1)
n = struct.unpack('=I', raw)[0]
json.loads(p.stdout.read(n).decode('utf-8'))
p.stdin.close(); p.wait(timeout=5)
PYEOF
then
    echo -e "${GREEN}  ✓ Протокол native messaging отвечает${NC}"
else
    echo -e "${RED}  ✗ Хост не отвечает по протоколу${NC}"
    ERRORS=$((ERRORS+1))
fi

echo ""
if [ "$ERRORS" -eq 0 ]; then
    echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  ${GREEN}${BOLD}Установка завершена успешно${NC}${CYAN}                     ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
else
    echo -e "${RED}Установка завершена с ошибками ($ERRORS)${NC}"
fi

echo ""
echo -e "${YELLOW}ОСТАЛОСЬ 2 ШАГА:${NC}"
echo ""
echo -e "  ${BOLD}1.${NC} Откройте ${GRAY}chrome://extensions/${NC} → «Режим разработчика»"
echo -e "  ${BOLD}2.${NC} «Загрузить распакованное расширение» → ${GRAY}$PROJECT_DIR/extension${NC}"
echo ""
echo -e "${GRAY}Копировать Extension ID и перезапускать браузер не нужно:${NC}"
echo -e "${GRAY}ID закреплён полем «key» в manifest.json.${NC}"
echo ""
echo -e "${GRAY}Логи:      $INSTALL_DIR/native-host.log${NC}"
echo -e "${GRAY}Удаление:  $SCRIPT_DIR/install/uninstall.sh${NC}"
echo ""
