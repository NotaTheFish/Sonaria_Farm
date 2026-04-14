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


def _truthy_env(name: str, default: str = "1") -> bool:
    v = (os.getenv(name) or default).strip().lower()
    return v not in ("0", "false", "no", "off")


def _lua_long_bracket_string(s: str) -> str:
    """Lua literal [=*[ ... ]=*] so JSON need not be escaped (pick delimiter that does not appear in s)."""
    for level in range(0, 64):
        pad = "=" * level
        closer = "]" + pad + "]"
        if closer not in s:
            return "[" + pad + "[" + s + closer
    raise ValueError("cannot build Lua long-string literal for params JSON")


def materialize_universal_script_bundle(
    *,
    task_id: str,
    source_path: Path,
    params: dict[str, Any],
) -> Path:
    """
    Пишет временный .lua: rawset(_G, '__SONARIA_PARAMS_JSON', [[json]]) + исходный скрипт.

    Многие инжекторы/мосты выполняют файл как ``execute(whole_file)`` **без** передачи
    JSON в ``...`` — тогда ``local args = {...}`` пустой и бот сразу выходил с
    «No arguments provided», не доходя до main() и кликов по Play.
    """
    if not _truthy_env("INJECTOR_UNIVERSAL_EMBED_PARAMS", "1"):
        return source_path.resolve()

    json_str = json.dumps(params, ensure_ascii=False, separators=(",", ":"))
    prelude = (
        '-- sonaria_farm: embedded task params (see INJECTOR_UNIVERSAL_EMBED_PARAMS)\n'
        "rawset(_G, '__SONARIA_PARAMS_JSON', "
        + _lua_long_bracket_string(json_str)
        + ")\n"
    )
    body = source_path.read_text(encoding="utf-8")
    out_dir = inj.REPO_ROOT / "runtime" / "inject_universal_wrap"
    out_dir.mkdir(parents=True, exist_ok=True)
    safe_id = "".join(c if c.isalnum() or c in "-_" else "_" for c in task_id)[:120] or "task"
    out_path = out_dir / f"{safe_id}.lua"
    out_path.write_text(prelude + body, encoding="utf-8")
    return out_path.resolve()


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
