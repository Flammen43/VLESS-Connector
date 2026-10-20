# -*- coding: utf-8 -*-
"""Сбой старта хоста — тихий выход, а не «Unhandled exception».

exe собран с --noconsole: необработанное исключение при запуске даёт модальное
окно на рабочем столе (так выглядела установка с неполным каталогом _internal). Хост
обязан выйти кодом 1 без трейсбэка, оставив причину в файле.
"""

import os
import shutil
import subprocess
import sys
from pathlib import Path

HOST_DIR = Path(__file__).resolve().parent.parent / 'native-host-python'


def _run(host_dir, tmp, extra_env=None):
    env = dict(os.environ, TMP=str(tmp), TEMP=str(tmp), TMPDIR=str(tmp))
    env.update(extra_env or {})
    return subprocess.run(
        [sys.executable, str(host_dir / 'native_host.py')],
        input=b'', capture_output=True, timeout=30, env=env,
    )


def _startup_log(tmp):
    path = Path(tmp) / 'vlesschrome-host-startup.log'
    return path.read_text(encoding='utf-8') if path.exists() else ''


def test_unusable_data_dir_exits_quietly(tmp_path):
    blocker = tmp_path / 'file.txt'
    blocker.write_text('x')
    result = _run(HOST_DIR, tmp_path, {'VLESSCHROME_APP_DIR': str(blocker / 'sub')})
    assert result.returncode == 1
    assert b'Traceback' not in result.stderr
    assert 'bootstrap' in _startup_log(tmp_path)


def test_broken_import_exits_quietly(tmp_path):
    host = tmp_path / 'host'
    shutil.copytree(HOST_DIR, host, ignore=shutil.ignore_patterns('__pycache__'))
    (host / 'parsers.py').write_text("raise ImportError('модуль повреждён')\n", encoding='utf-8')
    result = _run(host, tmp_path, {'VLESSCHROME_APP_DIR': str(tmp_path / 'data')})
    assert result.returncode == 1
    assert b'Traceback' not in result.stderr
    log = _startup_log(tmp_path)
    assert 'imports' in log and 'повреждён' in log


def test_healthy_host_still_starts_and_exits_on_eof(tmp_path):
    result = _run(HOST_DIR, tmp_path, {'VLESSCHROME_APP_DIR': str(tmp_path / 'data')})
    assert b'Traceback' not in result.stderr
    assert _startup_log(tmp_path) == ''
