// Тесты разбора ссылок (extension/links.js). Запуск: node tests/js/links.test.js
// (pytest делает это сам, если node есть в PATH). Без зависимостей.
//
// Каждый случай — конкретный сбой, найденный на настоящих функциях проекта.

function runLinkTests(L, assert) {
  const eq = (actual, expected, msg) =>
    assert(JSON.stringify(actual) === JSON.stringify(expected), `${msg}: ждали ${JSON.stringify(expected)}, получили ${JSON.stringify(actual)}`);
  const throws = (fn, re, msg) => {
    let err = null;
    try { fn(); } catch (e) { err = e; }
    assert(err && re.test(err.message), `${msg}: ждали ошибку ${re}, получили ${err && err.message}`);
  };

  // ── IPv6 ────────────────────────────────────────────────────
  const v6 = L.parseVlessUrl('vless://u-1@[2001:db8::1]:8443?security=tls&type=tcp#v6');
  eq(v6.server, '2001:db8::1', 'IPv6-сервер без скобок (xray со скобками не подключится)');
  eq(v6.port, 8443, 'порт IPv6-ссылки');
  eq(v6.sni, '2001:db8::1', 'sni по умолчанию — адрес без скобок');
  eq(L.parseVlessUrl('vless://u@example.com:443?type=tcp').server, 'example.com', 'обычный хост не тронут');
  eq(L.formatHostPort('2001:db8::1', 8443), '[2001:db8::1]:8443', 'IPv6 для показа — в скобках');
  eq(L.formatHostPort('[2001:db8::1]', 8443), '[2001:db8::1]:8443', 'скобки не удваиваются');
  eq(L.formatHostPort('example.com', 443), 'example.com:443', 'обычный host:port');

  // ── «%» в названии ──────────────────────────────────────────
  const pct = L.parseVlessUrl('vless://u@h.example:443?security=tls#Server 100%');
  eq(pct.remarks, 'Server 100%', 'ссылка с «%» в названии принимается');
  eq(L.extractProfileName('vless://u@h.example:443#Server 100%'), 'Server 100%', 'имя профиля с «%»');
  eq(L.extractProfileName('vless://u@h.example:443#%D0%A1%D0%B5%D1%80'), 'Сер', 'закодированное имя по-прежнему декодируется');
  eq(L.extractProfileName('vless://u@h.example:443'), 'VLESS Server', 'без названия — запасное');
  eq(L.safeDecode('50%'), '50%', 'safeDecode не бросает');

  // ── WireGuard: комментарии ──────────────────────────────────
  const wg = L.parseWireGuardConf([
    '# заголовок',
    '[Interface]',
    'PrivateKey = SECRETKEY123= # мой ключ',
    'Address = 10.0.0.2/32 # внутренний адрес',
    'DNS = 1.1.1.1',
    '; ещё комментарий',
    '[Peer]',
    'PublicKey = PUBKEY456=  # сервер',
    'Endpoint = wg.example.com:51820 # основной',
    'AllowedIPs = 0.0.0.0/0, ::/0 # всё',
    'PersistentKeepalive = 25 # держим NAT',
  ].join('\n'));
  eq(wg.secretKey, 'SECRETKEY123=', 'комментарий не попадает в PrivateKey');
  eq(wg.address, ['10.0.0.2/32'], 'комментарий не попадает в Address');
  eq(wg.peers[0].publicKey, 'PUBKEY456=', 'комментарий не попадает в PublicKey');
  eq(wg.peers[0].endpoint, 'wg.example.com:51820', 'комментарий не попадает в Endpoint');
  eq(wg.peers[0].allowedIPs, ['0.0.0.0/0', '::/0'], 'AllowedIPs без комментария');
  eq(wg.peers[0].keepAlive, 25, 'keepalive читается при комментарии');
  eq(wg.dns, ['1.1.1.1'], 'DNS');
  eq(L.extractWireGuardProfileName('[Interface]\nPrivateKey=k\n[Peer]\nPublicKey=p\nEndpoint=[2001:db8::2]:51820'), '2001:db8::2', 'имя WireGuard из IPv6-endpoint');
  throws(() => L.parseWireGuardConf('[Interface]\nAddress = 10.0.0.2/32'), /PrivateKey/, 'нет PrivateKey');
  throws(() => L.parseWireGuardConf('[Interface]\nPrivateKey = k # только комментарий-ключ\n'), /Peer/, 'нет Peer');

  // ── gRPC / путь ─────────────────────────────────────────────
  eq(L.parseVlessUrl('vless://u@h:443?type=grpc&serviceName=svc').path, 'svc', 'gRPC: serviceName');
  eq(L.parseVlessUrl('vless://u@h:443?type=grpc').path, '', 'gRPC без serviceName — пусто, а не «/»');
  eq(L.parseVlessUrl('vless://u@h:443?type=ws').path, '/', 'ws без path — «/»');
  eq(L.parseVlessUrl('vless://u@h:443?type=ws&path=%2Fws').path, '/ws', 'ws path декодируется');
  eq(L.parseVlessUrl('vless://u@h:443?type=xhttp&path=%2Fx&mode=packet-up').mode, 'packet-up', 'xhttp mode');

  // ── прочее, что менять нельзя ───────────────────────────────
  const base = L.parseVlessUrl('vless://uuid-1@h.example?type=tcp');
  eq(base.port, 443, 'порт по умолчанию');
  eq(base.uuid, 'uuid-1', 'uuid');
  eq(base.security, 'tls', 'security по умолчанию — tls (осознанно безопаснее «none»)');
  eq(L.parseVlessUrl('vless://u@h:443?security=none').security, 'none', 'явный none сохраняется');
  eq(L.parseVlessUrl('vless://u@h:443?security=reality&pbk=P&sid=S&flow=xtls-rprx-vision').pbk, 'P', 'reality pbk');
  throws(() => L.parseVlessUrl('not a url'), /Ошибка парсинга/, 'мусор вместо ссылки');
}

if (typeof module !== 'undefined' && module.exports) {
  const fs = require('fs');
  const path = require('path');
  const src = fs.readFileSync(path.join(__dirname, '..', '..', 'extension', 'links.js'), 'utf8');
  const L = new Function(`${src}; return { safeDecode, stripBrackets, formatHostPort, extractProfileName,
    parseWireGuardConf, parseEndpoint, extractWireGuardProfileName, parseVlessUrl };`)();
  let failed = 0;
  runLinkTests(L, (ok, msg) => { if (!ok) { failed++; console.error('FAIL: ' + msg); } });
  console.log(failed ? `${failed} проверок не прошло` : 'ok');
  process.exit(failed ? 1 : 0);
}
