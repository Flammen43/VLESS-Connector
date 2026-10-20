// Сверка версий расширения и Native Host. Чистые функции без chrome.*;
// проверяются tests/js/compat.test.js.
//
// Расширение и хост обновляются раздельно (установщик копирует их независимо),
// и «расширение новое, хост старый» уже случалось: старый хост не знал команду
// protectMany, и ошибка выглядела как «неизвестная команда». Теперь расширение
// спрашивает версию и объясняет, что делать.

function parseVersion(value) {
  const m = /^(\d+)\.(\d+)(?:\.(\d+))?/.exec(String(value || '').trim());
  return m ? [Number(m[1]), Number(m[2]), Number(m[3] || 0)] : null;
}

/** Сравнение по major.minor: патч-релизы совместимы между собой. */
function compareMinor(a, b) {
  return (a[0] - b[0]) || (a[1] - b[1]);
}

/**
 * kind: 'ok' | 'old' (хост старее расширения, в т. ч. вовсе без версии) |
 *       'newer' (хост новее расширения).
 */
function hostCompatibility(extensionVersion, hostVersion) {
  const ext = parseVersion(extensionVersion);
  const host = parseVersion(hostVersion);
  if (!host) {
    return {
      ok: false, kind: 'old',
      message: 'Native Host устаревшей версии (не сообщает версию). Запустите установщик ещё раз — в новых версиях исправлены ошибки безопасности.'
    };
  }
  if (!ext) return { ok: true, kind: 'ok', message: '' };
  const diff = compareMinor(host, ext);
  if (diff < 0) {
    return {
      ok: false, kind: 'old',
      message: `Native Host ${hostVersion} старее расширения ${extensionVersion}. Запустите установщик ещё раз.`
    };
  }
  if (diff > 0) {
    return {
      ok: false, kind: 'newer',
      message: `Native Host ${hostVersion} новее расширения ${extensionVersion}. Обновите папку расширения и перезагрузите его в chrome://extensions.`
    };
  }
  return { ok: true, kind: 'ok', message: '' };
}
