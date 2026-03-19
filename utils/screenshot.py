# utils/screenshot.py
import asyncio
import os
from PIL import Image, ImageGrab
import numpy as np
from datetime import datetime
from typing import Optional, Tuple
import io

class ScreenshotHelper:
    """
    Помощник для работы со скриншотами
    Поддерживает захват экрана, сохранение, обработку
    """
    
    def __init__(self, debug_mode: bool = False, debug_path: str = "logs/screenshots"):
        """
        Инициализация
        
        Args:
            debug_mode: сохранять ли скриншоты для отладки
            debug_path: путь для сохранения
        """
        self.debug_mode = debug_mode
        self.debug_path = debug_path
        
        if debug_mode:
            os.makedirs(debug_path, exist_ok=True)
    
    def capture(self) -> Image.Image:
        """
        Захват скриншота всего экрана (синхронная версия)
        
        Returns:
            PIL Image объект
        """
        return ImageGrab.grab()
    
    async def capture_async(self) -> Image.Image:
        """
        Захват скриншота (асинхронная версия)
        
        Returns:
            PIL Image объект
        """
        # Запускаем захват в отдельном потоке
        loop = asyncio.get_event_loop()
        screenshot = await loop.run_in_executor(None, ImageGrab.grab)
        return screenshot
    
    def capture_region(self, x: int, y: int, width: int, height: int) -> Image.Image:
        """
        Захват определенной области экрана
        
        Args:
            x, y: координаты левого верхнего угла
            width, height: размеры области
            
        Returns:
            PIL Image объект
        """
        return ImageGrab.grab(bbox=(x, y, x + width, y + height))
    
    async def capture_region_async(self, x: int, y: int, width: int, height: int) -> Image.Image:
        """
        Захват области экрана (асинхронно)
        
        Args:
            x, y: координаты левого верхнего угла
            width, height: размеры области
            
        Returns:
            PIL Image объект
        """
        loop = asyncio.get_event_loop()
        screenshot = await loop.run_in_executor(
            None, 
            lambda: ImageGrab.grab(bbox=(x, y, x + width, y + height))
        )
        return screenshot
    
    def save_screenshot(self, image: Image.Image, prefix: str = "screenshot") -> str:
        """
        Сохранение скриншота в файл
        
        Args:
            image: PIL Image объект
            prefix: префикс имени файла
            
        Returns:
            Путь к сохраненному файлу
        """
        if not self.debug_mode:
            return ""
        
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S_%f")[:-3]
        filename = f"{prefix}_{timestamp}.png"
        filepath = os.path.join(self.debug_path, filename)
        
        image.save(filepath)
        return filepath
    
    async def save_screenshot_async(self, image: Image.Image, prefix: str = "screenshot") -> str:
        """
        Асинхронное сохранение скриншота
        
        Args:
            image: PIL Image объект
            prefix: префикс имени файла
            
        Returns:
            Путь к сохраненному файлу
        """
        loop = asyncio.get_event_loop()
        return await loop.run_in_executor(None, self.save_screenshot, image, prefix)
    
    def image_to_bytes(self, image: Image.Image, format: str = "PNG") -> bytes:
        """
        Конвертация изображения в байты
        
        Args:
            image: PIL Image объект
            format: формат изображения
            
        Returns:
            Байтовое представление
        """
        img_bytes = io.BytesIO()
        image.save(img_bytes, format=format)
        return img_bytes.getvalue()
    
    def image_to_numpy(self, image: Image.Image) -> np.ndarray:
        """
        Конвертация PIL Image в numpy array для OpenCV
        
        Args:
            image: PIL Image объект
            
        Returns:
            numpy array
        """
        return np.array(image)
    
    def numpy_to_image(self, array: np.ndarray) -> Image.Image:
        """
        Конвертация numpy array обратно в PIL Image
        
        Args:
            array: numpy array
            
        Returns:
            PIL Image объект
        """
        return Image.fromarray(array)
    
    def get_screen_size(self) -> Tuple[int, int]:
        """
        Получение размера экрана
        
        Returns:
            Кортеж (ширина, высота)
        """
        return ImageGrab.grab().size
    
    def find_color(self, image: Image.Image, target_color: Tuple[int, int, int], tolerance: int = 30) -> list:
        """
        Поиск пикселей определенного цвета на изображении
        
        Args:
            image: PIL Image объект
            target_color: целевой цвет (R, G, B)
            tolerance: допуск по цвету
            
        Returns:
            Список координат найденных пикселей
        """
        import numpy as np
        
        img_array = np.array(image)
        target = np.array(target_color)
        
        # Вычисляем разницу по каждому каналу
        diff = np.abs(img_array - target)
        
        # Находим пиксели, где разница меньше допуска по всем каналам
        mask = np.all(diff <= tolerance, axis=2)
        
        # Получаем координаты
        y_coords, x_coords = np.where(mask)
        
        return list(zip(x_coords, y_coords))
    
    def crop_center(self, image: Image.Image, crop_width: int, crop_height: int) -> Image.Image:
        """
        Вырезание центра изображения
        
        Args:
            image: PIL Image объект
            crop_width: ширина вырезаемой области
            crop_height: высота вырезаемой области
            
        Returns:
            Вырезанное изображение
        """
        width, height = image.size
        
        left = (width - crop_width) // 2
        top = (height - crop_height) // 2
        right = left + crop_width
        bottom = top + crop_height
        
        return image.crop((left, top, right, bottom))
    
    def resize_image(self, image: Image.Image, scale_factor: float) -> Image.Image:
        """
        Изменение размера изображения
        
        Args:
            image: PIL Image объект
            scale_factor: коэффициент масштабирования
            
        Returns:
            Измененное изображение
        """
        new_size = (int(image.width * scale_factor), int(image.height * scale_factor))
        return image.resize(new_size, Image.Resampling.LANCZOS)
    
    def enhance_for_ocr(self, image: Image.Image) -> Image.Image:
        """
        Улучшение изображения для OCR
        
        Args:
            image: PIL Image объект
            
        Returns:
            Обработанное изображение
        """
        import cv2
        
        # Конвертируем в numpy
        img_array = np.array(image)
        
        # Конвертируем в grayscale если нужно
        if len(img_array.shape) == 3:
            gray = cv2.cvtColor(img_array, cv2.COLOR_RGB2GRAY)
        else:
            gray = img_array
        
        # Увеличиваем контраст
        gray = cv2.equalizeHist(gray)
        
        # Бинаризация
        _, binary = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
        
        # Убираем шум
        denoised = cv2.medianBlur(binary, 3)
        
        return Image.fromarray(denoised)
    
    def compare_images(self, img1: Image.Image, img2: Image.Image) -> float:
        """
        Сравнение двух изображений
        
        Args:
            img1, img2: сравниваемые изображения
            
        Returns:
            Коэффициент схожести (0-1)
        """
        import cv2
        
        # Приводим к одинаковому размеру
        if img1.size != img2.size:
            img2 = img2.resize(img1.size)
        
        # Конвертируем в numpy
        arr1 = np.array(img1)
        arr2 = np.array(img2)
        
        # Конвертируем в grayscale
        if len(arr1.shape) == 3:
            arr1 = cv2.cvtColor(arr1, cv2.COLOR_RGB2GRAY)
        if len(arr2.shape) == 3:
            arr2 = cv2.cvtColor(arr2, cv2.COLOR_RGB2GRAY)
        
        # Вычисляем разницу
        diff = cv2.absdiff(arr1, arr2)
        
        # Нормализуем
        similarity = 1.0 - (diff.sum() / (255 * arr1.size))
        
        return similarity
    
    async def wait_for_screen_change(self, timeout: int = 10, threshold: float = 0.1) -> bool:
        """
        Ожидание изменения экрана
        
        Args:
            timeout: максимальное время ожидания
            threshold: порог изменения для обнаружения
            
        Returns:
            True если экран изменился
        """
        start_time = asyncio.get_event_loop().time()
        
        # Первый скриншот
        prev_screen = await self.capture_async()
        
        while asyncio.get_event_loop().time() - start_time < timeout:
            await asyncio.sleep(0.5)
            
            current_screen = await self.capture_async()
            similarity = self.compare_images(prev_screen, current_screen)
            
            if similarity < (1.0 - threshold):
                return True
            
            prev_screen = current_screen
        
        return False