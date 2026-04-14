"""
Адаптер игры (Windows + Roblox + Creatures of Sonaria).

Здесь не античит и не обходы — только контракты и заглушки.
Твоя реализация: подкласс `GameAdapter` или замена фабрики `get_game_adapter()`.

Воркер получает из БД только `account_id`; логин/пароль читаются внутри адаптера
из `farm.models.Account` (или через переданный объект `account`).
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import sys
import time
from abc import ABC, abstractmethod
from collections import defaultdict
from pathlib import Path
from typing import Any

from sqlalchemy import select, update

from farm.database import AsyncSessionMaker
from farm.game import file_bridge as fb
from farm.game import injector_backend as ib
from farm.game import injector_launcher as inj
from farm.game.script_params import (
    build_farm_tick_script_params,
    build_sell_script_params,
    build_transfer_script_params,
    build_universal_farm_tick_params,
    build_universal_script_params,
)
from farm.models import Account, AccountStatus
from farm.task_queue import append_task_log, get_task_account

logger = logging.getLogger("farm.game.adapter")


def _truthy_env(name: str) -> bool:
    return (os.getenv(name) or "").strip().lower() in {"1", "true", "yes", "on"}


def _dex_script_mode() -> int:
    """
    Режим Dex-скрипта:
      0 -> основной (DEX_LOADER_URL / payload)
      1 -> тестовый (test_dex/test_dex_command.txt)
    """
    raw = (os.getenv("DEX_SCRIPT_MODE") or os.getenv("DEX_TEST_MODE") or "0").strip()
    return 1 if raw == "1" else 0


def _load_test_dex_url() -> str | None:
    """Читает URL Dex из `test_dex/test_dex_command.txt`."""
    command_path = inj.REPO_ROOT / "test_dex" / "test_dex_command.txt"
    if not command_path.is_file():
        return None
    raw = command_path.read_text(encoding="utf-8", errors="ignore").strip()
    if not raw:
        return None
    if raw.lower().startswith(("http://", "https://")):
        return raw
    m = re.search(r'HttpGet\(\s*["\']([^"\']+)["\']', raw, flags=re.IGNORECASE)
    if not m:
        return None
    return m.group(1).strip()


class GameAdapter(ABC):
    """Контракт для всех игровых операций, вызываемых из воркера."""

    @abstractmethod
    async def login_and_check(self, *, task_id: str, worker_id: str, account: Account) -> None:
        """Проверка аккаунта: выставить корректный Account.status и banned_reason при необходимости."""

    @abstractmethod
    async def farm_tick(
        self,
        *,
        task_id: str,
        worker_id: str,
        account: Account,
        death_points_target: int,
    ) -> None:
        """Один шаг фарма (миссии, DP и т.д.). Вызывается в цикле до cancel."""

    @abstractmethod
    async def transfer_to_storage(
        self,
        *,
        task_id: str,
        worker_id: str,
        farmer_account: Account,
        payload: dict[str, Any],
    ) -> None:
        """Передача токенов фермер -> склад по данным payload (target_storage_account_id, batch, cd)."""

    @abstractmethod
    async def set_sell_price(
        self,
        *,
        task_id: str,
        worker_id: str,
        storage_account: Account,
        payload: dict[str, Any],
    ) -> None:
        """Торговый мир: выставить лоты по ranges и priority_tokens."""

    @abstractmethod
    async def universal_farm_tick(
        self,
        *,
        task_id: str,
        worker_id: str,
        account: Account,
        death_points_target: int,
        payload: dict[str, Any] | None = None,
    ) -> None:
        """Долгий фарм через ``universal_sonaria_bot.lua`` (задача ``universal_farm``)."""

    @abstractmethod
    async def universal_transfer(
        self,
        *,
        task_id: str,
        worker_id: str,
        farmer_account: Account,
        payload: dict[str, Any],
    ) -> None:
        """Перенос через универсальный скрипт (задача ``universal_transfer``)."""

    @abstractmethod
    async def universal_sell(
        self,
        *,
        task_id: str,
        worker_id: str,
        storage_account: Account,
        payload: dict[str, Any],
    ) -> None:
        """Продажи через универсальный скрипт (задача ``universal_sell``)."""

    @abstractmethod
    async def universal_inventory(
        self,
        *,
        task_id: str,
        worker_id: str,
        account: Account,
        payload: dict[str, Any],
    ) -> None:
        """Снимок инвентаря через универсальный скрипт (задача ``universal_inventory``)."""

    @abstractmethod
    async def universal_dex(
        self,
        *,
        task_id: str,
        worker_id: str,
        account: Account,
        payload: dict[str, Any],
    ) -> None:
        """Инжект Dex GUI через универсальный скрипт (задача ``universal_dex``)."""

    async def on_start_farm_cancel(self, *, task_id: str, worker_id: str, account: Account) -> None:
        """Опциональный хук: вызывается воркером при cancel start_farm."""
        return None


class WindowsGameAdapter(GameAdapter):
    """
    Каркас под реальный запуск на Windows + Roblox + Creatures of Sonaria.

    Как подключать:
      1) В .env или переменных окружения: GAME_ADAPTER=windows
      2) Методы `login_and_check`, `farm_tick`, `transfer_to_storage`, `set_sell_price` используют файловые мосты; реальную игру делает твой процесс по JSON в `runtime/` (или см. `FILE_BRIDGE_ROOT` / `FILE_BRIDGE_UNIFIED_DIR` в `farm.game.file_bridge`).

    Общий поток (наводки, без деталей клиента):
      - Храни сессию «один аккаунт = один процесс Roblox» в полях экземпляра
        (например self._roblox_pid, self._session_started_at).
      - Логин: взять account.login / account.password из объекта Account (уже из БД).
      - После каждого значимого шага пиши append_task_log(...) — так видно прогресс в task_logs.
      - При бане Roblox / неверном пароле / чекпоинте:
        обнови строку accounts (status + banned_reason) через AsyncSessionMaker + update(Account).
      - При трейдлоке в игре: status=cooldown или disabled + reason в banned_reason.
      - Не блокируй event loop надолго: тяжёлые ожидания выноси в asyncio.to_thread(...)
        или короткие sleep + проверка состояния.

    Полезные ключи в payload (уже задаёт контроллер):
      - start_farm: death_points_target, loop
      - transfer_to_storage: target_storage_account_id, batch_size, cooldown_seconds, ...
      - set_sell_price: ranges, priority_tokens, ...
    """

    def __init__(self) -> None:
        self.check_results_dir = fb.resolve_repo_relative(
            os.getenv("LOGIN_CHECK_RESULTS_DIR", "runtime/login_check_results")
        )
        self.check_timeout_seconds = int(os.getenv("LOGIN_CHECK_TIMEOUT_SECONDS", "180"))
        self.check_poll_seconds = float(os.getenv("LOGIN_CHECK_POLL_SECONDS", "1.0"))
        self.check_results_dir.mkdir(parents=True, exist_ok=True)

        self.farm_tick_dir, self.transfer_bridge_dir, self.sell_bridge_dir = fb.bridge_directories_for_worker()
        unified = fb.get_unified_bridge_dir() is not None
        self._bridge_tag_farm = fb.TAG_FARM_TICK if unified else None
        self._bridge_tag_transfer = fb.TAG_TRANSFER if unified else None
        self._bridge_tag_sell = fb.TAG_SELL if unified else None

        self.farm_tick_timeout_seconds = int(os.getenv("FARM_TICK_TIMEOUT_SECONDS", "120"))
        self.farm_tick_poll_seconds = float(os.getenv("FARM_TICK_POLL_SECONDS", "1.0"))
        self.farm_tick_dir.mkdir(parents=True, exist_ok=True)
        self._farm_tick_seq: dict[str, int] = defaultdict(int)

        if os.getenv("FARM_TICK_CLEAN_ON_START", "").strip().lower() in ("1", "true", "yes"):
            if self._bridge_tag_farm:
                wiped = fb.wipe_unified_tag_files(self.farm_tick_dir, fb.TAG_FARM_TICK)
            else:
                wiped = fb.wipe_all_legacy_bridge_files(self.farm_tick_dir)
            if wiped:
                logger.info("FARM_TICK_CLEAN_ON_START: удалены файлы моста: %s", wiped)

        self.transfer_bridge_dir.mkdir(parents=True, exist_ok=True)
        self.transfer_bridge_timeout_seconds = int(
            os.getenv("TRANSFER_BRIDGE_TIMEOUT_SECONDS", os.getenv("FARM_TICK_TIMEOUT_SECONDS", "120"))
        )
        self.transfer_bridge_poll_seconds = float(
            os.getenv("TRANSFER_BRIDGE_POLL_SECONDS", os.getenv("FARM_TICK_POLL_SECONDS", "1.0"))
        )

        self.sell_bridge_dir.mkdir(parents=True, exist_ok=True)
        self.sell_bridge_timeout_seconds = int(
            os.getenv("SELL_BRIDGE_TIMEOUT_SECONDS", os.getenv("FARM_TICK_TIMEOUT_SECONDS", "120"))
        )
        self.sell_bridge_poll_seconds = float(
            os.getenv("SELL_BRIDGE_POLL_SECONDS", os.getenv("FARM_TICK_POLL_SECONDS", "1.0"))
        )

        if unified:
            logger.info(
                "WindowsGameAdapter: FILE_BRIDGE_UNIFIED_DIR — один каталог %s "
                "(имена: {task_id}.farm_tick|transfer|sell.request.json)",
                self.farm_tick_dir.resolve(),
            )
        logger.info(
            "WindowsGameAdapter paths (absolute): LOGIN_CHECK=%s FARM_TICK=%s TRANSFER=%s SELL=%s",
            self.check_results_dir.resolve(),
            self.farm_tick_dir.resolve(),
            self.transfer_bridge_dir.resolve(),
            self.sell_bridge_dir.resolve(),
        )
        self._injector_launch_done = False
        self._injector_farm_proc_by_task: dict[str, asyncio.subprocess.Process] = {}
        self._universal_farm_proc_by_task: dict[str, asyncio.subprocess.Process] = {}
        self._universal_farm_started_tasks: set[str] = set()
        self._universal_farm_retry_after: dict[str, float] = {}

    def _injector_scripts_ready(self) -> bool:
        return ib.legacy_ready()

    def _universal_sonaria_ready(self) -> bool:
        """Скрипт Kimi: отдельный путь от legacy ``INJECTOR_SCRIPTS_DIR``."""
        return ib.universal_ready()

    @staticmethod
    def _parse_sonaria_stdout(text: str) -> dict[str, Any]:
        """
        Ожидает строку ``SONARIA_RESPONSE:{json}`` (см. universal_sonaria_bot.lua).
        Fallback: последняя строка с валидным JSON-объектом.
        """
        for line in text.splitlines():
            line = line.strip()
            if line.startswith("SONARIA_RESPONSE:"):
                raw = line[len("SONARIA_RESPONSE:") :].strip()
                parsed = json.loads(raw)
                if not isinstance(parsed, dict):
                    raise RuntimeError("SONARIA_RESPONSE JSON must be an object")
                return parsed
        for line in reversed(text.splitlines()):
            s = line.strip()
            if not s:
                continue
            try:
                parsed = json.loads(s)
            except json.JSONDecodeError:
                continue
            if isinstance(parsed, dict):
                return parsed
        raise RuntimeError("no SONARIA_RESPONSE line and no JSON object in injector stdout")

    async def _run_universal_script(
        self,
        *,
        task_id: str,
        worker_id: str,
        params: dict[str, Any],
        wait_for_exit: bool,
        timeout_seconds: int | None = None,
    ) -> dict[str, Any] | None:
        script_path = inj.resolve_universal_sonaria_script_path()
        if not script_path and not ib.is_mock_backend():
            raise RuntimeError(
                "Универсальный скрипт не настроен: задай INJECTOR_ENABLED=1, INJECTOR_PATH "
                "и положи universal_sonaria_bot.lua (или INJECTOR_UNIVERSAL_SCRIPT_PATH)."
            )
        if ib.is_mock_backend():
            await append_task_log(
                task_id=task_id,
                worker_id=worker_id,
                message=f"[injector:mock] universal command={params.get('command')} wait={wait_for_exit}",
            )
            if wait_for_exit:
                return {"ok": True, "log": "mock backend"}
            # Нужен живой процесс для long-running farm/cancel.
            proc = await asyncio.create_subprocess_exec(
                sys.executable, "-c", "import time; time.sleep(3600)"
            )
            self._universal_farm_proc_by_task[task_id] = proc
            return None
        assert script_path is not None
        await self._hook_injector_if_configured(
            task_id=task_id,
            worker_id=worker_id,
            bridge="universal_script",
        )
        inject_path = ib.materialize_universal_script_bundle(
            task_id=task_id,
            source_path=script_path,
            params=params,
        )
        argv, pid = ib.build_argv(script_path=inject_path, params=params)
        await append_task_log(
            task_id=task_id,
            worker_id=worker_id,
            message=(
                "[universal_sonaria] запуск (Kimi), pid=%s wait_for_exit=%s script=%s"
                % (pid, wait_for_exit, str(inject_path))
            ),
        )

        if wait_for_exit:
            try:
                stdout, stderr, returncode = await ib.run_wait(
                    argv=argv,
                    timeout_seconds=(
                        timeout_seconds if timeout_seconds is not None else inj.injector_timeout_seconds()
                    ),
                )
            except TimeoutError as exc:
                raise RuntimeError("universal_sonaria inject timeout") from exc
                if returncode not in (0, None):
                    out_text = stdout.decode("utf-8", errors="replace").strip()
                    err_text = stderr.decode("utf-8", errors="replace").strip()
                    details = []
                    if err_text:
                        details.append(f"stderr={err_text!r}")
                    if out_text:
                        details.append(f"stdout={out_text!r}")
                    tail = " ".join(details) if details else "no stdout/stderr"
                    raise RuntimeError(f"universal_sonaria failed rc={returncode}: {tail}")
            out_text = stdout.decode("utf-8", errors="replace")
            if not out_text.strip():
                return None
            return self._parse_sonaria_stdout(out_text)

        # VD Executor CLI режим одноразовый: полезнее дождаться завершения и забрать диагностику.
        if inj.is_vd_executor_path(inj.injector_executable()):
            try:
                stdout, stderr, returncode = await ib.run_wait(
                    argv=argv,
                    timeout_seconds=max(90, inj.injector_timeout_seconds()),
                )
            except TimeoutError:
                await append_task_log(
                    task_id=task_id,
                    worker_id=worker_id,
                    level="warning",
                    message="[universal_sonaria] VD CLI timeout",
                )
                raise RuntimeError("vd_executor_cli_timeout")
            out_text = stdout.decode("utf-8", errors="replace").strip()
            err_text = stderr.decode("utf-8", errors="replace").strip()
            await append_task_log(
                task_id=task_id,
                worker_id=worker_id,
                level="warning" if returncode not in (0, None) else "info",
                message=(
                    "[universal_sonaria] VD CLI rc=%s%s%s"
                    % (
                        returncode,
                        (f" stdout={out_text[:400]!r}" if out_text else ""),
                        (f" stderr={err_text[:400]!r}" if err_text else ""),
                    )
                ),
            )
            if returncode not in (0, None):
                raise RuntimeError(f"vd_executor_cli_failed rc={returncode}")
            return None

        proc = await ib.run_detached(argv=argv)
        self._universal_farm_proc_by_task[task_id] = proc
        await asyncio.sleep(0.7)
        if proc.returncode is not None:
            err_tail = ""
            try:
                if proc.stderr is not None:
                    err_bytes = await proc.stderr.read()
                    if err_bytes:
                        err_tail = err_bytes.decode("utf-8", errors="replace").strip()
            except Exception:
                err_tail = ""
            await append_task_log(
                task_id=task_id,
                worker_id=worker_id,
                level="warning",
                message=(
                    "[universal_sonaria] injector exited quickly rc=%s%s"
                    % (
                        proc.returncode,
                        (f" stderr={err_tail[:500]!r}" if err_tail else ""),
                    )
                ),
            )
        return None

    async def _run_injector_script(
        self,
        *,
        task_id: str,
        worker_id: str,
        script_name: str,
        params: dict[str, Any],
        wait_for_exit: bool,
        timeout_seconds: int | None = None,
    ) -> dict[str, Any] | None:
        script_path = inj.resolve_injector_script_path(script_name)
        if not script_path and not ib.is_mock_backend():
            raise RuntimeError(
                f"Не найден Lua-скрипт: {script_name!r}. Проверь INJECTOR_SCRIPTS_DIR и имя файла."
            )
        if ib.is_mock_backend():
            await append_task_log(
                task_id=task_id,
                worker_id=worker_id,
                message=f"[injector:mock] script={script_name} wait={wait_for_exit}",
            )
            if wait_for_exit:
                return {"ok": True, "log": f"mock {script_name} done"}
            proc = await asyncio.create_subprocess_exec(
                sys.executable, "-c", "import time; time.sleep(3600)"
            )
            self._injector_farm_proc_by_task[task_id] = proc
            return None
        assert script_path is not None
        argv, pid = ib.build_argv(script_path=script_path, params=params)
        await append_task_log(
            task_id=task_id,
            worker_id=worker_id,
            message=f"[injector] run script={script_name} pid={pid} wait={wait_for_exit}",
        )

        if wait_for_exit:
            try:
                stdout, stderr, returncode = await ib.run_wait(
                    argv=argv,
                    timeout_seconds=(
                        timeout_seconds if timeout_seconds is not None else inj.injector_timeout_seconds()
                    ),
                )
            except TimeoutError as exc:
                raise RuntimeError(f"injector timeout for script={script_name}") from exc
                if returncode not in (0, None):
                    out_text = stdout.decode("utf-8", errors="replace").strip()
                    err_text = stderr.decode("utf-8", errors="replace").strip()
                    details = []
                    if err_text:
                        details.append(f"stderr={err_text!r}")
                    if out_text:
                        details.append(f"stdout={out_text!r}")
                    tail = " ".join(details) if details else "no stdout/stderr"
                    raise RuntimeError(
                        f"injector script failed rc={returncode} script={script_name}: {tail}"
                    )
            out_text = stdout.decode("utf-8", errors="replace").strip()
            if not out_text:
                return None
            last_line = out_text.splitlines()[-1].strip()
            if not last_line:
                return None
            try:
                parsed = json.loads(last_line)
            except json.JSONDecodeError as exc:
                raise RuntimeError(
                    f"script {script_name} returned non-JSON stdout tail: {last_line[:300]!r}"
                ) from exc
            if not isinstance(parsed, dict):
                raise RuntimeError(f"script {script_name} expected JSON object, got {type(parsed).__name__}")
            return parsed

        proc = await ib.run_detached(argv=argv)
        self._injector_farm_proc_by_task[task_id] = proc
        return None

    async def _farm_tick_via_injector(
        self,
        *,
        task_id: str,
        worker_id: str,
        account: Account,
        death_points_target: int,
    ) -> None:
        existing = self._injector_farm_proc_by_task.get(task_id)
        if existing is None:
            params = build_farm_tick_script_params(
                account=account,
                death_points_target=death_points_target,
                tick_seq=1,
            )
            params["role"] = account.role or "farmer"
            await self._run_injector_script(
                task_id=task_id,
                worker_id=worker_id,
                script_name="farm.lua",
                params=params,
                wait_for_exit=False,
            )
            await append_task_log(
                task_id=task_id,
                worker_id=worker_id,
                message="[injector] farm.lua started (long-running).",
            )
            return
        if existing.returncode is not None:
            self._injector_farm_proc_by_task.pop(task_id, None)
            if existing.returncode == 0:
                await append_task_log(
                    task_id=task_id,
                    worker_id=worker_id,
                    level="warning",
                    message="[injector] farm.lua exited gracefully before cancel.",
                )
                return
            raise RuntimeError(f"farm.lua exited unexpectedly rc={existing.returncode}")

    async def on_start_farm_cancel(self, *, task_id: str, worker_id: str, account: Account) -> None:
        self._universal_farm_started_tasks.discard(task_id)
        self._universal_farm_retry_after.pop(task_id, None)
        proc = self._injector_farm_proc_by_task.pop(task_id, None)
        if proc and proc.returncode is None:
            proc.terminate()
            try:
                await asyncio.wait_for(proc.wait(), timeout=5)
            except TimeoutError:
                proc.kill()
                await proc.wait()
            await append_task_log(
                task_id=task_id,
                worker_id=worker_id,
                message=f"[injector] farm.lua process terminated for account_id={account.id}",
            )

        proc_u = self._universal_farm_proc_by_task.pop(task_id, None)
        if proc_u and proc_u.returncode is None:
            proc_u.terminate()
            try:
                await asyncio.wait_for(proc_u.wait(), timeout=5)
            except TimeoutError:
                proc_u.kill()
                await proc_u.wait()
            await append_task_log(
                task_id=task_id,
                worker_id=worker_id,
                message=f"[universal_sonaria] universal farm process terminated for account_id={account.id}",
            )

    @staticmethod
    def _normalize_status(value: str | None) -> str | None:
        if not value:
            return None
        norm = value.strip().lower()
        allowed = {
            AccountStatus.ACTIVE.value,
            AccountStatus.BANNED.value,
            AccountStatus.INVALID_CREDENTIALS.value,
            AccountStatus.CHECKPOINT.value,
            AccountStatus.DISABLED.value,
            AccountStatus.COOLDOWN.value,
        }
        return norm if norm in allowed else None

    async def _set_account_status(
        self,
        *,
        account_id: str,
        status: str,
        reason: str | None = None,
    ) -> None:
        async with AsyncSessionMaker() as session:
            await session.execute(
                update(Account)
                .where(Account.id == account_id)
                .values(
                    status=status,
                    banned_reason=reason,
                )
            )
            await session.commit()

    async def _storage_login_for_payload(self, target_storage_account_id: str | None) -> str | None:
        if not target_storage_account_id:
            return None
        async with AsyncSessionMaker() as session:
            acc = await session.scalar(select(Account).where(Account.id == target_storage_account_id))
            return acc.login if acc else None

    async def _file_bridge_exchange(
        self,
        *,
        kind: str,
        bridge_dir: Path,
        bridge_tag: str | None,
        task_id: str,
        worker_id: str,
        request_document: dict[str, Any],
        timeout_seconds: int,
        poll_seconds: float,
    ) -> dict[str, Any]:
        """
        Один обмен request.json → response.json (как farm_tick, без tick_seq).
        """
        bridge_dir.mkdir(parents=True, exist_ok=True)
        request_path = fb.bridge_request_path(bridge_dir, task_id, bridge_tag)
        response_name = fb.bridge_canonical_response_name(task_id, bridge_tag)
        response_path = bridge_dir / response_name

        removed_orphans = fb.cleanup_bridge_orphans(bridge_dir, task_id, bridge_tag)
        fb.pre_exchange_remove_stale_responses(bridge_dir, task_id, bridge_tag)

        request_path.write_text(
            json.dumps(request_document, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        orphan_note = (
            f" Очищены чужие файлы моста: {', '.join(removed_orphans)}."
            if removed_orphans
            else ""
        )
        await append_task_log(
            task_id=task_id,
            worker_id=worker_id,
            message=(
                f"[windows] {kind}: request → {request_path.resolve()}, "
                f"жду response → {response_path.resolve()}.{orphan_note}"
            ),
        )

        waited = 0.0
        last_diagnostic = -1e9
        diagnostic_every = float(os.getenv(fb.ENV_DIAGNOSTIC_SECONDS, "15"))
        response_found: Path | None = None
        while waited < timeout_seconds:
            response_found = fb.find_bridge_response_file(bridge_dir, task_id, bridge_tag)
            if response_found is not None:
                break
            if waited - last_diagnostic >= diagnostic_every:
                logger.info(
                    "%s: жду ответ уже %.0f с → %s",
                    kind,
                    waited,
                    response_path.resolve(),
                )
                try:
                    all_names = sorted(p.name for p in bridge_dir.iterdir() if p.is_file())
                    logger.info("%s: файлы в %s: %r", kind, bridge_dir.resolve(), all_names)
                except OSError as exc:
                    logger.warning("%s: listdir: %s", kind, exc)
                last_diagnostic = waited
            await asyncio.sleep(poll_seconds)
            waited += poll_seconds

        if response_found is None:
            try:
                request_path.unlink(missing_ok=True)
            except OSError as exc:
                logger.warning("%s timeout: cannot delete request %s: %s", kind, request_path, exc)
            raise RuntimeError(
                f"{kind}: response not found. Expected {response_path.resolve()} "
                f"within {timeout_seconds}s."
            )

        try:
            parsed = fb.read_json_from_file_bytes(response_found)
            if not isinstance(parsed, dict):
                raise ValueError(f"ожидался JSON-объект, получен {type(parsed).__name__}")
            data = parsed
        except Exception as exc:
            raise RuntimeError(f"{kind}: invalid response JSON: {exc}") from exc
        finally:
            try:
                response_found.unlink(missing_ok=True)
            except OSError as exc:
                logger.warning("%s: could not delete response %s: %s", kind, response_found, exc)
            try:
                request_path.unlink(missing_ok=True)
            except OSError as exc:
                logger.warning("%s: could not delete request %s: %s", kind, request_path, exc)

        if not data.get("ok", False):
            err = data.get("error") or f"{kind} failed"
            raise RuntimeError(str(err))
        return data

    async def _apply_optional_bridge_account_status(
        self,
        *,
        data: dict[str, Any],
        account: Account,
        task_id: str,
        worker_id: str,
        kind: str,
    ) -> None:
        acc_status = self._normalize_status(
            str(data["account_status"]) if data.get("account_status") is not None else None
        )
        reason = data.get("reason")
        if acc_status:
            await self._set_account_status(
                account_id=account.id,
                status=acc_status,
                reason=reason if isinstance(reason, str) else None,
            )
        log_msg = data.get("log")
        tail = f" {log_msg}" if log_msg else ""
        await append_task_log(
            task_id=task_id,
            worker_id=worker_id,
            message=f"[windows] {kind} ok.{tail}",
        )

    async def _maybe_save_inventory_from_response(
        self,
        data: dict[str, Any],
        account_id: str,
    ) -> None:
        """Если в ответе моста есть объект inventory — сохраняем снимок в accounts."""
        inv = data.get("inventory")
        if not isinstance(inv, dict) or not inv:
            return
        from farm.account_inventory import save_account_inventory_snapshot

        await save_account_inventory_snapshot(account_id, inv)

    async def _poll_token_report(self, account_id: str) -> None:
        """
        Проверяет файл токенов смерти, записанный Lua через writefile().
        Файл лежит в workspace эксплойта: <injector_dir>/sonaria_death_tokens/<account_id>.json
        """
        exe = inj.injector_executable()
        if not exe:
            return
        from farm.game.script_params import _token_report_relative_path

        rel = _token_report_relative_path(account_id)
        token_file = exe.parent / rel
        if not token_file.is_file():
            return
        try:
            raw = token_file.read_text(encoding="utf-8").strip()
            if not raw:
                return
            tokens = json.loads(raw)
            if not isinstance(tokens, dict) or not tokens:
                return
            from farm.account_inventory import accumulate_earned_tokens

            await accumulate_earned_tokens(account_id, tokens)
            token_file.unlink(missing_ok=True)
            logger.info("token report consumed for account %s: %s", account_id, tokens)
        except (json.JSONDecodeError, OSError) as exc:
            logger.debug("token report read error for %s: %s", account_id, exc)

    async def _hook_injector_if_configured(
        self,
        *,
        task_id: str,
        worker_id: str,
        bridge: str,
    ) -> None:
        """См. farm.game.injector_launcher и INJECTOR_LAUNCH_WHEN.

        bridge ``universal_script`` — перед запуском universal_sonaria_bot.lua (sell/transfer/…),
        чтобы при INJECTOR_LAUNCH_WHEN=windows_adapter_init поднять VD Executor, если ещё не
        вызывали login_and_check / farm_tick.
        """
        if not inj.injector_enabled_flag():
            return
        when = inj.injector_launch_when()
        if when == "never":
            return
        if when == "every_farm_tick":
            if bridge != "farm_tick":
                return
            if inj.is_vd_executor_path(inj.injector_executable()):
                logger.warning(
                    "INJECTOR_LAUNCH_WHEN=every_farm_tick пропущен: INJECTOR_PATH — VD Executor.exe "
                    "(не запускаем лаунчер на каждый тик). Используй Dex (универсал) или never."
                )
                return
            await inj.launch_injector_subprocess(
                task_id=task_id,
                worker_id=worker_id,
                trigger="every_farm_tick",
            )
            return
        if when == "windows_adapter_init":
            if self._injector_launch_done:
                return
            self._injector_launch_done = True
            if inj.is_vd_executor_path(inj.injector_executable()):
                # По умолчанию prelaunch включён (можно выключить INJECTOR_VD_PRELAUNCH=0).
                prelaunch_raw = (os.getenv("INJECTOR_VD_PRELAUNCH") or "1").strip().lower()
                if prelaunch_raw not in {"0", "false", "no", "off"}:
                    await inj.launch_vd_executor_detached(
                        task_id=task_id,
                        worker_id=worker_id,
                        trigger="windows_adapter_init",
                    )
                else:
                    await append_task_log(
                        task_id=task_id,
                        worker_id=worker_id,
                        message="[vd_executor] windows_adapter_init skipped by INJECTOR_VD_PRELAUNCH=0.",
                    )
            else:
                await inj.launch_injector_subprocess(
                    task_id=task_id,
                    worker_id=worker_id,
                    trigger="windows_adapter_init",
                )

    async def login_and_check(self, *, task_id: str, worker_id: str, account: Account) -> None:
        """
        Рабочий базовый контракт:
        - внешний процесс проверки должен записать JSON-файл результата в LOGIN_CHECK_RESULTS_DIR
        - имя файла: <account_id>.json
        - формат:
            {
              "status": "active|banned|invalid_credentials|checkpoint|disabled|cooldown",
              "reason": "optional text"
            }
        """
        result_path = (self.check_results_dir / f"{account.id}.json").resolve()

        await append_task_log(
            task_id=task_id,
            worker_id=worker_id,
            message=(
                f"[windows] login_and_check started for account_id={account.id}. "
                f"Waiting result file (absolute): {result_path}"
            ),
        )

        await self._hook_injector_if_configured(
            task_id=task_id,
            worker_id=worker_id,
            bridge="login_and_check",
        )

        waited = 0.0
        while waited < self.check_timeout_seconds:
            if result_path.exists():
                break
            await asyncio.sleep(self.check_poll_seconds)
            waited += self.check_poll_seconds

        if not result_path.exists():
            # Ничего не меняем в БД, задача упадет и пойдет в retry/ручную проверку.
            raise RuntimeError(
                "login_and_check result not found. "
                f"Expected file: {result_path} within {self.check_timeout_seconds}s"
            )

        try:
            parsed = fb.read_json_from_file_bytes(result_path)
            if not isinstance(parsed, dict):
                raise ValueError(f"ожидался JSON-объект, получен {type(parsed).__name__}")
            data = parsed
        except Exception as exc:
            raise RuntimeError(f"Invalid login_and_check result JSON: {exc}") from exc
        finally:
            # Одноразовый файл результата (на Windows может не удалиться, если файл открыт в редакторе)
            try:
                result_path.unlink(missing_ok=True)
            except OSError as exc:
                logger.warning(
                    "login_and_check: could not delete result file %s: %s",
                    result_path,
                    exc,
                )
                await append_task_log(
                    task_id=task_id,
                    worker_id=worker_id,
                    level="warning",
                    message=(
                        f"[windows] login_and_check: не удалось удалить файл результата "
                        f"(закройте его в редакторе): {result_path} — {exc}"
                    ),
                )

        status = self._normalize_status(str(data.get("status", "")))
        reason = data.get("reason")

        if not status:
            raise RuntimeError(
                "login_and_check result has unknown status. "
                "Allowed: active,banned,invalid_credentials,checkpoint,disabled,cooldown"
            )

        await self._set_account_status(
            account_id=account.id,
            status=status,
            reason=reason if isinstance(reason, str) else None,
        )

        await append_task_log(
            task_id=task_id,
            worker_id=worker_id,
            message=(
                f"[windows] login_and_check done for account_id={account.id}: "
                f"status={status}, reason={reason!r}"
            ),
        )

    async def farm_tick(
        self,
        *,
        task_id: str,
        worker_id: str,
        account: Account,
        death_points_target: int,
    ) -> None:
        """
        Один шаг цикла фарма через файловый мост (как login_and_check):

        1) Адаптер пишет request в FARM_TICK_DIR (или FILE_BRIDGE_UNIFIED_DIR):
           ``{task_id}.request.json`` либо ``{task_id}.farm_tick.request.json`` — см. ``farm.game.file_bridge``.
        2) Внешний процесс пишет ответ с тем же префиксом/тегом
           (алиас: ``.resp.json`` / ``.response.json.txt`` — см. README).
        3) Адаптер читает ответ, опционально обновляет статус аккаунта, удаляет response.

        request.json:
          {
            "bridge": "farm_tick",
            "task_id": "...",
            "account_id": "...",
            "worker_id": "...",
            "death_points_target": 600,
            "tick_seq": 1,
            "script_params": { ... }   # см. docs/SCRIPT_PARAMS_AND_LUA.md
          }

        response.json:
          { "ok": true, "log": "optional", "death_points_current": 123,
            "account_status": null, "reason": null,
            "inventory": { "Revive Token": 1, ... } }
        или
          { "ok": false, "error": "..." }

        Если задан account_status (как в login_and_check) — обновляется accounts и воркер
        на следующей итерации увидит inactive.
        """
        self._farm_tick_seq[task_id] += 1
        tick_seq = self._farm_tick_seq[task_id]

        await self._hook_injector_if_configured(
            task_id=task_id,
            worker_id=worker_id,
            bridge="farm_tick",
        )

        if self._injector_scripts_ready():
            await self._farm_tick_via_injector(
                task_id=task_id,
                worker_id=worker_id,
                account=account,
                death_points_target=death_points_target,
            )
            return

        tag = self._bridge_tag_farm
        request_path = fb.bridge_request_path(self.farm_tick_dir, task_id, tag)
        response_path = self.farm_tick_dir / fb.bridge_canonical_response_name(task_id, tag)

        removed_orphans = fb.cleanup_bridge_orphans(self.farm_tick_dir, task_id, tag)
        if removed_orphans:
            logger.info(
                "farm_tick: removed bridge files from other task_id(s): %s",
                removed_orphans,
            )

        fb.pre_exchange_remove_stale_responses(self.farm_tick_dir, task_id, tag)

        script_params = build_farm_tick_script_params(
            account=account,
            death_points_target=death_points_target,
            tick_seq=tick_seq,
        )
        request_payload = {
            "bridge": "farm_tick",
            "task_id": task_id,
            "account_id": account.id,
            "worker_id": worker_id,
            "death_points_target": death_points_target,
            "tick_seq": tick_seq,
            "script_params": script_params,
        }
        request_path.write_text(
            json.dumps(request_payload, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )

        orphan_note = (
            f" Очищены файлы других задач: {', '.join(removed_orphans)}."
            if removed_orphans
            else ""
        )
        await append_task_log(
            task_id=task_id,
            worker_id=worker_id,
            message=(
                f"[windows] farm_tick tick_seq={tick_seq} account_id={account.id} "
                f"DP_target={death_points_target}. "
                f"Wrote request: {request_path.resolve()}, "
                f"waiting response: {response_path.resolve()}.{orphan_note}"
            ),
        )

        waited = 0.0
        last_diagnostic = -1e9
        diagnostic_every = float(os.getenv(fb.ENV_DIAGNOSTIC_SECONDS, "15"))
        response_found: Path | None = None
        while waited < self.farm_tick_timeout_seconds:
            response_found = fb.find_bridge_response_file(self.farm_tick_dir, task_id, tag)
            if response_found is not None:
                break
            if waited - last_diagnostic >= diagnostic_every:
                expect = response_path.resolve()
                logger.info(
                    "farm_tick tick_seq=%s: жду ответ уже %.0f с. Ожидаемый файл: %s",
                    tick_seq,
                    waited,
                    expect,
                )
                try:
                    all_names = sorted(p.name for p in self.farm_tick_dir.iterdir() if p.is_file())
                    related = [n for n in all_names if task_id in n]
                    logger.info(
                        "farm_tick: полный список файлов в %s: %r",
                        self.farm_tick_dir.resolve(),
                        all_names,
                    )
                    if related:
                        logger.info("farm_tick: имена, содержащие этот task_id: %r", related)
                    else:
                        logger.info(
                            "farm_tick: ни один файл не содержит этот task_id — "
                            "часто ответ сохраняют не в эту папку (нужен runtime\\farm_tick).",
                        )
                except OSError as exc:
                    logger.warning("farm_tick: не удалось прочитать каталог: %s", exc)
                last_diagnostic = waited
            await asyncio.sleep(self.farm_tick_poll_seconds)
            waited += self.farm_tick_poll_seconds

        if response_found is None:
            # Убираем request, иначе в папке висит «старый» тик после таймаута.
            try:
                request_path.unlink(missing_ok=True)
            except OSError as exc:
                logger.warning("farm_tick timeout: could not delete request %s: %s", request_path, exc)
            hint = ""
            try:
                parent = response_path.parent
                if parent.exists():
                    similar = sorted(p.name for p in parent.iterdir() if p.is_file())
                    if similar:
                        hint = f" Сейчас в каталоге файлы: {similar!r}."
            except OSError:
                pass
            raise RuntimeError(
                "farm_tick response not found. "
                f"Ожидался файл (точное имя): {response_path.resolve()} "
                f"в течение {self.farm_tick_timeout_seconds}s.{hint} "
                "Проверь: воркер запущен и в task_logs есть строка «Wrote request» для этого тика; "
                "файл ответа не открыт в редакторе; путь совпадает с логом. "
                "На Windows иногда лишнее расширение .txt (включи отображение расширений)."
            )

        canonical = fb.bridge_canonical_response_name(task_id, tag)
        if response_found.name.lower() != canonical.lower():
            await append_task_log(
                task_id=task_id,
                worker_id=worker_id,
                level="warning",
                message=(
                    f"[windows] farm_tick: ответ в файле {response_found.name!r} "
                    f"(каноническое имя: {canonical}; .resp.json — допустимый алиас)."
                ),
            )

        try:
            parsed = fb.read_json_from_file_bytes(response_found)
            if not isinstance(parsed, dict):
                raise ValueError(f"ожидался JSON-объект {{}}, получен {type(parsed).__name__}")
            data = parsed
        except Exception as exc:
            raise RuntimeError(f"Invalid farm_tick response JSON: {exc}") from exc
        finally:
            try:
                response_found.unlink(missing_ok=True)
            except OSError as exc:
                logger.warning("farm_tick: could not delete response %s: %s", response_found, exc)
                await append_task_log(
                    task_id=task_id,
                    worker_id=worker_id,
                    level="warning",
                    message=f"[windows] farm_tick: не удалось удалить response (закрой файл в редакторе): {response_found} — {exc}",
                )
            try:
                request_path.unlink(missing_ok=True)
            except OSError as exc:
                logger.warning("farm_tick: could not delete request %s: %s", request_path, exc)
                await append_task_log(
                    task_id=task_id,
                    worker_id=worker_id,
                    level="warning",
                    message=f"[windows] farm_tick: не удалось удалить request: {request_path} — {exc}",
                )

        if not data.get("ok", False):
            err = data.get("error") or "farm_tick failed"
            raise RuntimeError(str(err))

        acc_status = self._normalize_status(
            str(data["account_status"]) if data.get("account_status") is not None else None
        )
        reason = data.get("reason")
        if acc_status:
            await self._set_account_status(
                account_id=account.id,
                status=acc_status,
                reason=reason if isinstance(reason, str) else None,
            )

        await self._maybe_save_inventory_from_response(data, account.id)

        log_msg = data.get("log")
        dp_cur = data.get("death_points_current")
        extra = f" death_points_current={dp_cur}" if dp_cur is not None else ""
        await append_task_log(
            task_id=task_id,
            worker_id=worker_id,
            message=f"[windows] farm_tick ok tick_seq={tick_seq}{extra}. {log_msg or ''}",
        )

    async def transfer_to_storage(
        self,
        *,
        task_id: str,
        worker_id: str,
        farmer_account: Account,
        payload: dict[str, Any],
    ) -> None:
        """
        Файловый мост: TRANSFER_BRIDGE_DIR / {task_id}.request.json → .response.json
        request: bridge, task_id, worker_id, farmer_account_id, payload (как в задаче бота).
        response: { "ok": true|false, "error"?, "log"?, "account_status"?, "reason"? }
        """
        await self._hook_injector_if_configured(
            task_id=task_id,
            worker_id=worker_id,
            bridge="transfer_to_storage",
        )
        storage_login = await self._storage_login_for_payload(
            str(payload.get("target_storage_account_id") or "") or None
        )
        script_params = build_transfer_script_params(
            farmer=farmer_account,
            payload=payload,
            target_storage_login=storage_login,
        )
        script_params["role"] = farmer_account.role or "farmer"
        if self._injector_scripts_ready():
            data = await self._run_injector_script(
                task_id=task_id,
                worker_id=worker_id,
                script_name="transfer.lua",
                params=script_params,
                wait_for_exit=True,
                timeout_seconds=self.transfer_bridge_timeout_seconds,
            )
            if data is None:
                data = {"ok": True, "log": "transfer.lua completed without JSON response"}
            if not data.get("ok", False):
                raise RuntimeError(str(data.get("error") or "transfer_to_storage failed"))
            await self._apply_optional_bridge_account_status(
                data=data,
                account=farmer_account,
                task_id=task_id,
                worker_id=worker_id,
                kind="transfer_to_storage",
            )
            await self._maybe_save_inventory_from_response(data, farmer_account.id)
            return
        data = await self._file_bridge_exchange(
            kind="transfer_to_storage",
            bridge_dir=self.transfer_bridge_dir,
            bridge_tag=self._bridge_tag_transfer,
            task_id=task_id,
            worker_id=worker_id,
            request_document={
                "bridge": "transfer_to_storage",
                "task_id": task_id,
                "worker_id": worker_id,
                "farmer_account_id": farmer_account.id,
                "payload": payload,
                "script_params": script_params,
            },
            timeout_seconds=self.transfer_bridge_timeout_seconds,
            poll_seconds=self.transfer_bridge_poll_seconds,
        )
        await self._apply_optional_bridge_account_status(
            data=data,
            account=farmer_account,
            task_id=task_id,
            worker_id=worker_id,
            kind="transfer_to_storage",
        )
        await self._maybe_save_inventory_from_response(data, farmer_account.id)

    async def set_sell_price(
        self,
        *,
        task_id: str,
        worker_id: str,
        storage_account: Account,
        payload: dict[str, Any],
    ) -> None:
        """
        Файловый мост: SELL_BRIDGE_DIR / {task_id}.request.json → .response.json
        request: bridge, task_id, worker_id, storage_account_id, payload.
        response: как у transfer_to_storage.
        """
        await self._hook_injector_if_configured(
            task_id=task_id,
            worker_id=worker_id,
            bridge="set_sell_price",
        )
        script_params = build_sell_script_params(storage=storage_account, payload=payload)
        script_params["role"] = storage_account.role or "storage"
        if self._injector_scripts_ready():
            data = await self._run_injector_script(
                task_id=task_id,
                worker_id=worker_id,
                script_name="sell.lua",
                params=script_params,
                wait_for_exit=True,
                timeout_seconds=self.sell_bridge_timeout_seconds,
            )
            if data is None:
                data = {"ok": True, "log": "sell.lua completed without JSON response"}
            if not data.get("ok", False):
                raise RuntimeError(str(data.get("error") or "set_sell_price failed"))
            await self._apply_optional_bridge_account_status(
                data=data,
                account=storage_account,
                task_id=task_id,
                worker_id=worker_id,
                kind="set_sell_price",
            )
            await self._maybe_save_inventory_from_response(data, storage_account.id)
            return
        data = await self._file_bridge_exchange(
            kind="set_sell_price",
            bridge_dir=self.sell_bridge_dir,
            bridge_tag=self._bridge_tag_sell,
            task_id=task_id,
            worker_id=worker_id,
            request_document={
                "bridge": "set_sell_price",
                "task_id": task_id,
                "worker_id": worker_id,
                "storage_account_id": storage_account.id,
                "payload": payload,
                "script_params": script_params,
            },
            timeout_seconds=self.sell_bridge_timeout_seconds,
            poll_seconds=self.sell_bridge_poll_seconds,
        )
        await self._apply_optional_bridge_account_status(
            data=data,
            account=storage_account,
            task_id=task_id,
            worker_id=worker_id,
            kind="set_sell_price",
        )
        await self._maybe_save_inventory_from_response(data, storage_account.id)

    async def universal_farm_tick(
        self,
        *,
        task_id: str,
        worker_id: str,
        account: Account,
        death_points_target: int,
        payload: dict[str, Any] | None = None,
    ) -> None:
        if not self._universal_sonaria_ready():
            raise RuntimeError(
                "Универсальный скрипт Kimi недоступен. Нужны INJECTOR_ENABLED=1, INJECTOR_PATH "
                "и файл universal_sonaria_bot.lua (см. INJECTOR_UNIVERSAL_SCRIPT_PATH)."
            )
        now = time.monotonic()
        retry_after = self._universal_farm_retry_after.get(task_id, 0.0)
        if now < retry_after:
            await asyncio.sleep(0.7)
            return
        existing = self._universal_farm_proc_by_task.get(task_id)
        if task_id not in self._universal_farm_started_tasks:
            params = build_universal_farm_tick_params(
                account=account,
                death_points_target=death_points_target,
                task_payload=payload,
            )
            try:
                await self._run_universal_script(
                    task_id=task_id,
                    worker_id=worker_id,
                    params=params,
                    wait_for_exit=False,
                )
            except RuntimeError as exc:
                await append_task_log(
                    task_id=task_id,
                    worker_id=worker_id,
                    level="warning",
                    message=f"[universal_sonaria] inject attempt failed: {exc}. retry in 8s",
                )
                self._universal_farm_started_tasks.discard(task_id)
                self._universal_farm_retry_after[task_id] = time.monotonic() + 8.0
                await asyncio.sleep(0.7)
                return
            self._universal_farm_started_tasks.add(task_id)
            await append_task_log(
                task_id=task_id,
                worker_id=worker_id,
                message="[universal_sonaria] command=farm started (one-shot inject).",
            )
            await asyncio.sleep(0.7)
            return
        # Poll for token report file from exploit workspace
        await self._poll_token_report(account.id)

        if existing is None:
            # Для one-shot CLI-инжекторов процесс может сразу завершиться с rc=0 —
            # это нормально: Lua уже выполняется в клиенте Roblox.
            await asyncio.sleep(0.7)
            return
        if existing.returncode is not None:
            self._universal_farm_proc_by_task.pop(task_id, None)
            if existing.returncode == 0:
                await append_task_log(
                    task_id=task_id,
                    worker_id=worker_id,
                    level="info",
                    message="[universal_sonaria] injector process exited rc=0 (expected for one-shot CLI).",
                )
                await asyncio.sleep(0.7)
                return
            await append_task_log(
                task_id=task_id,
                worker_id=worker_id,
                level="warning",
                message=(
                    "[universal_sonaria] injector process exited rc=%s; retry in 8s"
                    % (existing.returncode,)
                ),
            )
            # Не валим задачу: attach/inject может не пройти на коротком окне.
            self._universal_farm_started_tasks.discard(task_id)
            self._universal_farm_retry_after[task_id] = time.monotonic() + 8.0
            await asyncio.sleep(0.7)
            return
        await asyncio.sleep(0.7)

    async def universal_transfer(
        self,
        *,
        task_id: str,
        worker_id: str,
        farmer_account: Account,
        payload: dict[str, Any],
    ) -> None:
        if not self._universal_sonaria_ready():
            raise RuntimeError("universal_sonaria: не настроен скрипт (см. universal_farm_tick).")
        storage_login = await self._storage_login_for_payload(
            str(payload.get("target_storage_account_id") or "") or None
        )
        extra = build_transfer_script_params(
            farmer=farmer_account,
            payload=payload,
            target_storage_login=storage_login,
        )
        params = build_universal_script_params(
            farmer_account,
            "transfer",
            extra_params=extra,
        )
        data = await self._run_universal_script(
            task_id=task_id,
            worker_id=worker_id,
            params=params,
            wait_for_exit=True,
            timeout_seconds=self.transfer_bridge_timeout_seconds,
        )
        if data is None:
            data = {"ok": True, "log": "universal transfer: no stdout response"}
        if not data.get("ok", False):
            raise RuntimeError(str(data.get("error") or "universal_transfer failed"))
        await self._apply_optional_bridge_account_status(
            data=data,
            account=farmer_account,
            task_id=task_id,
            worker_id=worker_id,
            kind="universal_transfer",
        )
        await self._maybe_save_inventory_from_response(data, farmer_account.id)

    async def universal_sell(
        self,
        *,
        task_id: str,
        worker_id: str,
        storage_account: Account,
        payload: dict[str, Any],
    ) -> None:
        if not self._universal_sonaria_ready():
            raise RuntimeError("universal_sonaria: не настроен скрипт (см. universal_farm_tick).")
        extra = build_sell_script_params(storage=storage_account, payload=payload)
        params = build_universal_script_params(
            storage_account,
            "sell",
            extra_params=extra,
        )
        data = await self._run_universal_script(
            task_id=task_id,
            worker_id=worker_id,
            params=params,
            wait_for_exit=True,
            timeout_seconds=self.sell_bridge_timeout_seconds,
        )
        if data is None:
            data = {"ok": True, "log": "universal sell: no stdout response"}
        if not data.get("ok", False):
            raise RuntimeError(str(data.get("error") or "universal_sell failed"))
        await self._apply_optional_bridge_account_status(
            data=data,
            account=storage_account,
            task_id=task_id,
            worker_id=worker_id,
            kind="universal_sell",
        )
        await self._maybe_save_inventory_from_response(data, storage_account.id)

    async def universal_inventory(
        self,
        *,
        task_id: str,
        worker_id: str,
        account: Account,
        payload: dict[str, Any],
    ) -> None:
        if not self._universal_sonaria_ready():
            raise RuntimeError("universal_sonaria: не настроен скрипт (см. universal_farm_tick).")
        inv_timeout = int(
            os.getenv(
                "UNIVERSAL_INVENTORY_TIMEOUT_SECONDS",
                os.getenv("FARM_TICK_TIMEOUT_SECONDS", "120"),
            )
        )
        params = build_universal_script_params(
            account,
            "inventory",
            extra_params=dict(payload or {}),
        )
        data = await self._run_universal_script(
            task_id=task_id,
            worker_id=worker_id,
            params=params,
            wait_for_exit=True,
            timeout_seconds=inv_timeout,
        )
        if data is None:
            data = {"ok": True, "log": "universal inventory: no stdout response"}
        if not data.get("ok", False):
            raise RuntimeError(str(data.get("error") or "universal_inventory failed"))
        await self._maybe_save_inventory_from_response(data, account.id)

    async def universal_dex(
        self,
        *,
        task_id: str,
        worker_id: str,
        account: Account,
        payload: dict[str, Any],
    ) -> None:
        launcher_exe = inj.injector_executable()
        if not launcher_exe:
            hint = inj.vd_executor_default_exe()
            extra = (
                f' Пример: INJECTOR_PATH="{hint}"' if hint else " Задай INJECTOR_PATH в .env."
            )
            raise RuntimeError(
                "Dex (универсал): не настроен INJECTOR_PATH (исполняемый файл не найден)."
                + extra
            )

        # VD Executor — не CLI ``pid script.lua JSON``: только отдельный старт процесса.
        if inj.injector_dex_uses_vd_executor_start_only():
            if not inj.injector_enabled_flag():
                raise RuntimeError("Dex (универсал): включи INJECTOR_ENABLED=1 для запуска VD Executor.")
            await inj.launch_vd_executor_detached(
                task_id=task_id,
                worker_id=worker_id,
                trigger="universal_dex",
            )
            await append_task_log(
                task_id=task_id,
                worker_id=worker_id,
                message="[vd_executor] Dex (универсал): лаунчер запущен; дальше attach/скрипты — вручную в окне VD Executor.",
            )
            return

        if not self._universal_sonaria_ready():
            raise RuntimeError("universal_sonaria: не настроен скрипт (см. universal_farm_tick).")
        script_path = inj.resolve_universal_sonaria_script_path()
        if not script_path and not ib.is_mock_backend():
            raise RuntimeError(
                "Универсальный скрипт не настроен: задай INJECTOR_UNIVERSAL_SCRIPT_PATH "
                "или положи external/injector_scripts/universal_sonaria_bot.lua."
            )
        assert script_path is not None
        asset_path = (payload or {}).get("dex_asset_path") or os.getenv("DEX_MODEL_PATH", "Dex_roblox.rbxm")
        dex_url = (payload or {}).get("dex_url") or os.getenv("DEX_LOADER_URL")
        if _dex_script_mode() == 1:
            test_dex_url = _load_test_dex_url()
            if not test_dex_url:
                raise RuntimeError(
                    "DEX_SCRIPT_MODE=1, но не удалось прочитать URL из "
                    "test_dex/test_dex_command.txt."
                )
            dex_url = test_dex_url
            await append_task_log(
                task_id=task_id,
                worker_id=worker_id,
                message="[universal_sonaria] dex mode=1: используем test_dex/test_dex_command.txt",
            )
        params = build_universal_script_params(
            account,
            "dex",
            extra_params={
                "dex_asset_path": str(asset_path),
                **({"dex_url": str(dex_url)} if dex_url else {}),
            },
        )
        inject_path = ib.materialize_universal_script_bundle(
            task_id=task_id,
            source_path=script_path,
            params=params,
        )
        argv, pid = ib.build_argv(
            script_path=inject_path,
            params=params,
            injector_executable=launcher_exe,
        )
        await append_task_log(
            task_id=task_id,
            worker_id=worker_id,
            message=f"[universal_sonaria] dex запуск лаунчером INJECTOR_PATH, pid={pid}",
        )
        try:
            stdout, stderr, returncode = await ib.run_wait(argv=argv, timeout_seconds=60)
        except TimeoutError as exc:
            raise RuntimeError("Dex (универсал): таймаут запуска лаунчера (INJECTOR_PATH)") from exc
        if returncode not in (0, None):
            out_text = stdout.decode("utf-8", errors="replace").strip()
            err_text = stderr.decode("utf-8", errors="replace").strip()
            details = []
            if err_text:
                details.append(f"stderr={err_text!r}")
            if out_text:
                details.append(f"stdout={out_text!r}")
            tail = " ".join(details) if details else "no stdout/stderr"
            raise RuntimeError(f"Dex (универсал) failed rc={returncode}: {tail}")
        out_text = stdout.decode("utf-8", errors="replace")
        data = self._parse_sonaria_stdout(out_text) if out_text.strip() else None
        if data is None:
            data = {"ok": True, "log": "dex: no stdout response"}
        if not data.get("ok", False):
            raise RuntimeError(str(data.get("error") or "universal_dex failed"))
        # Защита от ложного "ok": лаунчер мог вернуть успех только факта инжекта DLL,
        # без выполнения universal_sonaria_bot.lua (и тогда Dex в игре не появляется).
        message = str(data.get("message") or "")
        if message.strip().lower() == "dll injected successfully.":
            raise RuntimeError(
                "Dex не был выполнен: лаунчер сообщил только DLL injected successfully. "
                "Нужен ответ SONARIA_RESPONSE от universal_sonaria_bot.lua."
            )
        log_text = str(data.get("log") or "")
        if not log_text.strip():
            raise RuntimeError(
                "Dex не подтверждён: в ответе нет поля 'log' от universal_sonaria_bot.lua."
            )
        await append_task_log(
            task_id=task_id,
            worker_id=worker_id,
            message=f"[universal_sonaria] dex ok. {data.get('log') or ''}",
        )


class StubGameAdapter(GameAdapter):
    """
    Заглушка для разработки без Roblox.
    В проде на Windows замени на свою реализацию.
    """

    async def login_and_check(self, *, task_id: str, worker_id: str, account: Account) -> None:
        await append_task_log(
            task_id=task_id,
            worker_id=worker_id,
            message=f"[stub] login_and_check account_id={account.id}",
        )
        if account.status == AccountStatus.NEW.value:
            async with AsyncSessionMaker() as session:
                await session.execute(
                    update(Account)
                    .where(Account.id == account.id)
                    .values(status=AccountStatus.ACTIVE.value)
                )
                await session.commit()
        await append_task_log(
            task_id=task_id,
            worker_id=worker_id,
            message=f"[stub] account {account.id} -> active (replace with real check)",
        )

    async def farm_tick(
        self,
        *,
        task_id: str,
        worker_id: str,
        account: Account,
        death_points_target: int,
    ) -> None:
        await append_task_log(
            task_id=task_id,
            worker_id=worker_id,
            message=(
                f"[stub] farm_tick account_id={account.id} "
                f"death_points_target={death_points_target}"
            ),
        )
        if os.getenv("STUB_INVENTORY_DEMO", "").strip().lower() in ("1", "true", "yes"):
            from farm.account_inventory import save_account_inventory_snapshot

            await save_account_inventory_snapshot(
                account.id,
                {
                    "Revive Token": 0,
                    "Max Growth Token": 0,
                    "_demo": "STUB_INVENTORY_DEMO=1 в .env — убери в проде",
                },
            )
        await asyncio.sleep(1)

    async def transfer_to_storage(
        self,
        *,
        task_id: str,
        worker_id: str,
        farmer_account: Account,
        payload: dict[str, Any],
    ) -> None:
        await append_task_log(
            task_id=task_id,
            worker_id=worker_id,
            message=f"[stub] transfer_to_storage farmer={farmer_account.id} payload={json.dumps(payload)}",
        )
        await asyncio.sleep(1)

    async def set_sell_price(
        self,
        *,
        task_id: str,
        worker_id: str,
        storage_account: Account,
        payload: dict[str, Any],
    ) -> None:
        await append_task_log(
            task_id=task_id,
            worker_id=worker_id,
            message=f"[stub] set_sell_price storage={storage_account.id} payload keys={list(payload)}",
        )
        await asyncio.sleep(1)

    async def universal_farm_tick(
        self,
        *,
        task_id: str,
        worker_id: str,
        account: Account,
        death_points_target: int,
        payload: dict[str, Any] | None = None,
    ) -> None:
        await append_task_log(
            task_id=task_id,
            worker_id=worker_id,
            message=f"[stub] universal_farm_tick account_id={account.id} dp={death_points_target} "
            f"payload_keys={list((payload or {}).keys())}",
        )
        await asyncio.sleep(1)

    async def universal_transfer(
        self,
        *,
        task_id: str,
        worker_id: str,
        farmer_account: Account,
        payload: dict[str, Any],
    ) -> None:
        await append_task_log(
            task_id=task_id,
            worker_id=worker_id,
            message=f"[stub] universal_transfer farmer={farmer_account.id}",
        )
        await asyncio.sleep(1)

    async def universal_sell(
        self,
        *,
        task_id: str,
        worker_id: str,
        storage_account: Account,
        payload: dict[str, Any],
    ) -> None:
        await append_task_log(
            task_id=task_id,
            worker_id=worker_id,
            message=f"[stub] universal_sell storage={storage_account.id}",
        )
        await asyncio.sleep(1)

    async def universal_inventory(
        self,
        *,
        task_id: str,
        worker_id: str,
        account: Account,
        payload: dict[str, Any],
    ) -> None:
        await append_task_log(
            task_id=task_id,
            worker_id=worker_id,
            message=f"[stub] universal_inventory account={account.id} payload_keys={list(payload)}",
        )
        await asyncio.sleep(1)

    async def universal_dex(
        self,
        *,
        task_id: str,
        worker_id: str,
        account: Account,
        payload: dict[str, Any],
    ) -> None:
        await append_task_log(
            task_id=task_id,
            worker_id=worker_id,
            message=f"[stub] universal_dex account={account.id} payload_keys={list(payload)}",
        )
        await asyncio.sleep(1)


def get_game_adapter() -> GameAdapter:
    """
    - GAME_ADAPTER=stub (по умолчанию) — без Roblox, для проверки очереди.
    - GAME_ADAPTER=windows — файловые мосты login_check / farm_tick / transfer / sell; игровую логику делает внешний процесс.
    """
    name = (os.getenv("GAME_ADAPTER") or "stub").strip().lower()
    if name == "stub":
        return StubGameAdapter()
    if name == "windows":
        return WindowsGameAdapter()
    raise RuntimeError(
        f"Unknown GAME_ADAPTER={name!r}. "
        "Use stub, windows, or register a new name in farm.game.adapter.get_game_adapter()."
    )


async def load_account_or_raise(task_id: str) -> Account:
    account = await get_task_account(task_id=task_id)
    if not account:
        raise RuntimeError("Task has no account")
    return account
