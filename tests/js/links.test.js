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

  // ── экспорт / импорт профилей ────────────────────────────────
  const validate = (type, text) => {
    if (type === 'vless' && !text.startsWith('vless://')) throw new Error('Неверный формат URL');
    if (type === 'wireguard') L.parseWireGuardConf(text); else L.parseVlessUrl(text);
  };
  const wgText = '[Interface]\nPrivateKey = k\n[Peer]\nPublicKey = p\nEndpoint = wg.example.com:51820';
  const profiles = [
    { id: 'a', type: 'vless', name: 'Один', vlessUrl: 'vless://u1@h1.example:443?security=tls#Один' },
    { id: 'b', type: 'wireguard', name: 'WG', wgConfig: wgText },
    { id: 'c', type: 'vless', name: 'Закрыт', vlessUrl: 'enc:v1:xxxx', locked: true },
    { id: 'd', type: 'vless', name: 'Пустой' },
  ];
  const exp = L.buildProfilesExport(profiles, new Date('2026-01-02T03:04:05Z'));
  eq(exp.count, 2, 'экспортируются только расшифрованные непустые профили');
  eq(exp.skipped, 2, 'заблокированные и пустые пропущены');
  assert(!exp.json.includes('enc:v1'), 'шифртекст не попадает в экспорт');
  assert(!exp.json.includes('"id"'), 'внутренние id не экспортируются');
  eq(JSON.parse(exp.json).exportedAt, '2026-01-02T03:04:05.000Z', 'метка времени');

  let n = 0;
  const mk = () => 'id' + (++n);
  const imp = L.parseProfilesImport(exp.json, validate, [], mk);
  eq(imp.profiles.length, 2, 'импорт возвращает оба профиля');
  eq(imp.profiles[0].vlessUrl, profiles[0].vlessUrl, 'ссылка сохранилась как есть');
  eq(imp.profiles[0].name, 'Один', 'имя берётся из ссылки');
  eq(imp.profiles[1].type, 'wireguard', 'тип WireGuard');
  eq(imp.profiles[1].name, 'wg.example.com', 'имя WireGuard из endpoint');
  eq(imp.profiles.map(p => p.id), ['id1', 'id2'], 'новые id');

  const again = L.parseProfilesImport(exp.json, validate, [profiles[0].vlessUrl, wgText]);
  eq(again.profiles.length, 0, 'повторный импорт не плодит дубликаты');
  eq(again.duplicates, 2, 'дубликаты посчитаны');

  const dirty = JSON.stringify({ format: 'vless-connector-profiles', version: 1, profiles: [
    { type: 'vless', config: 'vless://ok@h.example:443#ok' },
    { type: 'vless', config: 'http://not-vless' },
    { type: 'vless', config: '' },
    null,
    { type: 'wireguard', config: '[Interface]' },
  ] });
  const part = L.parseProfilesImport(dirty, validate);
  eq(part.profiles.length, 1, 'хорошие профили импортируются, плохие — нет');
  eq(part.errors.length, 4, 'каждая плохая запись даёт причину');
  assert(part.errors.some(e => /№2/.test(e) && /URL/.test(e)), 'причина указывает номер записи');

  throws(() => L.parseProfilesImport('not json', validate), /не JSON/, 'не JSON');
  throws(() => L.parseProfilesImport('{"a":1}', validate), /не похож на экспорт/, 'чужой JSON');
  throws(() => L.parseProfilesImport(JSON.stringify({ format: 'vless-connector-profiles', version: 99, profiles: [] }), validate), /новой/, 'более новая версия формата');
  eq(L.parseProfilesImport('﻿' + exp.json, validate).profiles.length, 2, 'BOM в начале файла не мешает');
}

if (typeof module !== 'undefined' && module.exports) {
  const fs = require('fs');
  const path = require('path');
  const src = fs.readFileSync(path.join(__dirname, '..', '..', 'extension', 'links.js'), 'utf8');
  const L = new Function(`${src}; return { safeDecode, stripBrackets, formatHostPort, extractProfileName,
    parseWireGuardConf, parseEndpoint, extractWireGuardProfileName, parseVlessUrl,
    buildProfilesExport, parseProfilesImport, profileConfigText };`)();
  let failed = 0;
  runLinkTests(L, (ok, msg) => { if (!ok) { failed++; console.error('FAIL: ' + msg); } });
  console.log(failed ? `${failed} проверок не прошло` : 'ok');
  process.exit(failed ? 1 : 0);
}
