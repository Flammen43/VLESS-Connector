# -*- coding: utf-8 -*-
import pytest

from parsers import (
    parse_wireguard_conf,
    wireguard_conf_to_config,
    normalize_proxy_config,
    split_csv,
)


SAMPLE_WG = """[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Address = 10.0.0.2/32
MTU = 1420
DNS = 1.1.1.1

[Peer]
PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=
AllowedIPs = 0.0.0.0/0
Endpoint = wg.example.com:51820
PersistentKeepalive = 21
"""


def test_split_csv():
    assert split_csv('0.0.0.0/0, ::/0') == ['0.0.0.0/0', '::/0']
    assert split_csv('') == []


def test_parse_sample_wg():
    cfg = wireguard_conf_to_config(SAMPLE_WG)
    assert cfg['protocol'] == 'wireguard'
    # Парсеру важна форма ключа, а не содержимое: привязываться к конкретной
    # строке нельзя, иначе в тестах приходится держать похожий на настоящий ключ.
    assert cfg['secretKey'] == 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='
    assert cfg['address'] == ['10.0.0.2/32']
    assert cfg['mtu'] == 1420
    assert cfg['peers'][0]['endpoint'] == 'wg.example.com:51820'
    assert cfg['peers'][0]['keepAlive'] == 21
    assert cfg['peers'][0]['allowedIPs'] == ['0.0.0.0/0']
    assert cfg['dns'] == ['1.1.1.1']


def test_bom_and_comments():
    text = '\ufeff# comment\n; also\n' + SAMPLE_WG
    cfg = wireguard_conf_to_config(text)
    assert cfg['peers'][0]['endpoint'] == 'wg.example.com:51820'


def test_comma_separated_allowed_ips_and_address():
    text = """[Interface]
PrivateKey = abc
Address = 10.0.0.2/32, fd00::2/128
[Peer]
PublicKey = pk
Endpoint = [2001:db8::1]:51820
AllowedIPs = 0.0.0.0/0, ::/0
"""
    cfg = wireguard_conf_to_config(text)
    assert cfg['address'] == ['10.0.0.2/32', 'fd00::2/128']
    assert cfg['peers'][0]['allowedIPs'] == ['0.0.0.0/0', '::/0']
    assert cfg['peers'][0]['endpoint'] == '[2001:db8::1]:51820'


def test_preshared_key():
    text = SAMPLE_WG.replace(
        'PersistentKeepalive = 21',
        'PresharedKey = psk-value\nPersistentKeepalive = 21',
    )
    cfg = wireguard_conf_to_config(text)
    assert cfg['peers'][0]['preSharedKey'] == 'psk-value'


def test_missing_private_key():
    with pytest.raises(ValueError, match='PrivateKey'):
        wireguard_conf_to_config('[Interface]\n[Peer]\nPublicKey=a\nEndpoint=h:1\n')


def test_missing_peer():
    with pytest.raises(ValueError, match='\\[Peer\\]'):
        wireguard_conf_to_config('[Interface]\nPrivateKey = abc\n')


def test_peer_without_endpoint_skipped():
    with pytest.raises(ValueError, match='PublicKey и Endpoint'):
        wireguard_conf_to_config(
            '[Interface]\nPrivateKey = abc\n[Peer]\nPublicKey = only\n'
        )


def test_normalize_vless():
    cfg = normalize_proxy_config({'uuid': 'u', 'server': 's', 'port': 443})
    assert cfg['protocol'] == 'vless'
    assert cfg['uuid'] == 'u'


def test_normalize_wg_from_text():
    cfg = normalize_proxy_config({'protocol': 'wireguard', 'wgConfig': SAMPLE_WG})
    assert cfg['secretKey']
    assert cfg['peers']


def test_normalize_wg_already_parsed():
    parsed = wireguard_conf_to_config(SAMPLE_WG)
    out = normalize_proxy_config(parsed)
    assert out is parsed


def test_normalize_empty_wg():
    with pytest.raises(ValueError, match='Пустой'):
        normalize_proxy_config({'protocol': 'wireguard'})


def test_parse_empty_sections_ignored():
    iface, peers = parse_wireguard_conf('[Something]\nFoo = bar\n')
    assert iface == {}
    assert peers == []


def test_wg_v4_only_strategy():
    from parsers import wireguard_ip_strategy
    cfg = wireguard_conf_to_config(SAMPLE_WG)
    s = wireguard_ip_strategy(cfg)
    assert s['domainStrategy'] == 'ForceIPv4'
    assert s['blockIPv6'] is True


def test_wg_v6_strategy():
    from parsers import wireguard_ip_strategy
    s = wireguard_ip_strategy({
        'address': ['10.0.0.2/32', 'fd00::2/128'],
        'peers': [{'allowedIPs': ['0.0.0.0/0', '::/0']}],
    })
    assert s['domainStrategy'] == 'ForceIPv4v6'
    assert s['blockIPv6'] is False
