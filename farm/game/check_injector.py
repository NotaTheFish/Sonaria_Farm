"""
CLI health-check for injector before worker start.

Пример:
    python -m farm.game.check_injector
    python -m farm.game.check_injector --json
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

from dotenv import load_dotenv

from farm.game import injector_backend as ib
from farm.game import injector_launcher as inj

REPO_ROOT = Path(__file__).resolve().parents[2]
load_dotenv(REPO_ROOT / ".env")


def _normalize_path(p: Path | None) -> str | None:
    if p is None:
        return None
    try:
        return str(p.resolve())
    except OSError:
        return str(p)


def collect_status() -> dict[str, Any]:
    backend = ib.backend_name()
    enabled = inj.injector_enabled_flag()
    exe = inj.injector_executable()
    scripts_dir = inj.injector_scripts_dir()
    universal_script = inj.resolve_universal_sonaria_script_path()
    pid = inj.resolve_roblox_pid()
    extra_argv = inj.injector_extra_argv()
    launch_when = inj.injector_launch_when()
    timeout_seconds = inj.injector_timeout_seconds()

    require_pid = (os.getenv("INJECTOR_PREFLIGHT_REQUIRE_ROBLOX_PID", "1") or "").strip().lower()
    require_pid_bool = require_pid in ("1", "true", "yes", "on")

    legacy_ready = ib.legacy_ready()
    universal_ready = ib.universal_ready()

    issues: list[str] = []
    if backend == "external_cli":
        if not enabled:
            issues.append("INJECTOR_ENABLED is disabled or missing.")
        if exe is None:
            issues.append("INJECTOR_PATH is missing or points to non-existing file.")
        if require_pid_bool and pid is None:
            issues.append("Roblox PID not found (ROBLOX_PID missing and Roblox process not running).")
    if backend == "external_cli" and universal_script is None:
        issues.append("universal_sonaria_bot.lua not found (INJECTOR_UNIVERSAL_SCRIPT_PATH).")

    return {
        "backend": backend,
        "enabled": enabled,
        "injector_path": _normalize_path(exe),
        "injector_scripts_dir": _normalize_path(scripts_dir),
        "universal_script_path": _normalize_path(universal_script),
        "roblox_pid": pid,
        "injector_args": extra_argv,
        "launch_when": launch_when,
        "timeout_seconds": timeout_seconds,
        "legacy_ready": legacy_ready,
        "universal_ready": universal_ready,
        "require_pid": require_pid_bool,
        "issues": issues,
        "ok": len(issues) == 0,
    }


def _print_human(status: dict[str, Any]) -> None:
    print("Injector health-check")
    print("=====================")
    print(f"backend:            {status['backend']}")
    print(f"enabled:            {status['enabled']}")
    print(f"injector_path:      {status['injector_path'] or '-'}")
    print(f"injector_scripts:   {status['injector_scripts_dir'] or '-'}")
    print(f"universal_script:   {status['universal_script_path'] or '-'}")
    print(f"roblox_pid:         {status['roblox_pid'] or '-'}")
    print(f"injector_args:      {status['injector_args']}")
    print(f"launch_when:        {status['launch_when']}")
    print(f"timeout_seconds:    {status['timeout_seconds']}")
    print(f"legacy_ready:       {status['legacy_ready']}")
    print(f"universal_ready:    {status['universal_ready']}")
    if status["issues"]:
        print("issues:")
        for issue in status["issues"]:
            print(f"  - {issue}")
    else:
        print("issues:             none")
    print(f"ok:                 {status['ok']}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Check INJECTOR_* configuration and Roblox PID.")
    parser.add_argument("--json", action="store_true", help="Print output as JSON.")
    args = parser.parse_args()

    status = collect_status()
    if args.json:
        print(json.dumps(status, ensure_ascii=False, indent=2))
    else:
        _print_human(status)
    return 0 if status["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
