#!/usr/bin/env python3
"""
Авто-ответ на файловый мост (тест без инжектора).

Следит за каталогами:
  runtime/farm_tick
  runtime/transfer_bridge
  runtime/sell_bridge

Для каждого нового *.request.json создаёт рядом *.response.json с {"ok": true, "log": "..."}.

Запуск из корня репозитория:
  python scripts/file_bridge_echo.py

Осторожно: с активным фармом будет отвечать на каждый тик — для стресс-теста ок,
для ручной отладки лучше остановить echo или фарм.

Переменные окружения:
  BRIDGE_ECHO_POLL — интервал опроса сек (по умолчанию 0.5)
"""
from __future__ import annotations

import json
import os
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DIRS = [
    ROOT / "runtime" / "farm_tick",
    ROOT / "runtime" / "transfer_bridge",
    ROOT / "runtime" / "sell_bridge",
]
POLL = float(os.environ.get("BRIDGE_ECHO_POLL", "0.5"))


def main() -> None:
    print("file_bridge_echo: watching (Ctrl+C to stop)")
    for d in DIRS:
        print(" ", d.resolve())
    while True:
        for d in DIRS:
            if not d.is_dir():
                continue
            for req in sorted(d.glob("*.request.json")):
                name = req.name
                if not name.endswith(".request.json"):
                    continue
                task_id = name[: -len(".request.json")]
                resp = d / f"{task_id}.response.json"
                if resp.exists():
                    continue
                try:
                    body = json.loads(req.read_bytes())
                except Exception as exc:
                    body = {"_read_error": str(exc)}
                bridge = body.get("bridge") if isinstance(body, dict) else None
                out = {
                    "ok": True,
                    "log": f"file_bridge_echo auto ok (bridge={bridge!r})",
                }
                try:
                    resp.write_text(
                        json.dumps(out, ensure_ascii=False, indent=2),
                        encoding="utf-8",
                    )
                    print(f"+ {resp}")
                except OSError as exc:
                    print(f"! write failed {resp}: {exc}")
        time.sleep(POLL)


if __name__ == "__main__":
    main()
