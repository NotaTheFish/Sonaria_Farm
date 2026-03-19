# android_emulation/ldplayer_manager.py
import subprocess
import time
import os
import random

class LDPlayerManager:
    """
    Управление эмуляторами LDPlayer для массового запуска
    """
    
    def __init__(self, ldplayer_path="C:/LDPlayer/LDPlayer9"):
        self.ldpath = ldplayer_path
        self.instances = []
        
    def create_instance(self, instance_name, proxy=None):
        """
        Создание нового экземпляра эмулятора
        """
        # Создаем копию основного эмулятора
        cmd = f'"{self.ldpath}/ldconsole.exe" add --name {instance_name}'
        subprocess.run(cmd, shell=True)
        
        # Настраиваем прокси (если есть)
        if proxy:
            self.set_proxy(instance_name, proxy)
        
        # Настраиваем разрешение
        self.set_resolution(instance_name, 1280, 720)
        
        return instance_name
    
    def start_instance(self, instance_name):
        """
        Запуск эмулятора
        """
        cmd = f'"{self.ldpath}/ldconsole.exe" launch --name {instance_name}'
        subprocess.run(cmd, shell=True)
        time.sleep(15)  # Ждем загрузку Android
        
    def install_roblox(self, instance_name):
        """
        Установка Roblox через APK
        """
        # Скачиваем Roblox APK (официальный или модифицированный)
        apk_path = "C:/apks/roblox_latest.apk"
        
        cmd = f'"{self.ldpath}/ldconsole.exe" installapp --name {instance_name} --filename "{apk_path}"'
        subprocess.run(cmd, shell=True)
        time.sleep(20)
    
    def install_fluxus_android(self, instance_name):
        """
        Установка Fluxus APK (Android версия)
        """
        fluxus_apk = "C:/apks/fluxus_android.apk"
        
        cmd = f'"{self.ldpath}/ldconsole.exe" installapp --name {instance_name} --filename "{fluxus_apk}"'
        subprocess.run(cmd, shell=True)
        time.sleep(10)
    
    def run_script_in_android(self, instance_name, lua_script):
        """
        Запуск Lua-скрипта через Fluxus на Android
        """
        # Сохраняем скрипт в файл
        script_file = f"scripts/{instance_name}.lua"
        with open(script_file, "w") as f:
            f.write(lua_script)
        
        # Копируем скрипт в эмулятор
        # ADB команды
        adb_path = f"{self.ldpath}/adb.exe"
        
        # Получаем порт ADB для эмулятора
        port = self.get_adb_port(instance_name)
        
        # Копируем файл
        subprocess.run(
            f'"{adb_path}" -s 127.0.0.1:{port} push {script_file} /sdcard/script.lua',
            shell=True
        )
        
        # Запускаем скрипт через Fluxus (нужен Intent)
        # Это зависит от API Fluxus
        
    def set_proxy(self, instance_name, proxy_string):
        """
        Настройка прокси для эмулятора
        proxy_string: "ip:port:login:pass" или "ip:port"
        """
        # Разбираем строку
        parts = proxy_string.split(':')
        
        if len(parts) == 2:
            ip, port = parts
            # Настройка HTTP прокси через adb
            adb_path = f"{self.ldpath}/adb.exe"
            port_adb = self.get_adb_port(instance_name)
            
            # Для Android 7+ настройка прокси через settings
            subprocess.run(
                f'"{adb_path}" -s 127.0.0.1:{port_adb} shell settings put global http_proxy {ip}:{port}',
                shell=True
            )