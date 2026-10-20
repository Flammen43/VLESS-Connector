// Список адресов, которые Chrome ходит МИМО прокси. Чистая функция без
// chrome.*: подключается в service worker через importScripts и проверяется
// тестами (tests/js/proxy-rules.test.js).
//
// Раньше обход был ['localhost', '127.0.0.1', '<local>']. «<local>» покрывает
// только имена без точки (http://router/), а не IP-адреса: роутер по
// 192.168.1.1, NAS, принтер, камеры через туннель были недоступны.

const LOOPBACK_BYPASS = ['localhost', '127.0.0.1', '[::1]', '<local>'];

// Частные диапазоны RFC 1918, link-local и имена mDNS. CGNAT 100.64.0.0/10
// сюда намеренно не входит: там живут Tailscale и подобные сети, и пустить
// их мимо туннеля или через него — решение пользователя, а не расширения.
const LAN_BYPASS = [
  '10.0.0.0/8',
  '172.16.0.0/12',
  '192.168.0.0/16',
  '169.254.0.0/16',
  '*.local',
];

/** lanDirect=true — локальная сеть идёт напрямую (по умолчанию). */
function buildBypassList(lanDirect = true) {
  return lanDirect ? [...LOOPBACK_BYPASS, ...LAN_BYPASS] : [...LOOPBACK_BYPASS];
}

/** Конфиг chrome.proxy: весь трафик в локальный SOCKS Xray, кроме списка обхода. */
function buildProxyConfig(port, lanDirect = true) {
  return {
    mode: 'fixed_servers',
    rules: {
      singleProxy: { scheme: 'socks5', host: '127.0.0.1', port: port },
      bypassList: buildBypassList(lanDirect)
    }
  };
}

// Порт, на котором заведомо никто не слушает: прокси «в никуда». Chrome при
// отказе явно заданного прокси НЕ уходит на прямое соединение, страницы просто
// не открываются (ERR_PROXY_CONNECTION_FAILED), а имена при SOCKS5 разрешает
// сам прокси — значит, и DNS-запросов мимо туннеля нет.
const BLOCK_PROXY_PORT = 1;

/** Строгий kill-switch: пока Xray мёртв, трафик не должен идти напрямую. */
function buildBlockConfig(lanDirect = true) {
  return buildProxyConfig(BLOCK_PROXY_PORT, lanDirect);
}
