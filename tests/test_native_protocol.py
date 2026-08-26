# -*- coding: utf-8 -*-
"""Протокол native messaging и выбор SOCKS-порта."""

import json
import socket
import struct
import sys

import pytest

import native_host
from native_host import (
    MAX_NATIVE_MESSAGE_BYTES,
    PORT_RETRIES,
    XrayManager,
    get_free_port,
    is_port_conflict,
    port_is_free,
    read_exactly,
    read_message,
)


class ChunkedStream:
    """Отдаёт данные порциями — так же, как настоящий пайп."""

    def __init__(self, data, chunk=3):
        self.data = data
        self.chunk = chunk
        self.pos = 0

    def read(self, n):
        end = min(self.pos + min(n, self.chunk), len(self.data))
        out = self.data[self.pos:end]
        self.pos = end
        return out


def encode_message(obj):
    body = json.dumps(obj).encode('utf-8')
    return struct.pack('=I', len(body)) + body


def feed(monkeypatch, data, chunk=3):
    stream = ChunkedStream(data, chunk=chunk)
    monkeypatch.setattr(sys, 'stdin', type('S', (), {'buffer': stream})())
    return stream


# ── read_exactly ────────────────────────────────────────────────

def test_read_exactly_assembles_chunks():
    stream = ChunkedStream(b'abcdefghij', chunk=3)
    assert read_exactly(stream, 10) == b'abcdefghij'


def test_read_exactly_stops_at_eof():
    stream = ChunkedStream(b'abc', chunk=2)
    assert read_exactly(stream, 10) == b'abc'


# ── read_message ────────────────────────────────────────────────

def test_read_message_reassembles_split_payload(monkeypatch):
    """Главный случай: длинный конфиг приходит несколькими порциями.

    Одиночный read() возвращал обрезанный JSON и ронял хост.
    """
    payload = {'action': 'start', 'config': {'wgConfig': 'x' * 5000}}
    feed(monkeypatch, encode_message(payload), chunk=7)
    assert read_message() == payload


def test_read_message_single_chunk(monkeypatch):
    payload = {'action': 'status'}
    feed(monkeypatch, encode_message(payload), chunk=10_000)
    assert read_message() == payload


def test_read_message_exits_on_closed_channel(monkeypatch):
    """Пустой stdin — расширение отключилось, это штатное завершение."""
    feed(monkeypatch, b'')
    with pytest.raises(SystemExit) as e:
        read_message()
    assert e.value.code == 0


def test_read_message_rejects_truncated_header(monkeypatch):
    feed(monkeypatch, b'\x01\x02')
    with pytest.raises(ValueError, match='заголовок 2 из 4'):
        read_message()


def test_read_message_rejects_truncated_body(monkeypatch):
    body = json.dumps({'action': 'start'}).encode('utf-8')
    # заявляем больше, чем реально отдаём
    feed(monkeypatch, struct.pack('=I', len(body) + 50) + body)
    with pytest.raises(ValueError, match='тело'):
        read_message()


def test_read_message_rejects_zero_length(monkeypatch):
    feed(monkeypatch, struct.pack('=I', 0))
    with pytest.raises(ValueError, match='Пустое сообщение'):
        read_message()


def test_read_message_rejects_oversized(monkeypatch):
    feed(monkeypatch, struct.pack('=I', MAX_NATIVE_MESSAGE_BYTES + 1))
    with pytest.raises(ValueError, match='too large'):
        read_message()


# ── порт ────────────────────────────────────────────────────────

def test_port_is_free_detects_occupied_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(('127.0.0.1', 0))
        busy = s.getsockname()[1]
        assert port_is_free(busy) is False
    # сокет закрыт — порт снова свободен
    assert port_is_free(busy) is True


def test_get_free_port_returns_usable_port():
    port = get_free_port()
    assert 0 < port < 65536
    assert port_is_free(port) is True


@pytest.mark.parametrize('text', [
    'failed to listen: address already in use',
    'Only one usage of each socket address is normally permitted',
    'bind: address in use',
])
def test_is_port_conflict_recognises_markers(text):
    assert is_port_conflict(text) is True


@pytest.mark.parametrize('text', [
    '', None, 'invalid vless uuid', 'failed to parse config',
])
def test_is_port_conflict_ignores_other_errors(text):
    assert is_port_conflict(text) is False


# ── повтор при занятом порте ────────────────────────────────────

def make_manager(tmp_path, monkeypatch):
    # APP_DIR обязателен: start() пишет конфиг и убирает старые профили прямо
    # в рабочем каталоге. Без подмены тест делает это в настоящем
    # %LOCALAPPDATA%\VLESSChrome и удаляет файлы пользователя.
    monkeypatch.setattr(native_host, 'APP_DIR', tmp_path)
    # Заглушка именно под тем именем, которое ждёт _init_paths: start()
    # вызывает его повторно и перетирает любой xray_path, выставленный здесь.
    # Раньше тест проходил только потому, что APP_DIR указывал на настоящий
    # каталог с настоящим xray.exe.
    (tmp_path / native_host.get_xray_binary_name()).write_text('stub')
    mgr = XrayManager()
    mgr._init_paths('test')
    monkeypatch.setattr(mgr, '_check_existing_process', lambda: None)
    return mgr


VALID_CONFIG = {'uuid': 'u-1', 'server': 'host.example', 'port': 443}


def test_start_retries_on_port_conflict(tmp_path, monkeypatch):
    """Порт перехватили — берём другой и пробуем снова."""
    mgr = make_manager(tmp_path, monkeypatch)
    attempts = []

    def fake_attempt(config):
        attempts.append(mgr.port)
        if len(attempts) < 3:
            return False, f'Порт {mgr.port} занят', True
        return True, None, False

    monkeypatch.setattr(mgr, '_start_attempt', fake_attempt)
    ok, msg, port = mgr.start('', VALID_CONFIG, 'test')

    assert ok is True
    assert len(attempts) == 3
    assert port == attempts[-1]


def test_start_gives_up_after_retry_limit(tmp_path, monkeypatch):
    mgr = make_manager(tmp_path, monkeypatch)
    calls = []

    def always_conflict(config):
        calls.append(mgr.port)
        return False, 'Порт занят', True

    monkeypatch.setattr(mgr, '_start_attempt', always_conflict)
    ok, msg, port = mgr.start('', VALID_CONFIG, 'test')

    assert ok is False
    assert port is None
    assert len(calls) == PORT_RETRIES


def test_start_does_not_retry_on_config_error(tmp_path, monkeypatch):
    """Ошибка в конфиге от смены порта не пройдёт — повторять бессмысленно."""
    mgr = make_manager(tmp_path, monkeypatch)
    calls = []

    def config_error(config):
        calls.append(mgr.port)
        return False, 'Xray не слушает порт (код 23): invalid uuid', False

    monkeypatch.setattr(mgr, '_start_attempt', config_error)
    ok, msg, port = mgr.start('', VALID_CONFIG, 'test')

    assert ok is False
    assert len(calls) == 1
    assert 'invalid uuid' in msg
