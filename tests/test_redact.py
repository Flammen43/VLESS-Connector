# -*- coding: utf-8 -*-
import native_host
from native_host import (
    MAX_NATIVE_MESSAGE_BYTES,
    MAX_SECRET_BATCH,
    redact_for_log,
    get_xray_binary_name,
    process_secret_batch,
    XrayManager,
)
from dpapi_store import ENC_PREFIX
import os
import struct


def test_redact_nested_secrets():
    msg = {
        'action': 'start',
        'config': {'secretKey': 'SECRET', 'uuid': 'u-1', 'server': 'ok.example'},
        'vlessUrl': 'vless://leak',
        'text': 'should-hide',
    }
    out = redact_for_log(msg)
    assert out['config']['secretKey'] == '***REDACTED***'
    assert out['config']['uuid'] == '***REDACTED***'
    assert out['config']['server'] == 'ok.example'
    assert out['vlessUrl'] == '***REDACTED***'
    assert out['text'] == '***REDACTED***'
    assert out['action'] == 'start'


def test_redact_list():
    assert redact_for_log([{'pbk': 'x'}]) == [{'pbk': '***REDACTED***'}]


def test_max_message_size():
    assert MAX_NATIVE_MESSAGE_BYTES == 4 * 1024 * 1024
    too_big = struct.pack('=I', MAX_NATIVE_MESSAGE_BYTES + 1)
    n = struct.unpack('=I', too_big)[0]
    assert n > MAX_NATIVE_MESSAGE_BYTES


def test_xray_binary_name():
    name = get_xray_binary_name()
    if os.name == 'nt':
        assert name == 'xray.exe'
    else:
        assert name == 'xray'


# ── каталог данных по платформам ────────────────────────────────
#
# Ветки платформенные, на одной ОС их вручную не проверить. Установочные
# скрипты обязаны класть файлы ровно туда, куда потом смотрит хост, поэтому
# путь фиксируем тестом.

def test_app_dir_on_macos_ignores_xdg():
    """macOS: рядом с манифестами браузеров, а не в ~/.config.

    XDG_CONFIG_HOME не должен перебивать: иначе путь зависел бы от случайно
    унаследованной переменной и разошёлся бы с установочным скриптом.
    """
    app_dir = native_host.app_dir_for(
        'posix', 'darwin', '/Users/u', xdg='/tmp/не-должен-победить'
    )
    assert app_dir.parts[-3:] == ('Library', 'Application Support', 'VLESSChrome')


def test_app_dir_on_linux_respects_xdg():
    app_dir = native_host.app_dir_for('posix', 'linux', '/home/u', xdg='/home/u/cfg')
    assert app_dir.parts[-2:] == ('cfg', 'VLESSChrome')


def test_app_dir_on_linux_without_xdg():
    app_dir = native_host.app_dir_for('posix', 'linux', '/home/u')
    assert app_dir.parts[-2:] == ('.config', 'VLESSChrome')


def test_app_dir_on_windows():
    app_dir = native_host.app_dir_for(
        'nt', 'win32', 'C:/Users/u', localappdata='C:/Users/u/AppData/Local'
    )
    assert app_dir.parts[-2:] == ('Local', 'VLESSChrome')


def test_app_dir_windows_without_localappdata_falls_back():
    """Без LOCALAPPDATA не падаем, а уходим на общий путь."""
    app_dir = native_host.app_dir_for('nt', 'win32', 'C:/Users/u')
    assert app_dir.parts[-2:] == ('.config', 'VLESSChrome')


def test_validate_config_reality_requires_pbk():
    mgr = XrayManager()
    base = {'uuid': 'u-1', 'server': 'host.example', 'port': 443, 'security': 'reality'}
    err = mgr._validate_config(base)
    assert err is not None
    assert 'pbk' in err

    ok = dict(base, pbk='some-public-key')
    assert mgr._validate_config(ok) is None


def test_validate_config_tls_does_not_require_pbk():
    mgr = XrayManager()
    cfg = {'uuid': 'u-1', 'server': 'host.example', 'port': 443, 'security': 'tls'}
    assert mgr._validate_config(cfg) is None


def test_redact_hides_batch_items():
    """items — список голых секретов, без явного правила он утёк бы в лог."""
    out = redact_for_log({'action': 'unprotectMany', 'items': ['vless://leak', 'enc:v1:x']})
    assert out['items'] == '***REDACTED***'
    assert out['action'] == 'unprotectMany'


def test_secret_batch_roundtrip():
    secrets = ['vless://uuid@host:443#a', 'PrivateKey = abc']
    enc = process_secret_batch('protectMany', secrets)
    assert all(r['ok'] for r in enc)
    dec = process_secret_batch('unprotectMany', [r['data'] for r in enc])
    assert [r['data'] for r in dec] == secrets


def test_secret_batch_one_bad_item_does_not_kill_others():
    """Битый ciphertext не должен ронять расшифровку остальных профилей."""
    good = process_secret_batch('protectMany', ['keep-me'])[0]['data']
    results = process_secret_batch(
        'unprotectMany',
        [good, ENC_PREFIX + 'не-base64-и-не-blob', 'plaintext-passthrough'],
    )
    assert results[0] == {'ok': True, 'data': 'keep-me'}
    assert results[1]['ok'] is False
    assert 'error' in results[1]
    assert results[2] == {'ok': True, 'data': 'plaintext-passthrough'}


def test_secret_batch_handles_non_string_items():
    results = process_secret_batch('protectMany', [None, 123])
    assert all(r['ok'] for r in results)
    assert all(r['data'] == '' for r in results)


def test_secret_batch_limit_is_sane():
    assert 0 < MAX_SECRET_BATCH <= 1000
