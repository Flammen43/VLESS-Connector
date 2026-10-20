# -*- coding: utf-8 -*-
"""Формат шифртекста должен совпадать у хоста (dpapi_store.py) и у popup.js.

История бага: хост на macOS/Linux начал писать enc:v2:..., а popup.js знал
только enc:v1:. После перезапуска шифртекст не узнавался, не уходил на
расшифровку и принимался за обычный конфиг — пользователь видел «обрезанную»
абракадабру вместо ссылки, а подключение падало. Тест ловит такое расхождение,
пока оно ещё в коде, а не у пользователя.
"""

import re
from pathlib import Path

import pytest

import dpapi_store

ROOT = Path(__file__).resolve().parent.parent
POPUP_JS = (ROOT / 'extension' / 'popup.js').read_text(encoding='utf-8')


def host_prefixes():
    return {
        value for name, value in vars(dpapi_store).items()
        if name.startswith('ENC_PREFIX') and isinstance(value, str)
    }


def popup_prefixes():
    m = re.search(r"const ENC_PREFIXES\s*=\s*\[([^\]]*)\]", POPUP_JS)
    assert m, 'в popup.js нет массива ENC_PREFIXES'
    return set(re.findall(r"'([^']+)'", m.group(1)))


def test_host_declares_prefixes():
    """Если хост перестанет объявлять префиксы, остальные проверки ничего не значат."""
    assert host_prefixes() >= {'enc:v1:', 'enc:v2:'}


@pytest.mark.parametrize('prefix', sorted(host_prefixes()))
def test_popup_recognises_every_host_prefix(prefix):
    assert prefix in popup_prefixes(), (
        f'хост пишет {prefix}, а popup.js его не узнаёт: такие секреты не будут '
        f'расшифрованы и отобразятся как «обрезанный» конфиг'
    )


def test_popup_has_no_prefix_the_host_cannot_read():
    """Лишний префикс в popup — мёртвая ветка, которая когда-нибудь введёт в заблуждение."""
    unknown = popup_prefixes() - host_prefixes()
    assert not unknown, f'popup.js знает префиксы, которых нет у хоста: {unknown}'


def test_popup_does_not_fall_back_to_single_prefix_check():
    """Возврат к одиночной константе — ровно та регрессия, ради которой тест написан."""
    assert not re.search(r'startsWith\(\s*ENC_PREFIX\s*\)', POPUP_JS), (
        'popup.js снова сравнивает только с одним префиксом'
    )


@pytest.mark.parametrize('value', ['enc:v1:AQAAANCM', 'enc:v2:gAAAAABk'])
def test_host_treats_its_own_prefixes_as_encrypted(value):
    assert dpapi_store.is_encrypted(value)


def test_plaintext_is_not_mistaken_for_ciphertext():
    for plain in ('vless://u@h:443#enc:v2:', '[Interface]\nPrivateKey = x', ''):
        assert not dpapi_store.is_encrypted(plain)
