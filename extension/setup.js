let extensionId = '';
let manifestConfigured = false;

document.addEventListener('DOMContentLoaded', async () => {
  extensionId = chrome.runtime.id;
  document.getElementById('extensionId').textContent = extensionId;

  await loadSavedProjectPath();
  await checkAllSteps();

  document.getElementById('copyIdBtn').addEventListener('click', copyExtensionId);
  document.getElementById('openFolderBtn').addEventListener('click', copyFolderPath);
  document.getElementById('showPathToggle').addEventListener('click', togglePathDetail);
  document.getElementById('testConnectionBtn').addEventListener('click', testConnection);
  document.getElementById('openExtensionsBtn').addEventListener('click', () => chrome.tabs.create({ url: 'chrome://extensions/' }));
  document.getElementById('refreshStatusBtn').addEventListener('click', refreshStatus);
  document.getElementById('closeBtn').addEventListener('click', () => window.close());
});

// ============================================
// TOAST (замена alert)
// ============================================

function showToast(message, type = 'info', duration = 4000) {
  const toast = document.getElementById('toast');
  toast.textContent = message;
  toast.className = `toast toast-${type}`;

  requestAnimationFrame(() => {
    toast.classList.add('show');
  });

  setTimeout(() => {
    toast.classList.remove('show');
  }, duration);
}

// ============================================
// EXPANDABLE DETAILS
// ============================================

function togglePathDetail() {
  const btn = document.getElementById('showPathToggle');
  const content = document.getElementById('pathDetail');
  btn.classList.toggle('open');
  content.classList.toggle('open');
}

// ============================================
// COPY WITH INLINE FEEDBACK
// ============================================

async function copyExtensionId() {
  try {
    await navigator.clipboard.writeText(extensionId);
    showInlineFeedback('copyFeedback');
    showToast('Extension ID скопирован', 'ok');
  } catch {
    showToast('Не удалось скопировать. ID: ' + extensionId, 'err');
  }
}

async function copyFolderPath() {
  const path = '%LOCALAPPDATA%\\VLESSChrome';
  try {
    await navigator.clipboard.writeText(path);
    showInlineFeedback('pathCopyFeedback');
    showToast('Путь скопирован. Вставьте в адресную строку Проводника.', 'ok');
  } catch {
    showToast('Скопируйте вручную: ' + path, 'info', 6000);
  }
}

function showInlineFeedback(elementId) {
  const el = document.getElementById(elementId);
  el.style.opacity = '1';
  setTimeout(() => { el.style.opacity = '0'; }, 2000);
}

// ============================================
// STATUS CHECKS
// ============================================

async function checkManifestStatus() {
  try {
    const response = await chrome.runtime.sendMessage({ action: 'pingNative' });

    if (response && response.success && response.running !== undefined) {
      return {
        configured: true,
        nativeHostWorking: true,
        message: 'Native Host отвечает'
      };
    }

    if (response && response.success === false) {
      return {
        configured: false,
        nativeHostWorking: false,
        message: response.error || 'Native Host не отвечает'
      };
    }

    return { configured: false, nativeHostWorking: false, message: 'Требуется обновление манифеста' };
  } catch (e) {
    const msg = e.message || '';
    if (msg.includes('native') || msg.includes('Native')) {
      return { configured: false, nativeHostWorking: false, message: 'Native Host не подключен' };
    }
    return { configured: false, nativeHostWorking: false, message: 'Native Host не подключен' };
  }
}

/** ID, который Chrome обязан присвоить по полю "key" из манифеста.
 *  Считаем прямо здесь, чтобы страница сама ловила случай «key потерялся». */
async function expectedExtensionId() {
  const key = chrome.runtime.getManifest().key;
  if (!key) return null;
  const der = Uint8Array.from(atob(key), c => c.charCodeAt(0));
  const hash = new Uint8Array(await crypto.subtle.digest('SHA-256', der));
  return [...hash.slice(0, 16)]
    .map(b => b.toString(16).padStart(2, '0')).join('')
    .replace(/./g, c => String.fromCharCode(97 + parseInt(c, 16)));
}

async function checkAllSteps() {
  const status = await checkManifestStatus();
  manifestConfigured = status.configured;

  if (status.configured) {
    updateStep(1, 'ok', '✓');
    updateStep(2, 'ok', '✓');
    updateProgress(1, 'done');
    updateProgress(2, 'done');
  } else {
    updateStep(1, 'warn', '⚠');
    updateStep(2, 'warn', '○');
    updateProgress(1, 'active');
    updateProgress(2, '');
  }

  showStatusPanel(status);
  await checkIdPinning();
}

/** Расширение загружено без поля "key" → ID выведен из пути и не совпадёт
 *  с тем, что зашито в манифесте native host. Это и есть та самая поломка,
 *  ради которой раньше существовал шаг «скопируйте ID». */
async function checkIdPinning() {
  const panel = document.getElementById('statusPanel');
  const old = panel.querySelector('.id-mismatch');
  if (old) old.remove();

  let expected;
  try {
    expected = await expectedExtensionId();
  } catch (_) {
    return;
  }

  if (expected && expected === chrome.runtime.id) return;

  const box = document.createElement('div');
  box.className = 'id-mismatch';
  if (!expected) {
    box.innerHTML = '<strong>В манифесте расширения нет поля «key».</strong><br>' +
      'ID зависит от пути к папке и будет разным на каждой машине. ' +
      'Native Host не примет подключение, пока ID не совпадёт.';
  } else {
    box.innerHTML = '<strong>ID не совпадает с ключом расширения.</strong><br>' +
      `Ожидался <code>${expected}</code>, а Chrome присвоил <code>${chrome.runtime.id}</code>. ` +
      'Похоже, загружена копия расширения без поля «key» — удалите её и загрузите папку заново.';
  }
  panel.appendChild(box);
}

async function refreshStatus() {
  const btn = document.getElementById('refreshStatusBtn');
  btn.disabled = true;
  btn.textContent = 'Обновление...';

  await checkAllSteps();

  setTimeout(() => {
    btn.disabled = false;
    btn.textContent = 'Обновить статус';
  }, 500);
}

// ============================================
// UI UPDATES
// ============================================

function updateStep(num, state, badgeChar) {
  const step = document.getElementById(`step${num}`);
  const badge = document.getElementById(`step${num}-badge`);

  step.classList.remove('step-ok', 'step-warn', 'step-err');

  if (state === 'ok') {
    step.classList.add('step-ok');
    badge.textContent = '✅';
  } else if (state === 'warn') {
    step.classList.add('step-warn');
    badge.textContent = '⚠️';
  } else if (state === 'err') {
    step.classList.add('step-err');
    badge.textContent = '❌';
  }
}

function updateProgress(segment, state) {
  const el = document.getElementById(`prog${segment}`);
  el.classList.remove('done', 'active');
  if (state) el.classList.add(state);
}

function showStatusPanel(status) {
  const details = document.getElementById('statusDetails');

  const rows = [
    { label: 'Extension ID', val: extensionId, cls: '' },
    { label: 'Native Host', val: status.nativeHostWorking ? 'Работает' : 'Не установлен', cls: status.nativeHostWorking ? 'ok' : 'err' },
  ];

  details.innerHTML = rows.map(r =>
    `<div class="status-row"><span class="label">${r.label}</span><span class="val ${r.cls}">${r.val}</span></div>`
  ).join('');

  if (status.configured) {
    details.innerHTML += '<div class="status-row" style="margin-top:8px;"><span class="val ok" style="width:100%;text-align:center;">Готово к использованию</span></div>';
  } else {
    details.innerHTML += '<div class="status-row" style="margin-top:8px;"><span class="val warn" style="width:100%;text-align:center;">Запустите install.bat</span></div>';
  }
}

// ============================================
// TEST CONNECTION
// ============================================

async function testConnection() {
  const btn = document.getElementById('testConnectionBtn');
  btn.disabled = true;
  btn.textContent = 'Проверка...';

  try {
    const response = await chrome.runtime.sendMessage({ action: 'pingNative' });

    if (!response || !response.success) {
      showToast('Native Host не отвечает. Запустите install.bat в корне проекта.', 'err', 5000);
      updateStep(2, 'err', '✗');
    } else {
      showToast('Native Host отвечает! Можно использовать расширение.', 'ok', 5000);
      await checkAllSteps();
    }
  } catch (error) {
    showToast('Ошибка: ' + error.message + '. Запустите install.bat и повторите.', 'err', 6000);
    updateStep(2, 'err', '✗');
  } finally {
    btn.disabled = false;
    btn.textContent = 'Проверить подключение';
  }
}

// ============================================
// SAVED PROJECT PATH
// ============================================

async function loadSavedProjectPath() {
  try {
    const data = await chrome.storage.local.get(['projectPath']);
    if (data.projectPath) {
      document.getElementById('savedPathText').textContent = data.projectPath + '\\install.bat';
      document.getElementById('savedPathInfo').classList.remove('hidden');
    }
  } catch {
    // no saved path
  }
}
