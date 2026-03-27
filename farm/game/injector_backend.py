"""
Backend-слой запуска инжектора для WindowsGameAdapter.

По умолчанию используется внешний CLI (`external_cli`), но для отладки
пайплайна доступен `mock` без запуска стороннего exe.
"""

from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path
from typing import Any

from farm.game import injector_launcher as inj

_BACKENDS = frozenset({"external_cli", "mock"})


def backend_name() -> str:
    raw = (os.getenv("INJECTOR_BACKEND") or "external_cli").strip().lower()
    return raw if raw in _BACKENDS else "external_cli"


def is_mock_backend() -> bool:
    return backend_name() == "mock"


def legacy_ready() -> bool:
    if is_mock_backend():
        return True
    return (
        inj.injector_enabled_flag()
        and inj.injector_executable() is not None
        and inj.injector_scripts_dir() is not None
    )


def universal_ready() -> bool:
    if is_mock_backend():
        return True
    return (
        inj.injector_enabled_flag()
        and inj.injector_executable() is not None
        and inj.resolve_universal_sonaria_script_path() is not None
    )


def build_argv(
    *,
    script_path: Path,
    params: dict[str, Any],
    injector_executable: Path | None = None,
) -> tuple[list[str], int]:
    exe = injector_executable or inj.injector_executable()
    if not exe:
        raise RuntimeError("INJECTOR_ENABLED=1, но не найден INJECTOR_PATH")
    pid = inj.resolve_roblox_pid()
    if not pid:
        raise RuntimeError("Не удалось определить PID Roblox. Укажи ROBLOX_PID или запусти RobloxPlayerBeta.exe.")
    params_json = json.dumps(params, ensure_ascii=False, separators=(",", ":"))
    argv = [
        str(exe.resolve()),
        *inj.injector_extra_argv(),
        str(pid),
        str(script_path.resolve()),
        params_json,
    ]
    return argv, pid


def no_window_kwargs() -> dict[str, Any]:
    kwargs: dict[str, Any] = {}
    if os.getenv("INJECTOR_NO_WINDOW", "").strip().lower() in ("1", "true", "yes", "on"):
        import subprocess

        if hasattr(subprocess, "CREATE_NO_WINDOW"):
            kwargs["creationflags"] = subprocess.CREATE_NO_WINDOW
    return kwargs


async def run_wait(*, argv: list[str], timeout_seconds: int) -> tuple[bytes, bytes, int | None]:
    proc = await asyncio.create_subprocess_exec(
        *argv,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
        **no_window_kwargs(),
    )
    stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout_seconds)
    return stdout or b"", stderr or b"", proc.returncode


async def run_detached(*, argv: list[str]) -> asyncio.subprocess.Process:
    return await asyncio.create_subprocess_exec(
        *argv,
        stdout=asyncio.subprocess.DEVNULL,
        stderr=asyncio.subprocess.PIPE,
        **no_window_kwargs(),
    )
