# -*- coding: utf-8 -*-
"""Уборка файлов брошенных профилей в рабочем каталоге."""

import os
import time

import pytest

import native_host
from native_host import (
    ORPHAN_MAX_AGE_DAYS,
    cleanup_orphaned_profiles,
    group_profile_files,
)


OLD = (ORPHAN_MAX_AGE_DAYS + 3) * 86400


def make_profile(app_dir, cid, age_seconds=0, with_pid=False):
    """Создаёт набор файлов профиля и при необходимости состаривает его."""
    paths = [
        app_dir / f'config_{cid}.json',
        app_dir / f'xray_{cid}.log',
    ]
    if with_pid:
        paths.append(app_dir / f'xray_{cid}.pid')
    for p in paths:
        p.write_text('{}' if p.suffix == '.json' else 'x', encoding='utf-8')
    if age_seconds:
        old = time.time() - age_seconds
        for p in paths:
            os.utime(p, (old, old))
    return paths


# ── группировка ─────────────────────────────────────────────────

def test_group_splits_by_client_id(tmp_path):
    make_profile(tmp_path, 'aaa', with_pid=True)
    make_profile(tmp_path, 'bbb')
    groups = group_profile_files(tmp_path)

    assert set(groups) == {'aaa', 'bbb'}
    assert len(groups['aaa']) == 3
    assert len(groups['bbb']) == 2


def test_group_ignores_shared_files(tmp_path):
    """Общие журналы к профилям не относятся и удаляться не должны."""
    (tmp_path / 'xray.log').write_text('x', encoding='utf-8')
    (tmp_path / 'native-host.log').write_text('x', encoding='utf-8')
    (tmp_path / 'xray.exe').write_text('x', encoding='utf-8')
    (tmp_path / 'geoip.dat').write_text('x', encoding='utf-8')
    make_profile(tmp_path, 'aaa')

    assert set(group_profile_files(tmp_path)) == {'aaa'}


def test_group_handles_uuid_client_ids(tmp_path):
    """crypto.randomUUID() даёт дефисы — они не должны ломать разбор имени."""
    cid = '5a6afcb0-87db-4f17-be6a-30805b3a4768'
    make_profile(tmp_path, cid)
    assert set(group_profile_files(tmp_path)) == {cid}


# ── что удаляется ───────────────────────────────────────────────

def test_removes_only_stale_foreign_profile(tmp_path):
    make_profile(tmp_path, 'stale', age_seconds=OLD)
    removed = cleanup_orphaned_profiles('current', app_dir=tmp_path)

    assert sorted(removed) == ['config_stale.json', 'xray_stale.log']
    assert not (tmp_path / 'config_stale.json').exists()


def test_keeps_current_profile_even_if_old(tmp_path):
    """Текущий профиль трогать нельзя — им пользуются прямо сейчас."""
    make_profile(tmp_path, 'mine', age_seconds=OLD)
    removed = cleanup_orphaned_profiles('mine', app_dir=tmp_path)

    assert removed == []
    assert (tmp_path / 'config_mine.json').exists()


def test_keeps_recently_used_profile(tmp_path):
    """Свежие файлы — это, скорее всего, другой активный профиль браузера."""
    make_profile(tmp_path, 'other', age_seconds=0)
    removed = cleanup_orphaned_profiles('current', app_dir=tmp_path)

    assert removed == []
    assert (tmp_path / 'config_other.json').exists()


def test_keeps_profile_with_live_xray(tmp_path, monkeypatch):
    """У другого профиля жив свой xray — его файлы не наши."""
    paths = make_profile(tmp_path, 'live', age_seconds=OLD, with_pid=True)
    (tmp_path / 'xray_live.pid').write_text('4242', encoding='utf-8')
    old = time.time() - OLD
    os.utime(tmp_path / 'xray_live.pid', (old, old))

    monkeypatch.setattr(native_host, 'is_xray_pid_alive', lambda pid: pid == 4242)
    removed = cleanup_orphaned_profiles('current', app_dir=tmp_path)

    assert removed == []
    assert all(p.exists() for p in paths)


def test_removes_stale_profile_with_dead_pid(tmp_path, monkeypatch):
    make_profile(tmp_path, 'dead', age_seconds=OLD, with_pid=True)
    (tmp_path / 'xray_dead.pid').write_text('999999', encoding='utf-8')
    old = time.time() - OLD
    os.utime(tmp_path / 'xray_dead.pid', (old, old))

    monkeypatch.setattr(native_host, 'is_xray_pid_alive', lambda pid: False)
    removed = cleanup_orphaned_profiles('current', app_dir=tmp_path)

    assert len(removed) == 3
    assert not (tmp_path / 'xray_dead.pid').exists()


def test_corrupt_pid_file_does_not_block_cleanup(tmp_path, monkeypatch):
    make_profile(tmp_path, 'bad', age_seconds=OLD, with_pid=True)
    (tmp_path / 'xray_bad.pid').write_text('не число', encoding='utf-8')
    old = time.time() - OLD
    os.utime(tmp_path / 'xray_bad.pid', (old, old))

    monkeypatch.setattr(native_host, 'is_xray_pid_alive', lambda pid: False)
    removed = cleanup_orphaned_profiles('current', app_dir=tmp_path)

    assert len(removed) == 3


def test_survives_missing_directory(tmp_path):
    """Каталога нет — уборка молчит, а не роняет подключение."""
    assert cleanup_orphaned_profiles('x', app_dir=tmp_path / 'нет-такого') == []


def test_mixed_profiles_only_stale_go(tmp_path):
    make_profile(tmp_path, 'current')
    make_profile(tmp_path, 'fresh', age_seconds=0)
    make_profile(tmp_path, 'stale1', age_seconds=OLD)
    make_profile(tmp_path, 'stale2', age_seconds=OLD)

    removed = cleanup_orphaned_profiles('current', app_dir=tmp_path)

    assert set(group_profile_files(tmp_path)) == {'current', 'fresh'}
    assert len(removed) == 4
