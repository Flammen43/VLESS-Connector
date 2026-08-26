# -*- coding: utf-8 -*-
"""Генерация конфига Xray, включая гео-маршрутизацию RU."""

import pytest

import native_host
from native_host import GEO_FILES, XrayManager, geo_databases_present, ru_direct_rules


VLESS = {
    'protocol': 'vless',
    'uuid': 'u-1',
    'server': 'host.example',
    'port': 443,
    'security': 'tls',
    'type': 'tcp',
}

WIREGUARD = {
    'protocol': 'wireguard',
    'secretKey': 'sk',
    'address': ['10.0.0.2/32'],
    'peers': [{
        'publicKey': 'pk',
        'endpoint': 'wg.example.com:51820',
        'allowedIPs': ['0.0.0.0/0'],
        'keepAlive': 25,
    }],
}


@pytest.fixture
def geo(tmp_path, monkeypatch):
    """Гео-базы «установлены»."""
    for name in GEO_FILES:
        (tmp_path / name).write_bytes(b'stub')
    monkeypatch.setattr(native_host, 'APP_DIR', tmp_path)
    return tmp_path


@pytest.fixture
def no_geo(tmp_path, monkeypatch):
    """Гео-баз нет — как у тех, кто не переустановил хост."""
    monkeypatch.setattr(native_host, 'APP_DIR', tmp_path)
    return tmp_path


def outbound_tags(cfg):
    return [o.get('tag') for o in cfg['outbounds']]


def direct_rules(cfg):
    return [r for r in cfg.get('routing', {}).get('rules', [])
            if r.get('outboundTag') == 'direct']


# ── наличие баз ─────────────────────────────────────────────────

def test_geo_databases_present_requires_both(tmp_path):
    assert geo_databases_present(tmp_path) is False
    (tmp_path / 'geoip.dat').write_bytes(b'x')
    assert geo_databases_present(tmp_path) is False, 'одного файла мало'
    (tmp_path / 'geosite.dat').write_bytes(b'x')
    assert geo_databases_present(tmp_path) is True


def test_ru_rules_use_verified_category_names():
    """geosite:ru не существует — сверено с реальными базами."""
    rules = ru_direct_rules()
    domains = [d for r in rules for d in r.get('domain', [])]
    ips = [i for r in rules for i in r.get('ip', [])]
    assert 'geosite:category-ru' in domains
    assert 'geosite:ru' not in domains
    assert 'geoip:ru' in ips
    assert 'geoip:private' in ips, 'локальная сеть тоже должна идти напрямую'


def test_ru_rules_are_fresh_objects():
    """Общую константу можно было бы испортить мутацией."""
    first = ru_direct_rules()
    first[0]['domain'].append('geosite:injected')
    assert 'geosite:injected' not in ru_direct_rules()[0]['domain']


# ── VLESS ───────────────────────────────────────────────────────

def test_vless_outbound_is_tagged():
    cfg = XrayManager()._generate_config(dict(VLESS))
    assert outbound_tags(cfg) == ['proxy']


def test_vless_without_flag_has_no_routing():
    cfg = XrayManager()._generate_config(dict(VLESS))
    assert 'routing' not in cfg
    assert outbound_tags(cfg) == ['proxy']


def test_vless_with_ru_direct(geo):
    cfg = XrayManager()._generate_config({**VLESS, 'routeRuDirect': True})
    assert outbound_tags(cfg) == ['proxy', 'direct']
    assert cfg['routing']['domainStrategy'] == 'IPIfNonMatch'
    assert len(direct_rules(cfg)) == 2


def test_ru_direct_ignored_without_geo_databases(no_geo):
    """Опция не должна ломать подключение, если баз нет."""
    cfg = XrayManager()._generate_config({**VLESS, 'routeRuDirect': True})
    assert outbound_tags(cfg) == ['proxy']
    assert 'routing' not in cfg


# ── WireGuard ───────────────────────────────────────────────────

def test_wireguard_ru_direct_keeps_ipv6_block(geo):
    """У WG уже есть routing для блокировки IPv6 — его нельзя терять."""
    cfg = XrayManager()._generate_config({**WIREGUARD, 'routeRuDirect': True})

    assert outbound_tags(cfg) == ['wg', 'block', 'direct']
    rules = cfg['routing']['rules']
    blocked = [r for r in rules if r.get('outboundTag') == 'block']
    assert blocked and blocked[0]['ip'] == ['::/0'], 'правило блокировки IPv6 пропало'
    assert len(direct_rules(cfg)) == 2
    assert cfg['routing']['domainStrategy'] == 'IPIfNonMatch'


def test_wireguard_v6_tunnel_without_flag_unchanged():
    """Без флага поведение прежнее: v6-туннель не блокирует IPv6."""
    v6 = {**WIREGUARD, 'address': ['fd00::2/128']}
    cfg = XrayManager()._generate_config(v6)
    assert outbound_tags(cfg) == ['wg']
    assert 'routing' not in cfg


def test_wireguard_ru_direct_on_v6_tunnel(geo):
    v6 = {**WIREGUARD, 'address': ['fd00::2/128'], 'routeRuDirect': True}
    cfg = XrayManager()._generate_config(v6)
    assert outbound_tags(cfg) == ['wg', 'direct']
    assert len(direct_rules(cfg)) == 2


# ── DNS для гео-маршрутизации ───────────────────────────────────
#
# Маршрут выбирается по разрешённому адресу (IPIfNonMatch), поэтому ответ
# резолвера определяет, куда пойдёт трафик. Провайдер для заблокированных
# сайтов подменяет ответ на российский адрес-заглушку — rutracker.org и
# nnmclub.to приходили с одного и того же 77.94.164.71 — и правило geoip:ru
# уводило их напрямую, в блокировку. Поэтому резолвим через DoH.

def dns_servers(cfg):
    return cfg.get('dns', {}).get('servers', [])


def test_vless_ru_direct_resolves_over_doh(geo):
    cfg = XrayManager()._generate_config({**VLESS, 'routeRuDirect': True})

    servers = dns_servers(cfg)
    assert servers[:2] == [
        'https://1.1.1.1/dns-query',
        'https://8.8.8.8/dns-query',
    ], 'решение о маршруте нельзя принимать по ответу системного резолвера'
    assert servers[-1] == 'localhost', 'нужен запасной резолвер, если DoH недоступен'


def test_vless_without_flag_has_no_dns_section():
    """Без гео-правил имя разрешает удалённый сервер — свой DNS не нужен."""
    cfg = XrayManager()._generate_config(VLESS)
    assert 'dns' not in cfg


def test_ru_direct_without_geo_databases_adds_no_dns(no_geo):
    cfg = XrayManager()._generate_config({**VLESS, 'routeRuDirect': True})
    assert 'dns' not in cfg


def test_wireguard_ru_direct_keeps_own_dns_as_fallback(geo):
    wg = {**WIREGUARD, 'dns': ['10.0.0.1'], 'routeRuDirect': True}
    cfg = XrayManager()._generate_config(wg)

    servers = dns_servers(cfg)
    assert servers[0] == 'https://1.1.1.1/dns-query'
    assert '10.0.0.1' in servers, 'DNS из конфига WireGuard потерян'
    assert servers.index('https://1.1.1.1/dns-query') < servers.index('10.0.0.1')


def test_wireguard_ru_direct_keeps_query_strategy(geo):
    """У v4-туннеля queryStrategy уже выставлен — перетирать его нельзя."""
    plain = XrayManager()._generate_config(WIREGUARD)
    expected = plain['dns']['queryStrategy']

    cfg = XrayManager()._generate_config({**WIREGUARD, 'routeRuDirect': True})
    assert cfg['dns']['queryStrategy'] == expected
