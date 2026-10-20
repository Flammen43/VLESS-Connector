// Тесты сверки версий (extension/compat.js). Запуск: node tests/js/compat.test.js

function runCompatTests(C, assert) {
  const eq = (a, b, msg) => assert(JSON.stringify(a) === JSON.stringify(b), `${msg}: ждали ${JSON.stringify(b)}, получили ${JSON.stringify(a)}`);
  const kind = (ext, host) => C.hostCompatibility(ext, host).kind;

  eq(C.parseVersion('1.1.0'), [1, 1, 0], 'parseVersion полная');
  eq(C.parseVersion('1.2'), [1, 2, 0], 'parseVersion без патча');
  eq(C.parseVersion('v1.1.0'), null, 'префикс v — не версия');
  eq(C.parseVersion(undefined), null, 'нет версии');

  eq(kind('1.1.0', '1.1.0'), 'ok', 'одинаковые');
  eq(kind('1.1.0', '1.1.7'), 'ok', 'патч-релизы совместимы');
  eq(kind('1.1.3', '1.1.0'), 'ok', 'патч хоста ниже — совместимо');
  eq(kind('1.2.0', '1.1.9'), 'old', 'хост старее по minor');
  eq(kind('2.0.0', '1.9.9'), 'old', 'хост старее по major');
  eq(kind('1.1.0', '1.2.0'), 'newer', 'хост новее по minor');
  eq(kind('1.1.0', undefined), 'old', 'старый хост без версии (до этой версии поля не было)');
  eq(kind('1.1.0', ''), 'old', 'пустая версия хоста');
  eq(kind('1.1.0', 'abc'), 'old', 'мусор вместо версии хоста');
  eq(kind(undefined, '1.1.0'), 'ok', 'неизвестная версия расширения не пугает пользователя');

  const old = C.hostCompatibility('1.1.0', undefined);
  assert(old.ok === false && /установщик/.test(old.message), 'сообщение для старого хоста говорит про установщик');
  const newer = C.hostCompatibility('1.1.0', '1.2.0');
  assert(/перезагрузите/.test(newer.message), 'сообщение для нового хоста говорит про перезагрузку расширения');
  assert(C.hostCompatibility('1.1.0', '1.1.0').message === '', 'у совместимых версий сообщения нет');
}

if (typeof module !== 'undefined' && module.exports) {
  const fs = require('fs');
  const path = require('path');
  const src = fs.readFileSync(path.join(__dirname, '..', '..', 'extension', 'compat.js'), 'utf8');
  const C = new Function(`${src}; return { parseVersion, hostCompatibility };`)();
  let failed = 0;
  runCompatTests(C, (ok, msg) => { if (!ok) { failed++; console.error('FAIL: ' + msg); } });
  console.log(failed ? `${failed} проверок не прошло` : 'ok');
  process.exit(failed ? 1 : 0);
}
