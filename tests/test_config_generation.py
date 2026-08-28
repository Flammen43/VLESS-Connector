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


# ── транспорты ──────────────────────────────────────────────────
#
# Имена секций и допустимые режимы сверены с самим xray 26.3.27
# (`xray run -test`), а не взяты из документации: h2 из него удалён, а
# неизвестный режим xhttp он не игнорирует, а отказывается стартовать.

def stream(cfg):
    return cfg['outbounds'][0]['streamSettings']


def vless_with(**extra):
    return {**VLESS, **extra}


def test_ws_transport_unchanged():
    cfg = XrayManager()._generate_config(
        vless_with(type='ws', path='/p', host='h.example'))
    assert stream(cfg)['wsSettings'] == {'path': '/p', 'headers': {'Host': 'h.example'}}


def test_grpc_transport_unchanged():
    cfg = XrayManager()._generate_config(vless_with(type='grpc', path='svc'))
    assert stream(cfg)['grpcSettings'] == {'serviceName': 'svc'}


def test_xhttp_builds_settings():
    """Раньше для xhttp секция настроек не создавалась вовсе."""
    cfg = XrayManager()._generate_config(
        vless_with(type='xhttp', path='/p', host='h.example', mode='packet-up'))
    s = stream(cfg)
    assert s['network'] == 'xhttp'
    assert s['xhttpSettings'] == {'path': '/p', 'host': 'h.example', 'mode': 'packet-up'}


def test_xhttp_without_mode_omits_field():
    cfg = XrayManager()._generate_config(vless_with(type='xhttp', path='/p'))
    assert 'mode' not in stream(cfg)['xhttpSettings']


def test_xhttp_rejects_unknown_mode():
    """Неизвестный режим уронил бы xray целиком — поле пропускаем."""
    cfg = XrayManager()._generate_config(
        vless_with(type='xhttp', path='/p', mode='чушь'))
    assert 'mode' not in stream(cfg)['xhttpSettings']


def test_splithttp_is_alias_for_xhttp():
    cfg = XrayManager()._generate_config(vless_with(type='splithttp', path='/p'))
    assert stream(cfg)['network'] == 'xhttp'
    assert 'xhttpSettings' in stream(cfg)


def test_httpupgrade_transport():
    cfg = XrayManager()._generate_config(
        vless_with(type='httpupgrade', path='/p', host='h.example'))
    s = stream(cfg)
    assert s['network'] == 'httpupgrade'
    assert s['httpupgradeSettings'] == {'path': '/p', 'host': 'h.example'}


def test_h2_migrated_to_xhttp_stream_one():
    """Xray удалил h2 и сам указывает на XHTTP stream-one как замену.

    Без миграции старые профили просто перестают работать после
    обновления xray.
    """
    cfg = XrayManager()._generate_config(
        vless_with(type='h2', path='/p', host='h.example'))
    s = stream(cfg)
    assert s['network'] == 'xhttp'
    assert 'httpSettings' not in s
    assert s['xhttpSettings']['mode'] == 'stream-one'


def test_h2_respects_explicit_mode():
    cfg = XrayManager()._generate_config(
        vless_with(type='h2', path='/p', mode='auto'))
    assert stream(cfg)['xhttpSettings']['mode'] == 'auto'


def test_tcp_has_no_transport_section():
    cfg = XrayManager()._generate_config(vless_with(type='tcp'))
    s = stream(cfg)
    assert s['network'] == 'tcp'
    for key in ('wsSettings', 'grpcSettings', 'xhttpSettings', 'httpupgradeSettings'):
        assert key not in s
