#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
VLESS Chrome Native Messaging Host (Python версия)
Для использования когда Go не установлен
"""

import json
import sys
import struct
import subprocess
import os
import logging
import time
import atexit
from logging.handlers import RotatingFileHandler
from pathlib import Path
import socket

from parsers import normalize_proxy_config, wireguard_ip_strategy
from dpapi_store import protect_secret, unprotect_secret
from host_ping import ping_host

def get_free_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


def port_is_free(port):
    """Свободен ли порт прямо сейчас.

    get_free_port() закрывает сокет до того, как порт займёт xray, поэтому
    между выбором и стартом его может перехватить кто угодно. Полностью окно
    не закрыть, но проверка перед самым запуском делает его сильно уже.
    """
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        try:
            s.bind(('127.0.0.1', port))
            return True
        except OSError:
            return False


# Признаки того, что xray не смог занять порт: перезапуск с новым портом
# имеет смысл, а вот при ошибке в конфиге он бесполезен.
PORT_CONFLICT_MARKERS = (
    'address already in use',
    'only one usage of each socket address',
    'address in use',
)
PORT_RETRIES = 3


def is_port_conflict(log_text):
    lowered = (log_text or '').lower()
    return any(marker in lowered for marker in PORT_CONFLICT_MARKERS)


# Гео-базы едут в архиве Xray, установщик кладёт их рядом с xray.exe.
# Без них правила geoip:/geosite: не работают и xray откажется стартовать.
GEO_FILES = ('geoip.dat', 'geosite.dat')


def geo_databases_present(app_dir=None):
    base = Path(app_dir) if app_dir is not None else APP_DIR
    return all((base / name).exists() for name in GEO_FILES)


# Резолверы для гео-маршрутизации: только DoH, ответы по обычному DNS брать
# нельзя. Последним стоит системный резолвер — если DoH недоступен, поведение
# деградирует до прежнего, а не ломается совсем.
GEO_DNS_SERVERS = (
    "https://1.1.1.1/dns-query",
    "https://8.8.8.8/dns-query",
    "localhost",
)


# Через сколько дней простоя файлы профиля считаются брошенными.
ORPHAN_MAX_AGE_DAYS = 7


def is_xray_pid_alive(pid):
    """Жив ли процесс xray с этим PID (psutil, иначе tasklist)."""
    if psutil:
        try:
            if not psutil.pid_exists(pid):
                return False
            return 'xray' in psutil.Process(pid).name().lower()
        except Exception:
            return False
    if os.name == 'nt':
        try:
            binary = get_xray_binary_name()
            out = subprocess.run(
                ['tasklist', '/FI', f'PID eq {pid}', '/FI', f'IMAGENAME eq {binary}', '/NH'],
                creationflags=subprocess.CREATE_NO_WINDOW,
                capture_output=True, text=True, timeout=5,
            ).stdout
            return binary.lower() in (out or '').lower()
        except Exception:
            return False
    return False


def group_profile_files(app_dir):
    """Файлы рабочего каталога, разложенные по clientId.

    Именование задаётся _init_paths: config_<cid>.json, xray_<cid>.log,
    xray_<cid>.pid. Общие xray.log и native-host.log под шаблон не подходят
    и остаются нетронутыми.
    """
    groups = {}
    for path in Path(app_dir).iterdir():
        if not path.is_file():
            continue
        name = path.name
        cid = None
        if name.startswith('config_') and name.endswith('.json'):
            cid = name[len('config_'):-len('.json')]
        elif name.startswith('xray_') and (name.endswith('.log') or name.endswith('.pid')):
            cid = name[len('xray_'):name.rindex('.')]
        if cid:
            groups.setdefault(cid, []).append(path)
    return groups


def cleanup_orphaned_profiles(current_client_id, app_dir=None,
                              max_age_days=ORPHAN_MAX_AGE_DAYS):
    """Убирает файлы профилей, которыми давно не пользовались.

    Каждый профиль браузера заводит свой clientId, и его файлы остаются
    навсегда: конфиг при остановке затирается в {}, но не удаляется, логи и
    pid тоже. За несколько переустановок расширения каталог зарастает.

    Хост не знает списка валидных clientId — только текущий, поэтому удаляем
    исключительно заведомо ненужное: не текущий профиль, без живого xray и
    не тронутое max_age_days дней. Файлы профиля, которым пользуются,
    обновляются при каждом подключении и под условие не попадут.
    """
    base = Path(app_dir) if app_dir is not None else APP_DIR
    cutoff = time.time() - max_age_days * 86400
    removed = []

    try:
        groups = group_profile_files(base)
    except Exception as e:
        logging.warning(f"Не удалось перечислить файлы профилей: {e}")
        return removed

    for cid, paths in groups.items():
        if cid == current_client_id:
            continue

        pid_file = base / f'xray_{cid}.pid'
        if pid_file.exists():
            try:
                if is_xray_pid_alive(int(pid_file.read_text().strip())):
                    continue  # другой профиль сейчас подключён
            except Exception:
                pass

        try:
            newest = max(p.stat().st_mtime for p in paths)
        except Exception:
            continue
        if newest > cutoff:
            continue

        for p in paths:
            try:
                p.unlink()
                removed.append(p.name)
            except Exception as e:
                logging.warning(f"Не удалось удалить {p.name}: {e}")

    if removed:
        logging.info(f"Убрано осиротевших файлов: {len(removed)}")
    return removed


def ru_direct_rules():
    """Правила «российские адреса — мимо туннеля».

    Имена категорий сверены с реальными базами: geosite:ru не существует,
    правильное имя — geosite:category-ru. geoip:private добавлен, чтобы
    локальная сеть тоже шла напрямую.

    Возвращает свежие словари: общие константы легко испортить мутацией.
    """
    return [
        {"type": "field", "domain": ["geosite:category-ru"], "outboundTag": "direct"},
        {"type": "field", "ip": ["geoip:ru", "geoip:private"], "outboundTag": "direct"},
    ]

try:
    import psutil
except ImportError:
    psutil = None


def app_dir_for(os_name, platform, home, localappdata=None, xdg=None, explicit=None):
    """Куда класть данные приложения на каждой платформе.

    Чистая функция: все внешние данные приходят аргументами, поэтому ветки
    проверяются тестами с любой ОС. Подменять os.name в тестах нельзя —
    по нему pathlib выбирает тип пути и ломается.

    Установочные скрипты обязаны класть файлы ровно сюда же, иначе хост их
    не найдёт.

    explicit (VLESSCHROME_APP_DIR) имеет приоритет над всем остальным: его
    выставляет обёртка native-host.sh/.bat, подставляя каталог, где лежит
    сама. Это единственный надёжный способ в песочнице — Flatpak-браузер
    подменяет XDG_CONFIG_HOME на ~/.var/app/<id>/config, и хост, запущенный
    внутри песочницы, искал xray там, а установщик клал его в ~/.config.
    """
    if explicit:
        return Path(explicit)
    if os_name == 'nt' and localappdata:
        return Path(localappdata) / 'VLESSChrome'
    # macOS: рядом с манифестами native messaging, которые Chrome держит
    # в ~/Library/Application Support. XDG здесь намеренно не смотрим —
    # иначе путь зависел бы от случайно унаследованной переменной, и
    # установочный скрипт разошёлся бы с хостом.
    if platform == 'darwin':
        return Path(home) / 'Library' / 'Application Support' / 'VLESSChrome'
    if xdg:
        return Path(xdg) / 'VLESSChrome'
    return Path(home) / '.config' / 'VLESSChrome'


def get_app_dir():
    """Кросс-платформенная директория данных приложения."""
    return app_dir_for(
        os.name,
        sys.platform,
        Path.home(),
        os.getenv('LOCALAPPDATA'),
        os.getenv('XDG_CONFIG_HOME'),
        os.getenv('VLESSCHROME_APP_DIR'),
    )


def get_xray_binary_name():
    return 'xray.exe' if os.name == 'nt' else 'xray'


MAX_NATIVE_MESSAGE_BYTES = 4 * 1024 * 1024

# Батч-лимит: расширение шлёт по одному секрету на профиль, тысячи профилей
# не бывает. Ограничение защищает от случайного/злонамеренного гигантского пакета.
MAX_SECRET_BATCH = 200


def process_secret_batch(action, items):
    """protectMany/unprotectMany: пакетная обработка секретов.

    Раньше расширение слало по одному сообщению на профиль, а каждое сообщение —
    это отдельный запуск процесса native host. N профилей = N стартов Python при
    каждом открытии popup. Здесь всё делается за один запуск.

    Ошибка на одном элементе не роняет весь пакет: остальные профили должны
    расшифроваться, а сбойный — быть помечен как заблокированный.
    """
    fn = protect_secret if action == 'protectMany' else unprotect_secret
    results = []
    for item in items:
        try:
            results.append({'ok': True, 'data': fn(item if isinstance(item, str) else '')})
        except Exception as e:
            results.append({'ok': False, 'error': str(e)})
    return results


def redact_for_log(obj):
    """Убирает секреты из объекта перед записью в лог."""
    sensitive_keys = {
        'secretkey', 'privatekey', 'presharedkey', 'uuid', 'vlessurl',
        'wgconfig', 'wg_config', 'secret_key', 'password', 'token', 'pbk',
        'text', 'data', 'items'
    }
    if isinstance(obj, dict):
        out = {}
        for k, v in obj.items():
            if k.lower() in sensitive_keys:
                out[k] = '***REDACTED***'
            else:
                out[k] = redact_for_log(v)
        return out
    if isinstance(obj, list):
        return [redact_for_log(i) for i in obj]
    return obj


# Настройка логирования с ротацией (лог не растёт безгранично)
APP_DIR = get_app_dir()
APP_DIR.mkdir(parents=True, exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[RotatingFileHandler(
        str(APP_DIR / 'native-host.log'),
        maxBytes=5 * 1024 * 1024,
        backupCount=3,
        encoding='utf-8'
    )]
)

if psutil is None:
    logging.warning("psutil не установлен, остановка по PID будет через taskkill")


class XrayManager:
    def __init__(self):
        self.process = None
        self.client_id = "default"
        self.port = 10808
        # до первого start() stop() вызывает _remove_pid(); без pid_file — AttributeError
        self.pid_file = APP_DIR / f'xray_{self.client_id}.pid'
        
    def _init_paths(self, client_id):
        self.client_id = client_id
        self.config_path = APP_DIR / f'config_{client_id}.json'
        self.xray_path = APP_DIR / get_xray_binary_name()
        self.pid_file = APP_DIR / f'xray_{client_id}.pid'
        
    def _taskkill_tree(self, pid):
        """Жёсткое снятие процесса и его дерева (Windows). Запасной путь."""
        if os.name != 'nt':
            return False
        try:
            subprocess.run(
                ['taskkill', '/PID', str(pid), '/T', '/F'],
                creationflags=subprocess.CREATE_NO_WINDOW,
                capture_output=True, timeout=10
            )
            return True
        except Exception as e:
            logging.error(f"taskkill не сработал для PID {pid}: {e}")
            return False

    def _stop_pid(self, pid):
        """Остановка процесса xray по PID (psutil + taskkill-фолбэк)."""
        if not psutil:
            return self._taskkill_tree(pid)
        try:
            if not psutil.pid_exists(pid):
                return False
            proc = psutil.Process(pid)
            if 'xray' not in proc.name().lower():
                return False
            logging.info(f"Остановка Xray (PID: {pid})")
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except psutil.TimeoutExpired:
                proc.kill()
            return True
        except Exception as e:
            logging.error(f"Ошибка остановки процесса по PID {pid}: {e}")
            return self._taskkill_tree(pid)

    def _check_existing_process(self):
        """Остановка осиротевшего Xray из прошлой сессии — ТОЛЬКО по PID-файлу.

        Полный обход процессов ОС (process_iter с cmdline) убран намеренно:
        на терминальном сервере он занимал 10+ секунд и провоцировал таймаут
        в расширении (гонка start/stop, обрыв подключения). PID-файла достаточно.
        """
        try:
            if self.pid_file.exists():
                try:
                    pid = int(self.pid_file.read_text().strip())
                    if self._stop_pid(pid):
                        logging.info("Процесс остановлен по PID файлу")
                except Exception as e:
                    logging.error(f"Ошибка чтения PID файла: {e}")
                finally:
                    self.pid_file.unlink(missing_ok=True)
        except Exception as e:
            logging.error(f"Ошибка проверки существующих процессов: {e}")

    def _wait_port_ready(self, port, timeout=3.0):
        """Ждём, пока Xray реально начнёт слушать SOCKS-порт (а не просто 'процесс жив')."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.process and self.process.poll() is not None:
                return False
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                s.settimeout(0.5)
                if s.connect_ex(('127.0.0.1', port)) == 0:
                    return True
            time.sleep(0.15)
        return False

    def _validate_config(self, config):
        """Проверка обязательных полей. Возвращает текст ошибки или None."""
        protocol = (config.get('protocol') or 'vless').lower()
        if protocol == 'wireguard':
            if not config.get('secretKey'):
                return "В WireGuard конфиге нет PrivateKey"
            peers = config.get('peers') or []
            if not peers:
                return "В WireGuard конфиге нет [Peer]"
            peer = peers[0]
            if not peer.get('publicKey'):
                return "В WireGuard конфиге нет PublicKey"
            if not peer.get('endpoint'):
                return "В WireGuard конфиге нет Endpoint"
            return None

        if not config.get('uuid'):
            return "В конфиге нет UUID (проверьте VLESS URL)"
        if not config.get('server'):
            return "В конфиге нет адреса сервера (проверьте VLESS URL)"
        try:
            p = int(config.get('port', 0))
            if not (0 < p < 65536):
                return f"Некорректный порт сервера: {config.get('port')}"
        except (TypeError, ValueError):
            return f"Некорректный порт сервера: {config.get('port')}"
        if (config.get('security') or '').lower() == 'reality' and not config.get('pbk'):
            return "В конфиге нет publicKey (pbk) для Reality (проверьте VLESS URL)"
        return None
    
    def _save_pid(self):
        """Сохранение PID процесса"""
        if self.process:
            with open(self.pid_file, 'w') as f:
                f.write(str(self.process.pid))
    
    def _remove_pid(self):
        """Удаление PID файла"""
        self.pid_file.unlink(missing_ok=True)

    def _wipe_config_file(self):
        """После остановки Xray не оставляем plaintext ключи на диске."""
        path = getattr(self, 'config_path', None)
        if not path:
            return
        try:
            if path.exists():
                path.write_text('{}\n', encoding='utf-8')
        except Exception as e:
            logging.warning(f"Не удалось очистить конфиг {path}: {e}")

    def _atexit_cleanup(self):
        """Останавливаем Xray и чистим PID ТОЛЬКО если этот процесс сам его запускал.

        Критично: ping/status/stop прилетают в отдельных короткоживущих процессах
        native host (self.process is None, свой Xray они не запускали). Раньше они
        на выходе БЕЗУСЛОВНО стирали PID-файл → следующий status видел 'stopped',
        и расширение обрывало ЖИВОЕ соединение. Теперь одноразовые процессы
        PID-файл не трогают.
        """
        if self.process and self.process.poll() is None:
            try:
                logging.info("atexit: останавливаем Xray")
                self.process.terminate()
                self.process.wait(timeout=3)
            except Exception as e:
                logging.warning(f"atexit terminate: {e}")
                try:
                    self.process.kill()
                except Exception:
                    pass
            self.process = None
            try:
                self._remove_pid()
            except Exception:
                pass
    
    def start(self, vless_url, config, client_id="default"):
        """Запуск Xray с конфигом"""
        self._init_paths(client_id)

        # Уборка брошенных профилей — побочная задача, подключение из-за неё
        # не должно падать ни при каких обстоятельствах.
        try:
            cleanup_orphaned_profiles(client_id)
        except Exception as e:
            logging.warning(f"Уборка старых профилей пропущена: {e}")

        try:
            config = normalize_proxy_config(config or {})
        except ValueError as e:
            logging.error(f"Ошибка разбора конфига: {e}")
            return False, str(e), None

        # Валидация до любых действий
        err = self._validate_config(config)
        if err:
            logging.error(f"Валидация конфига не пройдена: {err}")
            return False, err, None

        if self.process and self.process.poll() is None:
            logging.info("Перезапуск: останавливаем текущий Xray")
            ok, msg = self.stop()
            if not ok:
                return False, msg, None
        self._check_existing_process()

        # Проверка наличия xray.exe
        if not self.xray_path.exists():
            return False, f"{self.xray_path.name} не найден: {self.xray_path}", None

        # Порт мог перехватить чужой процесс между выбором и стартом xray —
        # тогда пробуем ещё раз с новым портом.
        last_error = None
        for attempt in range(1, PORT_RETRIES + 1):
            self.port = get_free_port()
            ok, error_msg, conflict = self._start_attempt(config)
            if ok:
                return True, "Xray запущен", self.port
            last_error = error_msg
            if not conflict:
                break
            logging.warning(
                f"Порт {self.port} занят (попытка {attempt}/{PORT_RETRIES}), пробуем другой"
            )
        return False, last_error, None

    def _start_attempt(self, config):
        """Одна попытка запуска на self.port.

        Возвращает (успех, текст_ошибки, это_конфликт_порта).
        """
        # Генерация конфига
        xray_config = self._generate_config(config)

        # Сохранение конфига
        with open(self.config_path, 'w', encoding='utf-8') as f:
            json.dump(xray_config, f, indent=2, ensure_ascii=False)

        logging.info(f"Конфиг сохранен: {self.config_path}")

        if not port_is_free(self.port):
            return False, f"Порт {self.port} занят", True

        # Запуск Xray
        # xray-лог пересоздаём на каждый старт (не растёт, видно только текущий запуск)
        log_path = APP_DIR / f'xray_{self.client_id}.log'
        log_file = None
        try:
            log_file = open(log_path, 'w', encoding='utf-8')
            self.process = subprocess.Popen(
                [str(self.xray_path), '-config', str(self.config_path)],
                stdout=log_file,
                stderr=subprocess.STDOUT,
                cwd=str(APP_DIR),
                creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0
            )
            log_file = None  # Popen владеет дескриптором
            
            # Сохраняем PID для отслеживания между сессиями
            self._save_pid()
            
            # Health-check: ждём, что Xray не упал И реально слушает SOCKS-порт.
            # Иначе расширение выставит прокси в пустоту.
            if not self._wait_port_ready(self.port, timeout=3.0):
                exit_code = self.process.poll()
                xray_log = ""
                try:
                    with open(log_path, 'r', encoding='utf-8') as lf:
                        xray_log = lf.read()[-500:]
                except Exception:
                    pass
                try:
                    if self.process.poll() is None:
                        self.process.terminate()
                        self.process.wait(timeout=5)
                except Exception:
                    try:
                        self.process.kill()
                    except Exception:
                        pass
                self.process = None
                self._remove_pid()
                error_msg = f"Xray не слушает порт {self.port} (код {exit_code})"
                if xray_log:
                    error_msg += f": {xray_log.strip()}"
                logging.error(error_msg)
                return False, error_msg, is_port_conflict(xray_log)

            logging.info(f"Xray запущен (PID: {self.process.pid}) на порту {self.port}")
            return True, None, False

        except Exception as e:
            if log_file is not None:
                try:
                    log_file.close()
                except Exception:
                    pass
            logging.error(f"Ошибка запуска Xray: {e}")
            return False, str(e), False

    def stop(self, client_id=None):
        """Остановка Xray. client_id — для убийства зомби из другого процесса native host."""
        cid = client_id if client_id else None
        if isinstance(cid, str) and not cid.strip():
            cid = None
        if cid:
            self._init_paths(cid)

        if self.process and self.process.poll() is None:
            try:
                logging.info(f"Остановка Xray (PID: {self.process.pid})")
                self.process.terminate()
                self.process.wait(timeout=5)
                self.process = None
                self._remove_pid()
                self._wipe_config_file()
                return True, "Xray остановлен"
            except Exception as e:
                try:
                    self.process.kill()
                except Exception:
                    pass
                self.process = None
                self._remove_pid()
                self._wipe_config_file()
                logging.error(f"Ошибка остановки Xray: {e}")
                return False, str(e)

        self._check_existing_process()
        self.process = None
        self._wipe_config_file()
        return True, "Xray не запущен (очистка выполнена)"
    
    def is_running(self):
        """Проверка статуса (по своему процессу и по PID-файлу профиля)"""
        if self.process and self.process.poll() is None:
            return True, "running"

        # Осиротевший Xray (SW был убит, python вышел, xray жив) — по PID-файлу
        try:
            if self.pid_file.exists():
                pid = int(self.pid_file.read_text().strip())
                if psutil:
                    if psutil.pid_exists(pid):
                        try:
                            if 'xray' in psutil.Process(pid).name().lower():
                                return True, "running"
                        except Exception:
                            pass
                elif os.name == 'nt':
                    out = subprocess.run(
                        ['tasklist', '/FI', f'PID eq {pid}', '/FI', 'IMAGENAME eq xray.exe', '/NH'],
                        creationflags=subprocess.CREATE_NO_WINDOW,
                        capture_output=True, text=True, timeout=5
                    ).stdout
                    if 'xray.exe' in out.lower():
                        return True, "running"
        except Exception as e:
            logging.error(f"Ошибка проверки статуса по PID: {e}")
        return False, "stopped"
    
    def _socks_inbound(self):
        return {
            "port": self.port,
            "protocol": "socks",
            "settings": {
                "auth": "noauth",
                "udp": True
            },
            "sniffing": {
                "enabled": True,
                "destOverride": ["http", "tls", "quic"],
                "routeOnly": True
            }
        }

    def _generate_config(self, config):
        """Генерация конфига Xray"""
        protocol = (config.get('protocol') or 'vless').lower()
        if protocol == 'wireguard':
            xray_config = self._generate_wireguard_config(config)
        else:
            xray_config = self._generate_vless_config(config)

        if config.get('routeRuDirect'):
            self._apply_ru_direct(xray_config)
        return xray_config

    def _apply_ru_direct(self, xray_config):
        """Добавляет direct-outbound и правила «российское — напрямую».

        Дописывается поверх готового конфига, а не встраивается в генераторы:
        у WireGuard уже есть свой routing (блокировка IPv6), и его правила
        нужно сохранить, а не затереть.
        """
        if not geo_databases_present():
            # Молча игнорируем опцию вместо падения: терять соединение
            # из-за необязательной настройки хуже, чем не применить её.
            logging.warning(
                f"Гео-маршрутизация запрошена, но {' и '.join(GEO_FILES)} "
                f"не найдены в {APP_DIR} — правило пропущено. Переустановите хост."
            )
            return

        xray_config.setdefault("outbounds", []).append({
            "tag": "direct",
            "protocol": "freedom"
        })

        routing = xray_config.setdefault("routing", {})
        routing.setdefault("rules", []).extend(ru_direct_rules())
        # Без IPIfNonMatch правила geoip: не применятся к доменным адресам:
        # xray сверяет их только после разрешения имени в IP.
        routing["domainStrategy"] = "IPIfNonMatch"

        # Раз маршрут выбирается по разрешённому адресу, ответ DNS обязан быть
        # честным. Системный резолвер для заблокированных сайтов отдаёт
        # подменённый российский адрес-заглушку (rutracker.org и nnmclub.to
        # приходили с одного и того же 77.94.164.71), правило geoip:ru уводило
        # их напрямую — то есть прямиком в блокировку. Через DoH возвращаются
        # настоящие адреса, и такие сайты уходят в туннель.
        dns = xray_config.setdefault("dns", {})
        # Свои серверы WireGuard-конфига сохраняем запасным вариантом.
        existing = [s for s in (dns.get("servers") or []) if s not in GEO_DNS_SERVERS]
        dns["servers"] = list(GEO_DNS_SERVERS) + existing
        dns.setdefault("queryStrategy", "UseIPv4")

    def _generate_wireguard_config(self, config):
        """Генерация Xray конфига с WireGuard outbound."""
        strategy = wireguard_ip_strategy(config)
        wg_settings = {
            "secretKey": config['secretKey'],
            "peers": config['peers'],
            "domainStrategy": strategy['domainStrategy'],
        }
        if config.get('address'):
            wg_settings["address"] = config['address']
        mtu = config.get('mtu')
        if mtu:
            wg_settings["mtu"] = int(mtu)

        dns_servers = [s for s in (config.get('dns') or []) if s]
        if not dns_servers:
            dns_servers = ['1.1.1.1', '8.8.8.8']

        outbounds = [{
            "tag": "wg",
            "protocol": "wireguard",
            "settings": wg_settings
        }]
        routing_rules = []
        if strategy['blockIPv6']:
            outbounds.append({"tag": "block", "protocol": "blackhole"})
            routing_rules.append({
                "type": "field",
                "ip": ["::/0"],
                "outboundTag": "block"
            })

        xray_config = {
            "log": {"loglevel": "warning"},
            "dns": {
                "servers": dns_servers,
                "queryStrategy": strategy['queryStrategy']
            },
            "inbounds": [self._socks_inbound()],
            "outbounds": outbounds
        }
        if routing_rules:
            xray_config["routing"] = {
                "domainStrategy": "AsIs",
                "rules": routing_rules
            }
        return xray_config

    def _generate_vless_config(self, config):
        """Генерация Xray конфига с VLESS outbound."""
        uuid = config.get('uuid', '')
        server = config.get('server', '')
        port = int(config.get('port', 443))
        encryption = config.get('encryption', 'none')
        security = config.get('security', 'tls')
        network_type = config.get('type', 'tcp')
        host = config.get('host', server)
        path = config.get('path', '/')
        sni = config.get('sni', server)
        alpn = config.get('alpn', '')
        fingerprint = config.get('fingerprint', 'chrome')
        flow = config.get('flow', '')  # Flow для XTLS
        # Reality параметры
        pbk = config.get('pbk', '')
        sid = config.get('sid', '')
        spx = config.get('spx', '')
        
        xray_config = {
            "log": {
                "loglevel": "warning"
            },
            "inbounds": [self._socks_inbound()],
            "outbounds": [{
                # Первый outbound — маршрут по умолчанию; тег нужен, чтобы
                # правила маршрутизации читались однозначно.
                "tag": "proxy",
                "protocol": "vless",
                "settings": {
                    "vnext": [{
                        "address": server,
                        "port": port,
                        "users": [{
                            **{"id": uuid, "encryption": encryption},
                            **({"flow": flow} if flow else {})
                        }]
                    }]
                },
                "streamSettings": self._build_stream_settings(
                    security, network_type, host, path, sni, alpn, fingerprint, pbk, sid, spx
                )
            }]
        }
        
        return xray_config
    
    def _build_stream_settings(self, security, network_type, host, path, sni, alpn, fingerprint, pbk='', sid='', spx=''):
        """Построение streamSettings"""
        stream_settings = {
            "network": network_type
        }
        
        # TLS настройки
        if security == "tls":
            tls_settings = {
                "serverName": sni,
                "fingerprint": fingerprint
            }
            
            if alpn:
                tls_settings["alpn"] = [a.strip() for a in alpn.split(',') if a.strip()]
            else:
                tls_settings["alpn"] = ["h2", "http/1.1"]
            
            stream_settings["security"] = "tls"
            stream_settings["tlsSettings"] = tls_settings
        
        # Reality настройки
        elif security == "reality":
            reality_settings = {
                "serverName": sni,
                "fingerprint": fingerprint,
                "show": False
            }
            
            # publicKey (обязательный для Reality)
            if pbk:
                reality_settings["publicKey"] = pbk
            
            # shortId (опциональный)
            if sid:
                reality_settings["shortId"] = sid
            
            # spiderX (опциональный)
            if spx:
                reality_settings["spiderX"] = spx
            
            stream_settings["security"] = "reality"
            stream_settings["realitySettings"] = reality_settings
        
        # Транспорт
        if network_type == "ws":
            ws_settings = {}
            if path:
                ws_settings["path"] = path
            if host:
                ws_settings["headers"] = {"Host": host}
            stream_settings["wsSettings"] = ws_settings
            
        elif network_type == "grpc":
            grpc_settings = {}
            if path:
                grpc_settings["serviceName"] = path
            stream_settings["grpcSettings"] = grpc_settings
            
        elif network_type == "h2":
            http_settings = {}
            if path:
                http_settings["path"] = path
            if host:
                http_settings["host"] = [host]
            stream_settings["httpSettings"] = http_settings
        
        return stream_settings


# Native Messaging Protocol
def read_exactly(stream, n):
    """Читает ровно n байт (или меньше, если канал закрылся).

    Пайп не обязан отдавать всё запрошенное за один read(): длинный конфиг
    WireGuard легко приходит несколькими порциями. Одиночный read() в этом
    случае возвращал обрезанный JSON, main() ловил исключение и убивал хост
    посреди сессии.
    """
    chunks = []
    remaining = n
    while remaining > 0:
        chunk = stream.read(remaining)
        if not chunk:  # EOF
            break
        chunks.append(chunk)
        remaining -= len(chunk)
    return b''.join(chunks)


def read_message():
    """Чтение сообщения из stdin"""
    raw_length = read_exactly(sys.stdin.buffer, 4)
    if len(raw_length) == 0:
        sys.exit(0)  # канал закрыт штатно — расширение отключилось
    if len(raw_length) < 4:
        raise ValueError(
            f'Обрыв канала: заголовок {len(raw_length)} из 4 байт'
        )

    message_length = struct.unpack('=I', raw_length)[0]
    if message_length == 0:
        raise ValueError('Пустое сообщение (нулевая длина)')
    if message_length > MAX_NATIVE_MESSAGE_BYTES:
        raise ValueError(
            f'Native message too large: {message_length} bytes '
            f'(max {MAX_NATIVE_MESSAGE_BYTES})'
        )

    body = read_exactly(sys.stdin.buffer, message_length)
    if len(body) < message_length:
        raise ValueError(
            f'Обрыв канала: тело {len(body)} из {message_length} байт'
        )
    return json.loads(body.decode('utf-8'))


def send_message(message):
    """Отправка сообщения в stdout"""
    encoded_message = json.dumps(message).encode('utf-8')
    encoded_length = struct.pack('=I', len(encoded_message))
    
    sys.stdout.buffer.write(encoded_length)
    sys.stdout.buffer.write(encoded_message)
    sys.stdout.buffer.flush()


def main():
    logging.info("Native host Python запущен")
    
    xray_manager = XrayManager()
    atexit.register(xray_manager._atexit_cleanup)
    
    try:
        while True:
            # Чтение сообщения
            message = read_message()
            logging.info(f"Получено сообщение: {redact_for_log(message)}")
            
            message_id = message.get('id', 0)
            action = message.get('action', '')
            
            response = {
                'id': message_id,
                'success': False
            }
            
            # Обработка команд
            if action == 'start':
                vless_url = message.get('vlessUrl', '')
                config = message.get('config', {})
                client_id = message.get('clientId', 'default')
                
                success, msg, port = xray_manager.start(vless_url, config, client_id)
                response['success'] = success
                if success:
                    response['port'] = port
                if not success:
                    response['error'] = msg
                logging.info(f"Start: {msg} (port: {port})")
                
            elif action == 'stop':
                cid = message.get('clientId')
                success, msg = xray_manager.stop(client_id=cid)
                response['success'] = success
                if not success:
                    response['error'] = msg
                logging.info(f"Stop: {msg}")
            
            elif action == 'ping':
                host = message.get('host') or message.get('server')
                port = int(message.get('port', 443) or 443)
                transport = message.get('transport') or 'tcp'
                socks_port = message.get('socksPort') or message.get('socks_port')
                if socks_port:
                    try:
                        socks_port = int(socks_port)
                    except (TypeError, ValueError):
                        socks_port = None
                if not host:
                    response['error'] = 'Не указан host'
                    logging.warning("Ping: нет host")
                else:
                    try:
                        timeout = float(message.get('timeout') or 5)
                        if timeout <= 0 or timeout > 15:
                            timeout = 5
                        ms = ping_host(
                            host,
                            port=port,
                            transport=transport,
                            socks_port=socks_port,
                            timeout=timeout,
                        )
                        response['success'] = True
                        response['pingMs'] = ms
                        logging.info(
                            f"Ping {transport} {host}:{port} socks={socks_port} -> {ms}ms"
                        )
                    except Exception as e:
                        response['error'] = str(e)
                        logging.info(f"Ping {host}:{port} fail: {e}")
                
            elif action == 'protect':
                try:
                    response['success'] = True
                    response['data'] = protect_secret(message.get('text') or '')
                except Exception as e:
                    response['error'] = str(e)
                    logging.error(f"protect: {e}")

            elif action == 'unprotect':
                try:
                    response['success'] = True
                    response['data'] = unprotect_secret(message.get('text') or '')
                except Exception as e:
                    response['error'] = str(e)
                    logging.error(f"unprotect: {e}")

            elif action in ('protectMany', 'unprotectMany'):
                items = message.get('items')
                if not isinstance(items, list):
                    response['error'] = 'items должен быть списком'
                    logging.warning(f"{action}: items не список")
                elif len(items) > MAX_SECRET_BATCH:
                    response['error'] = f'Слишком много элементов (максимум {MAX_SECRET_BATCH})'
                    logging.warning(f"{action}: {len(items)} элементов, лимит {MAX_SECRET_BATCH}")
                else:
                    results = process_secret_batch(action, items)
                    response['success'] = True
                    response['results'] = results
                    failed = sum(1 for r in results if not r['ok'])
                    logging.info(f"{action}: {len(results)} шт., ошибок {failed}")

            elif action == 'status':
                cid = message.get('clientId')
                if cid:
                    xray_manager._init_paths(cid)
                is_running, status = xray_manager.is_running()
                response['success'] = True
                response['data'] = status
                logging.info(f"Status: {status}")
                
            else:
                response['error'] = f"Неизвестная команда: {action}"
                logging.warning(f"Неизвестная команда: {action}")
            
            # Отправка ответа
            send_message(response)
            
    except Exception as e:
        logging.error(f"Ошибка: {e}", exc_info=True)
        sys.exit(1)


if __name__ == '__main__':
    main()
