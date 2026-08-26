#!/bin/bash
# Обёртка для Chrome: он запускает хост без PATH-контекста, поэтому
# интерпретатор подставляет установщик (см. quick-install.sh).
DIR="$(cd "$(dirname "$0")" && pwd)"
exec __PYTHON__ "$DIR/native_host.py"
