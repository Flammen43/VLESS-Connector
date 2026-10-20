// Тесты списка обхода прокси (extension/proxy-rules.js). Запуск: node tests/js/proxy-rules.test.js

function runProxyRulesTests(R, assert) {
  const eq = (a, b, msg) =>
    assert(JSON.stringify(a) === JSON.stringify(b), `${msg}: ждали ${JSON.stringify(b)}, получили ${JSON.stringify(a)}`);

  const on = R.buildBypassList(true);
  const off = R.buildBypassList(false);
  const byDefault = R.buildBypassList();

  eq(byDefault, on, 'по умолчанию локальная сеть идёт напрямую');

  // loopback обходится всегда, даже когда LAN отключён
  for (const entry of ['localhost', '127.0.0.1', '[::1]', '<local>']) {
    assert(on.includes(entry), `loopback ${entry} должен обходиться (LAN включён)`);
    assert(off.includes(entry), `loopback ${entry} должен обходиться (LAN выключен)`);
  }

  // диапазоны частных сетей RFC 1918 + link-local
  for (const entry of ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '169.254.0.0/16', '*.local']) {
    assert(on.includes(entry), `LAN ${entry} должен обходиться`);
    assert(!off.includes(entry), `LAN ${entry} не должен обходиться при выключенном переключателе`);
  }

  // CGNAT (Tailscale и т. п.) — решение пользователя, расширение его не принимает
  assert(!on.some(e => e.startsWith('100.64.')), 'CGNAT 100.64.0.0/10 не трогаем');

  // каждая запись — строка без пробелов (Chrome разбирает список по элементам)
  for (const e of on) assert(typeof e === 'string' && e.length > 0 && !/\s/.test(e), `некорректная запись ${JSON.stringify(e)}`);

  // конфиг прокси
  const cfg = R.buildProxyConfig(10808, true);
  eq(cfg.mode, 'fixed_servers', 'режим fixed_servers');
  eq(cfg.rules.singleProxy, { scheme: 'socks5', host: '127.0.0.1', port: 10808 }, 'SOCKS5 на loopback');
  eq(cfg.rules.bypassList, byDefault, 'список обхода из buildBypassList');
  eq(R.buildProxyConfig(10808, false).rules.bypassList, off, 'без LAN — только loopback');

  // строгий kill-switch: прокси «в никуда», но локальная сеть по-прежнему доступна
  const block = R.buildBlockConfig(true);
  eq(block.rules.singleProxy.host, '127.0.0.1', 'блокировка: прокси только локальный');
  eq(block.rules.singleProxy.port, R.BLOCK_PROXY_PORT, 'блокировка: порт-заглушка');
  assert(block.rules.singleProxy.port < 1024, 'порт-заглушка привилегированный: Xray на нём не стартует');
  eq(block.rules.bypassList, byDefault, 'блокировка не рвёт локальную сеть');
  eq(R.buildBlockConfig(false).rules.bypassList, off, 'блокировка без LAN-обхода');
  assert(!block.rules.bypassList.includes('<all>') && !block.rules.bypassList.includes('*'), 'блокировка не должна обходить всё');

  // результат — копия: мутация не портит общие константы
  on.push('evil.example');
  assert(!R.buildBypassList(true).includes('evil.example'), 'buildBypassList должен возвращать копию');
}

if (typeof module !== 'undefined' && module.exports) {
  const fs = require('fs');
  const path = require('path');
  const src = fs.readFileSync(path.join(__dirname, '..', '..', 'extension', 'proxy-rules.js'), 'utf8');
  const R = new Function(`${src}; return { buildBypassList, buildProxyConfig, buildBlockConfig, BLOCK_PROXY_PORT };`)();
  let failed = 0;
  runProxyRulesTests(R, (ok, msg) => { if (!ok) { failed++; console.error('FAIL: ' + msg); } });
  console.log(failed ? `${failed} проверок не прошло` : 'ok');
  process.exit(failed ? 1 : 0);
}
