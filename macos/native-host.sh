#!/bin/bash
# Обёртка для Chrome: он запускает хост без PATH-контекста, поэтому
# интерпретатор подставляет установщик (см. quick-install.sh).
DIR="$(cd "$(dirname "$0")" && pwd)"
# VLESSCHROME_APP_DIR — каталог, где лежит сам хост. Без него внутри
# песочницы Flatpak сработал бы подменённый XDG_CONFIG_HOME, и xray
# искался бы в ~/.var/app/<id>/config вместо каталога установки.
export VLESSCHROME_APP_DIR="$DIR"
exec __PYTHON__ "$DIR/native_host.py"
