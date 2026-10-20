// Разбор vless://-ссылок и WireGuard-конфигов.
//
// Вынесено из popup.js: это чистые функции без chrome.* и DOM, их можно
// гонять тестами (tests/js/links.test.js) без браузера. Загружается в
// popup.html перед popup.js.

/** decodeURIComponent, который не бросает на «%» вне escape-последовательности:
 *  название «Server 100%» раньше отклоняло всю ссылку («URI malformed»).
 *  Декодируем только корректные участки %XX: URL-парсер превращает пробел в
 *  «%20», и «всё или ничего» оставило бы «Server%20100%». */
function safeDecode(value) {
  return String(value).replace(/(?:%[0-9A-Fa-f]{2})+/g, (chunk) => {
    try {
      return decodeURIComponent(chunk);
    } catch {
      return chunk;
    }
  });
}

/** IPv6-адрес в URL приходит со скобками («[2001:db8::1]»), Xray ждёт без них. */
function stripBrackets(host) {
  return (host || '').replace(/^\[(.*)\]$/, '$1');
}

/** host:port для показа; IPv6 берём в скобки, иначе не отличить порт от хвоста адреса. */
function formatHostPort(host, port) {
  const bare = stripBrackets(host);
  return bare.includes(':') ? `[${bare}]:${port}` : `${bare}:${port}`;
}

function extractProfileName(vlessUrl) {
  try {
    const urlObj = new URL(vlessUrl);
    return safeDecode(urlObj.hash.substring(1)) || 'VLESS Server';
  } catch {
    return 'VLESS Server';
  }
}

function parseWireGuardConf(text) {
  const interfaceSection = {};
  const peers = [];
  let current = null;

  for (const rawLine of text.split(/\r?\n/)) {
    // Комментарий в wg-quick начинается с «#» в любом месте строки. Раньше
    // «PrivateKey = … # мой ключ» уходил в Xray вместе с комментарием.
    const hash = rawLine.indexOf('#');
    const line = (hash === -1 ? rawLine : rawLine.slice(0, hash)).trim();
    if (!line || line.startsWith(';')) continue;

    const sectionMatch = line.match(/^\[(.+)\]$/);
    if (sectionMatch) {
      const section = sectionMatch[1].trim().toLowerCase();
      if (section === 'interface') current = 'interface';
      else if (section === 'peer') {
        current = 'peer';
        peers.push({});
      } else current = null;
      continue;
    }

    const eq = line.indexOf('=');
    if (eq === -1 || !current) continue;

    const key = line.slice(0, eq).trim().toLowerCase();
    const value = line.slice(eq + 1).trim();

    if (current === 'interface') {
      if (key === 'address') {
        if (!interfaceSection.address) interfaceSection.address = [];
        interfaceSection.address.push(...value.split(',').map(s => s.trim()).filter(Boolean));
      } else {
        interfaceSection[key] = value;
      }
    } else if (current === 'peer' && peers.length) {
      if (key === 'allowedips') {
        if (!peers[peers.length - 1].allowedips) peers[peers.length - 1].allowedips = [];
        peers[peers.length - 1].allowedips.push(...value.split(',').map(s => s.trim()).filter(Boolean));
      } else {
        peers[peers.length - 1][key] = value;
      }
    }
  }

  const secretKey = interfaceSection.privatekey;
  if (!secretKey) throw new Error('В конфиге нет PrivateKey ([Interface])');
  if (!peers.length) throw new Error('В конфиге нет секции [Peer]');

  const xrayPeers = peers.map((peer) => {
    const publicKey = peer.publickey;
    const endpoint = peer.endpoint;
    if (!publicKey || !endpoint) {
      throw new Error('В [Peer] нужны PublicKey и Endpoint');
    }
    const entry = {
      publicKey,
      endpoint,
      allowedIPs: peer.allowedips?.length ? peer.allowedips : ['0.0.0.0/0'],
      keepAlive: parseInt(peer.persistentkeepalive || peer.keepalive || '0', 10) || 0
    };
    if (peer.presharedkey) entry.preSharedKey = peer.presharedkey;
    return entry;
  });

  const config = {
    protocol: 'wireguard',
    secretKey,
    peers: xrayPeers,
    mtu: parseInt(interfaceSection.mtu || '1420', 10) || 1420
  };
  if (interfaceSection.address?.length) {
    config.address = interfaceSection.address;
  }
  if (interfaceSection.dns) {
    config.dns = interfaceSection.dns.split(',').map(s => s.trim()).filter(Boolean);
  }
  return config;
}

function parseEndpoint(endpoint) {
  if (!endpoint) return { host: '', port: 51820 };
  if (endpoint.startsWith('[')) {
    const m = endpoint.match(/^\[([^\]]+)\]:(\d+)$/);
    if (m) return { host: m[1], port: parseInt(m[2], 10) };
  }
  const idx = endpoint.lastIndexOf(':');
  if (idx === -1) return { host: endpoint, port: 51820 };
  return {
    host: endpoint.slice(0, idx),
    port: parseInt(endpoint.slice(idx + 1), 10) || 51820
  };
}

function extractWireGuardProfileName(text) {
  try {
    const config = parseWireGuardConf(text);
    const endpoint = config.peers[0]?.endpoint;
    if (endpoint) {
      return parseEndpoint(endpoint).host || 'WireGuard';
    }
  } catch (_) { /* ignore */ }
  return 'WireGuard';
}

function parseVlessUrl(url) {
  try {
    const urlObj = new URL(url);

    const uuid = urlObj.username || urlObj.pathname.split('@')[0].replace('//', '');
    const server = stripBrackets(urlObj.hostname);
    const port = urlObj.port ? parseInt(urlObj.port, 10) : 443;

    const params = new URLSearchParams(urlObj.search);
    const network = params.get('type') || 'tcp';

    // gRPC: «путь» — это serviceName. Без него раньше подставлялся «/», и
    // Xray получал имя сервиса «/» вместо умолчания. Остальным транспортам
    // нужен путь, по умолчанию «/».
    const path = network === 'grpc'
      ? (params.get('serviceName') || params.get('path') || '')
      : (params.get('path') || params.get('serviceName') || '/');

    return {
      protocol: 'vless',
      uuid: uuid,
      server: server,
      port: port || 443,
      encryption: params.get('encryption') || 'none',
      // По спецификации ссылок умолчание — «none», но здесь намеренно «tls»:
      // ссылка без security= чаще всего неполная, и при «none» трафик ушёл бы
      // на сервер без шифрования транспорта молча. С «tls» такая ссылка просто
      // не подключится — отказ безопаснее тихого понижения защиты.
      security: params.get('security') || 'tls',
      type: network,
      host: params.get('host') || params.get('sni') || server,
      path: path,
      sni: params.get('sni') || params.get('host') || server,
      alpn: params.get('alpn') || '',
      fingerprint: params.get('fp') || params.get('fingerprint') || 'chrome',
      remarks: safeDecode(urlObj.hash.substring(1)) || 'VLESS Server',
      flow: params.get('flow') || '',
      pbk: params.get('pbk') || '',
      sid: params.get('sid') || '',
      spx: params.get('spx') || '',
      // Режим транспорта xhttp (auto / packet-up / stream-up / stream-one).
      // Без него ссылки вида ?type=xhttp&mode=... теряли настройку.
      mode: params.get('mode') || ''
    };
  } catch (error) {
    throw new Error(`Ошибка парсинга URL: ${error.message}`);
  }
}
