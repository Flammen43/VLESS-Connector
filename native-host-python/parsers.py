# -*- coding: utf-8 -*-
"""Парсеры VLESS/WireGuard конфигов. Без side-effects — удобно тестировать."""


def is_ipv6_host(value):
    host = (value or '').split('/')[0].strip().strip('[]')
    return ':' in host


def wireguard_ip_strategy(config):
    """v4-only туннель → только IPv4, иначе AAAA/:: виснут по 20с на каждый запрос."""
    addrs = config.get('address') or []
    allowed = []
    for peer in config.get('peers') or []:
        allowed.extend(peer.get('allowedIPs') or peer.get('allowedips') or [])
    has_v6 = any(is_ipv6_host(a) for a in list(addrs) + list(allowed))
    if has_v6:
        return {
            'domainStrategy': 'ForceIPv4v6',
            'queryStrategy': 'UseIP',
            'blockIPv6': False,
        }
    return {
        'domainStrategy': 'ForceIPv4',
        'queryStrategy': 'UseIPv4',
        'blockIPv6': True,
    }


def split_csv(value):
    if not value:
        return []
    return [p.strip() for p in str(value).split(',') if p.strip()]


def parse_wireguard_conf(text):
    """Парсинг WireGuard .conf ([Interface] / [Peer])."""
    interface = {}
    peers = []
    current = None

    for raw_line in (text or '').splitlines():
        line = raw_line.strip()
        if line.startswith('\ufeff'):
            line = line.lstrip('\ufeff').strip()
        if not line or line.startswith('#') or line.startswith(';'):
            continue
        if line.startswith('[') and line.endswith(']'):
            section = line[1:-1].strip().lower()
            if section == 'interface':
                current = 'interface'
            elif section == 'peer':
                current = 'peer'
                peers.append({})
            else:
                current = None
            continue
        if '=' not in line or current is None:
            continue
        key, _, value = line.partition('=')
        key = key.strip().lower()
        value = value.strip()
        if current == 'interface':
            if key == 'address':
                interface.setdefault('address', []).extend(split_csv(value))
            else:
                interface[key] = value
        elif current == 'peer' and peers:
            if key == 'allowedips':
                peers[-1].setdefault('allowedips', []).extend(split_csv(value))
            else:
                peers[-1][key] = value

    return interface, peers


def wireguard_conf_to_config(text):
    """WireGuard .conf → dict для Xray wireguard outbound."""
    interface, peers = parse_wireguard_conf(text)

    secret_key = interface.get('privatekey', '')
    if not secret_key:
        raise ValueError('В конфиге нет PrivateKey ([Interface])')
    if not peers:
        raise ValueError('В конфиге нет секции [Peer]')

    addresses = list(interface.get('address') or [])

    mtu = 1420
    if interface.get('mtu'):
        try:
            mtu = int(interface['mtu'])
        except (TypeError, ValueError):
            pass

    xray_peers = []
    for peer in peers:
        public_key = peer.get('publickey', '')
        endpoint = peer.get('endpoint', '')
        if not public_key or not endpoint:
            continue
        allowed = peer.get('allowedips') or ['0.0.0.0/0']
        keep_alive = 0
        ka_raw = peer.get('persistentkeepalive') or peer.get('keepalive') or '0'
        try:
            keep_alive = int(ka_raw)
        except (TypeError, ValueError):
            pass
        entry = {
            'publicKey': public_key,
            'endpoint': endpoint,
            'allowedIPs': allowed,
            'keepAlive': keep_alive,
        }
        psk = peer.get('presharedkey', '')
        if psk:
            entry['preSharedKey'] = psk
        xray_peers.append(entry)

    if not xray_peers:
        raise ValueError('В [Peer] нет PublicKey и Endpoint')

    return {
        'protocol': 'wireguard',
        'secretKey': secret_key,
        'address': addresses,
        'mtu': mtu,
        'peers': xray_peers,
        'dns': split_csv(interface.get('dns') or ''),
    }


def normalize_proxy_config(config):
    """Приводит config от расширения к единому виду (vless / wireguard)."""
    if not config:
        return config
    protocol = (config.get('protocol') or 'vless').lower()
    if protocol != 'wireguard':
        config = dict(config)
        config['protocol'] = 'vless'
        return config
    if config.get('secretKey') and config.get('peers'):
        return config
    wg_text = config.get('wgConfig') or config.get('wg_config') or ''
    if not str(wg_text).strip():
        raise ValueError('Пустой WireGuard конфиг')
    parsed = wireguard_conf_to_config(wg_text)
    merged = dict(config)
    merged.update(parsed)
    return merged
