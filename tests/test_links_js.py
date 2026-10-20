# -*- coding: utf-8 -*-
"""JS-часть расширения: запуск tests/js/*.test.js через node и проверки «проводки».

Разбор ссылок, правила обхода прокси, сверка версий и логика background.js живут
в JS, и Python-тесты их не видят. Без node запуск пропускается — тогда JS-тесты
стоит гонять в CI (там node есть) или руками: node tests/js/<файл>.test.js.
"""

import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
EXT = ROOT / 'extension'
NODE = shutil.which('node')
JS_TESTS = sorted((ROOT / 'tests' / 'js').glob('*.test.js'))


def _read(path):
    return path.read_text(encoding='utf-8')


@pytest.mark.skipif(NODE is None, reason='node не установлен')
@pytest.mark.parametrize('test_file', JS_TESTS, ids=lambda p: p.name)
def test_js_suite(test_file):
    result = subprocess.run(
        [NODE, str(test_file)], capture_output=True, text=True, timeout=120, encoding='utf-8',
    )
    assert result.returncode == 0, result.stderr or result.stdout


def test_js_suites_exist():
    names = {p.name for p in JS_TESTS}
    assert {'links.test.js', 'proxy-rules.test.js', 'compat.test.js', 'background.test.js'} <= names


# ── popup ───────────────────────────────────────────────────────

def test_popup_loads_helper_scripts_before_popup_script():
    html = _read(EXT / 'popup.html')
    for helper in ('links.js', 'compat.js'):
        assert html.index(helper) < html.index('popup.js'), helper


def test_parsers_are_not_duplicated_in_popup():
    # две копии разбора расходятся: правка попадёт в одну, а работать будет другая
    popup = _read(EXT / 'popup.js')
    for name in ('parseVlessUrl', 'parseWireGuardConf', 'parseEndpoint', 'extractProfileName',
                 'buildProfilesExport', 'parseProfilesImport', 'hostCompatibility'):
        assert f'function {name}(' not in popup, f'{name} снова определён в popup.js'


def test_popup_controls_are_wired():
    popup = _read(EXT / 'popup.js')
    html = _read(EXT / 'popup.html')
    for element_id in ('lanDirect', 'exportProfilesBtn', 'importProfilesBtn', 'importProfilesFile'):
        assert f'id="{element_id}"' in html, element_id
        assert f"getElementById('{element_id}')" in popup, f'{element_id} не подключён в popup.js'


# ── background ──────────────────────────────────────────────────

def test_background_uses_shared_proxy_rules():
    background = _read(EXT / 'background.js')
    assert "importScripts('proxy-rules.js', 'compat.js')" in background
    assert 'buildProxyConfig(port, lanDirect)' in background
    # прежний жёсткий список не должен вернуться
    assert "bypassList: ['localhost'" not in background


def test_every_background_helper_script_is_installed_and_checked():
    # importScripts падает целиком, если файла нет, — установка проверяет его наличие
    check = _read(ROOT / 'check-installation.ps1')
    for helper in re.findall(r"'([\w.-]+\.js)'", re.search(r"importScripts\(([^)]*)\)", _read(EXT / 'background.js')).group(1)):
        assert (EXT / helper).is_file(), helper
        assert f'"{helper}"' in check, f'{helper} не проверяется в check-installation.ps1'


def test_removed_options_stay_removed():
    # блокировка трафика, «Разблокировать интернет» и защита WebRTC убраны по решению
    # владельца; без разрешения privacy расширение не просит у пользователя лишнего
    import json
    manifest = json.loads(_read(EXT / 'manifest.json'))
    assert 'privacy' not in manifest['permissions']
    assert 'optional_permissions' not in manifest
    ui = _read(EXT / 'popup.html') + _read(EXT / 'popup.js') + _read(EXT / 'proxy-rules.js')
    for marker in ('killSwitchStrict', 'webrtcProtect', 'unblockBtn', 'Разблокировать', 'buildBlockConfig', 'BLOCK_PROXY_PORT'):
        assert marker not in ui, f'{marker} вернулся в интерфейс'
    background = _read(EXT / 'background.js')
    for marker in ('blockTraffic', 'applyWebRtcPolicy', 'buildBlockConfig'):
        assert marker not in background, f'{marker} вернулся в background.js'


# ── релиз ───────────────────────────────────────────────────────

def test_release_archive_name_keeps_platform_between_dashes():
    # web-install.* выбирает архив по «-<платформа>-»; версия проекта не должна это ломать
    script = _read(ROOT / 'release' / 'make-release.ps1')
    name = re.search(r'\$name = "(vlesschrome-[^"]+)"', script).group(1)
    assert name == 'vlesschrome-v$projectVersion-$Plat-xray$Version.zip'
    sample = name.replace('$projectVersion', '1.1.0').replace('$Version', '26.3.27')
    for plat in ('win-x64', 'linux-x64', 'linux-arm64', 'macos-arm64', 'macos-x64'):
        assert f'-{plat}-' in sample.replace('$Plat', plat)
