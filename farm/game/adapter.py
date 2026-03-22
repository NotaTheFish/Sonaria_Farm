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
from abc import ABC, abstractmethod
from collections import defaultdict
from pathlib import Path
from typing import Any

logger = logging.getLogger("farm.game.adapter")

# Корень репозитория: farm/game/adapter.py -> parents[2] == <repo>/
_REPO_ROOT = Path(__file__).resolve().parents[2]


def _bridge_dir_from_env(var_name: str, default_relative: str) -> Path:
    """
    Каталог для файлового моста. Относительные пути считаются от корня репозитория,
    а не от текущего cwd процесса (иначе воркер не находит файлы при запуске из другой папки).
    """
    raw = os.getenv(var_name, default_relative)
    p = Path(raw)
    if not p.is_absolute():
        p = _REPO_ROOT / p
    return p

from sqlalchemy import update

from farm.database import AsyncSessionMaker
from farm.models import Account, AccountStatus
from farm.task_queue import append_task_log, get_task_account

# Длинные суффиксы первыми (иначе .response.json «съест» .response.json.txt)
_FARM_TICK_BRIDGE_SUFFIXES: tuple[str, ...] = (
    ".response.json.txt",
    ".response.json",
    ".resp.json",
    ".request.json",
)
_FARM_TICK_RESPONSE_SUFFIXES: tuple[str, ...] = (
    ".response.json.txt",
    ".response.json",
    ".resp.json",
)


def _farm_tick_bridge_task_id(name: str) -> str | None:
    """UUID задачи из имени файла моста или None."""
    for suf in _FARM_TICK_BRIDGE_SUFFIXES:
        if name.endswith(suf):
            tid = name[: -len(suf)].strip()
            return tid or None
    return None


def _is_farm_tick_bridge_file(name: str) -> bool:
    return _farm_tick_bridge_task_id(name) is not None


def _is_farm_tick_response_filename(name: str) -> bool:
    return any(name.endswith(s) for s in _FARM_TICK_RESPONSE_SUFFIXES)


def _read_json_from_file_bytes(path: Path) -> Any:
    """
    JSON из файла, созданного в Блокноте и переименованного в .json:
    по умолчанию Notepad часто пишет UTF-16 LE, а мы раньше читали только utf-8.
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


def _find_farm_tick_response_file(farm_tick_dir: Path, task_id: str) -> Path | None:
    """
    Ищет файл ответа (канон и распространённые варианты на Windows).
    """
    norm_tid = task_id.strip().lower()
    try:
        for suf in _FARM_TICK_RESPONSE_SUFFIXES:
            p = farm_tick_dir / f"{task_id}{suf}"
            if p.is_file():
                return p.resolve()
        for p in farm_tick_dir.iterdir():
            if not p.is_file() or not _is_farm_tick_response_filename(p.name):
                continue
            tid = _farm_tick_bridge_task_id(p.name)
            if tid is not None and tid.strip().lower() == norm_tid:
                return p.resolve()
    except OSError:
        pass
    return None


def _cleanup_other_task_bridge_files(bridge_dir: Path, current_task_id: str) -> list[str]:
    """
    Удаляет файлы моста (*.request.json / *.response* / *.resp*) с другим task_id.
    """
    removed: list[str] = []
    cur = current_task_id.strip().lower()
    try:
        for p in list(bridge_dir.iterdir()):
            if not p.is_file():
                continue
            tid = _farm_tick_bridge_task_id(p.name)
            if tid is not None and tid.strip().lower() != cur:
                try:
                    p.unlink(missing_ok=True)
                    removed.append(p.name)
                except OSError as exc:
                    logger.warning("farm_tick orphan cleanup: cannot remove %s: %s", p, exc)
    except OSError as exc:
        logger.warning("bridge orphan cleanup: listdir %s: %s", bridge_dir, exc)
    return removed


def _wipe_all_farm_tick_bridge_files(farm_tick_dir: Path) -> list[str]:
    """Удаляет все файлы моста в каталоге (чистый старт воркера)."""
    removed: list[str] = []
    try:
        for p in list(farm_tick_dir.iterdir()):
            if not p.is_file() or not _is_farm_tick_bridge_file(p.name):
                continue
            try:
                p.unlink(missing_ok=True)
                removed.append(p.name)
            except OSError as exc:
                logger.warning("farm_tick wipe: cannot remove %s: %s", p, exc)
    except OSError as exc:
        logger.warning("farm_tick wipe: listdir %s: %s", farm_tick_dir, exc)
    return removed


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


class WindowsGameAdapter(GameAdapter):
    """
    Каркас под реальный запуск на Windows + Roblox + Creatures of Sonaria.

    Как подключать:
      1) В .env или переменных окружения: GAME_ADAPTER=windows
      2) Методы `login_and_check`, `farm_tick`, `transfer_to_storage`, `set_sell_price` используют файловые мосты; реальную игру делает твой процесс по JSON в `runtime/`.

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
        self.check_results_dir = _bridge_dir_from_env(
            "LOGIN_CHECK_RESULTS_DIR",
            "runtime/login_check_results",
        )
        self.check_timeout_seconds = int(os.getenv("LOGIN_CHECK_TIMEOUT_SECONDS", "180"))
        self.check_poll_seconds = float(os.getenv("LOGIN_CHECK_POLL_SECONDS", "1.0"))
        self.check_results_dir.mkdir(parents=True, exist_ok=True)

        self.farm_tick_dir = _bridge_dir_from_env("FARM_TICK_DIR", "runtime/farm_tick")
        self.farm_tick_timeout_seconds = int(os.getenv("FARM_TICK_TIMEOUT_SECONDS", "120"))
        self.farm_tick_poll_seconds = float(os.getenv("FARM_TICK_POLL_SECONDS", "1.0"))
        self.farm_tick_dir.mkdir(parents=True, exist_ok=True)
        self._farm_tick_seq: dict[str, int] = defaultdict(int)

        if os.getenv("FARM_TICK_CLEAN_ON_START", "").strip().lower() in ("1", "true", "yes"):
            wiped = _wipe_all_farm_tick_bridge_files(self.farm_tick_dir)
            if wiped:
                logger.info("FARM_TICK_CLEAN_ON_START: удалены файлы моста: %s", wiped)

        self.transfer_bridge_dir = _bridge_dir_from_env("TRANSFER_BRIDGE_DIR", "runtime/transfer_bridge")
        self.transfer_bridge_dir.mkdir(parents=True, exist_ok=True)
        self.transfer_bridge_timeout_seconds = int(
            os.getenv("TRANSFER_BRIDGE_TIMEOUT_SECONDS", os.getenv("FARM_TICK_TIMEOUT_SECONDS", "120"))
        )
        self.transfer_bridge_poll_seconds = float(
            os.getenv("TRANSFER_BRIDGE_POLL_SECONDS", os.getenv("FARM_TICK_POLL_SECONDS", "1.0"))
        )

        self.sell_bridge_dir = _bridge_dir_from_env("SELL_BRIDGE_DIR", "runtime/sell_bridge")
        self.sell_bridge_dir.mkdir(parents=True, exist_ok=True)
        self.sell_bridge_timeout_seconds = int(
            os.getenv("SELL_BRIDGE_TIMEOUT_SECONDS", os.getenv("FARM_TICK_TIMEOUT_SECONDS", "120"))
        )
        self.sell_bridge_poll_seconds = float(
            os.getenv("SELL_BRIDGE_POLL_SECONDS", os.getenv("FARM_TICK_POLL_SECONDS", "1.0"))
        )

        logger.info(
            "WindowsGameAdapter paths (absolute): LOGIN_CHECK=%s FARM_TICK=%s TRANSFER=%s SELL=%s",
            self.check_results_dir.resolve(),
            self.farm_tick_dir.resolve(),
            self.transfer_bridge_dir.resolve(),
            self.sell_bridge_dir.resolve(),
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

    async def _file_bridge_exchange(
        self,
        *,
        kind: str,
        bridge_dir: Path,
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
        request_path = bridge_dir / f"{task_id}.request.json"
        response_path = bridge_dir / f"{task_id}.response.json"

        removed_orphans = _cleanup_other_task_bridge_files(bridge_dir, task_id)
        for suf in _FARM_TICK_RESPONSE_SUFFIXES:
            try:
                (bridge_dir / f"{task_id}{suf}").unlink(missing_ok=True)
            except Exception:
                pass

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
        diagnostic_every = float(os.getenv("FARM_TICK_DIAGNOSTIC_SECONDS", "15"))
        response_found: Path | None = None
        while waited < timeout_seconds:
            response_found = _find_farm_tick_response_file(bridge_dir, task_id)
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
            parsed = _read_json_from_file_bytes(response_found)
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
            parsed = _read_json_from_file_bytes(result_path)
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

        1) Адаптер пишет: FARM_TICK_DIR/{task_id}.request.json
        2) Внешний процесс пишет ответ: FARM_TICK_DIR/{task_id}.response.json
           (алиас: {task_id}.resp.json — см. README)
        3) Адаптер читает ответ, опционально обновляет статус аккаунта, удаляет response.

        request.json:
          {
            "task_id": "...",
            "account_id": "...",
            "worker_id": "...",
            "death_points_target": 600,
            "tick_seq": 1
          }

        response.json:
          { "ok": true, "log": "optional", "death_points_current": 123,
            "account_status": null, "reason": null }
        или
          { "ok": false, "error": "..." }

        Если задан account_status (как в login_and_check) — обновляется accounts и воркер
        на следующей итерации увидит inactive.
        """
        self._farm_tick_seq[task_id] += 1
        tick_seq = self._farm_tick_seq[task_id]

        request_path = self.farm_tick_dir / f"{task_id}.request.json"
        response_path = self.farm_tick_dir / f"{task_id}.response.json"

        removed_orphans = _cleanup_other_task_bridge_files(self.farm_tick_dir, task_id)
        if removed_orphans:
            logger.info(
                "farm_tick: removed bridge files from other task_id(s): %s",
                removed_orphans,
            )

        for suf in _FARM_TICK_RESPONSE_SUFFIXES:
            _pre = self.farm_tick_dir / f"{task_id}{suf}"
            try:
                _pre.unlink(missing_ok=True)
            except Exception:
                pass

        request_payload = {
            "task_id": task_id,
            "account_id": account.id,
            "worker_id": worker_id,
            "death_points_target": death_points_target,
            "tick_seq": tick_seq,
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
        diagnostic_every = float(os.getenv("FARM_TICK_DIAGNOSTIC_SECONDS", "15"))
        response_found: Path | None = None
        while waited < self.farm_tick_timeout_seconds:
            response_found = _find_farm_tick_response_file(self.farm_tick_dir, task_id)
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

        if response_found.name.lower() != f"{task_id}.response.json".lower():
            await append_task_log(
                task_id=task_id,
                worker_id=worker_id,
                level="warning",
                message=(
                    f"[windows] farm_tick: ответ в файле {response_found.name!r} "
                    f"(каноническое имя: {task_id}.response.json; .resp.json — допустимый алиас)."
                ),
            )

        try:
            parsed = _read_json_from_file_bytes(response_found)
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
        data = await self._file_bridge_exchange(
            kind="transfer_to_storage",
            bridge_dir=self.transfer_bridge_dir,
            task_id=task_id,
            worker_id=worker_id,
            request_document={
                "bridge": "transfer_to_storage",
                "task_id": task_id,
                "worker_id": worker_id,
                "farmer_account_id": farmer_account.id,
                "payload": payload,
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
        data = await self._file_bridge_exchange(
            kind="set_sell_price",
            bridge_dir=self.sell_bridge_dir,
            task_id=task_id,
            worker_id=worker_id,
            request_document={
                "bridge": "set_sell_price",
                "task_id": task_id,
                "worker_id": worker_id,
                "storage_account_id": storage_account.id,
                "payload": payload,
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
