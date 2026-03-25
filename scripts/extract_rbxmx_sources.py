from __future__ import annotations

import html
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


@dataclass(frozen=True)
class ScriptItem:
    class_name: str
    name: str
    referent: str
    path: str
    source: str


def _safe_name(s: str) -> str:
    s = s.strip()
    s = re.sub(r"[^\w\-. ]+", "_", s, flags=re.UNICODE)
    s = re.sub(r"\s+", " ", s).strip()
    return s or "unnamed"


_ITEM_OPEN_RE = re.compile(r'<Item\s+class="([^"]+)"\s+referent="([^"]+)">')

_NAME_RE = re.compile(r'<string\s+name="Name">(.*?)</string>', re.DOTALL)
_SOURCE_RE = re.compile(r'<string\s+name="Source">(.*?)</string>', re.DOTALL)


def _find_first(pattern: re.Pattern[str], text: str) -> str | None:
    m = pattern.search(text)
    if not m:
        return None
    return m.group(1)


def _iter_items(text: str) -> Iterable[tuple[str, str, str, list[str]]]:
    """
    Stack parser that tracks open positions so we can slice inner blocks.
    Returns (class, referent, inner_text, name_stack).
    """
    # Remove invalid XML control chars that commonly break scanners.
    text = re.sub(r"[\x00-\x08\x0B\x0C\x0E-\x1F]", "", text)

    token_re = re.compile(r'<Item\s+class="[^"]+"\s+referent="[^"]+">|</Item>')
    stack: list[dict[str, Any]] = []  # {class, ref, open_end, name?}

    for m in token_re.finditer(text):
        tok = m.group(0)
        if tok.startswith("<Item"):
            om = _ITEM_OPEN_RE.match(tok)
            if not om:
                continue
            stack.append(
                {
                    "class": om.group(1),
                    "ref": om.group(2),
                    "open_end": m.end(),
                    "name": None,
                }
            )
            continue

        # </Item>
        if not stack:
            continue
        cur = stack.pop()
        inner = text[cur["open_end"] : m.start()]

        # Best-effort: grab Name from this item's Properties block.
        # Cache it for path stack building for future yields.
        nm = _find_first(_NAME_RE, inner)
        if nm is not None:
            cur["name"] = html.unescape(nm.strip())

        name_stack = []
        for it in stack + [cur]:
            n = it.get("name")
            if isinstance(n, str) and n.strip():
                name_stack.append(_safe_name(n))
            else:
                name_stack.append(_safe_name(str(it.get("class") or "Item")))

        yield str(cur["class"]), str(cur["ref"]), inner, name_stack


def _extract_source(inner: str) -> str | None:
    raw = _find_first(_SOURCE_RE, inner)
    if raw is None:
        return None
    # Roblox XML usually wraps script sources in <![CDATA[...]]> but sometimes escapes it.
    raw = raw.strip()
    raw = html.unescape(raw)
    if raw.startswith("<![CDATA[") and raw.endswith("]]>"):
        raw = raw[len("<![CDATA[") : -len("]]>")]
    return raw


def extract_scripts_from_rbxmx_text(text: str) -> list[ScriptItem]:
    out: list[ScriptItem] = []
    for class_name, referent, inner, name_stack in _iter_items(text):
        if class_name not in ("LocalScript", "ModuleScript", "Script"):
            continue
        nm = _find_first(_NAME_RE, inner)
        name = html.unescape(nm.strip()) if nm else class_name
        src = _extract_source(inner) or ""
        out.append(
            ScriptItem(
                class_name=class_name,
                name=name,
                referent=referent,
                path="/".join(name_stack),
                source=src,
            )
        )
    return out


def main() -> int:
    repo_root = Path(__file__).resolve().parents[1]
    src_path = repo_root / "Dex_roblox.txt"
    if not src_path.exists():
        raise SystemExit(f"Input not found: {src_path}")

    xml_text = src_path.read_text("utf-8", errors="replace")
    items = extract_scripts_from_rbxmx_text(xml_text)

    out_dir = repo_root / "external" / "dex_extracted"
    out_dir.mkdir(parents=True, exist_ok=True)

    index: list[dict[str, Any]] = []
    for i, it in enumerate(items):
        rel_name = f"{i:04d}_{_safe_name(it.name)}_{it.class_name}.lua"
        # Keep folder hint in filename (flattened) so duplicates are readable.
        hint = _safe_name(it.path.replace("/", "__"))
        rel_name = f"{i:04d}_{hint}_{it.class_name}.lua"
        (out_dir / rel_name).write_text(it.source, "utf-8")
        index.append(
            {
                "file": str(Path("external/dex_extracted") / rel_name),
                "class": it.class_name,
                "name": it.name,
                "referent": it.referent,
                "path": it.path,
                "source_len": len(it.source),
            }
        )

    (out_dir / "dex_index.json").write_text(json.dumps(index, ensure_ascii=False, indent=2), "utf-8")

    print(f"Extracted {len(items)} scripts to {out_dir}")
    print(f"Index: {out_dir / 'dex_index.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

