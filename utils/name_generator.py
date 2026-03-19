# utils/name_generator.py
import random
import string
from typing import List, Optional

class NameGenerator:
    """
    Генератор случайных имен для существ
    Создает разнообразные имена, похожие на реальные никнеймы игроков
    """
    
    def __init__(self):
        # Списки для генерации имен
        self.prefixes = [
            # Английские
            'Fluffy', 'Shadow', 'Crystal', 'Blaze', 'Frost', 'Wild', 'Swift', 'Silent',
            'Mighty', 'Brave', 'Clever', 'Noble', 'Royal', 'Golden', 'Silver', 'Emerald',
            'Ruby', 'Sapphire', 'Onyx', 'Storm', 'Thunder', 'Lightning', 'Echo', 'Spirit',
            'Ghost', 'Phantom', 'Mystic', 'Magic', 'Dark', 'Light', 'Fire', 'Ice',
            'Wind', 'Earth', 'Water', 'Leaf', 'Rose', 'Lily', 'Moon', 'Star',
            'Sun', 'Sky', 'Cloud', 'Rain', 'Snow', 'Ocean', 'River', 'Mountain',
            'Alpha', 'Beta', 'Gamma', 'Delta', 'Omega', 'Prime', 'Ultra', 'Super',
            'Hyper', 'Mega', 'Giga', 'Tera', 'Peta', 'Exo', 'Nova', 'Cosmo'
        ]
        
        self.middle = [
            'paw', 'tail', 'wing', 'horn', 'claw', 'fur', 'scale', 'feather',
            'heart', 'soul', 'eye', 'fang', 'whisker', 'hoof', 'mane', 'spine',
            'runner', 'walker', 'hunter', 'gatherer', 'roamer', 'guardian',
            'fighter', 'warrior', 'knight', 'mage', 'wizard', 'druid', 'shaman',
            'dragon', 'serpent', 'wolf', 'fox', 'bear', 'lion', 'tiger', 'eagle',
            'hawk', 'raven', 'crow', 'owl', 'snake', 'lizard', 'frog', 'fish',
            'flower', 'bloom', 'blossom', 'leaf', 'root', 'branch', 'tree', 'forest',
            'crystal', 'gem', 'stone', 'rock', 'mountain', 'volcano', 'desert'
        ]
        
        self.suffixes = [
            'er', 'or', 'ar', 'ian', 'ist', 'ic', 'al', 'ous',
            'ing', 'ed', 'en', 'ly', 'y', 'ie', 'ey', 'ette',
            'kin', 'let', 'ling', 'ster', 'ton', 'dor', 'gor', 'thor'
        ]
        
        # Популярные комбинации из игры
        self.common_names = [
            'Predator', 'Hunter', 'Gatherer', 'Scavenger', 'Survivor',
            'Walker', 'Runner', 'Flyer', 'Swimmer', 'Climber',
            'Defender', 'Attacker', 'Support', 'Tank', 'Healer',
            'Solo', 'Team', 'Pack', 'Lone', 'Group',
            'Alpha', 'Beta', 'Omega', 'Leader', 'Follower',
            'Young', 'Elder', 'Ancient', 'Prime', 'Evolved'
        ]
        
        # Эмодзи-подобные символы (если игра поддерживает)
        self.symbols = ['★', '☆', '♡', '♥', '⚡', '🔥', '❄️', '💧', '🌿', '🌟']
    
    def generate_name(self, style: str = "random", min_length: int = 3, max_length: int = 20) -> str:
        """
        Генерация случайного имени
        
        Args:
            style: стиль имени (random, cute, edgy, simple, compound)
            min_length: минимальная длина
            max_length: максимальная длина
            
        Returns:
            Сгенерированное имя
        """
        generators = {
            'random': self._generate_random,
            'cute': self._generate_cute,
            'edgy': self._generate_edgy,
            'simple': self._generate_simple,
            'compound': self._generate_compound
        }
        
        generator = generators.get(style, self._generate_random)
        
        # Генерируем имя
        for _ in range(10):  # Пробуем до 10 раз
            name = generator()
            if min_length <= len(name) <= max_length:
                return name
        
        # Если не получилось, возвращаем простое имя
        return self._generate_simple()
    
    def _generate_random(self) -> str:
        """Случайное имя из всех возможных комбинаций"""
        patterns = [
            lambda: random.choice(self.prefixes) + random.choice(self.middle),
            lambda: random.choice(self.prefixes) + random.choice(self.suffixes),
            lambda: random.choice(self.middle) + random.choice(self.suffixes),
            lambda: random.choice(self.prefixes) + random.choice(self.middle) + random.choice(self.suffixes),
            lambda: random.choice(self.prefixes) + random.choice(self.common_names),
            lambda: random.choice(self.common_names) + random.choice(self.suffixes)
        ]
        
        name = random.choice(patterns)()
        
        # Добавляем число
        if random.random() < 0.3:
            name += str(random.randint(1, 999))
        
        # Добавляем символ
        if random.random() < 0.1:
            name += random.choice(self.symbols)
        
        return name
    
    def _generate_cute(self) -> str:
        """Милые имена"""
        cute_prefixes = ['Fluffy', 'Cute', 'Sweet', 'Candy', 'Sugar', 'Honey', 'Baby', 'Tiny']
        cute_suffixes = ['paw', 'tail', 'pop', 'pie', 'cake', 'cup', 'kin', 'let']
        
        name = random.choice(cute_prefixes) + random.choice(cute_suffixes)
        
        if random.random() < 0.5:
            name += str(random.randint(10, 99))
        
        return name
    
    def _generate_edgy(self) -> str:
        """Крутые/мрачные имена"""
        edgy_prefixes = ['Dark', 'Shadow', 'Night', 'Death', 'Blood', 'Dark', 'Evil', 'Sin']
        edgy_suffixes = ['fang', 'claw', 'killer', 'hunter', 'stalker', 'reaper', 'doom']
        
        name = random.choice(edgy_prefixes) + random.choice(edgy_suffixes)
        name = name + str(random.randint(666, 999))
        
        return name
    
    def _generate_simple(self) -> str:
        """Простые имена (буквы + цифры)"""
        # Буквы
        letters = random.choices(string.ascii_letters, k=random.randint(4, 8))
        name = ''.join(letters).capitalize()
        
        # Цифры
        if random.random() < 0.7:
            name += str(random.randint(1, 999))
        
        return name
    
    def _generate_compound(self) -> str:
        """Составные имена с разделителями"""
        part1 = random.choice(self.prefixes)
        part2 = random.choice(self.middle)
        
        # Разные разделители
        separators = ['_', '-', '', ' ']
        sep = random.choice(separators)
        
        name = part1 + sep + part2
        
        if random.random() < 0.4:
            name += sep + str(random.randint(1, 999))
        
        return name
    
    def generate_batch(self, count: int, style: str = "random") -> List[str]:
        """
        Генерация нескольких имен
        
        Args:
            count: количество имен
            style: стиль имени
            
        Returns:
            Список имен
        """
        names = []
        for _ in range(count):
            name = self.generate_name(style)
            # Проверяем на уникальность
            while name in names:
                name = self.generate_name(style)
            names.append(name)
        
        return names
    
    def generate_from_template(self, template: str) -> str:
        """
        Генерация имени по шаблону
        
        Шаблон может содержать:
        {prefix} - случайный префикс
        {middle} - случайная середина
        {suffix} - случайный суффикс
        {number} - случайное число
        {symbol} - случайный символ
        
        Args:
            template: шаблон, например "{prefix}{middle}{number}"
            
        Returns:
            Сгенерированное имя
        """
        replacements = {
            '{prefix}': lambda: random.choice(self.prefixes),
            '{middle}': lambda: random.choice(self.middle),
            '{suffix}': lambda: random.choice(self.suffixes),
            '{common}': lambda: random.choice(self.common_names),
            '{number}': lambda: str(random.randint(1, 9999)),
            '{symbol}': lambda: random.choice(self.symbols),
            '{letter}': lambda: random.choice(string.ascii_letters),
            '{digit}': lambda: random.choice(string.digits)
        }
        
        result = template
        for placeholder, generator in replacements.items():
            while placeholder in result:
                result = result.replace(placeholder, generator(), 1)
        
        return result
    
    def is_valid_name(self, name: str, min_length: int = 3, max_length: int = 20) -> bool:
        """
        Проверка валидности имени
        
        Args:
            name: имя для проверки
            min_length: минимальная длина
            max_length: максимальная длина
            
        Returns:
            True если имя валидно
        """
        if not name:
            return False
        
        if len(name) < min_length or len(name) > max_length:
            return False
        
        # Проверяем на запрещенные символы (зависит от игры)
        allowed_chars = set(string.ascii_letters + string.digits + '_ -' + ''.join(self.symbols))
        
        for char in name:
            if char not in allowed_chars:
                return False
        
        return True
    
    def normalize_name(self, name: str) -> str:
        """
        Нормализация имени (удаление лишних символов)
        
        Args:
            name: исходное имя
            
        Returns:
            Нормализованное имя
        """
        # Удаляем пробелы в начале и конце
        name = name.strip()
        
        # Заменяем множественные пробелы на один
        name = ' '.join(name.split())
        
        # Ограничиваем длину
        if len(name) > 20:
            name = name[:20]
        
        return name