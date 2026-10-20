# -*- coding: utf-8 -*-
"""Закрепляет находки аудита безопасности и надёжности хоста.

Каждый тест описывает конкретный сбой, найденный на настоящем коде, а не
абстрактное «правильное поведение».
"""

import io
import json
import os
import struct
import sys

import pytest

import native_host
from native_host import (
    PRIVATE_FILE_MODE,
    MessageDecodeError,
    XrayManager,
    handle_message,
    mask_host,
    read_message,
    redact_for_log,
    restrict_permissions,
    write_private_text,
)

VLESS = {
    'protocol': 'vless', 'uuid': 'u-1', 'server': 'host.example',
    'port': 443, 'security': 'tls', 'type': 'tcp',
}
WIREGUARD = {
    'protocol': 'wireguard', 'secretKey': 'sk', 'address': ['10.0.0.2/32'],
    'peers': [{'publicKey': 'pk', 'endpoint': 'wg.example.com:51820',
               'allowedIPs': ['0.0.0.0/0'], 'keepAlive': 25}],
}


# ── 1. SOCKS слушает только loopback ────────────────────────────
#
# Без listen Xray занимает все интерфейсы. Проверено на настоящем xray: порт
# оказывался на :: и был достижим по сетевому адресу машины, а SOCKS без
# пароля — то есть открытый прокси в туннель пользователя для всей сети.

@pytest.mark.parametrize('cfg', [VLESS, WIREGUARD, {**VLESS, 'routeRuDirect': True}],
                         ids=['vless', 'wireguard', 'vless+ru-direct'])
def test_socks_inbound_listens_on_loopback_only(cfg):
    inbound = XrayManager()._generate_config(cfg)['inbounds'][0]
    assert inbound['listen'] == '127.0.0.1'


def test_socks_inbound_never_unauthenticated_on_public_interface():
    """Страховка от «упрощения»: noauth допустим только при явном loopback."""
    inbound = XrayManager()._generate_config(VLESS)['inbounds'][0]
    if inbound['settings']['auth'] == 'noauth':
        assert inbound.get('listen') in ('127.0.0.1', 'localhost', '::1')


# ── 5. Данные подключения не попадают в лог ─────────────────────

REALITY_CONFIG = {
    'uuid': 'b831381d-6324-4d53-ad4f-8cda48b30811',
    'server': 'my-secret-vpn.example.com', 'port': 443, 'security': 'reality',
    'pbk': 'PUBLICKEY', 'sid': 'a1b2c3d4', 'spx': '/spider',
    'sni': 'www.microsoft.com', 'path': '/secret-path-token',
    'host': 'front.example.com', 'serviceName': 'secret-grpc',
    'flow': 'xtls-rprx-vision', 'type': 'tcp', 'fingerprint': 'chrome',
}


@pytest.mark.parametrize('key', ['uuid', 'pbk', 'sid', 'spx', 'path', 'server',
                                 'host', 'sni', 'serviceName'])
def test_connection_details_are_redacted(key):
    out = redact_for_log({'action': 'start', 'config': REALITY_CONFIG})
    assert out['config'][key] == '***REDACTED***', f'{key} попадает в лог'


def test_redaction_keeps_fields_needed_for_diagnostics():
    cfg = redact_for_log({'config': REALITY_CONFIG})['config']
    for key in ('port', 'security', 'flow', 'type', 'fingerprint'):
        assert cfg[key] == REALITY_CONFIG[key], f'{key} скрыт зря — лог станет бесполезным'


def test_wireguard_endpoint_is_redacted_inside_peers():
    out = redact_for_log({'config': WIREGUARD})
    assert out['config']['peers'][0]['endpoint'] == '***REDACTED***'
    assert out['config']['peers'][0]['publicKey'] == 'pk'   # публичный ключ не секрет


def test_serialised_log_line_contains_no_secret_values():
    """Сквозная проверка: ищем значения в итоговой строке, а не в структуре."""
    line = str(redact_for_log({'action': 'start', 'config': REALITY_CONFIG}))
    for secret in ('b831381d', 'a1b2c3d4', 'secret-path-token', 'my-secret-vpn',
                   'front.example.com', 'PUBLICKEY', 'secret-grpc'):
        assert secret not in line, f'«{secret}» утекает в лог'


@pytest.mark.parametrize('host,expected', [
    ('127.0.0.1', '127.0.0.1'), ('localhost', 'localhost'), ('::1', '::1'),
    ('vpn.example.com', '***'), ('203.0.113.7', '***'), ('', '***'),
])
def test_mask_host(host, expected):
    assert mask_host(host) == expected


# ── 4. Одно битое сообщение не убивает хост ─────────────────────
#
# Раньше исключение в обработчике команды уходило в main(), где было
# sys.exit(1): хост умирал, а через atexit останавливался и работающий xray.

class FakeManager:
    """Хватает ровно того, что трогает handle_message."""
    def start(self, *a):  raise OSError('диск переполнен')
    def stop(self, client_id=None): return True, 'ok'
    def is_running(self): return False, 'stopped'
    def _init_paths(self, cid): pass


@pytest.fixture
def no_network(monkeypatch):
    """Тесты ping не должны ходить в сеть: на Windows закрытый порт loopback
    отвечает ~2 с, а результат сокета тут ничего не доказывает."""
    monkeypatch.setattr(native_host, 'ping_host',
                        lambda *a, **kw: (_ for _ in ()).throw(OSError('заглушка')))


@pytest.mark.parametrize('bad_port', ['abc', [], {}, 'NaN', -5, 70000, '99999'])
def test_ping_with_bad_port_returns_error_instead_of_raising(bad_port, no_network):
    resp = handle_message(FakeManager(), {
        'id': 7, 'action': 'ping', 'host': '127.0.0.1', 'port': bad_port})
    assert resp['id'] == 7
    assert resp['success'] is False
    assert 'error' in resp


@pytest.mark.parametrize('empty_port', [None, '', 0])
def test_ping_with_empty_port_keeps_default_443(empty_port, no_network):
    """Пустое значение — прежнее поведение (порт по умолчанию), не ошибка ввода:
    ответ приходит от самого ping (заглушка), а не от проверки порта."""
    resp = handle_message(FakeManager(), {
        'id': 3, 'action': 'ping', 'host': '127.0.0.1', 'port': empty_port})
    assert resp['error'] == 'заглушка'


def test_ping_with_non_numeric_port_reports_clear_error(no_network):
    resp = handle_message(FakeManager(), {
        'id': 1, 'action': 'ping', 'host': '127.0.0.1', 'port': 'abc'})
    assert resp['success'] is False
    assert 'порт' in resp['error'].lower()


@pytest.mark.parametrize('payload', [[], 'text', 42, None, [1, 2, 3]])
def test_non_object_message_gets_error_response(payload):
    resp = handle_message(FakeManager(), payload)
    assert resp['success'] is False and 'error' in resp


def test_exception_in_command_propagates_for_main_to_convert():
    """handle_message не глотает исключения сам — это делает main(), чтобы
    ответ всегда получал id запроса."""
    with pytest.raises(OSError):
        handle_message(FakeManager(), {'id': 1, 'action': 'start', 'config': VLESS})


def test_protect_failure_is_not_reported_as_success(monkeypatch):
    """Раньше success=True выставлялся до вызова и оставался при исключении."""
    def boom(_): raise RuntimeError('keyring недоступен')
    monkeypatch.setattr(native_host, 'protect_secret', boom)
    resp = handle_message(FakeManager(), {'id': 1, 'action': 'protect', 'text': 'x'})
    assert resp['success'] is False
    assert 'keyring' in resp['error']
    assert 'data' not in resp


def frame(body: bytes) -> io.BytesIO:
    return io.BytesIO(struct.pack('=I', len(body)) + body)


def feed(monkeypatch, stream):
    monkeypatch.setattr(sys, 'stdin', type('S', (), {'buffer': stream})())


@pytest.mark.parametrize('body', [b'{not json', b'\xff\xfe\x00bad', b'[1,2', b'{"a":'])
def test_undecodable_body_is_recoverable(monkeypatch, body):
    """Рамка цела, тело битое — поток не рассинхронизирован, жить можно."""
    feed(monkeypatch, frame(body))
    with pytest.raises(MessageDecodeError):
        read_message()


def test_decode_error_stays_a_valueerror():
    """Прежний код ловил ValueError — подкласс обязан его не сломать."""
    assert issubclass(MessageDecodeError, ValueError)


def test_next_message_is_readable_after_a_bad_one(monkeypatch):
    """Главное свойство: после битого сообщения хост читает следующее."""
    good = json.dumps({'id': 5, 'action': 'status'}).encode()
    feed(monkeypatch, io.BytesIO(
        struct.pack('=I', 8) + b'{broken!' + struct.pack('=I', len(good)) + good))
    with pytest.raises(MessageDecodeError):
        read_message()
    assert read_message()['id'] == 5


def test_truncated_frame_is_still_fatal(monkeypatch):
    """Обрыв — не то же самое, что битый JSON: после него читать нельзя."""
    feed(monkeypatch, io.BytesIO(struct.pack('=I', 100) + b'short'))
    with pytest.raises(ValueError) as e:
        read_message()
    assert not isinstance(e.value, MessageDecodeError)


# ── 6. Права на файлы с ключами ─────────────────────────────────
#
# На Unix config_<id>.json (UUID/приватный ключ) создавался по umask — обычно
# 0644, то есть читаемым всеми. chmod нигде не вызывался.

def test_write_private_text_roundtrip_and_overwrite(tmp_path):
    p = tmp_path / 'config.json'
    write_private_text(p, '{"a": 1}')
    assert p.read_text(encoding='utf-8') == '{"a": 1}'
    write_private_text(p, '{"b": 2}')                    # перезапись, не дозапись
    assert p.read_text(encoding='utf-8') == '{"b": 2}'


def test_write_private_text_handles_unicode(tmp_path):
    p = tmp_path / 'c.json'
    text = '{"name": "Сервер ✓ 日本"}'
    write_private_text(p, text)
    assert p.read_text(encoding='utf-8') == text


def test_file_is_created_with_private_mode(tmp_path, monkeypatch):
    """Права запрашиваются при создании, а не chmod'ом постфактум — иначе есть
    окно, когда ключ читаем всеми."""
    seen = {}
    real_open = os.open

    def spy(path, flags, mode=0o777, **kw):
        seen['mode'] = mode
        return real_open(path, flags, mode)

    monkeypatch.setattr(native_host.os, 'open', spy)
    write_private_text(tmp_path / 'c.json', '{}')
    assert seen['mode'] == PRIVATE_FILE_MODE == 0o600


def test_chmod_is_applied_after_write_for_preexisting_files(tmp_path, monkeypatch):
    """mode у os.open действует только при создании: файл, уже лежавший с 0644,
    остался бы открытым без повторного chmod."""
    calls = []
    monkeypatch.setattr(native_host.os, 'chmod', lambda p, m: calls.append((str(p), m)))
    monkeypatch.setattr(native_host, 'restrict_permissions',
                        lambda p, m, enabled=None: calls.append((str(p), m)) or True)
    write_private_text(tmp_path / 'c.json', '{}')
    assert calls and calls[-1][1] == 0o600


def test_restrict_permissions_is_noop_on_windows_semantics(tmp_path):
    f = tmp_path / 'x'
    f.write_text('x')
    assert restrict_permissions(f, 0o600, enabled=False) is False


def test_restrict_permissions_calls_chmod_when_enabled(tmp_path, monkeypatch):
    calls = []
    monkeypatch.setattr(native_host.os, 'chmod', lambda p, m: calls.append((str(p), m)))
    f = tmp_path / 'x'
    f.write_text('x')
    assert restrict_permissions(f, 0o700, enabled=True) is True
    assert calls == [(str(f), 0o700)]


def test_restrict_permissions_survives_chmod_failure(tmp_path, monkeypatch):
    """Чужой владелец / ФС без chmod не должны ронять хост."""
    def deny(p, m): raise PermissionError('чужой файл')
    monkeypatch.setattr(native_host.os, 'chmod', deny)
    f = tmp_path / 'x'
    f.write_text('x')
    assert restrict_permissions(f, 0o600, enabled=True) is False


@pytest.mark.skipif(os.name == 'nt', reason='биты доступа существуют только на Unix')
def test_real_file_mode_on_unix(tmp_path):
    p = tmp_path / 'config.json'
    p.write_text('старый, открытый')
    os.chmod(p, 0o644)
    write_private_text(p, '{"uuid": "secret"}')
    assert oct(p.stat().st_mode & 0o777) == oct(0o600)


@pytest.mark.skipif(os.name == 'nt', reason='биты доступа существуют только на Unix')
def test_real_dir_mode_on_unix(tmp_path):
    d = tmp_path / 'data'
    d.mkdir(mode=0o755)
    restrict_permissions(d, native_host.PRIVATE_DIR_MODE)
    assert oct(d.stat().st_mode & 0o777) == oct(0o700)


# ── 11. Разбор ссылок: зеркальные правки на стороне хоста ───────────────

def test_wireguard_inline_comments_do_not_leak_into_values():
    from parsers import wireguard_conf_to_config
    cfg = wireguard_conf_to_config(
        '[Interface]\nPrivateKey = SECRET= # мой ключ\nAddress = 10.0.0.2/32 # адрес\n'
        '[Peer]\nPublicKey = PUB= # сервер\nEndpoint = wg.example.com:51820 # основной\n'
        'PersistentKeepalive = 25 # NAT\n'
    )
    assert cfg['secretKey'] == 'SECRET='
    assert cfg['address'] == ['10.0.0.2/32']
    assert cfg['peers'][0]['publicKey'] == 'PUB='
    assert cfg['peers'][0]['endpoint'] == 'wg.example.com:51820'
    assert cfg['peers'][0]['keepAlive'] == 25


def test_ipv6_server_brackets_are_stripped_for_xray():
    manager = XrayManager()
    for raw in ('[2001:db8::1]', '2001:db8::1'):
        cfg = manager._generate_vless_config({**VLESS, 'server': raw})
        address = cfg['outbounds'][0]['settings']['vnext'][0]['address']
        assert address == '2001:db8::1'


def test_plain_hostname_is_not_touched():
    cfg = XrayManager()._generate_vless_config({**VLESS, 'server': 'host.example'})
    assert cfg['outbounds'][0]['settings']['vnext'][0]['address'] == 'host.example'


def test_grpc_without_service_name_omits_it():
    cfg = XrayManager()._generate_vless_config({**VLESS, 'type': 'grpc', 'path': ''})
    assert cfg['outbounds'][0]['streamSettings']['grpcSettings'] == {}


# ── ping: адрес не должен становиться опцией системного ping ───────────

@pytest.mark.parametrize('bad', ['-f', '-s 65500 x', '--help', '', None, 'a b', 'x;rm', '$(id)'])
def test_icmp_ping_rejects_option_like_targets(monkeypatch, bad):
    import host_ping
    monkeypatch.setattr(host_ping.subprocess, 'run',
                        lambda *a, **k: pytest.fail('ping запущен с недопустимой целью'))
    with pytest.raises(ValueError):
        host_ping.icmp_ping(bad)


@pytest.mark.parametrize('good,expected', [
    ('example.com', 'example.com'), ('1.2.3.4', '1.2.3.4'),
    ('[2001:db8::1]', '2001:db8::1'), ('xn--80asehdb.рф', 'xn--80asehdb.рф'),
])
def test_icmp_ping_accepts_normal_targets(good, expected):
    import host_ping
    assert host_ping.safe_ping_target(good) == expected
