"""
Общий контракт файлового моста для WindowsGameAdapter.

Режимы каталогов
----------------
1. По умолчанию — три папки: ``runtime/farm_tick``, ``runtime/transfer_bridge``,
   ``runtime/sell_bridge`` (или явные ``FARM_TICK_DIR`` / ``TRANSFER_BRIDGE_DIR`` / ``SELL_BRIDGE_DIR``).

2. **FILE_BRIDGE_ROOT** — один корень; если конкретная переменная не задана, пути:
   ``<root>/farm_tick``, ``<root>/transfer_bridge``, ``<root>/sell_bridge``.

3. **FILE_BRIDGE_UNIFIED_DIR** — одна папка на все мосты; имена с тегом:
   ``{task_id}.farm_tick.request.json`` → ``{task_id}.farm_tick.response.json`` (и алиасы ``.resp.json``),
   то же с тегами ``transfer`` и ``sell``. Удобно для инжектора: один ``Watch`` на каталог.

Если заданы и root, и unified — приоритет у **FILE_BRIDGE_UNIFIED_DIR** (три отдельные
переменные `FARM_TICK_DIR` / … в этом режиме для игровых мостов **не используются**).
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

# farm/game/file_bridge.py -> parents[2] == корень репозитория
REPO_ROOT = Path(__file__).resolve().parents[2]

# Теги для unified-имён (стабильный контракт для внешнего процесса)
TAG_FARM_TICK = "farm_tick"
TAG_TRANSFER = "transfer"
TAG_SELL = "sell"

ENV_FARM_TICK_DIR = "FARM_TICK_DIR"
ENV_TRANSFER_DIR = "TRANSFER_BRIDGE_DIR"
ENV_SELL_DIR = "SELL_BRIDGE_DIR"
ENV_FILE_BRIDGE_ROOT = "FILE_BRIDGE_ROOT"
ENV_FILE_BRIDGE_UNIFIED_DIR = "FILE_BRIDGE_UNIFIED_DIR"
ENV_DIAGNOSTIC_SECONDS = "FARM_TICK_DIAGNOSTIC_SECONDS"

# Длинные суффиксы первыми (иначе .response.json «съест» .response.json.txt)
LEGACY_BRIDGE_SUFFIXES: tuple[str, ...] = (
    ".response.json.txt",
    ".response.json",
    ".resp.json",
    ".request.json",
)
LEGACY_RESPONSE_SUFFIXES: tuple[str, ...] = (
    ".response.json.txt",
    ".response.json",
    ".resp.json",
)

_DEFAULT_RELATIVE: dict[str, str] = {
    ENV_FARM_TICK_DIR: "runtime/farm_tick",
    ENV_TRANSFER_DIR: "runtime/transfer_bridge",
    ENV_SELL_DIR: "runtime/sell_bridge",
}

_SUBDIR_UNDER_ROOT: dict[str, str] = {
    ENV_FARM_TICK_DIR: "farm_tick",
    ENV_TRANSFER_DIR: "transfer_bridge",
    ENV_SELL_DIR: "sell_bridge",
}


def resolve_repo_relative(raw: str) -> Path:
    """Относительные пути — от корня репозитория, не от cwd процесса."""
    p = Path(raw.strip())
    if not p.is_absolute():
        p = REPO_ROOT / p
    return p


def get_unified_bridge_dir() -> Path | None:
    raw = os.getenv(ENV_FILE_BRIDGE_UNIFIED_DIR, "").strip()
    if not raw:
        return None
    p = resolve_repo_relative(raw)
    return p


def bridge_dir_from_env(var_name: str) -> Path:
    """
    Разрешает каталог для одного из мостов.
    Учитывает явную переменную, затем FILE_BRIDGE_ROOT, затем дефолт из _DEFAULT_RELATIVE.
    """
    explicit = os.getenv(var_name, "").strip()
    if explicit:
        return resolve_repo_relative(explicit)
    root = os.getenv(ENV_FILE_BRIDGE_ROOT, "").strip()
    if root and var_name in _SUBDIR_UNDER_ROOT:
        sub = _SUBDIR_UNDER_ROOT[var_name]
        return resolve_repo_relative(str(Path(root) / sub))
    return resolve_repo_relative(_DEFAULT_RELATIVE[var_name])


def bridge_directories_for_worker() -> tuple[Path, Path, Path]:
    """
    (farm_tick, transfer, sell). В unified-режиме все три пути совпадают.
    """
    uni = get_unified_bridge_dir()
    if uni is not None:
        return uni, uni, uni
    return (
        bridge_dir_from_env(ENV_FARM_TICK_DIR),
        bridge_dir_from_env(ENV_TRANSFER_DIR),
        bridge_dir_from_env(ENV_SELL_DIR),
    )


def iter_distinct_bridge_directories() -> list[Path]:
    """Каталоги для вотчеров / echo: без дублей при unified."""
    a, b, c = bridge_directories_for_worker()
    out: list[Path] = []
    for p in (a, b, c):
        rp = p.resolve()
        if rp not in out:
            out.append(rp)
    return out


# --- legacy (без тега в имени) ---


def legacy_bridge_task_id(name: str) -> str | None:
    for suf in LEGACY_BRIDGE_SUFFIXES:
        if name.endswith(suf):
            tid = name[: -len(suf)].strip()
            return tid or None
    return None


def is_legacy_bridge_file(name: str) -> bool:
    return legacy_bridge_task_id(name) is not None


def is_legacy_response_filename(name: str) -> bool:
    return any(name.endswith(s) for s in LEGACY_RESPONSE_SUFFIXES)


def find_legacy_response_file(bridge_dir: Path, task_id: str) -> Path | None:
    norm_tid = task_id.strip().lower()
    try:
        for suf in LEGACY_RESPONSE_SUFFIXES:
            p = bridge_dir / f"{task_id}{suf}"
            if p.is_file():
                return p.resolve()
        for p in bridge_dir.iterdir():
            if not p.is_file() or not is_legacy_response_filename(p.name):
                continue
            tid = legacy_bridge_task_id(p.name)
            if tid is not None and tid.strip().lower() == norm_tid:
                return p.resolve()
    except OSError:
        pass
    return None


def cleanup_legacy_orphans(bridge_dir: Path, current_task_id: str) -> list[str]:
    removed: list[str] = []
    cur = current_task_id.strip().lower()
    try:
        for p in list(bridge_dir.iterdir()):
            if not p.is_file():
                continue
            tid = legacy_bridge_task_id(p.name)
            if tid is not None and tid.strip().lower() != cur:
                try:
                    p.unlink(missing_ok=True)
                    removed.append(p.name)
                except OSError:
                    pass
    except OSError:
        pass
    return removed


def wipe_all_legacy_bridge_files(bridge_dir: Path) -> list[str]:
    removed: list[str] = []
    try:
        for p in list(bridge_dir.iterdir()):
            if not p.is_file() or not is_legacy_bridge_file(p.name):
                continue
            try:
                p.unlink(missing_ok=True)
                removed.append(p.name)
            except OSError:
                pass
    except OSError:
        pass
    return removed


# --- unified ({task_id}.{tag}.…) ---


def _unified_suffixes_for(tag: str) -> tuple[tuple[str, str], ...]:
    """(suffix, kind) kind = request|response"""
    return (
        (f".{tag}.request.json", "request"),
        (f".{tag}.response.json.txt", "response"),
        (f".{tag}.response.json", "response"),
        (f".{tag}.resp.json", "response"),
    )


def unified_bridge_task_id(name: str, tag: str) -> str | None:
    for suf, _kind in _unified_suffixes_for(tag):
        if name.endswith(suf):
            tid = name[: -len(suf)].strip()
            return tid or None
    return None


def is_unified_bridge_file(name: str, tag: str) -> bool:
    return unified_bridge_task_id(name, tag) is not None


def bridge_request_path(bridge_dir: Path, task_id: str, tag: str | None) -> Path:
    if tag:
        return bridge_dir / f"{task_id}.{tag}.request.json"
    return bridge_dir / f"{task_id}.request.json"


def bridge_canonical_response_name(task_id: str, tag: str | None) -> str:
    if tag:
        return f"{task_id}.{tag}.response.json"
    return f"{task_id}.response.json"


def _unified_response_suffixes(tag: str) -> tuple[str, ...]:
    return (
        f".{tag}.response.json.txt",
        f".{tag}.response.json",
        f".{tag}.resp.json",
    )


def find_unified_response_file(bridge_dir: Path, task_id: str, tag: str) -> Path | None:
    norm_tid = task_id.strip().lower()
    suffixes = _unified_response_suffixes(tag)
    try:
        for suf in suffixes:
            p = bridge_dir / f"{task_id}{suf}"
            if p.is_file():
                return p.resolve()
        for p in bridge_dir.iterdir():
            if not p.is_file():
                continue
            tid = unified_bridge_task_id(p.name, tag)
            if tid is None or tid.strip().lower() != norm_tid:
                continue
            if any(p.name.endswith(s) for s in suffixes):
                return p.resolve()
    except OSError:
        pass
    return None


def find_bridge_response_file(bridge_dir: Path, task_id: str, tag: str | None) -> Path | None:
    if tag:
        return find_unified_response_file(bridge_dir, task_id, tag)
    return find_legacy_response_file(bridge_dir, task_id)


def cleanup_unified_orphans(bridge_dir: Path, current_task_id: str, tag: str) -> list[str]:
    removed: list[str] = []
    cur = current_task_id.strip().lower()
    try:
        for p in list(bridge_dir.iterdir()):
            if not p.is_file():
                continue
            tid = unified_bridge_task_id(p.name, tag)
            if tid is not None and tid.strip().lower() != cur:
                try:
                    p.unlink(missing_ok=True)
                    removed.append(p.name)
                except OSError:
                    pass
    except OSError:
        pass
    return removed


def cleanup_bridge_orphans(bridge_dir: Path, current_task_id: str, tag: str | None) -> list[str]:
    if tag:
        return cleanup_unified_orphans(bridge_dir, current_task_id, tag)
    return cleanup_legacy_orphans(bridge_dir, current_task_id)


def wipe_unified_tag_files(bridge_dir: Path, tag: str) -> list[str]:
    removed: list[str] = []
    try:
        for p in list(bridge_dir.iterdir()):
            if not p.is_file() or not is_unified_bridge_file(p.name, tag):
                continue
            try:
                p.unlink(missing_ok=True)
                removed.append(p.name)
            except OSError:
                pass
    except OSError:
        pass
    return removed


def pre_exchange_remove_stale_responses(bridge_dir: Path, task_id: str, tag: str | None) -> None:
    """Перед новым request удаляет старые response для этого task_id (и тега)."""
    if tag:
        for suf in _unified_response_suffixes(tag):
            try:
                (bridge_dir / f"{task_id}{suf}").unlink(missing_ok=True)
            except OSError:
                pass
        return
    for suf in LEGACY_RESPONSE_SUFFIXES:
        try:
            (bridge_dir / f"{task_id}{suf}").unlink(missing_ok=True)
        except OSError:
            pass


def read_json_from_file_bytes(path: Path) -> Any:
    """
    JSON из файла; поддержка UTF-8/UTF-16 (Блокнот).
    """
    raw = path.read_bytes()
    if not raw.strip():
        raise ValueError("empty file")
    errs: list[str] = []
    for encoding in ("utf-8-sig", "utf-8", "utf-16-le", "utf-16-be", "utf-16", "cp1251"):
        try:
            text = raw.decode(encoding)
            return json.loads(text)
        except UnicodeDecodeError as e:
            errs.append(f"{encoding}: decode {e}")
        except json.JSONDecodeError as e:
            errs.append(f"{encoding}: json {e}")
    raise ValueError("; ".join(errs))


def echo_response_path_for_request(request_path: Path) -> Path | None:
    """
    По пути ``*.request.json`` возвращает путь для ``*.response.json`` (legacy или unified).
    """
    name = request_path.name
    if not name.endswith(".request.json"):
        return None
    stem = name[: -len(".request.json")]
    parent = request_path.parent
    if "." in stem:
        maybe_tag = stem.rsplit(".", 1)[-1]
        if maybe_tag in (TAG_FARM_TICK, TAG_TRANSFER, TAG_SELL):
            task_id = stem[: -(len(maybe_tag) + 1)]
            return parent / f"{task_id}.{maybe_tag}.response.json"
    return parent / f"{stem}.response.json"


__all__ = [
    "REPO_ROOT",
    "TAG_FARM_TICK",
    "TAG_TRANSFER",
    "TAG_SELL",
    "ENV_FARM_TICK_DIR",
    "ENV_TRANSFER_DIR",
    "ENV_SELL_DIR",
    "ENV_FILE_BRIDGE_ROOT",
    "ENV_FILE_BRIDGE_UNIFIED_DIR",
    "ENV_DIAGNOSTIC_SECONDS",
    "LEGACY_BRIDGE_SUFFIXES",
    "LEGACY_RESPONSE_SUFFIXES",
    "bridge_dir_from_env",
    "bridge_directories_for_worker",
    "get_unified_bridge_dir",
    "iter_distinct_bridge_directories",
    "legacy_bridge_task_id",
    "is_legacy_bridge_file",
    "is_legacy_response_filename",
    "find_legacy_response_file",
    "find_bridge_response_file",
    "bridge_request_path",
    "bridge_canonical_response_name",
    "cleanup_bridge_orphans",
    "cleanup_legacy_orphans",
    "wipe_all_legacy_bridge_files",
    "wipe_unified_tag_files",
    "pre_exchange_remove_stale_responses",
    "read_json_from_file_bytes",
    "echo_response_path_for_request",
]
