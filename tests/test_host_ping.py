# -*- coding: utf-8 -*-
from host_ping import build_socks5_connect_request


def test_socks5_ipv4():
    req = build_socks5_connect_request('1.1.1.1', 443)
    assert req[:4] == b'\x05\x01\x00\x01'
    assert req[-2:] == (443).to_bytes(2, 'big')
    assert len(req) == 10


def test_socks5_domain():
    req = build_socks5_connect_request('example.com', 80)
    assert req[:4] == b'\x05\x01\x00\x03'
    assert req[4] == len(b'example.com')
    assert req[5:5 + 11] == b'example.com'
    assert req[-2:] == (80).to_bytes(2, 'big')
