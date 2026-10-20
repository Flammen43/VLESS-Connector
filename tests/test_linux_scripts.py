# -*- coding: utf-8 -*-
"""Linux-скрипты: список Flatpak-браузеров общий, окончания строк — LF.

Список Flatpak-браузеров продублирован в четырёх скриптах (каждый запускается
сам по себе, общей библиотеки нет). Расхождение выглядит так: установщик
зарегистрировал хост в Vivaldi, а удаление и обновление Extension ID про него
не знают — манифест остаётся со старым ID или после удаления.
"""

import re
import shutil
import subprocess
from pathlib import Path

import pytest

LINUX = Path(__file__).resolve().parent.parent / 'linux'
SCRIPTS_WITH_LIST = [
    LINUX / 'quick-install.sh',
    LINUX / 'check-connection.sh',
    LINUX / 'install' / 'uninstall.sh',
    LINUX / 'install' / 'update-extension-id.sh',
]
ALL_SCRIPTS = sorted(LINUX.rglob('*.sh'))


def _flatpak_list(path):
    text = path.read_text(encoding='utf-8')
    block = re.search(r'FLATPAK_BROWSERS=\((.*?)\n\)', text, re.S)
    assert block, f'{path.name}: не найден список FLATPAK_BROWSERS'
    return re.findall(r'"([^"|]+\|[^"]+)"', block.group(1))


def test_flatpak_browser_lists_are_identical():
    lists = {p.name: _flatpak_list(p) for p in SCRIPTS_WITH_LIST}
    reference = lists['quick-install.sh']
    assert len(reference) >= 5
    for name, entries in lists.items():
        assert entries == reference, f'{name} разошёлся с quick-install.sh'


@pytest.mark.parametrize('path', ALL_SCRIPTS, ids=lambda p: p.name)
def test_shell_scripts_use_lf(path):
    # CRLF в shebang даёт «bad interpreter: /bin/bash^M»
    assert b'\r' not in path.read_bytes()


def _bash_works():
    exe = shutil.which('bash')
    if not exe:
        return None
    try:
        ok = subprocess.run([exe, '-c', 'true'], capture_output=True, timeout=10).returncode == 0
    except Exception:
        return None
    return exe if ok else None


@pytest.mark.skipif(_bash_works() is None, reason='нет рабочего bash')
@pytest.mark.parametrize('path', ALL_SCRIPTS, ids=lambda p: p.name)
def test_shell_scripts_parse(path):
    result = subprocess.run([_bash_works(), '-n', str(path)], capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stderr
