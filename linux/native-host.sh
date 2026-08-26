#!/bin/bash
# Обёртка для запуска native_host.py через Python3
DIR="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$DIR/native_host.py"
