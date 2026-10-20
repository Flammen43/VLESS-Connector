# -*- coding: utf-8 -*-
"""Версии хоста и расширения не должны расходиться молча."""

import json
from pathlib import Path

import native_host
from native_host import XrayManager, handle_message

ROOT = Path(__file__).resolve().parent.parent


def test_host_version_matches_extension_manifest():
    manifest = json.loads((ROOT / 'extension' / 'manifest.json').read_text(encoding='utf-8'))
    assert native_host.HOST_VERSION == manifest['version']


def test_status_reports_host_version():
    response = handle_message(XrayManager(), {'id': 1, 'action': 'status'})
    assert response['success'] is True
    assert response['hostVersion'] == native_host.HOST_VERSION
