"""
Опциональный запуск внешнего инжектора/лаунчера через subprocess (Windows).

Управляется переменными окружения (см. env.template). Не привязан к конкретному exe:
аргументы командной строки задаются через INJECTOR_ARGS_JSON.

По умолчанию выключено (INJECTOR_LAUNCH_WHEN=never), чтобы не ломать существующие деплои.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import subprocess
import sys
from pathlib import Path
from typing import Any

logger = logging.getLogger("farm.game.injector_launcher")

_LAUNCH_MODES = frozenset({"never", "windows_adapter_init", "every_farm_tick"})

# farm/game/injector_launcher.py -> parents[2] == корень репозитория
REPO_ROOT = Path(__file__).resolve().parents[2]


def _truthy(val: str | None) -> bool:
    if not val:
        return False
    return val.strip().lower() in ("1", "true", "yes", "on")


def injector_enabled_flag() -> bool:
    return _truthy(os.getenv("INJECTOR_ENABLED"))


def _injector_path_raw() -> str:
    return os.getenv("INJECTOR_PATH", "").strip().strip('"').strip("'")


def injector_executable() -> Path | None:
    raw = _injector_path_raw()
    if not raw:
        return None
    p = Path(raw)
    return p if p.is_file() else None


def vd_executor_default_exe() -> Path | None:
    """
    Подсказка для INJECTOR_PATH: свежая сборка из исходников, затем запасной путь VD_Exec.
    """
    candidates = (
        REPO_ROOT
        / "stocker"
        / "exploit"
        / "VD_Executor"
        / "bin"
        / "Release"
        / "net9.0-windows"
        / "win-x64"
        / "VD Executor.exe",
        REPO_ROOT / "stocker" / "exploit" / "VD_Exec" / "VD Executor.exe",
    )
    for p in candidates:
        if p.is_file():
            return p
    return None


def is_vd_executor_path(path: Path | None) -> bool:
    if path is None:
        return False
    return path.name.casefold() == "vd executor.exe"


def injector_dex_uses_vd_executor_start_only() -> bool:
    """
    Dex (универсал): только стартовать VD Executor, без CLI ``pid script.lua JSON``.

    Включается, если INJECTOR_DEX_START_ONLY=1, либо (по умолчанию) если INJECTOR_PATH
    указывает на файл ``VD Executor.exe`` и не задано INJECTOR_DEX_LEGACY_CLI=1.
    """
    if _truthy(os.getenv("INJECTOR_DEX_LEGACY_CLI")):
        return False
    if _truthy(os.getenv("INJECTOR_DEX_START_ONLY")):
        return True
    return is_vd_executor_path(injector_executable())


def injector_configured() -> bool:
    return injector_enabled_flag() and injector_executable() is not None


def injector_extra_argv() -> list[str]:
    raw = os.getenv("INJECTOR_ARGS_JSON", "").strip()
    if not raw:
        return []
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        logger.warning("INJECTOR_ARGS_JSON: невалидный JSON, игнор")
        return []
    if not isinstance(data, list) or not all(isinstance(x, str) for x in data):
        logger.warning("INJECTOR_ARGS_JSON: ожидается JSON-массив строк, игнор")
        return []
    return data


def injector_launch_when() -> str:
    v = (os.getenv("INJECTOR_LAUNCH_WHEN") or "never").strip().lower()
    return v if v in _LAUNCH_MODES else "never"


def injector_timeout_seconds() -> int:
    try:
        return max(1, int(os.getenv("INJECTOR_TIMEOUT_SECONDS", "30")))
    except ValueError:
        return 30


def build_injector_argv() -> list[str] | None:
    exe = injector_executable()
    if not exe:
        return None
    return [str(exe.resolve())] + injector_extra_argv()


def injector_scripts_dir() -> Path | None:
    raw = os.getenv("INJECTOR_SCRIPTS_DIR", "").strip().strip('"').strip("'")
    if not raw:
        return None
    p = Path(raw)
    return p if p.is_dir() else None


def resolve_injector_script_path(script_name: str) -> Path | None:
    scripts_dir = injector_scripts_dir()
    if not scripts_dir:
        return None
    p = scripts_dir / script_name
    return p if p.is_file() else None


def resolve_universal_sonaria_script_path() -> Path | None:
    """
    Универсальный скрипт Kimi (отдельно от legacy ``INJECTOR_SCRIPTS_DIR`` / farm.lua).
    По умолчанию: ``<repo>/external/injector_scripts/universal_sonaria_bot.lua``.
    """
    raw = os.getenv("INJECTOR_UNIVERSAL_SCRIPT_PATH", "").strip().strip('"').strip("'")
    if raw:
        p = Path(raw)
        if not p.is_absolute():
            p = REPO_ROOT / p
        return p if p.is_file() else None
    default = REPO_ROOT / "external" / "injector_scripts" / "universal_sonaria_bot.lua"
    return default if default.is_file() else None


def resolve_roblox_pid() -> int | None:
    raw = (os.getenv("ROBLOX_PID") or "").strip()
    if raw:
        try:
            pid = int(raw)
            return pid if pid > 0 else None
        except ValueError:
            logger.warning("ROBLOX_PID: ожидается положительное число, игнор")
    try:
        cp = subprocess.run(
            ["tasklist", "/FI", "IMAGENAME eq RobloxPlayerBeta.exe", "/FO", "CSV", "/NH"],
            capture_output=True,
            text=True,
            timeout=5,
        )
    except Exception:
        return None
    if cp.returncode != 0:
        return None
    for line in (cp.stdout or "").splitlines():
        line = line.strip()
        if not line or "No tasks are running" in line:
            continue
        row = line.strip('"')
        parts = row.split('","')
        if len(parts) < 2:
            continue
        pid_raw = parts[1].replace(",", "").strip()
        try:
            pid = int(pid_raw)
            if pid > 0:
                return pid
        except ValueError:
            continue
    return None


def _run_subprocess(argv: list[str]) -> subprocess.CompletedProcess[str]:
    kwargs: dict[str, Any] = {}
    if _truthy(os.getenv("INJECTOR_NO_WINDOW")) and hasattr(subprocess, "CREATE_NO_WINDOW"):
        kwargs["creationflags"] = subprocess.CREATE_NO_WINDOW
    return subprocess.run(
        argv,
        capture_output=True,
        text=True,
        timeout=injector_timeout_seconds(),
        **kwargs,
    )


def _truncate(s: str | None, n: int = 400) -> str:
    if not s:
        return ""
    s = s.strip()
    return s if len(s) <= n else s[: n - 3] + "..."


async def launch_injector_subprocess(
    *,
    task_id: str,
    worker_id: str | None,
    trigger: str,
    extra_argv: list[str] | None = None,
    capture_output: bool = True,
    timeout_seconds: int | None = None,
) -> subprocess.CompletedProcess[str] | None:
    """
    Запускает INJECTOR_PATH + INJECTOR_ARGS_JSON. Логирует в task_logs и в logger.
    """
    from farm.task_queue import append_task_log

    if not injector_enabled_flag():
        return

    argv = build_injector_argv()
    if not argv:
        path_raw = _injector_path_raw()
        msg = (
            f"[injector] INJECTOR_ENABLED, но исполняемый файл не найден: {path_raw!r} "
            "(проверь INJECTOR_PATH и кавычки для Program Files)"
        )
        logger.warning(msg)
        await append_task_log(task_id=task_id, worker_id=worker_id, level="warning", message=msg)
        return

    await append_task_log(
        task_id=task_id,
        worker_id=worker_id,
        message=f"[injector] запуск trigger={trigger!r} argv={argv!r}",
    )

    final_argv = list(argv)
    if extra_argv:
        final_argv.extend(extra_argv)

    run_timeout = timeout_seconds if timeout_seconds is not None else injector_timeout_seconds()

    def _run() -> subprocess.CompletedProcess[str]:
        kwargs: dict[str, Any] = {}
        if _truthy(os.getenv("INJECTOR_NO_WINDOW")) and hasattr(subprocess, "CREATE_NO_WINDOW"):
            kwargs["creationflags"] = subprocess.CREATE_NO_WINDOW
        if capture_output:
            kwargs["capture_output"] = True
            kwargs["text"] = True
        else:
            kwargs["capture_output"] = False
            kwargs["text"] = False
        return subprocess.run(
            final_argv,
            timeout=run_timeout,
            **kwargs,
        )

    try:
        cp = await asyncio.to_thread(_run)
    except subprocess.TimeoutExpired:
        msg = f"[injector] таймаут {run_timeout}s для {final_argv[0]!r}"
        logger.warning(msg)
        await append_task_log(task_id=task_id, worker_id=worker_id, level="warning", message=msg)
        return None
    except OSError as exc:
        msg = f"[injector] OSError: {exc}"
        logger.exception(msg)
        await append_task_log(task_id=task_id, worker_id=worker_id, level="error", message=msg)
        return None

    out = _truncate(cp.stdout if isinstance(cp.stdout, str) else "")
    err = _truncate(cp.stderr if isinstance(cp.stderr, str) else "")
    tail = f" returncode={cp.returncode}"
    if out:
        tail += f" stdout={out!r}"
    if err:
        tail += f" stderr={err!r}"
    log_line = f"[injector] завершено{tail}"
    logger.info(log_line)
    level = "warning" if cp.returncode not in (0, None) else "info"
    await append_task_log(task_id=task_id, worker_id=worker_id, level=level, message=log_line)
    return cp


async def launch_vd_executor_detached(
    *,
    task_id: str,
    worker_id: str | None,
    trigger: str,
) -> int:
    """
    Стартует INJECTOR_PATH + INJECTOR_ARGS_JSON и сразу возвращает pid (процесс не ждём).
    Для GUI/долгоживущих лаунчеров (VD Executor).
    """
    from farm.task_queue import append_task_log

    if not injector_enabled_flag():
        raise RuntimeError("INJECTOR_ENABLED не включён")

    argv = build_injector_argv()
    if not argv:
        raise RuntimeError("INJECTOR_PATH не задан или файл не найден")

    await append_task_log(
        task_id=task_id,
        worker_id=worker_id,
        message=f"[vd_executor] старт trigger={trigger!r} argv={argv!r}",
    )

    kwargs: dict[str, Any] = {}
    if _truthy(os.getenv("INJECTOR_NO_WINDOW")) and sys.platform == "win32":
        if hasattr(subprocess, "CREATE_NO_WINDOW"):
            kwargs["creationflags"] = subprocess.CREATE_NO_WINDOW

    try:
        proc = await asyncio.create_subprocess_exec(
            *argv,
            stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
            **kwargs,
        )
    except OSError as exc:
        msg = f"[vd_executor] не удалось запустить: {exc}"
        logger.exception(msg)
        await append_task_log(task_id=task_id, worker_id=worker_id, level="error", message=msg)
        raise RuntimeError(msg) from exc

    pid = proc.pid or -1
    log_line = f"[vd_executor] процесс запущен pid={pid}"
    logger.info(log_line)
    await append_task_log(task_id=task_id, worker_id=worker_id, message=log_line)
    return pid
