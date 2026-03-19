# utils/proxy_manager.py
import os
import random
import asyncio
from typing import List, Dict, Optional, Tuple
from datetime import datetime, timedelta
import json

class ProxyManager:
    """
    Менеджер прокси для ротации IP-адресов
    Распределяет прокси между ботами и отслеживает их работоспособность
    """
    
    def __init__(self, proxy_file: str = None):
        """
        Инициализация менеджера прокси
        
        Args:
            proxy_file: путь к файлу с прокси
        """
        self.proxies = []  # Список всех прокси
        self.available_proxies = []  # Доступные прокси
        self.used_proxies = {}  # {proxy: worker_id}
        self.failed_proxies = {}  # {proxy: fail_count, last_fail}
        
        self.proxy_stats = {
            'total': 0,
            'in_use': 0,
            'failed': 0,
            'working': 0
        }
        
        if proxy_file and os.path.exists(proxy_file):
            self.load_proxies(proxy_file)
    
    def load_proxies(self, filepath: str):
        """
        Загрузка прокси из файла
        
        Формат файла (каждая строка):
        - ip:port
        - ip:port:login:password
        - socks5://ip:port
        - http://ip:port
        
        Args:
            filepath: путь к файлу
        """
        try:
            with open(filepath, 'r', encoding='utf-8') as f:
                lines = f.readlines()
            
            for line in lines:
                line = line.strip()
                if line and not line.startswith('#'):
                    proxy = self.parse_proxy_string(line)
                    if proxy:
                        self.proxies.append(proxy)
                        self.available_proxies.append(proxy)
            
            self.proxy_stats['total'] = len(self.proxies)
            print(f"[ProxyManager] Загружено {len(self.proxies)} прокси из {filepath}")
            
        except Exception as e:
            print(f"[ProxyManager] Ошибка загрузки прокси: {e}")
    
    def parse_proxy_string(self, proxy_string: str) -> Optional[Dict]:
        """
        Парсинг строки прокси
        
        Args:
            proxy_string: строка вида "ip:port" или "ip:port:login:pass"
            
        Returns:
            Словарь с параметрами прокси или None
        """
        try:
            # Убираем протокол если есть
            proxy_string = proxy_string.replace('http://', '').replace('https://', '').replace('socks5://', '')
            
            parts = proxy_string.split(':')
            
            proxy = {
                'original': proxy_string,
                'ip': parts[0],
                'port': int(parts[1]) if len(parts) > 1 else None,
                'type': 'http',  # по умолчанию
                'login': None,
                'password': None,
                'fail_count': 0,
                'last_used': None,
                'response_time': None
            }
            
            # Определяем тип прокси
            if proxy_string.startswith('socks5'):
                proxy['type'] = 'socks5'
            elif proxy_string.startswith('socks4'):
                proxy['type'] = 'socks4'
            
            # Есть логин и пароль
            if len(parts) >= 4:
                proxy['login'] = parts[2]
                proxy['password'] = parts[3]
            elif len(parts) == 3 and '@' in parts[2]:
                # Формат login:password@ip:port
                auth, host = parts[2].split('@')
                proxy['login'], proxy['password'] = auth.split(':')
                proxy['ip'] = host
            
            return proxy
            
        except Exception as e:
            print(f"[ProxyManager] Ошибка парсинга {proxy_string}: {e}")
            return None
    
    def get_proxy_for_worker(self, worker_id: int) -> Optional[Dict]:
        """
        Получение прокси для воркера
        
        Args:
            worker_id: ID воркера
            
        Returns:
            Словарь с прокси или None
        """
        # Сначала проверяем, нет ли уже прокси для этого воркера
        for proxy, w_id in self.used_proxies.items():
            if w_id == worker_id:
                return proxy
        
        # Если нет, выдаем новый из доступных
        if not self.available_proxies:
            # Пробуем восстановить упавшие прокси
            self.recover_failed_proxies()
            
            if not self.available_proxies:
                print(f"[ProxyManager] Нет доступных прокси для воркера {worker_id}")
                return None
        
        # Берем случайный прокси из доступных
        proxy = random.choice(self.available_proxies)
        self.available_proxies.remove(proxy)
        self.used_proxies[worker_id] = proxy
        
        proxy['last_used'] = datetime.now()
        self.proxy_stats['in_use'] = len(self.used_proxies)
        
        print(f"[ProxyManager] Выдан прокси {proxy['ip']}:{proxy['port']} воркеру {worker_id}")
        
        return proxy
    
    def release_proxy(self, worker_id: int):
        """
        Освобождение прокси (воркер закончил работу)
        
        Args:
            worker_id: ID воркера
        """
        to_remove = None
        
        for w_id, proxy in self.used_proxies.items():
            if w_id == worker_id:
                to_remove = w_id
                # Возвращаем в доступные
                self.available_proxies.append(proxy)
                print(f"[ProxyManager] Прокси {proxy['ip']} освобожден от воркера {worker_id}")
                break
        
        if to_remove:
            del self.used_proxies[to_remove]
            self.proxy_stats['in_use'] = len(self.used_proxies)
    
    def mark_proxy_failed(self, proxy: Dict, worker_id: int):
        """
        Отметить прокси как нерабочий
        
        Args:
            proxy: словарь прокси
            worker_id: ID воркера
        """
        # Увеличиваем счетчик ошибок
        proxy['fail_count'] = proxy.get('fail_count', 0) + 1
        
        # Добавляем в список упавших
        self.failed_proxies[worker_id] = {
            'proxy': proxy,
            'fail_time': datetime.now(),
            'fail_count': proxy['fail_count']
        }
        
        # Удаляем из используемых
        if worker_id in self.used_proxies:
            del self.used_proxies[worker_id]
        
        # Удаляем из доступных если был там
        if proxy in self.available_proxies:
            self.available_proxies.remove(proxy)
        
        self.proxy_stats['failed'] = len(self.failed_proxies)
        self.proxy_stats['in_use'] = len(self.used_proxies)
        
        print(f"[ProxyManager] Прокси {proxy['ip']} отмечен как упавший (ошибок: {proxy['fail_count']})")
    
    def recover_failed_proxies(self, max_fail_count: int = 3, cooldown_minutes: int = 30):
        """
        Восстановление упавших прокси после таймаута
        
        Args:
            max_fail_count: максимальное количество ошибок для восстановления
            cooldown_minutes: время ожидания перед восстановлением
        """
        now = datetime.now()
        recovered = []
        
        for worker_id, data in list(self.failed_proxies.items()):
            proxy = data['proxy']
            fail_time = data['fail_time']
            
            # Если прошло достаточно времени
            if now - fail_time > timedelta(minutes=cooldown_minutes):
                # Если не слишком много ошибок
                if proxy['fail_count'] < max_fail_count:
                    self.available_proxies.append(proxy)
                    recovered.append(proxy['ip'])
                    del self.failed_proxies[worker_id]
        
        if recovered:
            print(f"[ProxyManager] Восстановлено {len(recovered)} прокси: {', '.join(recovered)}")
            
            self.proxy_stats['failed'] = len(self.failed_proxies)
            self.proxy_stats['working'] = len(self.available_proxies)
    
    def test_proxy(self, proxy: Dict, timeout: int = 5) -> bool:
        """
        Тестирование работоспособности прокси
        
        Args:
            proxy: словарь прокси
            timeout: таймаут в секундах
            
        Returns:
            True если прокси работает
        """
        import requests
        from requests.auth import HTTPProxyAuth
        
        try:
            # Настраиваем прокси для requests
            proxies = {
                'http': f"{proxy['type']}://{proxy['ip']}:{proxy['port']}",
                'https': f"{proxy['type']}://{proxy['ip']}:{proxy['port']}"
            }
            
            auth = None
            if proxy.get('login') and proxy.get('password'):
                auth = HTTPProxyAuth(proxy['login'], proxy['password'])
            
            # Тестируем на быстром сайте
            start_time = datetime.now()
            response = requests.get(
                'http://httpbin.org/ip',
                proxies=proxies,
                auth=auth,
                timeout=timeout
            )
            end_time = datetime.now()
            
            if response.status_code == 200:
                response_time = (end_time - start_time).total_seconds()
                proxy['response_time'] = response_time
                return True
            
        except Exception as e:
            print(f"[ProxyManager] Прокси {proxy['ip']} не работает: {e}")
        
        return False
    
    async def test_proxy_async(self, proxy: Dict, timeout: int = 5) -> bool:
        """
        Асинхронное тестирование прокси
        
        Args:
            proxy: словарь прокси
            timeout: таймаут в секундах
            
        Returns:
            True если прокси работает
        """
        loop = asyncio.get_event_loop()
        return await loop.run_in_executor(None, self.test_proxy, proxy, timeout)
    
    def get_proxy_string(self, proxy: Dict) -> str:
        """
        Получение строки прокси для использования в requests
        
        Args:
            proxy: словарь прокси
            
        Returns:
            Строка для использования в proxies
        """
        auth = ""
        if proxy.get('login') and proxy.get('password'):
            auth = f"{proxy['login']}:{proxy['password']}@"
        
        return f"{proxy['type']}://{auth}{proxy['ip']}:{proxy['port']}"
    
    def get_proxy_for_roblox(self, proxy: Dict) -> Dict:
        """
        Получение настроек прокси для Roblox (через систему)
        
        Args:
            proxy: словарь прокси
            
        Returns:
            Настройки для установки системного прокси
        """
        settings = {
            'ip': proxy['ip'],
            'port': proxy['port'],
            'type': proxy['type']
        }
        
        if proxy.get('login') and proxy.get('password'):
            settings['login'] = proxy['login']
            settings['password'] = proxy['password']
        
        return settings
    
    def get_statistics(self) -> Dict:
        """
        Получение статистики прокси
        
        Returns:
            Словарь со статистикой
        """
        self.proxy_stats.update({
            'total': len(self.proxies),
            'in_use': len(self.used_proxies),
            'failed': len(self.failed_proxies),
            'available': len(self.available_proxies),
            'working': len(self.available_proxies)  # Доступные считаем рабочими
        })
        
        return self.proxy_stats.copy()
    
    def save_proxy_stats(self, filepath: str = "logs/proxy_stats.json"):
        """
        Сохранение статистики в файл
        
        Args:
            filepath: путь для сохранения
        """
        stats = {
            'timestamp': datetime.now().isoformat(),
            'statistics': self.get_statistics(),
            'proxies': self.proxies,
            'failed': [
                {
                    'proxy': data['proxy'],
                    'fail_time': data['fail_time'].isoformat(),
                    'fail_count': data['fail_count']
                }
                for data in self.failed_proxies.values()
            ]
        }
        
        os.makedirs(os.path.dirname(filepath), exist_ok=True)
        
        with open(filepath, 'w', encoding='utf-8') as f:
            json.dump(stats, f, indent=2, ensure_ascii=False)
    
    def rotate_all_proxies(self):
        """
        Принудительная ротация всех прокси
        """
        # Освобождаем все используемые прокси
        for worker_id in list(self.used_proxies.keys()):
            self.release_proxy(worker_id)
        
        # Перемешиваем доступные
        random.shuffle(self.available_proxies)
        
        print(f"[ProxyManager] Выполнена ротация всех прокси")