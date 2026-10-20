# -*- coding: utf-8 -*-
"""Запускает tests/js/links.test.js через node (если он установлен).

Разбор ссылок живёт в JS (extension/links.js), и Python-тесты его не видят.
Без node тест пропускается — тогда JS-тесты стоит гонять в CI или руками.
"""

import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
NODE = shutil.which('node')


@pytest.mark.skipif(NODE is None, reason='node не установлен')
def test_link_parsers_js():
    result = subprocess.run(
        [NODE, str(ROOT / 'tests' / 'js' / 'links.test.js')],
        capture_output=True, text=True, timeout=60, encoding='utf-8',
    )
    assert result.returncode == 0, result.stderr or result.stdout


def test_popup_loads_link_parsers_before_popup_script():
    html = (ROOT / 'extension' / 'popup.html').read_text(encoding='utf-8')
    assert html.index('links.js') < html.index('popup.js')


def test_parsers_are_not_duplicated_in_popup():
    # две копии разбора расходятся: правка попадёт в одну, а работать будет другая
    popup = (ROOT / 'extension' / 'popup.js').read_text(encoding='utf-8')
    for name in ('parseVlessUrl', 'parseWireGuardConf', 'parseEndpoint', 'extractProfileName'):
        assert f'function {name}(' not in popup, f'{name} снова определён в popup.js'


@pytest.mark.skipif(NODE is None, reason='node не установлен')
def test_proxy_rules_js():
    result = subprocess.run(
        [NODE, str(ROOT / 'tests' / 'js' / 'proxy-rules.test.js')],
        capture_output=True, text=True, timeout=60, encoding='utf-8',
    )
    assert result.returncode == 0, result.stderr or result.stdout


def test_background_uses_shared_bypass_rules_and_lan_toggle_is_wired():
    ext = ROOT / 'extension'
    background = (ext / 'background.js').read_text(encoding='utf-8')
    popup = (ext / 'popup.js').read_text(encoding='utf-8')
    html = (ext / 'popup.html').read_text(encoding='utf-8')
    assert (ext / 'proxy-rules.js').is_file()
    assert "importScripts('proxy-rules.js')" in background
    assert 'buildBypassList(lanDirect)' in background
    # прежний жёсткий список не должен вернуться
    assert "bypassList: ['localhost'" not in background
    assert "action === 'refreshProxy'" in background
    assert "sendMessage({ action: 'refreshProxy' })" in popup
    assert 'id="lanDirect"' in html
