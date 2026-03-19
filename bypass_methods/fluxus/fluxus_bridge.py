# integration/fluxus_bridge.py
import subprocess
import time
import os
import random
from pathlib import Path

class FluxusInjector:
    """
    Мост для управления Fluxus Executor из Python
    """
    
    def __init__(self, fluxus_path="C:/FluxusExecutor/FluxusBootstrap.exe"):
        self.fluxus_path = fluxus_path
        self.injection_delay = random.uniform(2, 5)
        self.roblox_processes = []
        
    def launch_roblox_with_account(self, login, password, proxy=None):
        """
        Запуск Roblox с нужным аккаунтом
        """
        # Опция 1: Через cookie (если есть)
        # Опция 2: Через авто-логин с сохраненными данными
        
        # Для теста используем прямой запуск
        roblox_cmd = f"start roblox://placeID=4329801634"  # ID игры Sonaria
        
        if proxy:
            # Настройка прокси для Roblox (сложно, требует системных настроек)
            self.set_system_proxy(proxy)
        
        subprocess.run(roblox_cmd, shell=True)
        time.sleep(10)  # Ждем загрузку
        
    def inject_fluxus(self):
        """
        Запуск Fluxus и внедрение в Roblox
        """
        # Запускаем Fluxus от админа
        fluxus_process = subprocess.Popen(
            [self.fluxus_path],
            shell=True,
            creationflags=subprocess.CREATE_NO_WINDOW
        )
        
        time.sleep(self.injection_delay)
        
        # Нажимаем кнопку Inject (через автоматизацию)
        self.click_inject_button()
        
        return fluxus_process
    
    def click_inject_button(self):
        """
        Клик по кнопке Inject в окне Fluxus
        """
        import pygetwindow as gw
        import pyautogui
        
        # Ищем окно Fluxus
        fluxus_windows = gw.getWindowsWithTitle('Fluxus')
        if fluxus_windows:
            win = fluxus_windows[0]
            win.activate()
            time.sleep(0.5)
            
            # Кликаем на кнопку Inject (координаты под ваше разрешение)
            inject_x = win.left + 100
            inject_y = win.top + 200
            pyautogui.click(inject_x, inject_y)
            time.sleep(2)
    
    def execute_sonaria_script(self, script_content):
        """
        Отправка Lua-скрипта в Fluxus
        """
        # Fluxus имеет окно ввода, куда можно вставить скрипт
        # Через буфер обмена + Ctrl+V
        
        import pyperclip
        import pyautogui
        
        pyperclip.copy(script_content)
        
        # Активируем окно Fluxus
        # Кликаем в поле ввода
        pyautogui.hotkey('ctrl', 'a')  # Выделить всё
        pyautogui.hotkey('ctrl', 'v')  # Вставить
        time.sleep(0.5)
        
        # Нажимаем Execute
        pyautogui.press('f6')  # Часто хоткей для Execute
        time.sleep(1)