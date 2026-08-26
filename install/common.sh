# shellcheck shell=bash
# ============================================================
# Общая логика shell-установщиков (Linux и macOS).
# Подключается через dot-source:
#
#     . "$PROJECT_DIR/install/common.sh"
#
# Совместимо с bash 3.2 — в macOS штатный /bin/bash именно такой.
# ============================================================

# Цвета может задать вызывающий скрипт; если нет — работаем без них.
: "${RED:=}" "${GREEN:=}" "${YELLOW:=}" "${GRAY:=}" "${NC:=}"

vless_sha256_of() {
    # sha256sum есть в Linux, shasum — в macOS.
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        return 1
    fi
}

vless_fetch() {
    # $1 = URL, $2 = куда сохранить. Тихо, без прогресса.
    # Ошибки глушим: отсутствие .dgst — штатная ситуация, о ней сообщает
    # вызывающий код, а вывод curl поверх него только путает.
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$2" "$1" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$2" "$1" 2>/dev/null
    else
        return 1
    fi
}

verify_sha256() {
    # Сверяет файл с контрольной суммой из .dgst, лежащего рядом с архивом.
    #   $1 = локальный файл
    #   $2 = URL архива (к нему добавляется .dgst)
    #
    # Возвращает 1 ТОЛЬКО при реальном несовпадении — это значит, что файл
    # повреждён или подменён, и продолжать нельзя. Если .dgst недоступен или
    # нечем посчитать хеш, проверка пропускается с предупреждением: рвать
    # установку из-за недоступности вспомогательного файла неправильно.
    local file="$1" url="$2"
    local dgst="${file}.dgst"
    local expected actual

    if ! vless_sha256_of "$file" >/dev/null 2>&1; then
        echo -e "${YELLOW}[WARN] Нет sha256sum/shasum — проверка контрольной суммы пропущена${NC}"
        return 0
    fi

    if ! vless_fetch "${url}.dgst" "$dgst" || [ ! -s "$dgst" ]; then
        echo -e "${YELLOW}[WARN] Не удалось скачать .dgst — проверка пропущена${NC}"
        rm -f "$dgst"
        return 0
    fi

    expected=$(grep -i '^SHA2-256' "$dgst" \
        | sed -n 's/.*=[[:space:]]*\([0-9a-fA-F]\{64\}\).*/\1/p' \
        | head -n1 | tr 'A-F' 'a-f')
    rm -f "$dgst"

    if [ -z "$expected" ]; then
        echo -e "${YELLOW}[WARN] Не удалось разобрать .dgst — проверка пропущена${NC}"
        return 0
    fi

    actual=$(vless_sha256_of "$file")
    if [ "$actual" != "$expected" ]; then
        echo -e "${RED}[FAIL] Контрольная сумма НЕ совпадает!${NC}"
        echo -e "${RED}  Ожидалось: $expected${NC}"
        echo -e "${RED}  Получено:  $actual${NC}"
        echo -e "${RED}Файл повреждён или подменён — удаляю.${NC}"
        rm -f "$file"
        return 1
    fi

    echo -e "${GREEN}[OK] SHA-256 совпадает${NC}"
    return 0
}
