# utils/ocr_helper.py
import asyncio
import re
from typing import Optional, List, Dict, Any
from PIL import Image
import os

class OCRHelper:
    """
    Помощник для OCR (распознавания текста)
    Использует pytesseract для извлечения текста из изображений
    """
    
    def __init__(self, tesseract_path: Optional[str] = None):
        """
        Инициализация OCR помощника
        
        Args:
            tesseract_path: путь к исполняемому файлу tesseract (если не в PATH)
        """
        try:
            import pytesseract
            
            if tesseract_path:
                pytesseract.pytesseract.tesseract_cmd = tesseract_path
            
            self.tesseract = pytesseract
            self.available = True
            
        except ImportError:
            print("[OCR] pytesseract не установлен. OCR будет недоступен.")
            self.available = False
        except Exception as e:
            print(f"[OCR] Ошибка инициализации: {e}")
            self.available = False
    
    def extract_text(self, image: Image.Image, config: str = "--psm 6") -> str:
        """
        Извлечение текста из изображения
        
        Args:
            image: PIL Image объект
            config: конфигурация tesseract
            
        Returns:
            Извлеченный текст
        """
        if not self.available:
            return ""
        
        try:
            text = self.tesseract.image_to_string(image, config=config)
            return text.strip()
        except Exception as e:
            print(f"[OCR] Ошибка извлечения текста: {e}")
            return ""
    
    async def extract_text_async(self, image: Image.Image, config: str = "--psm 6") -> str:
        """
        Асинхронное извлечение текста
        
        Args:
            image: PIL Image объект
            config: конфигурация tesseract
            
        Returns:
            Извлеченный текст
        """
        loop = asyncio.get_event_loop()
        return await loop.run_in_executor(None, self.extract_text, image, config)
    
    def extract_numbers(self, image: Image.Image) -> List[int]:
        """
        Извлечение чисел из изображения
        
        Args:
            image: PIL Image объект
            
        Returns:
            Список найденных чисел
        """
        text = self.extract_text(image, "--psm 7")
        numbers = re.findall(r'\d+', text)
        return [int(num) for num in numbers]
    
    async def extract_numbers_async(self, image: Image.Image) -> List[int]:
        """
        Асинхронное извлечение чисел
        
        Args:
            image: PIL Image объект
            
        Returns:
            Список найденных чисел
        """
        loop = asyncio.get_event_loop()
        return await loop.run_in_executor(None, self.extract_numbers, image)
    
    def extract_first_number(self, image: Image.Image) -> Optional[int]:
        """
        Извлечение первого числа из изображения
        
        Args:
            image: PIL Image объект
            
        Returns:
            Первое найденное число или None
        """
        numbers = self.extract_numbers(image)
        return numbers[0] if numbers else None
    
    async def extract_first_number_async(self, image: Image.Image) -> Optional[int]:
        """
        Асинхронное извлечение первого числа
        
        Args:
            image: PIL Image объект
            
        Returns:
            Первое найденное число или None
        """
        loop = asyncio.get_event_loop()
        return await loop.run_in_executor(None, self.extract_first_number, image)
    
    def extract_death_points(self, image: Image.Image) -> int:
        """
        Специализированное извлечение Death Points
        
        Args:
            image: PIL Image объект
            
        Returns:
            Количество Death Points или 0
        """
        # Оптимизированные настройки для DP
        config = "--psm 7 -c tessedit_char_whitelist=0123456789"
        
        text = self.extract_text(image, config)
        
        try:
            return int(text.strip())
        except:
            return 0
    
    async def extract_death_points_async(self, image: Image.Image) -> int:
        """
        Асинхронное извлечение Death Points
        
        Args:
            image: PIL Image объект
            
        Returns:
            Количество Death Points или 0
        """
        loop = asyncio.get_event_loop()
        return await loop.run_in_executor(None, self.extract_death_points, image)
    
    def extract_player_names(self, image: Image.Image) -> List[str]:
        """
        Извлечение имен игроков из изображения
        
        Args:
            image: PIL Image объект
            
        Returns:
            Список имен
        """
        config = "--psm 6"
        text = self.extract_text(image, config)
        
        # Простой парсинг строк
        lines = text.split('\n')
        names = [line.strip() for line in lines if line.strip() and len(line.strip()) > 2]
        
        return names
    
    def extract_mission_text(self, image: Image.Image) -> Dict[str, Any]:
        """
        Извлечение информации о миссиях
        
        Args:
            image: PIL Image объект
            
        Returns:
            Словарь с информацией о миссиях
        """
        config = "--psm 4"
        text = self.extract_text(image, config)
        
        # Парсинг миссий
        missions = []
        lines = text.split('\n')
        
        for line in lines:
            if any(keyword in line.lower() for keyword in ['mission', 'quest', 'task', 'задание']):
                missions.append(line.strip())
        
        return {
            'raw_text': text,
            'missions': missions,
            'missions_count': len(missions)
        }
    
    def is_text_present(self, image: Image.Image, target_text: str, case_sensitive: bool = False) -> bool:
        """
        Проверка наличия определенного текста на изображении
        
        Args:
            image: PIL Image объект
            target_text: искомый текст
            case_sensitive: учитывать регистр
            
        Returns:
            True если текст найден
        """
        text = self.extract_text(image)
        
        if not case_sensitive:
            text = text.lower()
            target_text = target_text.lower()
        
        return target_text in text
    
    async def is_text_present_async(self, image: Image.Image, target_text: str, case_sensitive: bool = False) -> bool:
        """
        Асинхронная проверка наличия текста
        
        Args:
            image: PIL Image объект
            target_text: искомый текст
            case_sensitive: учитывать регистр
            
        Returns:
            True если текст найден
        """
        loop = asyncio.get_event_loop()
        return await loop.run_in_executor(None, self.is_text_present, image, target_text, case_sensitive)
    
    def detect_banned_account(self, image: Image.Image) -> bool:
        """
        Специализированная проверка на бан аккаунта
        
        Args:
            image: PIL Image объект
            
        Returns:
            True если аккаунт забанен
        """
        text = self.extract_text(image).lower()
        
        ban_phrases = [
            'terminated',
            'deleted',
            'banned',
            'account has been',
            'нарушение правил',
            'аккаунт заблокирован',
            'account deleted'
        ]
        
        for phrase in ban_phrases:
            if phrase in text:
                return True
        
        return False
    
    async def detect_banned_account_async(self, image: Image.Image) -> bool:
        """
        Асинхронная проверка на бан
        
        Args:
            image: PIL Image объект
            
        Returns:
            True если аккаунт забанен
        """
        loop = asyncio.get_event_loop()
        return await loop.run_in_executor(None, self.detect_banned_account, image)
    
    def get_available_languages(self) -> List[str]:
        """
        Получение списка доступных языков для OCR
        
        Returns:
            Список языков
        """
        if not self.available:
            return []
        
        try:
            languages = self.tesseract.get_languages()
            return languages
        except:
            return ['eng']  # По умолчанию только английский