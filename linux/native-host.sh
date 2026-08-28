#!/bin/bash
# Обёртка для запуска native_host.py через Python3
DIR="$(cd "$(dirname "$0")" && pwd)"
# VLESSCHROME_APP_DIR — каталог, где лежит сам хост. Без него внутри
# песочницы Flatpak сработал бы подменённый XDG_CONFIG_HOME, и xray
# искался бы в ~/.var/app/<id>/config вместо каталога установки.
export VLESSCHROME_APP_DIR="$DIR"
exec python3 "$DIR/native_host.py"
