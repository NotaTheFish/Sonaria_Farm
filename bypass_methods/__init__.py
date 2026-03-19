# bypass_methods/__init__.py
"""
Пакет с различными методами обхода Byfron
"""

# Импортируем доступные методы
try:
    from .fluxus.fluxus_bridge import FluxusInjector
    FLUXUS_AVAILABLE = True
except ImportError:
    FLUXUS_AVAILABLE = False

try:
    from .android.ldplayer_manager import LDPlayerManager
    ANDROID_AVAILABLE = True
except ImportError:
    ANDROID_AVAILABLE = False

try:
    from .uwp.uwp_launcher import UWPLauncher
    UWP_AVAILABLE = True
except ImportError:
    UWP_AVAILABLE = False

# C++ методы требуют компиляции, поэтому их не импортируем напрямую