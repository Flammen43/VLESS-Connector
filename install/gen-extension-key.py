#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Одноразовая генерация ключа расширения: фиксирует Extension ID.

Chrome выводит ID распакованного расширения из абсолютного пути к его папке,
поэтому ID разный на каждой машине. Из-за этого манифест native host нельзя
заполнить заранее: приходилось загрузить расширение, скопировать ID, дописать
его в манифест и перезапустить браузер.

Поле "key" в manifest.json переопределяет это правило: Chrome считает ID из
публичного ключа, и он становится одинаковым везде. Значит, ID можно зашить
в манифест native host прямо в репозитории — и шаг с копированием отпадает.

ЗАПУСКАТЬ ОДИН РАЗ. Повторный запуск сменит Extension ID, и всем пользователям
придётся заново загружать расширение — поэтому скрипт отказывается
перезаписывать существующий приватный ключ.

Приватный ключ нужен только для упаковки .crx; для работы расширения достаточно
публичного, который лежит в manifest.json. В репозиторий приватный ключ не
коммитится (.gitignore).

Пример:
    py -3 install/gen-extension-key.py \
        --manifest extension/manifest.json \
        --host-manifest install/native-host-manifest.json \
        --host-manifest linux/install/native-host-manifest.json
"""

import argparse
import base64
import hashlib
import json
import sys
from pathlib import Path

try:
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
except ImportError:
    sys.exit('Нужен пакет cryptography:  py -3 -m pip install cryptography')

# Вывод может уходить в пайп (Git Bash, CI) — там Python берёт кодировку локали
# и русский текст ломается. В настоящей консоли Windows это не требуется.
if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')


def chrome_extension_id(der_public_key):
    """ID = первые 16 байт sha256(DER) в hex, где 0-9a-f заменены на a-p."""
    digest = hashlib.sha256(der_public_key).digest()[:16]
    return ''.join(chr(ord('a') + int(c, 16)) for c in digest.hex())


def patch_json(path, mutate, label):
    path = Path(path)
    if not path.exists():
        print(f'[SKIP] {label}: файл не найден ({path})')
        return False
    data = json.loads(path.read_text(encoding='utf-8'))
    mutate(data)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
    print(f'[OK] {label}: {path}')
    return True


def main():
    ap = argparse.ArgumentParser(
        description='Генерация постоянного Extension ID',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    ap.add_argument('--private-key', default='vlesschrome-private.pem',
                    help='куда сохранить приватный ключ (по умолчанию: %(default)s)')
    ap.add_argument('--manifest', action='append', default=[],
                    help='extension/manifest.json — прописать поле "key"')
    ap.add_argument('--host-manifest', action='append', default=[],
                    help='манифест native host — прописать allowed_origins (можно несколько)')
    args = ap.parse_args()

    priv_path = Path(args.private_key)
    if priv_path.exists():
        sys.exit(
            f'Приватный ключ уже существует: {priv_path}\n'
            'Повторная генерация сменит Extension ID и сломает установку у всех, '
            'кто уже загрузил расширение.\n'
            'Если это действительно нужно — удалите файл вручную и запустите снова.'
        )

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    priv_path.write_bytes(key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    ))

    der = key.public_key().public_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PublicFormat.SubjectPublicKeyInfo,
    )
    pub_b64 = base64.b64encode(der).decode('ascii')
    ext_id = chrome_extension_id(der)

    print()
    print(f'Extension ID   : {ext_id}')
    print(f'Приватный ключ : {priv_path}  (не коммитить, нужен только для .crx)')
    print()

    for m in args.manifest:
        patch_json(m, lambda d: d.update({'key': pub_b64}), 'key в манифесте расширения')

    origin = f'chrome-extension://{ext_id}/'
    for m in args.host_manifest:
        patch_json(m, lambda d: d.update({'allowed_origins': [origin]}), 'allowed_origins')

    print()
    print('Готово. Extension ID теперь одинаков на всех машинах.')


if __name__ == '__main__':
    main()
