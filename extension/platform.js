// Подсказки по установке native host для каждой ОС.
//
// Страница настройки раньше говорила только про Windows («Запустите
// install.bat», %LOCALAPPDATA%), и на Linux/macOS/Steam Deck человек видел
// команду, которой у него нет. Здесь — чистые данные и функции без chrome.*,
// чтобы их можно было проверить отдельно; tests/test_setup_platform.py
// сверяет пути и скрипты с тем, что на самом деле лежит в репозитории и что
// использует хост (app_dir_for).

const RAW_BASE = 'https://raw.githubusercontent.com/Flammen43/VLESS-Connector/main';

const PLATFORM_HINTS = {
  win: {
    name: 'Windows',
    installCmd: 'install.bat',
    dataDir: '%LOCALAPPDATA%\\VLESSChrome',
    logFile: '%LOCALAPPDATA%\\VLESSChrome\\native-host.log',
    pasteTip: 'Вставьте в адресную строку Проводника.',
    checkCmd: 'check-installation.bat',
    howTo: [
      { title: 'Через Проводник', parts: ['откройте папку проекта VLESSCHROME и запустите ', { code: 'install.bat' }, ' двойным кликом.'] },
      { title: 'Через командную строку', parts: ['Win+R → ', { code: 'cmd' }, ' → ', { code: 'cd "путь\\к\\VLESSCHROME"' }, ' → ', { code: 'install.bat' }] },
      { title: 'Одной командой (PowerShell)', parts: [{ code: `irm ${RAW_BASE}/web-install.ps1 | iex` }] },
    ],
  },
  mac: {
    name: 'macOS',
    installCmd: './macos/quick-install.sh',
    dataDir: '~/Library/Application Support/VLESSChrome',
    logFile: '~/Library/Application Support/VLESSChrome/native-host.log',
    pasteTip: 'В Finder: Cmd+Shift+G и вставьте путь.',
    checkCmd: null,
    howTo: [
      { title: 'Из терминала', parts: ['в корне проекта VLESSCHROME: ', { code: 'chmod +x macos/quick-install.sh' }, ' → ', { code: './macos/quick-install.sh' }] },
      { title: 'Одной командой', parts: [{ code: `curl -fsSL ${RAW_BASE}/web-install.sh | bash` }] },
    ],
  },
  linux: {
    name: 'Linux',
    installCmd: './linux/quick-install.sh',
    dataDir: '~/.config/VLESSChrome',
    logFile: '~/.config/VLESSChrome/native-host.log',
    pasteTip: 'Вставьте в файловый менеджер или терминал.',
    checkCmd: 'linux/check-connection.sh',
    howTo: [
      { title: 'Из терминала', parts: ['в корне проекта VLESSCHROME: ', { code: 'chmod +x linux/*.sh linux/install/*.sh' }, ' → ', { code: './linux/quick-install.sh' }] },
      { title: 'Одной командой', parts: [{ code: `curl -fsSL ${RAW_BASE}/web-install.sh | bash` }] },
      { title: 'Steam Deck и Flatpak-браузеры', parts: ['установщик находит их сам и выдаёт доступ к каталогу хоста. Если связи нет — проверьте ', { code: 'linux/check-connection.sh' }, '.'] },
    ],
  },
};

/** ОС из chrome.runtime.getPlatformInfo().os; если её нет — по User-Agent. */
function detectOs(apiOs, userAgent) {
  if (apiOs && apiOs !== 'unknown') return apiOs;
  const ua = userAgent || '';
  if (/CrOS/.test(ua)) return 'cros';
  if (/Android/.test(ua)) return 'android';
  if (/Windows/.test(ua)) return 'win';
  if (/Macintosh|Mac OS X/.test(ua)) return 'mac';
  if (/Linux|X11/.test(ua)) return 'linux';
  return 'unknown';
}

/** Полный путь к установщику внутри папки проекта: C:\...\install.bat или /.../linux/quick-install.sh. */
function installerPath(projectDir, os) {
  const hints = platformHints(os);
  if (!hints) return projectDir;
  const sep = os === 'win' ? '\\' : '/';
  const rel = hints.installCmd.replace(/^\.\//, '');
  return projectDir.replace(/[\\/]+$/, '') + sep + rel;
}

/** Подсказки для ОС или null, если для неё установщика нет (ChromeOS, Android…). */
function platformHints(os) {
  return Object.prototype.hasOwnProperty.call(PLATFORM_HINTS, os) ? PLATFORM_HINTS[os] : null;
}
