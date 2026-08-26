# -*- coding: utf-8 -*-
"""Пинг endpoint'ов: TCP (VLESS), ICMP (WG host), SOCKS5 (туннель)."""

import os
import re
import socket
import subprocess
import time


def build_socks5_connect_request(dest_host, dest_port):
    port_b = int(dest_port).to_bytes(2, 'big')
    try:
        return b'\x05\x01\x00\x01' + socket.inet_aton(dest_host) + port_b
    except OSError:
        pass
    try:
        return b'\x05\x01\x00\x04' + socket.inet_pton(socket.AF_INET6, dest_host) + port_b
    except OSError:
        pass
    host_b = dest_host.encode('idna')
    if len(host_b) > 255:
        raise ValueError('hostname too long')
    return b'\x05\x01\x00\x03' + bytes([len(host_b)]) + host_b + port_b


def tcp_ping(host, port, timeout=5):
    t0 = time.perf_counter()
    with socket.create_connection((host, int(port)), timeout=timeout):
        pass
    return max(1, round((time.perf_counter() - t0) * 1000))


def icmp_ping(host, timeout_ms=3000):
    """ICMP echo через системный ping. WG-порт UDP, TCP туда бессмысленен."""
    timeout_ms = int(timeout_ms)
    t0 = time.perf_counter()
    if os.name == 'nt':
        cmd = ['ping', '-n', '1', '-w', str(timeout_ms), host]
        flags = subprocess.CREATE_NO_WINDOW
    else:
        sec = max(1, (timeout_ms + 999) // 1000)
        cmd = ['ping', '-c', '1', '-W', str(sec), host]
        flags = 0
    r = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=timeout_ms / 1000.0 + 2,
        creationflags=flags,
    )
    out = (r.stdout or '') + (r.stderr or '')
    if r.returncode != 0:
        raise OSError(out.strip() or 'icmp timeout')
    m = re.search(r'(?:time|время)\s*[=<]\s*(\d+)', out, re.I)
    if m:
        return max(1, int(m.group(1)))
    return max(1, round((time.perf_counter() - t0) * 1000))


def socks5_tcp_ping(socks_host, socks_port, dest_host, dest_port, timeout=5):
    """RTT через локальный SOCKS (трафик идёт в туннель Xray/WG)."""
    t0 = time.perf_counter()
    with socket.create_connection((socks_host, int(socks_port)), timeout=timeout) as s:
        s.settimeout(timeout)
        s.sendall(b'\x05\x01\x00')
        hello = s.recv(2)
        if len(hello) < 2 or hello[0] != 5 or hello[1] != 0:
            raise OSError('SOCKS5 handshake failed')
        s.sendall(build_socks5_connect_request(dest_host, dest_port))
        reply = s.recv(16)
        if len(reply) < 2 or reply[1] != 0:
            code = reply[1] if len(reply) > 1 else -1
            raise OSError(f'SOCKS5 connect failed ({code})')
    return max(1, round((time.perf_counter() - t0) * 1000))


def ping_host(host, port=443, transport='tcp', socks_port=None, timeout=5):
    transport = (transport or 'tcp').lower()
    if socks_port:
        return socks5_tcp_ping('127.0.0.1', socks_port, host, port, timeout=timeout)
    if transport == 'icmp':
        return icmp_ping(host, timeout_ms=int(timeout * 1000))
    return tcp_ping(host, port, timeout=timeout)
