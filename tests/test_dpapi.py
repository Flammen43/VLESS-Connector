# -*- coding: utf-8 -*-
import os

import pytest

import dpapi_store
from dpapi_store import ENC_PREFIX, ENC_PREFIX_KEYRING, is_encrypted, protect_secret, unprotect_secret


def test_plaintext_passthrough_unprotect():
    assert unprotect_secret('vless://plain') == 'vless://plain'
    assert unprotect_secret('') == ''
    assert unprotect_secret(None) is None


def test_protect_idempotent_and_empty():
    assert protect_secret('') == ''
    already = ENC_PREFIX + 'abc'
    assert protect_secret(already) == already
    already_v2 = ENC_PREFIX_KEYRING + 'abc'
    assert protect_secret(already_v2) == already_v2


@pytest.mark.skipif(os.name != 'nt', reason='DPAPI только на Windows')
def test_dpapi_roundtrip():
    secret = 'vless://uuid@host:443?security=tls#x\nPrivateKey = abc'
    enc = protect_secret(secret)
    assert is_encrypted(enc)
    assert enc != secret
    assert unprotect_secret(enc) == secret
    assert protect_secret(enc) == enc


@pytest.mark.skipif(os.name == 'nt', reason='на Windows шифруем через DPAPI')
def test_non_windows_keyring_roundtrip(monkeypatch):
    """Когда keyring/cryptography доступны и есть рабочий secret-бэкенд —
    секреты шифруются локальным Fernet-ключом (enc:v2:...), а не лежат как есть."""
    from cryptography.fernet import Fernet

    fake_fernet = Fernet(Fernet.generate_key())
    monkeypatch.setattr(dpapi_store, '_keyring_fernet', lambda: fake_fernet)

    secret = 'PrivateKey = abc'
    enc = protect_secret(secret)
    assert is_encrypted(enc)
    assert enc.startswith(ENC_PREFIX_KEYRING)
    assert enc != secret
    assert unprotect_secret(enc) == secret
    assert protect_secret(enc) == enc


@pytest.mark.skipif(os.name == 'nt', reason='на Windows шифруем через DPAPI')
def test_non_windows_falls_back_to_plaintext_without_keyring_backend(monkeypatch):
    """Нет keyring/cryptography или нет secret-бэкенда (headless/SSH без D-Bus) —
    protect_secret не должен падать, просто оставляет текст как есть."""
    def boom():
        raise RuntimeError('no keyring backend available')

    monkeypatch.setattr(dpapi_store, '_keyring_fernet', boom)
    secret = 'PrivateKey = abc'
    assert protect_secret(secret) == secret
