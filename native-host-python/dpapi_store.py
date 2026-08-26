# -*- coding: utf-8 -*-
"""Шифрование секретов at rest.

Windows: DPAPI (enc:v1:...).
Linux/macOS: ключ в системном keyring (Secret Service / Keychain) + Fernet
(enc:v2:...). Если keyring/cryptography недоступны или бэкенда нет
(headless-окружение без D-Bus secret service) — тихо откатываемся на
plaintext, как и раньше, ничего не ломая.
"""

import base64
import functools
import os

ENC_PREFIX = 'enc:v1:'
ENC_PREFIX_KEYRING = 'enc:v2:'

_KEYRING_SERVICE = 'VLESSChrome'
_KEYRING_USERNAME = 'secret-key'


def _crypt_protect(data: bytes) -> bytes:
    import ctypes
    from ctypes import wintypes

    class DATA_BLOB(ctypes.Structure):
        _fields_ = [
            ('cbData', wintypes.DWORD),
            ('pbData', ctypes.POINTER(ctypes.c_byte)),
        ]

    crypt32 = ctypes.windll.crypt32
    kernel32 = ctypes.windll.kernel32
    in_buf = ctypes.create_string_buffer(data, len(data))
    blob_in = DATA_BLOB(len(data), ctypes.cast(in_buf, ctypes.POINTER(ctypes.c_byte)))
    blob_out = DATA_BLOB()
    crypt_protect_ui_forbidden = 0x01
    if not crypt32.CryptProtectData(
        ctypes.byref(blob_in),
        None,
        None,
        None,
        None,
        crypt_protect_ui_forbidden,
        ctypes.byref(blob_out),
    ):
        raise OSError(f'CryptProtectData failed: {ctypes.GetLastError()}')
    try:
        return ctypes.string_at(blob_out.pbData, blob_out.cbData)
    finally:
        kernel32.LocalFree(blob_out.pbData)


def _crypt_unprotect(data: bytes) -> bytes:
    import ctypes
    from ctypes import wintypes

    class DATA_BLOB(ctypes.Structure):
        _fields_ = [
            ('cbData', wintypes.DWORD),
            ('pbData', ctypes.POINTER(ctypes.c_byte)),
        ]

    crypt32 = ctypes.windll.crypt32
    kernel32 = ctypes.windll.kernel32
    in_buf = ctypes.create_string_buffer(data, len(data))
    blob_in = DATA_BLOB(len(data), ctypes.cast(in_buf, ctypes.POINTER(ctypes.c_byte)))
    blob_out = DATA_BLOB()
    crypt_protect_ui_forbidden = 0x01
    if not crypt32.CryptUnprotectData(
        ctypes.byref(blob_in),
        None,
        None,
        None,
        None,
        crypt_protect_ui_forbidden,
        ctypes.byref(blob_out),
    ):
        raise OSError(f'CryptUnprotectData failed: {ctypes.GetLastError()}')
    try:
        return ctypes.string_at(blob_out.pbData, blob_out.cbData)
    finally:
        kernel32.LocalFree(blob_out.pbData)


@functools.lru_cache(maxsize=1)
def _keyring_fernet():
    """Ключ Fernet, хранящийся в системном keyring. Кэшируется на процесс.

    Может кинуть исключение (нет keyring/cryptography, нет secret service и
    т.п.) — вызывающий код обязан ловить и откатываться на plaintext.
    """
    import keyring
    from cryptography.fernet import Fernet

    key = keyring.get_password(_KEYRING_SERVICE, _KEYRING_USERNAME)
    if not key:
        key = Fernet.generate_key().decode('ascii')
        keyring.set_password(_KEYRING_SERVICE, _KEYRING_USERNAME, key)
    return Fernet(key.encode('ascii'))


def is_encrypted(text) -> bool:
    return isinstance(text, str) and (
        text.startswith(ENC_PREFIX) or text.startswith(ENC_PREFIX_KEYRING)
    )


def protect_secret(text: str) -> str:
    """Шифрует строку. Повторный вызов идемпотентен."""
    if text is None:
        return text
    if not text or is_encrypted(text):
        return text
    if os.name == 'nt':
        blob = _crypt_protect(text.encode('utf-8'))
        return ENC_PREFIX + base64.b64encode(blob).decode('ascii')
    try:
        token = _keyring_fernet().encrypt(text.encode('utf-8'))
        return ENC_PREFIX_KEYRING + token.decode('ascii')
    except Exception:
        # Нет keyring/cryptography или нет доступного secret-бэкенда
        # (типично для headless/SSH без D-Bus) — оставляем как есть, не роняем вызов.
        return text


def unprotect_secret(text: str) -> str:
    """Расшифровывает enc:v1:.../enc:v2:... или возвращает plaintext как есть."""
    if not text or not is_encrypted(text):
        return text
    if text.startswith(ENC_PREFIX):
        raw = base64.b64decode(text[len(ENC_PREFIX):])
        return _crypt_unprotect(raw).decode('utf-8')
    raw = text[len(ENC_PREFIX_KEYRING):].encode('ascii')
    return _keyring_fernet().decrypt(raw).decode('utf-8')
