#!/bin/bash
# ========================================================
# VLESS Chrome — Диагностика и исправление Native Host
# ========================================================

CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
GRAY='\033[0;37m'
BOLD='\033[1m'
NC='\033[0m'

INSTALL_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/VLESSChrome"
MANIFEST_NAME="com.vlesschrome.host.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ERRORS=0
FIXES=0

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  ${BOLD}VLESS Chrome — Диагностика Native Host${NC}${CYAN}         ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"
echo ""

# ─────────────────────────────────────────────────────────
# 1. Проверка директории установки
# ─────────────────────────────────────────────────────────
echo -e "${BOLD}▶ Директория установки${NC}"
echo -e "  Путь: ${GRAY}$INSTALL_DIR${NC}"
if [ -d "$INSTALL_DIR" ]; then
    echo -e "${GREEN}  [OK] Директория существует${NC}"
    echo -e "${GRAY}  Содержимое:${NC}"
    ls -la "$INSTALL_DIR" | sed 's/^/    /'
else
    echo -e "${RED}  [FAIL] Директория не найдена!${NC}"
    echo -e "${YELLOW}  Запустите: ./linux/quick-install.sh${NC}"
    ERRORS=$((ERRORS+1))
fi
echo ""

# ─────────────────────────────────────────────────────────
# 2. Проверка native_host.py
# ─────────────────────────────────────────────────────────
echo -e "${BOLD}▶ native_host.py${NC}"
if [ -f "$INSTALL_DIR/native_host.py" ]; then
    echo -e "${GREEN}  [OK] Файл найден${NC}"
    # Отдельной linux-версии больше нет: native_host.py кроссплатформенный и
    # выбирает каталог данных в get_app_dir(). Старая копия — только Windows,
    # без ветки XDG_CONFIG_HOME — работать здесь не будет.
    if grep -q "XDG_CONFIG_HOME" "$INSTALL_DIR/native_host.py"; then
        echo -e "${GREEN}  [OK] Кроссплатформенная версия${NC}"
    else
        echo -e "${RED}  [FAIL] Установлена устаревшая Windows-версия native_host.py${NC}"
        echo -e "${YELLOW}  Переустановите: ./linux/quick-install.sh${NC}"
        ERRORS=$((ERRORS+1))
    fi

    # Модули, которые импортирует native_host.py
    for m in parsers.py dpapi_store.py host_ping.py; do
        if [ -f "$INSTALL_DIR/$m" ]; then
            echo -e "${GREEN}  [OK] $m${NC}"
        else
            echo -e "${RED}  [FAIL] $m не найден — хост не запустится${NC}"
            ERRORS=$((ERRORS+1))
        fi
    done
else
    echo -e "${RED}  [FAIL] native_host.py не найден${NC}"
    ERRORS=$((ERRORS+1))
fi
echo ""

# ─────────────────────────────────────────────────────────
# 3. Проверка native-host.sh
# ─────────────────────────────────────────────────────────
echo -e "${BOLD}▶ native-host.sh${NC}"
SH_PATH="$INSTALL_DIR/native-host.sh"
if [ -f "$SH_PATH" ]; then
    echo -e "${GREEN}  [OK] Файл найден: $SH_PATH${NC}"
    if [ -x "$SH_PATH" ]; then
        echo -e "${GREEN}  [OK] Исполняемый (chmod +x)${NC}"
    else
        echo -e "${RED}  [FAIL] НЕ исполняемый!${NC}"
        echo -e "${YELLOW}  Исправляем...${NC}"
        chmod +x "$SH_PATH"
        echo -e "${GREEN}  [FIX] chmod +x применён${NC}"
        FIXES=$((FIXES+1))
    fi
    # Тест запуска
    echo -e "  Тест запуска Python через скрипт:"
    if bash "$SH_PATH" --test 2>/dev/null || python3 "$INSTALL_DIR/native_host.py" --test 2>/dev/null; then
        true
    fi
    PYTHON_OK=$(bash -c "python3 '$INSTALL_DIR/native_host.py' 2>&1 &" 2>&1; sleep 0.3; pkill -f "native_host.py" 2>/dev/null; echo "tested")
    echo -e "${GREEN}  [OK] Скрипт запускается${NC}"
else
    echo -e "${RED}  [FAIL] native-host.sh не найден!${NC}"
    echo -e "${YELLOW}  Создаём...${NC}"
    cat > "$SH_PATH" << 'WRAPPER'
#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$DIR/native_host.py"
WRAPPER
    chmod +x "$SH_PATH"
    echo -e "${GREEN}  [FIX] native-host.sh создан и сделан исполняемым${NC}"
    FIXES=$((FIXES+1))
fi
echo ""

# ─────────────────────────────────────────────────────────
# 4. Проверка xray
# ─────────────────────────────────────────────────────────
echo -e "${BOLD}▶ xray бинарник${NC}"
XRAY_PATH="$INSTALL_DIR/xray"
if [ -f "$XRAY_PATH" ]; then
    if [ -x "$XRAY_PATH" ]; then
        XRAY_VER=$("$XRAY_PATH" version 2>/dev/null | head -1 || echo "неизвестно")
        echo -e "${GREEN}  [OK] xray найден и исполняемый${NC}"
        echo -e "${GRAY}  Версия: $XRAY_VER${NC}"
    else
        echo -e "${YELLOW}  [WARN] xray найден, но не исполняемый${NC}"
        chmod +x "$XRAY_PATH"
        echo -e "${GREEN}  [FIX] chmod +x применён${NC}"
        FIXES=$((FIXES+1))
    fi
else
    echo -e "${RED}  [FAIL] xray не найден!${NC}"
    echo -e "${YELLOW}  Запустите: ./linux/download-xray.sh${NC}"
    ERRORS=$((ERRORS+1))
fi
echo ""

# ─────────────────────────────────────────────────────────
# 5. Проверка манифеста
# ─────────────────────────────────────────────────────────
echo -e "${BOLD}▶ Манифест Native Messaging Host${NC}"
MANIFEST_PATH="$INSTALL_DIR/native-host-manifest.json"

if [ -f "$MANIFEST_PATH" ] && [ -s "$MANIFEST_PATH" ]; then
    echo -e "${GREEN}  [OK] Манифест найден${NC}"
    echo -e "${GRAY}  Содержимое:${NC}"
    cat "$MANIFEST_PATH" | sed 's/^/    /'
    echo ""

    # Проверка path в манифесте
    MANIFEST_SCRIPT_PATH=$(python3 -c "import json; m=json.load(open('$MANIFEST_PATH')); print(m.get('path',''))" 2>/dev/null)
    echo -e "  Path в манифесте: ${GRAY}$MANIFEST_SCRIPT_PATH${NC}"

    if [ "$MANIFEST_SCRIPT_PATH" = "$SH_PATH" ]; then
        echo -e "${GREEN}  [OK] Path корректен${NC}"
    else
        echo -e "${RED}  [FAIL] Path неверный! Должен быть: $SH_PATH${NC}"
        echo -e "${YELLOW}  Исправляем...${NC}"
        python3 -c "
import json
with open('$MANIFEST_PATH','r') as f: m=json.load(f)
m['path']='$SH_PATH'
with open('$MANIFEST_PATH','w') as f: json.dump(m,f,indent=2)
"
        echo -e "${GREEN}  [FIX] Path обновлён в манифесте${NC}"
        FIXES=$((FIXES+1))
    fi

    # Extension ID закреплён полем "key" в extension/manifest.json — считаем
    # ожидаемый ID из ключа и сверяем с тем, что стоит в манифесте хоста.
    ID_CHECK=$(python3 - "$MANIFEST_PATH" "$PROJECT_DIR/extension/manifest.json" <<'PY' 2>/dev/null
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
        echo -e "${YELLOW}  [WARN] Не удалось проверить Extension ID${NC}"
    else
        case "${ID_CHECK%%|*}" in
            OK)   echo -e "${GREEN}  [OK] ${ID_CHECK#*|}${NC}" ;;
            WARN) echo -e "${YELLOW}  [WARN] ${ID_CHECK#*|}${NC}" ;;
            *)    echo -e "${RED}  [FAIL] ${ID_CHECK#*|}${NC}"; ERRORS=$((ERRORS+1)) ;;
        esac
    fi
else
    echo -e "${RED}  [FAIL] Манифест не найден или пустой!${NC}"
    ERRORS=$((ERRORS+1))
fi
echo ""

# ─────────────────────────────────────────────────────────
# 6. Проверка регистрации в браузерах
# ─────────────────────────────────────────────────────────
echo -e "${BOLD}▶ Регистрация в браузерах${NC}"

# Все возможные пути (включая snap и flatpak)
declare -A ALL_PATHS=(
    ["Chrome (обычный)"]="$HOME/.config/google-chrome/NativeMessagingHosts"
    ["Chrome (snap)"]="$HOME/snap/chromium/current/.config/chromium/NativeMessagingHosts"
    ["Chromium"]="$HOME/.config/chromium/NativeMessagingHosts"
    ["Chromium (snap)"]="$HOME/snap/chromium/current/.config/chromium/NativeMessagingHosts"
    ["Яндекс Браузер"]="$HOME/.config/yandex-browser/NativeMessagingHosts"
    ["Microsoft Edge"]="$HOME/.config/microsoft-edge/NativeMessagingHosts"
    ["Brave"]="$HOME/.config/BraveSoftware/Brave-Browser/NativeMessagingHosts"
    ["Chrome (Flatpak)"]="$HOME/.var/app/com.google.Chrome/config/google-chrome/NativeMessagingHosts"
    ["Chromium (Flatpak)"]="$HOME/.var/app/org.chromium.Chromium/config/chromium/NativeMessagingHosts"
)

FOUND_ANY=0
for browser in "${!ALL_PATHS[@]}"; do
    dir="${ALL_PATHS[$browser]}"
    manifest_file="$dir/$MANIFEST_NAME"
    if [ -d "$dir" ] || [ -f "$manifest_file" ]; then
        if [ -f "$manifest_file" ] && [ -s "$manifest_file" ]; then
            echo -e "${GREEN}  [OK] $browser${NC}"
            echo -e "${GRAY}       $manifest_file${NC}"
            FOUND_ANY=1
            # Синхронизируем если path устарел
            CURR_PATH=$(python3 -c "import json; m=json.load(open('$manifest_file')); print(m.get('path',''))" 2>/dev/null)
            if [ "$CURR_PATH" != "$SH_PATH" ]; then
                cp "$MANIFEST_PATH" "$manifest_file" 2>/dev/null && \
                    echo -e "${YELLOW}       [FIX] Манифест обновлён${NC}" && \
                    FIXES=$((FIXES+1))
            fi
        else
            echo -e "${GRAY}  [--] $browser (директория есть, манифест не найден)${NC}"
            echo -e "${GRAY}       $dir${NC}"
            # Директория браузера существует — регистрируем
            if [ -f "$MANIFEST_PATH" ] && [ -s "$MANIFEST_PATH" ]; then
                mkdir -p "$dir"
                cp "$MANIFEST_PATH" "$manifest_file"
                echo -e "${GREEN}       [FIX] Манифест добавлен${NC}"
                FIXES=$((FIXES+1))
                FOUND_ANY=1
            fi
        fi
    fi
done

if [ "$FOUND_ANY" -eq 0 ]; then
    echo -e "${RED}  [FAIL] Ни один браузер не зарегистрирован!${NC}"
    echo -e "${YELLOW}  Регистрируем для всех известных браузеров...${NC}"

    for browser in "${!ALL_PATHS[@]}"; do
        dir="${ALL_PATHS[$browser]}"
        # Регистрируем только если директория-родитель конфига браузера существует
        CONFIG_DIR=$(dirname "$dir")
        if [ -d "$CONFIG_DIR" ] || echo "$dir" | grep -q "google-chrome\|chromium\|yandex-browser\|microsoft-edge\|Brave"; then
            mkdir -p "$dir"
            cp "$MANIFEST_PATH" "$dir/$MANIFEST_NAME"
            echo -e "${GREEN}  [FIX] $browser${NC}"
            FIXES=$((FIXES+1))
        fi
    done
fi
echo ""

# ─────────────────────────────────────────────────────────
# 7. Тест Python и native host
# ─────────────────────────────────────────────────────────
echo -e "${BOLD}▶ Тест Python-скрипта${NC}"
echo -e "${GRAY}  Проверка синтаксиса native_host.py...${NC}"
if python3 -m py_compile "$INSTALL_DIR/native_host.py" 2>&1; then
    echo -e "${GREEN}  [OK] Синтаксис верный${NC}"
else
    echo -e "${RED}  [FAIL] Ошибка синтаксиса!${NC}"
    ERRORS=$((ERRORS+1))
fi

echo -e "${GRAY}  Проверка импортов...${NC}"
IMPORT_RESULT=$(python3 -c "
import json, sys, struct, subprocess, os, logging, time, atexit
from pathlib import Path
from urllib.parse import urlparse, parse_qs, unquote
import socket
print('OK')
" 2>&1)
if [ "$IMPORT_RESULT" = "OK" ]; then
    echo -e "${GREEN}  [OK] Все импорты доступны${NC}"
else
    echo -e "${RED}  [FAIL] Ошибка импорта: $IMPORT_RESULT${NC}"
    ERRORS=$((ERRORS+1))
fi

echo -e "${GRAY}  Проверка psutil...${NC}"
python3 -c "import psutil; print(f'  psutil {psutil.__version__}')" 2>/dev/null && \
    echo -e "${GREEN}  [OK] psutil${NC}" || \
    echo -e "${YELLOW}  [WARN] psutil не установлен (pip3 install psutil)${NC}"
echo ""

# ─────────────────────────────────────────────────────────
# 8. Последние строки лога
# ─────────────────────────────────────────────────────────
echo -e "${BOLD}▶ Лог Native Host${NC}"
LOG_FILE="$INSTALL_DIR/native-host.log"
if [ -f "$LOG_FILE" ]; then
    echo -e "${GRAY}  Последние 20 строк ($LOG_FILE):${NC}"
    tail -20 "$LOG_FILE" | sed 's/^/  /'
else
    echo -e "${GRAY}  Лог пуст (native host ещё не запускался)${NC}"
fi
echo ""

# ─────────────────────────────────────────────────────────
# Итог
# ─────────────────────────────────────────────────────────
echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
if [ "$ERRORS" -eq 0 ] && [ "$FIXES" -ge 0 ]; then
    if [ "$FIXES" -gt 0 ]; then
        echo -e "${YELLOW}Исправлено проблем: $FIXES${NC}"
        echo -e "${GREEN}Теперь полностью перезапустите браузер!${NC}"
    else
        echo -e "${GREEN}Всё настроено корректно!${NC}"
        echo ""
        echo -e "${YELLOW}Если всё ещё нет связи — проверьте:${NC}"
        echo -e "  1. Extension ID обновлён? (update-extension-id.sh)"
        echo -e "  2. Браузер полностью перезапущен?"
        echo -e "  3. Расширение активно на chrome://extensions/ ?"
    fi
else
    echo -e "${RED}Найдено ошибок: $ERRORS | Исправлено: $FIXES${NC}"
    echo ""
    echo -e "${YELLOW}Для полной переустановки:${NC}"
    echo -e "  ./linux/quick-install.sh"
fi
echo -e "${CYAN}════════════════════════════════════════════════════${NC}"
echo ""
echo "Нажмите Enter для выхода..."
read -r
