let profiles = [];
let activeProfileId = null;
let connectionStartTime = null;
let uptimeInterval = null;
let editingProfileId = null;
let firstConnectType = 'vless';
let profileFormType = 'vless';
// Профиль, для которого показано инлайн-подтверждение удаления.
// Удаление необратимо (конфиг больше нигде не хранится), поэтому в два шага.
let pendingDeleteId = null;

// Префиксы шифртекста обязаны совпадать с dpapi_store.py (ENC_PREFIX*):
//   enc:v1: — Windows, DPAPI
//   enc:v2: — macOS и Linux, ключ в Связке ключей/keyring + Fernet
// Неузнанный префикс опасен: шифртекст принимается за обычный конфиг, не
// уходит на расшифровку, и при следующем открытии вместо ссылки пользователь
// видит «обрезанную» абракадабру enc:v2:..., а подключение падает.
// Сверку с хостом держит tests/test_prefix_parity.py.
const ENC_PREFIXES = ['enc:v1:', 'enc:v2:'];
const isEncrypted = (value) =>
  typeof value === 'string' && ENC_PREFIXES.some((p) => value.startsWith(p));
const SECRET_FIELDS = ['vlessUrl', 'wgConfig'];

const WG_PLACEHOLDER = `[Interface]
PrivateKey = YOUR_PRIVATE_KEY
Address = 10.0.0.2/32
MTU = 1420

[Peer]
PublicKey = SERVER_PUBLIC_KEY
AllowedIPs = 0.0.0.0/0
Endpoint = server.example.com:51820
PersistentKeepalive = 25`;

document.addEventListener('DOMContentLoaded', async () => {
  await loadSavedConfig();
  await loadRouteOption();
  await updateStatus();
  await checkHostVersion();
  uptimeInterval = setInterval(updateUptime, 1000);
  setInterval(updateStatus, 5000);
  setInterval(verifyConnectionHealth, 30000);
  setupEventListeners();
  setupTypeTabs();
});

function setupEventListeners() {
  document.getElementById('connectBtn').addEventListener('click', handleFirstConnect);
  document.getElementById('pasteBtn').addEventListener('click', function () {
    pasteToField('vlessUrl', this);
  });

  document.getElementById('addProfileBtn').addEventListener('click', openAddForm);
  document.getElementById('profileFormCancelBtn').addEventListener('click', closeProfileForm);
  document.getElementById('profileFormSaveBtn').addEventListener('click', handleProfileFormSave);
  document.getElementById('profileFormPasteBtn').addEventListener('click', function () {
    pasteToField('profileFormUrl', this);
  });

  document.getElementById('toggleBtn').addEventListener('click', handleToggle);
  document.getElementById('profileList').addEventListener('click', handleProfileListClick);
  document.getElementById('routeRuDirect').addEventListener('change', handleRouteRuToggle);
  document.getElementById('lanDirect').addEventListener('change', handleLanToggle);
  document.getElementById('exportProfilesBtn').addEventListener('click', handleExportProfiles);
  document.getElementById('importProfilesBtn').addEventListener('click', () => {
    document.getElementById('importProfilesFile').click();
  });
  document.getElementById('importProfilesFile').addEventListener('change', handleImportProfiles);
  bindFileImport('firstConnectFileBtn', 'firstConnectFile', 'vlessUrl');
  bindFileImport('profileFormFileBtn', 'profileFormFile', 'profileFormUrl');
}

function setupTypeTabs() {
  bindTypeTabs('firstConnectTypeTabs', (type) => {
    firstConnectType = type;
    updateConfigInputUi(type, 'vlessUrl', 'firstConnectLabel', 'firstConnectHint');
  });
  bindTypeTabs('profileFormTypeTabs', (type) => {
    profileFormType = type;
    updateConfigInputUi(type, 'profileFormUrl', 'profileFormLabel');
  });
}

function bindTypeTabs(containerId, onChange) {
  const container = document.getElementById(containerId);
  if (!container) return;
  container.querySelectorAll('.profile-type-tab').forEach((tab) => {
    tab.addEventListener('click', () => {
      container.querySelectorAll('.profile-type-tab').forEach(t => t.classList.remove('active'));
      tab.classList.add('active');
      onChange(tab.dataset.type);
    });
  });
}

function setTypeTabs(containerId, type) {
  const container = document.getElementById(containerId);
  if (!container) return;
  container.querySelectorAll('.profile-type-tab').forEach((tab) => {
    tab.classList.toggle('active', tab.dataset.type === type);
  });
}

function updateConfigInputUi(type, fieldId, labelId, hintId) {
  const field = document.getElementById(fieldId);
  const label = document.getElementById(labelId);
  const hint = hintId ? document.getElementById(hintId) : null;
  if (type === 'wireguard') {
    if (label) label.textContent = 'WireGuard конфиг (.conf)';
    if (field) {
      field.placeholder = WG_PLACEHOLDER;
      // WG-конфиг это ~9 строк: в 3 строки его не прочитать и не проверить.
      field.rows = 9;
    }
    if (hint) hint.textContent = 'Вставьте содержимое .conf или загрузите файл';
  } else {
    if (label) label.textContent = 'VLESS URL';
    if (field) {
      field.placeholder = 'vless://uuid@server:port?security=tls&type=tcp#name';
      field.rows = 3;
    }
    if (hint) hint.textContent = 'Получите URL от администратора VPN';
  }
  const fileRowId = fieldId === 'vlessUrl' ? 'firstConnectFileRow' : 'profileFormFileRow';
  const fileRow = document.getElementById(fileRowId);
  if (fileRow) fileRow.classList.toggle('hidden', type !== 'wireguard');
}

function getProfileType(profile) {
  return profile?.type === 'wireguard' ? 'wireguard' : 'vless';
}

function getProfileConfigText(profile) {
  return getProfileType(profile) === 'wireguard' ? (profile.wgConfig || '') : (profile.vlessUrl || '');
}

function bindFileImport(btnId, inputId, fieldId) {
  const btn = document.getElementById(btnId);
  const input = document.getElementById(inputId);
  if (!btn || !input) return;
  btn.addEventListener('click', () => input.click());
  input.addEventListener('change', async () => {
    const file = input.files && input.files[0];
    input.value = '';
    if (!file) return;
    try {
      const text = (await file.text()).replace(/^\uFEFF/, '').trim();
      if (!text) {
        showError('Файл пустой');
        return;
      }
      document.getElementById(fieldId).value = text;
      showSuccess(`Загружен ${file.name}`);
    } catch (e) {
      showError('Не удалось прочитать файл: ' + e.message);
    }
  });
}

/** Один вызов native host на весь список секретов (было — по вызову на профиль). */
async function transformSecrets(action, values) {
  if (values.length === 0) return { hostOk: true, results: [] };
  try {
    const r = await chrome.runtime.sendMessage({ action, items: values });
    if (r?.success && Array.isArray(r.results)) {
      return { hostOk: true, results: r.results };
    }
    return { hostOk: false, results: [] };
  } catch (_) {
    return { hostOk: false, results: [] };
  }
}

/** Доступен ли Native Host. Спрашиваем только когда других сигналов нет
 *  (нет профилей / все секреты в plaintext), и кешируем успех на сессию,
 *  чтобы не плодить запуски процесса на каждое открытие popup. */
async function checkNativeHostReachable() {
  try {
    const cached = await chrome.storage.session.get(['nativeHostOk']);
    if (cached.nativeHostOk === true) return true;
    const r = await chrome.runtime.sendMessage({ action: 'pingNative' });
    const ok = !!r?.success;
    if (ok) await chrome.storage.session.set({ nativeHostOk: true });
    return ok;
  } catch (_) {
    return false;
  }
}

// ============================================
// CLIPBOARD PASTE
// ============================================

async function pasteToField(fieldId, btn) {
  try {
    const text = await navigator.clipboard.readText();
    if (text) {
      document.getElementById(fieldId).value = text.trim();
      if (btn) {
        btn.classList.add('pasted');
        const origHTML = btn.innerHTML;
        btn.innerHTML = `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3"><polyline points="20 6 9 17 4 12"></polyline></svg> Готово`;
        setTimeout(() => {
          btn.classList.remove('pasted');
          btn.innerHTML = origHTML;
        }, 1500);
      }
    }
  } catch {
    document.getElementById(fieldId).focus();
  }
}

// ============================================
// DATA MODEL & MIGRATION
// ============================================

async function loadSavedConfig() {
  try {
    const data = await chrome.storage.local.get([
      'profiles', 'activeProfileId', 'isConnected',
      'serverInfo', 'connectionStartTime',
      'vlessUrl', 'profileName'
    ]);

    if (data.profiles && data.profiles.length > 0) {
      let hadPlaintextSecrets = false;
      // locked — служебный флаг текущего сеанса, в storage он попасть не должен;
      // иначе профиль остаётся «заблокированным» и после починки Native Host.
      profiles = data.profiles.map(p => {
        const copy = { ...p, type: p.type || 'vless' };
        delete copy.locked;
        return copy;
      });

      const jobs = [];
      for (const profile of profiles) {
        for (const field of SECRET_FIELDS) {
          const value = profile[field];
          if (!value) continue;
          if (isEncrypted(value)) {
            jobs.push({ profile, field });
          } else {
            hadPlaintextSecrets = true;
          }
        }
      }

      const { hostOk, results } = await transformSecrets(
        'unprotectSecrets',
        jobs.map(j => j.profile[j.field])
      );

      jobs.forEach((job, i) => {
        const r = hostOk ? results[i] : null;
        if (r?.ok && typeof r.data === 'string') {
          job.profile[job.field] = r.data;
        } else {
          // Сбой одного профиля не должен ронять весь список: он остаётся
          // видимым, но помечен замком и недоступен для подключения.
          job.profile.locked = true;
        }
      });

      activeProfileId = data.activeProfileId || profiles[0].id;
      if (hadPlaintextSecrets) {
        await saveProfiles();
      }

      // Если секретов на расшифровку не было, доступность хоста ниоткуда не
      // известна — спрашиваем явно, чтобы не выяснять это при подключении.
      const nativeHostOk = jobs.length > 0 ? hostOk : await checkNativeHostReachable();
      reportNativeHostState(nativeHostOk, profiles.filter(p => p.locked).length);
    } else if (data.vlessUrl) {
      const profile = {
        id: crypto.randomUUID(),
        type: 'vless',
        name: data.profileName || extractProfileName(data.vlessUrl),
        vlessUrl: data.vlessUrl
      };
      profiles = [profile];
      activeProfileId = profile.id;
      await chrome.storage.local.set({ profiles, activeProfileId });
      await chrome.storage.local.remove(['vlessUrl', 'profileName']);
    } else {
      // Первый запуск: профилей нет, но именно здесь чаще всего и оказывается,
      // что Native Host не настроен. Говорим об этом до попытки подключения.
      reportNativeHostState(await checkNativeHostReachable(), 0);
    }

    if (profiles.length > 0) {
      showProfilesView();
      renderProfiles();

      if (data.isConnected) {
        connectionStartTime = data.connectionStartTime || Date.now();
        updateToggleButton(true);
        updateServerInfo(data.serverInfo);
      }
    }
  } catch (error) {
    console.error('Ошибка загрузки конфига:', error);
  }
}

/** Единое сообщение о состоянии Native Host при открытии popup. */
function reportNativeHostState(hostOk, lockedCount) {
  if (!hostOk) {
    // Формулировка с «Native Host» включает в showError вариант со ссылкой
    // на страницу настройки.
    showError('Нет связи с Native Host');
    return;
  }
  if (lockedCount > 0) {
    showError(lockedCount === 1
      ? 'Один профиль не удалось расшифровать — откройте его и вставьте конфиг заново.'
      : `Профилей не удалось расшифровать: ${lockedCount} — откройте их и вставьте конфиг заново.`);
  }
}

async function saveProfiles() {
  const encrypted = profiles.map(p => {
    const copy = { ...p };
    delete copy.locked;  // флаг сеанса, не часть профиля
    return copy;
  });

  const jobs = [];
  for (const copy of encrypted) {
    for (const field of SECRET_FIELDS) {
      if (copy[field]) jobs.push({ copy, field });
    }
  }

  const { hostOk, results } = await transformSecrets(
    'protectSecrets',
    jobs.map(j => j.copy[j.field])
  );

  // Хост недоступен — сохраняем как есть (plaintext), как и раньше:
  // потерять профиль хуже, чем записать его незашифрованным.
  if (hostOk) {
    jobs.forEach((job, i) => {
      const r = results[i];
      if (r?.ok && typeof r.data === 'string') {
        job.copy[job.field] = r.data;
      }
    });
  }

  await chrome.storage.local.set({ profiles: encrypted, activeProfileId });
}

function getActiveProfile() {
  return profiles.find(p => p.id === activeProfileId) || null;
}

// ============================================
// VIEW SWITCHING
// ============================================

function showProfilesView() {
  document.getElementById('configInput').classList.add('hidden');
  const view = document.getElementById('profilesView');
  view.classList.remove('hidden');
  view.classList.add('fade-in');
  refreshToggleAvailability();
}

/** Тумблер недоступен без профиля — объясняем причину в title, а не молчим. */
function setToggleDisabled(disabled, reason) {
  const btn = document.getElementById('toggleBtn');
  btn.disabled = disabled;
  btn.title = disabled ? reason : 'Переключить подключение';
}

function refreshToggleAvailability() {
  setToggleDisabled(!activeProfileId, 'Сначала добавьте профиль');
}

function showConfigInput() {
  document.getElementById('profilesView').classList.add('hidden');
  const input = document.getElementById('configInput');
  input.classList.remove('hidden');
  input.classList.add('fade-in');
}

// ============================================
// RENDER PROFILES
// ============================================

function renderProfiles() {
  const list = document.getElementById('profileList');
  list.innerHTML = profiles.map(p => {
    if (p.id === pendingDeleteId) {
      return `
        <div class="profile-item confirm-delete" data-id="${p.id}">
          <span class="confirm-text">Удалить «${escapeHtml(p.name)}»?</span>
          <div class="profile-item-actions">
            <button class="btn-confirm-delete" data-action="delete-confirm" data-id="${p.id}">Удалить</button>
            <button class="btn-cancel-delete" data-action="delete-cancel" data-id="${p.id}">Отмена</button>
          </div>
        </div>
      `;
    }
    const isActive = p.id === activeProfileId;
    const pType = getProfileType(p);
    const badgeClass = pType === 'wireguard' ? 'wireguard' : 'vless';
    const badgeLabel = pType === 'wireguard' ? 'WG' : 'VL';
    const lockedTitle = p.locked ? 'title="Не удалось расшифровать — проверьте Native Host или отредактируйте профиль заново"' : '';
    return `
      <div class="profile-item ${isActive ? 'active' : ''} ${p.locked ? 'locked' : ''}" data-id="${p.id}">
        <div class="profile-item-select" data-action="select" data-id="${p.id}" ${lockedTitle}>
          <div class="profile-item-radio"></div>
          <span class="profile-type-badge ${badgeClass}">${badgeLabel}</span>
          <span class="profile-item-name">${p.locked ? '🔒 ' : ''}${escapeHtml(p.name)}</span>
        </div>
        <div class="profile-item-actions">
          <button class="icon-btn ping-btn" data-action="ping" data-id="${p.id}" title="Ping" ${p.locked ? 'disabled' : ''}>
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <path d="M1 1l4 4m14-4l-4 4"></path>
              <path d="M5 12a7 7 0 0 1 14 0"></path>
              <path d="M8.5 12a3.5 3.5 0 0 1 7 0"></path>
              <circle cx="12" cy="12" r="1"></circle>
            </svg>
          </button>
          <span class="ping-result profile-ping-result" data-id="${p.id}"></span>
          <button class="icon-btn" data-action="edit" data-id="${p.id}" title="Редактировать">
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"></path>
              <path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z"></path>
            </svg>
          </button>
          <button class="icon-btn delete-btn" data-action="delete" data-id="${p.id}" title="Удалить">
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
              <path d="M18 6L6 18"></path>
              <path d="M6 6l12 12"></path>
            </svg>
          </button>
        </div>
      </div>
    `;
  }).join('');

  refreshToggleAvailability();
}

function escapeHtml(str) {
  const div = document.createElement('div');
  div.textContent = str;
  return div.innerHTML;
}

// ============================================
// PROFILE LIST EVENTS (delegated)
// ============================================

function handleProfileListClick(e) {
  const target = e.target.closest('[data-action]');
  if (!target) return;

  const action = target.dataset.action;
  const id = target.dataset.id;

  // Любое другое действие снимает висящее подтверждение удаления.
  if (pendingDeleteId && action !== 'delete-confirm') {
    pendingDeleteId = null;
    renderProfiles();
    if (action === 'delete-cancel') return;
  }

  switch (action) {
    case 'select': selectProfile(id).catch(e => { console.error('selectProfile:', e); showError(e.message); }); break;
    case 'ping': handleProfilePing(id); break;
    case 'edit': openEditForm(id); break;
    case 'delete': requestDeleteProfile(id); break;
    case 'delete-confirm': deleteProfile(id); break;
  }
}

function requestDeleteProfile(id) {
  pendingDeleteId = id;
  renderProfiles();
}

async function selectProfile(id) {
  if (id === activeProfileId) return;

  const target = profiles.find(p => p.id === id);
  if (target?.locked) {
    showError('Профиль заблокирован (не удалось расшифровать). Отредактируйте его заново.');
    return;
  }

  const data = await chrome.storage.local.get(['isConnected']);
  const wasConnected = data.isConnected;

  if (wasConnected) {
    await handleDisconnect(true);
  }

  activeProfileId = id;
  await saveProfiles();
  renderProfiles();

  if (wasConnected) {
    await doConnect();
  }
}

// ============================================
// ADD / EDIT FORM
// ============================================

function openAddForm() {
  editingProfileId = null;
  profileFormType = 'vless';
  setTypeTabs('profileFormTypeTabs', 'vless');
  updateConfigInputUi('vless', 'profileFormUrl', 'profileFormLabel');
  document.getElementById('profileFormUrl').value = '';
  document.getElementById('profileFormSaveBtn').textContent = 'Добавить';
  document.getElementById('profileForm').classList.add('open');
}

function openEditForm(id) {
  const profile = profiles.find(p => p.id === id);
  if (!profile) return;

  editingProfileId = id;
  profileFormType = getProfileType(profile);
  setTypeTabs('profileFormTypeTabs', profileFormType);
  updateConfigInputUi(profileFormType, 'profileFormUrl', 'profileFormLabel');
  // Заблокированный профиль хранит нерасшифрованный ciphertext — показывать его
  // в поле ввода бессмысленно и вводит в заблуждение, просим вставить заново.
  document.getElementById('profileFormUrl').value = profile.locked ? '' : getProfileConfigText(profile);
  document.getElementById('profileFormSaveBtn').textContent = 'Сохранить';
  document.getElementById('profileForm').classList.add('open');
}

function closeProfileForm() {
  document.getElementById('profileForm').classList.remove('open');
  editingProfileId = null;
}

async function handleProfileFormSave() {
  const text = document.getElementById('profileFormUrl').value.trim();
  const type = profileFormType;

  if (!text) {
    showError(type === 'wireguard' ? 'Введите WireGuard конфиг' : 'Введите VLESS URL');
    return;
  }

  try {
    validateProfileInput(type, text);
  } catch (error) {
    showError(error.message);
    return;
  }

  hideError();

  try {
    if (editingProfileId) {
      const profile = profiles.find(p => p.id === editingProfileId);
      if (!profile) return;

      const data = await chrome.storage.local.get(['isConnected']);
      if (data.isConnected && editingProfileId === activeProfileId) {
        await chrome.runtime.sendMessage({ action: 'disconnect' });
        updateToggleButton(false);
        connectionStartTime = null;
        updateServerInfo('—');
        document.getElementById('uptime').textContent = '—';
        await chrome.storage.local.set({ isConnected: false, connectionStartTime: null });
      }

      applyProfileConfig(profile, type, text);
      await saveProfiles();
      renderProfiles();
      closeProfileForm();
      showSuccess('Профиль обновлён');
    } else {
      const profile = { id: crypto.randomUUID(), type };
      applyProfileConfig(profile, type, text);
      profiles.push(profile);
      activeProfileId = profile.id;
      await saveProfiles();
      renderProfiles();
      closeProfileForm();
      showSuccess('Профиль добавлен');
    }
  } catch (error) {
    showError('Ошибка: ' + error.message);
  }
}

function applyProfileConfig(profile, type, text) {
  profile.type = type;
  delete profile.locked;
  if (type === 'wireguard') {
    profile.wgConfig = text;
    profile.name = extractWireGuardProfileName(text);
    delete profile.vlessUrl;
  } else {
    profile.vlessUrl = text;
    profile.name = extractProfileName(text);
    delete profile.wgConfig;
  }
}

async function deleteProfile(id) {
  pendingDeleteId = null;
  const data = await chrome.storage.local.get(['isConnected']);
  if (data.isConnected && id === activeProfileId) {
    try {
      await chrome.runtime.sendMessage({ action: 'disconnect' });
    } catch (_) { /* ignore */ }
    updateToggleButton(false);
    connectionStartTime = null;
    updateServerInfo('—');
    document.getElementById('uptime').textContent = '—';
    await chrome.storage.local.set({ isConnected: false, connectionStartTime: null });
  }

  profiles = profiles.filter(p => p.id !== id);

  if (id === activeProfileId) {
    activeProfileId = profiles[0]?.id || null;
  }

  await saveProfiles();

  if (profiles.length === 0) {
    showConfigInput();
  } else {
    renderProfiles();
  }

  showSuccess('Профиль удалён');
}

// ============================================
// FIRST CONNECT (from configInput — первый запуск)
// ============================================

async function handleFirstConnect() {
  const text = document.getElementById('vlessUrl').value.trim();
  const type = firstConnectType;

  if (!text) {
    showError(type === 'wireguard' ? 'Введите WireGuard конфиг' : 'Введите VLESS URL');
    return;
  }

  try {
    validateProfileInput(type, text);
  } catch (error) {
    showError(error.message);
    return;
  }

  hideError();

  const profile = { id: crypto.randomUUID(), type };
  applyProfileConfig(profile, type, text);

  profiles.push(profile);
  activeProfileId = profile.id;
  await saveProfiles();

  showProfilesView();
  renderProfiles();

  await doConnect();
}

// ============================================
// CONNECT / DISCONNECT / TOGGLE
// ============================================

async function handleToggle() {
  const data = await chrome.storage.local.get(['isConnected']);
  if (data.isConnected) {
    await handleDisconnect();
  } else {
    await doConnect();
  }
}

async function doConnect() {
  const profile = getActiveProfile();
  if (!profile) {
    showError('Профиль не выбран');
    return;
  }
  if (profile.locked) {
    showError('Профиль заблокирован (не удалось расшифровать). Отредактируйте его заново.');
    return;
  }

  updateToggleButton('connecting');

  try {
    const config = buildConnectConfig(profile);
    // Опция общая для всех профилей, а не часть конфига сервера.
    const { routeRuDirect = false } = await chrome.storage.local.get('routeRuDirect');
    config.routeRuDirect = routeRuDirect;
    const profileUrl = getProfileType(profile) === 'wireguard' ? profile.wgConfig : profile.vlessUrl;

    const response = await chrome.runtime.sendMessage({
      action: 'connect',
      vlessUrl: profileUrl,
      config: config
    });

    if (!response?.success) {
      throw new Error(response?.error || 'Неизвестная ошибка');
    }
    connectionStartTime = Date.now();
    const serverLabel = getProfileServerLabel(profile, config);
    await chrome.storage.local.set({
      isConnected: true,
      serverInfo: serverLabel,
      connectionStartTime: connectionStartTime
    });

    updateToggleButton(true);
    updateServerInfo(serverLabel);
    showSuccess('Подключено');
  } catch (error) {
    console.error('Ошибка подключения:', error);
    showError(error.message);
    updateToggleButton(false);
  }
}

async function handleDisconnect(silent = false) {
  updateToggleButton('connecting');

  try {
    const response = await chrome.runtime.sendMessage({ action: 'disconnect' });

    if (!response?.success) {
      throw new Error(response?.error || 'Ошибка отключения');
    }
    connectionStartTime = null;
    await chrome.storage.local.set({ isConnected: false, connectionStartTime: null });

    updateToggleButton(false);
    updateServerInfo('—');
    document.getElementById('uptime').textContent = '—';
    if (!silent) showSuccess('Отключено');
  } catch (error) {
    console.error('Ошибка отключения:', error);
    showError(error.message);
    await updateStatus();
  }
}

// ============================================
// VLESS / WIREGUARD PARSERS
// ============================================

function validateProfileInput(type, text) {
  if (type === 'wireguard') {
    parseWireGuardConf(text);
    return;
  }
  if (!text.startsWith('vless://')) {
    throw new Error('Неверный формат URL. Должен начинаться с vless://');
  }
  parseVlessUrl(text);
}

async function loadRouteOption() {
  const { routeRuDirect = false } = await chrome.storage.local.get('routeRuDirect');
  const el = document.getElementById('routeRuDirect');
  if (el) el.checked = routeRuDirect;

  const { lanDirect = true } = await chrome.storage.local.get('lanDirect');
  const lanEl = document.getElementById('lanDirect');
  if (lanEl) lanEl.checked = lanDirect;
}

/** Предупреждение без привязки к Native Host (showError подменяет текст на «Нет связи…»). */
function showWarning(message) {
  renderMessage('error-message', (body) => { body.textContent = message; });
}

/** Версия Native Host против версии расширения; удачный результат кешируется на сеанс. */
async function checkHostVersion() {
  try {
    const cached = await chrome.storage.session.get(['hostVersionOk']);
    if (cached.hostVersionOk === chrome.runtime.getManifest().version) return;
    const r = await chrome.runtime.sendMessage({ action: 'hostVersion' });
    if (!r?.success) return;   // нет связи — об этом уже говорит reportNativeHostState
    if (r.ok) {
      await chrome.storage.session.set({ hostVersionOk: chrome.runtime.getManifest().version });
      return;
    }
    // не перебиваем более важное сообщение (обрыв, нет связи)
    if (document.getElementById('errorMessage').classList.contains('hidden')) {
      showWarning(r.message);
    }
  } catch (_) { /* проверка необязательна */ }
}

// ============================================
// ЭКСПОРТ / ИМПОРТ ПРОФИЛЕЙ
// ============================================

function handleExportProfiles() {
  const { json, count, skipped } = buildProfilesExport(profiles);
  if (count === 0) {
    showError('Нечего экспортировать: нет доступных профилей');
    return;
  }
  const ok = window.confirm(
    'Файл будет содержать ключи и UUID в открытом виде — любой, кто его получит, сможет ' +
    'пользоваться вашими серверами. Храните его так же бережно, как пароли. Продолжить?'
  );
  if (!ok) return;

  const blob = new Blob([json], { type: 'application/json' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `vless-connector-profiles-${new Date().toISOString().slice(0, 10)}.json`;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 10000);
  showSuccess(skipped ? `Экспортировано: ${count}, пропущено (заблокированы): ${skipped}` : `Экспортировано профилей: ${count}`);
}

async function handleImportProfiles(event) {
  const input = event.target;
  const file = input.files && input.files[0];
  input.value = '';
  if (!file) return;
  try {
    const text = await file.text();
    const existing = profiles.map(getProfileConfigText);
    const { profiles: incoming, errors, duplicates } = parseProfilesImport(text, validateProfileInput, existing);
    if (incoming.length === 0) {
      showError(errors.length
        ? `Импортировать нечего. ${errors[0]}`
        : (duplicates ? 'Все профили из файла уже есть' : 'В файле нет профилей'));
      return;
    }
    profiles.push(...incoming);
    if (!activeProfileId) activeProfileId = incoming[0].id;
    await saveProfiles();
    showProfilesView();
    renderProfiles();
    const notes = [];
    if (duplicates) notes.push(`уже были: ${duplicates}`);
    if (errors.length) notes.push(`с ошибками: ${errors.length}`);
    showSuccess(`Импортировано: ${incoming.length}` + (notes.length ? ` (${notes.join(', ')})` : ''));
  } catch (error) {
    showError(error.message);
  }
}

async function handleLanToggle(event) {
  const enabled = event.target.checked;
  await chrome.storage.local.set({ lanDirect: enabled });
  event.target.disabled = true;
  try {
    // Если подключены — применяем сразу (Xray при этом не перезапускается)
    await chrome.runtime.sendMessage({ action: 'refreshProxy' });
    showSuccess(enabled ? 'Локальная сеть пойдёт напрямую' : 'Локальная сеть пойдёт через VPN');
  } catch (error) {
    showError(error.message);
  } finally {
    event.target.disabled = false;
  }
}

async function handleRouteRuToggle(event) {
  const enabled = event.target.checked;
  await chrome.storage.local.set({ routeRuDirect: enabled });

  const { isConnected } = await chrome.storage.local.get('isConnected');
  if (!isConnected) {
    showSuccess(enabled ? 'Российские сайты пойдут напрямую' : 'Весь трафик через VPN');
    return;
  }

  // Xray читает конфиг только при старте, поэтому активное соединение
  // приходится передёрнуть — иначе переключатель ничего не изменит.
  event.target.disabled = true;
  try {
    await handleDisconnect(true);
    await doConnect();
  } finally {
    event.target.disabled = false;
  }
}

function buildConnectConfig(profile) {
  if (getProfileType(profile) === 'wireguard') {
    return parseWireGuardConf(profile.wgConfig);
  }
  return parseVlessUrl(profile.vlessUrl);
}

function getProfileServerLabel(profile, config) {
  if (getProfileType(profile) === 'wireguard') {
    const endpoint = config.peers?.[0]?.endpoint || 'WireGuard';
    return endpoint;
  }
  return formatHostPort(config.server, config.port);
}

// ============================================
// STATUS
// ============================================

async function verifyConnectionHealth() {
  try {
    const status = await chrome.runtime.sendMessage({ action: 'getStatus' });
    if (!status?.isConnected) return;
    await chrome.runtime.sendMessage({ action: 'verifyConnection' });
  } catch (error) {
    console.error('Ошибка проверки Xray:', error);
  }
}

async function updateStatus() {
  try {
    const response = await chrome.runtime.sendMessage({ action: 'getStatus' });

    if (response.isConnected) {
      const data = await chrome.storage.local.get(['serverInfo', 'connectionStartTime']);
      connectionStartTime = data.connectionStartTime || Date.now();
      updateToggleButton(true);
      updateServerInfo(data.serverInfo);
    } else {
      connectionStartTime = null;
      updateToggleButton(false);
      updateServerInfo('—');
      document.getElementById('uptime').textContent = '—';

      await chrome.storage.local.set({ isConnected: false, connectionStartTime: null });
    }
    await showDropNoticeOnce();
  } catch (error) {
    console.error('Ошибка получения статуса:', error);
  }
}

/** Соединение оборвалось, пока окно было закрыто: один раз объясняем, что произошло. */
async function showDropNoticeOnce() {
  const { connectionDropped } = await chrome.storage.local.get('connectionDropped');
  if (!connectionDropped) return;
  showWarning('Соединение с VPN оборвалось, прокси снят — сейчас трафик идёт НАПРЯМУЮ. ' +
    'Подключитесь снова.');
  try {
    await chrome.runtime.sendMessage({ action: 'ackDrop' });
  } catch (_) { /* значок погаснет при следующем действии */ }
}

function updateToggleButton(state) {
  const toggleBtn = document.getElementById('toggleBtn');
  const toggleStatus = document.getElementById('toggleStatus');

  toggleBtn.classList.remove('connected', 'connecting');
  toggleStatus.classList.remove('connected', 'connecting');

  if (state === true) {
    toggleBtn.classList.add('connected');
    toggleStatus.classList.add('connected');
    toggleStatus.textContent = 'Подключено';
    toggleBtn.setAttribute('aria-pressed', 'true');
    toggleBtn.setAttribute('aria-label', 'Отключить VPN');
    refreshToggleAvailability();
  } else if (state === 'connecting') {
    toggleBtn.classList.add('connecting');
    toggleStatus.classList.add('connecting');
    toggleStatus.textContent = 'Подключение...';
    toggleBtn.setAttribute('aria-pressed', 'false');
    toggleBtn.setAttribute('aria-label', 'Идёт подключение');
    setToggleDisabled(true, 'Идёт подключение...');
  } else {
    toggleStatus.textContent = 'Отключено';
    toggleBtn.setAttribute('aria-pressed', 'false');
    toggleBtn.setAttribute('aria-label', 'Подключить VPN');
    refreshToggleAvailability();
  }
}

function updateServerInfo(serverInfo) {
  document.getElementById('serverInfo').textContent = serverInfo || '—';
}

function updateUptime() {
  if (!connectionStartTime) {
    document.getElementById('uptime').textContent = '—';
    return;
  }

  const diff = Math.floor((Date.now() - connectionStartTime) / 1000);
  const hours = Math.floor(diff / 3600);
  const minutes = Math.floor((diff % 3600) / 60);
  const seconds = diff % 60;

  document.getElementById('uptime').textContent =
    `${hours.toString().padStart(2, '0')}:${minutes.toString().padStart(2, '0')}:${seconds.toString().padStart(2, '0')}`;
}

// ============================================
// PING
// ============================================

async function measurePing(server, port, opts = {}) {
  const res = await chrome.runtime.sendMessage({
    action: 'pingHost',
    host: server,
    port: Number(port),
    transport: opts.transport || 'tcp',
    socksPort: opts.socksPort || null
  });
  if (!res || res.success !== true || typeof res.pingMs !== 'number') {
    return -1;
  }
  return res.pingMs;
}

async function handleProfilePing(id) {
  const profile = profiles.find(p => p.id === id);
  if (!profile || profile.locked) return;

  const resultEl = document.querySelector(`.profile-ping-result[data-id="${id}"]`);
  const btn = document.querySelector(`[data-action="ping"][data-id="${id}"]`);
  if (!resultEl) return;

  try {
    const config = buildConnectConfig(profile);
    const isWg = getProfileType(profile) === 'wireguard';

    if (isWg) {
      if (!config.peers?.[0]?.endpoint) {
        updatePingEl(resultEl, 'ERR', 'error');
        return;
      }
    } else if (!config.server) {
      updatePingEl(resultEl, 'ERR', 'error');
      return;
    }

    updatePingEl(resultEl, '...', 'loading');
    if (btn) btn.disabled = true;

    let pingMs;
    if (isWg) {
      const { host, port } = parseEndpoint(config.peers[0].endpoint);
      const st = await chrome.storage.local.get(['isConnected', 'socksPort']);
      // WG — UDP. TCP на Endpoint:port всегда timeout, даже когда туннель жив.
      // Активное подключение: RTT через локальный SOCKS. Иначе ICMP до IP пира.
      if (st.isConnected && st.socksPort && id === activeProfileId) {
        pingMs = await measurePing('1.1.1.1', 443, { socksPort: st.socksPort });
      } else {
        pingMs = await measurePing(host, port, { transport: 'icmp' });
      }
    } else {
      pingMs = await measurePing(config.server, config.port);
    }

    let text, status;
    if (pingMs < 0) {
      text = 'timeout';
      status = 'error';
    } else if (pingMs > 3000) {
      text = `${pingMs}ms`;
      status = 'error';
    } else {
      text = `${pingMs}ms`;
      status = 'success';
    }

    updatePingEl(resultEl, text, status);
    if (btn) btn.disabled = false;
  } catch (error) {
    console.error('Ошибка ping:', error);
    updatePingEl(resultEl, 'ERR', 'error');
    if (btn) btn.disabled = false;
  }
}

function updatePingEl(el, text, status) {
  el.classList.remove('loading', 'success', 'error');
  if (status) el.classList.add(status);
  el.textContent = text;
}

// ============================================
// MESSAGES
// ============================================

// Таймер автоскрытия общий на весь блок сообщений: без него setTimeout от
// showSuccess гасил показанную следом ошибку раньше, чем её успевали прочитать.
let messageTimer = null;

function clearMessageTimer() {
  if (messageTimer) {
    clearTimeout(messageTimer);
    messageTimer = null;
  }
}

function makeCloseButton() {
  const btn = document.createElement('button');
  btn.type = 'button';
  btn.className = 'message-close';
  btn.textContent = '×';
  btn.title = 'Закрыть';
  btn.setAttribute('aria-label', 'Закрыть сообщение');
  btn.addEventListener('click', hideError);
  return btn;
}

function renderMessage(cssClass, buildBody) {
  clearMessageTimer();
  const errorEl = document.getElementById('errorMessage');
  errorEl.textContent = '';

  const body = document.createElement('div');
  body.className = 'message-body';
  buildBody(body);

  errorEl.appendChild(body);
  errorEl.appendChild(makeCloseButton());
  errorEl.className = cssClass;
  errorEl.classList.remove('hidden');
  return errorEl;
}

function showError(message) {
  const lowerMsg = message.toLowerCase();
  const isNativeHostIssue = lowerMsg.includes('native host')
    || lowerMsg.includes('таймаут')
    || lowerMsg.includes('native messaging');

  renderMessage('error-message', (body) => {
    if (!isNativeHostIssue) {
      body.textContent = message;
      return;
    }
    const strong = document.createElement('strong');
    strong.textContent = 'Нет связи с Native Host';
    const link = document.createElement('button');
    link.type = 'button';
    link.className = 'error-setup-link';
    link.textContent = 'Открыть настройку';
    link.addEventListener('click', () => {
      chrome.tabs.create({ url: chrome.runtime.getURL('setup.html') });
    });
    body.appendChild(strong);
    body.appendChild(document.createElement('br'));
    body.appendChild(link);
  });
}

function showSuccess(message) {
  const errorEl = renderMessage('success-message', (body) => {
    body.textContent = message;
  });

  messageTimer = setTimeout(() => {
    errorEl.classList.add('hidden');
    messageTimer = null;
  }, 2500);
}

function hideError() {
  clearMessageTimer();
  document.getElementById('errorMessage').classList.add('hidden');
}
