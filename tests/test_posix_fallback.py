# -*- coding: utf-8 -*-
"""Остановка и опрос xray по PID на Linux/macOS, когда psutil недоступен.

Раньше без psutil хост на POSIX не мог ни остановить осиротевший xray (путь
был только через taskkill), ни увидеть его в status. Реальные сигналы здесь не
шлются: os.kill на Windows завершает процесс, поэтому всё идёт через инъекцию.
"""

import os
import signal
import subprocess
import types

import pytest

import native_host
from native_host import XrayManager


class _PosixOs:
    """os, который притворяется POSIX: подменять os.name глобально нельзя —
    по нему pathlib выбирает тип путей."""
    name = 'posix'

    def __getattr__(self, attr):
        return getattr(os, attr)


@pytest.fixture
def posix(monkeypatch):
    monkeypatch.setattr(native_host, 'os', _PosixOs())
    monkeypatch.setattr(native_host, 'psutil', None)


def _ps_output(monkeypatch, stdout):
    calls = []

    def fake_run(cmd, **kwargs):
        calls.append(cmd)
        return types.SimpleNamespace(stdout=stdout, returncode=0)

    monkeypatch.setattr(native_host.subprocess, 'run', fake_run)
    return calls


def _manager(tmp_path, pid_text=None):
    manager = XrayManager()
    manager.pid_file = tmp_path / 'xray_t.pid'
    if pid_text is not None:
        manager.pid_file.write_text(pid_text)
    return manager


# ── определение процесса ─────────────────────────────────────────

def test_process_name_from_ps_strips_macos_path(monkeypatch):
    # на macOS ps отдаёт полный путь, на Linux — короткое имя
    _ps_output(monkeypatch, '/Users/me/.config/VLESSChrome/xray\n')
    assert native_host.posix_process_name(4242) == 'xray'


def test_process_name_empty_when_ps_fails(monkeypatch):
    def boom(*a, **k):
        raise FileNotFoundError('ps')
    monkeypatch.setattr(native_host.subprocess, 'run', boom)
    assert native_host.posix_process_name(4242) == ''


@pytest.mark.parametrize('name,expected', [('xray', True), ('bash', False), ('', False)])
def test_alive_checks_name_not_just_pid(posix, monkeypatch, name, expected):
    # PID из файла мог пережить перезагрузку и достаться чужому процессу
    monkeypatch.setattr(native_host, 'posix_process_name', lambda pid: name)
    assert native_host.is_xray_pid_alive(4242) is expected


def test_is_running_sees_orphan_by_pid_file(posix, monkeypatch, tmp_path):
    monkeypatch.setattr(native_host, 'posix_process_name', lambda pid: 'xray')
    assert _manager(tmp_path, '4242').is_running() == (True, 'running')


def test_is_running_ignores_pid_taken_by_other_process(posix, monkeypatch, tmp_path):
    monkeypatch.setattr(native_host, 'posix_process_name', lambda pid: 'firefox')
    assert _manager(tmp_path, '4242').is_running() == (False, 'stopped')


# ── остановка ────────────────────────────────────────────────────

def _kill_spy(monkeypatch):
    sent = []
    monkeypatch.setattr(native_host, '_os_kill', lambda pid, sig: sent.append((pid, sig)))
    return sent


def test_terminate_sends_sigterm_and_stops_when_process_exits(posix, monkeypatch):
    alive = iter([True, True, False])        # проверка перед сигналом, один опрос, исход
    monkeypatch.setattr(native_host, 'is_xray_pid_alive', lambda pid: next(alive))
    monkeypatch.setattr(native_host.time, 'sleep', lambda s: None)
    sent = _kill_spy(monkeypatch)
    assert native_host.posix_terminate(4242) is True
    assert sent == [(4242, signal.SIGTERM)]


def test_terminate_escalates_to_sigkill_when_process_ignores_sigterm(posix, monkeypatch):
    monkeypatch.setattr(native_host, 'is_xray_pid_alive', lambda pid: True)
    monkeypatch.setattr(native_host.time, 'sleep', lambda s: None)
    ticks = iter(range(0, 1000))
    monkeypatch.setattr(native_host.time, 'monotonic', lambda: next(ticks))
    sent = _kill_spy(monkeypatch)
    assert native_host.posix_terminate(4242, timeout=3) is True
    assert [s for _, s in sent] == [signal.SIGTERM, getattr(signal, 'SIGKILL', signal.SIGTERM)]


def test_terminate_never_signals_foreign_process(posix, monkeypatch):
    monkeypatch.setattr(native_host, 'is_xray_pid_alive', lambda pid: False)
    sent = _kill_spy(monkeypatch)
    assert native_host.posix_terminate(4242) is False
    assert sent == []


def test_terminate_tolerates_process_vanishing(posix, monkeypatch):
    monkeypatch.setattr(native_host, 'is_xray_pid_alive', lambda pid: True)

    def gone(pid, sig):
        raise ProcessLookupError()
    monkeypatch.setattr(native_host, '_os_kill', gone)
    assert native_host.posix_terminate(4242) is False


def test_stop_pid_without_psutil_uses_signals_on_posix(posix, monkeypatch, tmp_path):
    called = []
    monkeypatch.setattr(native_host, 'is_xray_pid_alive', lambda pid: True)
    monkeypatch.setattr(native_host, 'posix_terminate', lambda pid: called.append(pid) or True)
    assert _manager(tmp_path)._stop_pid(4242) is True
    assert called == [4242]


def test_stop_pid_without_psutil_skips_foreign_pid_on_windows_too(monkeypatch, tmp_path):
    # taskkill /F по PID из файла без проверки имени убил бы чужой процесс
    monkeypatch.setattr(native_host, 'psutil', None)
    monkeypatch.setattr(native_host, 'is_xray_pid_alive', lambda pid: False)
    manager = _manager(tmp_path)
    monkeypatch.setattr(manager, '_taskkill_tree', lambda pid: pytest.fail('убит чужой процесс'))
    assert manager._stop_pid(4242) is False


# ── защита от os.kill на Windows ─────────────────────────────────

@pytest.mark.skipif(os.name != 'nt', reason='проверяет именно поведение Windows')
def test_os_kill_wrapper_refuses_on_windows(monkeypatch):
    monkeypatch.setattr(os, 'kill', lambda *a: pytest.fail('os.kill вызван на Windows'))
    with pytest.raises(RuntimeError):
        native_host._os_kill(4242, 0)


# ── домашний каталог ─────────────────────────────────────────────

def test_explicit_app_dir_does_not_need_home(monkeypatch, tmp_path):
    def no_home():
        raise RuntimeError('нет домашнего каталога')
    monkeypatch.setattr(native_host.Path, 'home', staticmethod(no_home))
    monkeypatch.setenv('VLESSCHROME_APP_DIR', str(tmp_path))
    assert native_host.get_app_dir() == tmp_path
