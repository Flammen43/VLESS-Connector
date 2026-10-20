# -*- coding: utf-8 -*-
"""Подсказки страницы настройки (extension/platform.js) не должны врать.

Страница учила только Windows: на Linux/macOS/Steam Deck человек видел
«Запустите install.bat». Теперь для каждой ОС там свои команды и пути, и этот
тест сверяет их с реальностью: скрипты существуют в репозитории, а каталог
данных совпадает с тем, что использует хост (app_dir_for).
"""

import re
from pathlib import Path

import pytest

from native_host import app_dir_for

ROOT = Path(__file__).resolve().parent.parent
PLATFORM_JS = (ROOT / 'extension' / 'platform.js').read_text(encoding='utf-8')
SETUP_JS = (ROOT / 'extension' / 'setup.js').read_text(encoding='utf-8')
SETUP_HTML = (ROOT / 'extension' / 'setup.html').read_text(encoding='utf-8')


def _hints():
    """{'win': {...}, 'mac': {...}, 'linux': {...}} из исходника, без JS-движка."""
    result = {}
    for os_key in ('win', 'mac', 'linux'):
        block = re.search(rf"\n  {os_key}: \{{(.*?)\n  \}},", PLATFORM_JS, re.S)
        assert block, f'нет блока {os_key}'
        fields = {}
        for name in ('installCmd', 'dataDir', 'logFile', 'checkCmd'):
            m = re.search(rf"{name}: (?:'((?:[^'\\]|\\.)*)'|(null))", block.group(1))
            assert m, f'{os_key}: нет поля {name}'
            fields[name] = None if m.group(2) else m.group(1).replace('\\\\', '\\')
        result[os_key] = fields
    return result


HINTS = _hints()


def _norm(path):
    # на Linux Path не разбирает «\», поэтому сравниваем строки
    return str(path).replace('\\', '/')


@pytest.mark.parametrize('os_key', ['win', 'mac', 'linux'])
def test_install_script_exists_in_repo(os_key):
    script = HINTS[os_key]['installCmd'].removeprefix('./')
    assert (ROOT / script).is_file(), f'{os_key}: {script} не найден'


@pytest.mark.parametrize('os_key', ['win', 'linux'])
def test_check_script_exists_in_repo(os_key):
    assert (ROOT / HINTS[os_key]['checkCmd']).is_file()


def test_mac_has_no_check_script_claimed():
    # на macOS проверочного скрипта нет — страница не должна его выдумывать
    assert HINTS['mac']['checkCmd'] is None
    assert not (ROOT / 'macos' / 'check-connection.sh').exists()


def test_data_dirs_match_what_the_host_uses():
    win = app_dir_for('nt', 'win32', Path('/h'), localappdata='%LOCALAPPDATA%')
    mac = app_dir_for('posix', 'darwin', Path('~'))
    linux = app_dir_for('posix', 'linux', Path('~'))
    assert _norm(HINTS['win']['dataDir']) == _norm(win)
    assert _norm(HINTS['mac']['dataDir']) == _norm(mac)
    assert _norm(HINTS['linux']['dataDir']) == _norm(linux)


@pytest.mark.parametrize('os_key', ['win', 'mac', 'linux'])
def test_log_lives_in_data_dir(os_key):
    h = HINTS[os_key]
    assert _norm(h['logFile']) == _norm(h['dataDir']) + '/native-host.log'


def test_setup_scripts_do_not_hardcode_windows_installer():
    # всё платформенное — через hints; «install.bat» допустим только как
    # значение по умолчанию в setup.html, которое setup.js перезаписывает
    assert 'install.bat' not in SETUP_JS
    assert "'%LOCALAPPDATA%" not in SETUP_JS.replace("hints ? hints.dataDir : '%LOCALAPPDATA%\\\\VLESSChrome'", '')


def test_platform_script_is_loaded_before_setup_script():
    assert SETUP_HTML.index('platform.js') < SETUP_HTML.index('setup.js')
