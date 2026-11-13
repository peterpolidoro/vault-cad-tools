"""What the import command shares: the layout's JSON writer, keys and hashes.

The layout (one directory per Vault file, a manifest per assembly) is
specified in the sibling `mechanical-cad` repository
(`docs/layout-specification.md`); Peter decided its choices on 2026-11-11.
`package_import.py` reads the exporter's package (`package.json`, `files/`)
into it and uses what is here.

Until 2026-11-13 this module also read the package of the earlier exporter
(`native-snapshot.json`, `scene.json`, `export-receipt.json`, `assets/`).
That exporter and its reader are removed; a project keeps the records of an
earlier export under `references/receipts/`.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
from pathlib import Path

from .project import ExchangeError

LAYOUT_SCHEMA_VERSION = 1
LOCK_SCHEMA_VERSION = 2
PRIMARY_STATES = (None, "[Primary]", "Primary")
KEY_MAX = 80
_DATA = re.compile(rb"ENDSEC\s*;\s*(DATA)\s*;")


def _sha(data):
    return hashlib.sha256(data).hexdigest()


def _read_json(path):
    raw = Path(path).read_bytes()
    if raw.startswith(b"\xef\xbb\xbf"):          # PowerShell writes a byte-order mark
        raw = raw[3:]
    try:
        return json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ExchangeError(f"{path}: {exc}") from None


def _scalar(v):
    return v is None or isinstance(v, (bool, int, float, str))


def _emit(v, level, out):
    pad, inner = "  " * level, "  " * (level + 1)
    if isinstance(v, dict):
        if not v:
            out.append("{}")
            return
        out.append("{\n")
        items = list(v.items())
        for i, (k, x) in enumerate(items):
            out.append(inner + json.dumps(k, ensure_ascii=False) + ": ")
            _emit(x, level + 1, out)
            out.append(",\n" if i < len(items) - 1 else "\n")
        out.append(pad + "}")
    elif isinstance(v, list):
        if not v:
            out.append("[]")
        elif all(_scalar(x) for x in v):
            out.append("[" + ", ".join(json.dumps(x, ensure_ascii=False) for x in v) + "]")
        else:
            out.append("[\n")
            for i, x in enumerate(v):
                out.append(inner)
                _emit(x, level + 1, out)
                out.append(",\n" if i < len(v) - 1 else "\n")
            out.append(pad + "]")
    else:
        out.append(json.dumps(v, ensure_ascii=False))


def write_json(path, obj):
    """Write a file of the layout: UTF-8 without a byte-order mark, LF, lists of scalars on one line."""
    _write_json(path, obj)


def _write_json(path, obj):
    """UTF-8 without a byte-order mark, LF, lists of scalars on one line."""
    out = []
    _emit(obj, 0, out)
    tmp = Path(str(path) + ".tmp")
    tmp.write_bytes(("".join(out) + "\n").encode("utf-8"))
    os.replace(tmp, path)


def data_sha256(data):
    """SHA-256 of a STEP file from its `DATA` keyword to the end of the file."""
    m = _DATA.search(data)
    if not m:
        raise ExchangeError("the STEP file has no DATA section after its header")
    return _sha(data[m.start(1):])


def slug(name):
    s = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    return s or "unnamed"


def _deviation(a, b):
    rot = max(abs(a[r][c] - b[r][c]) for r in range(3) for c in range(3))
    tra = max(abs(a[r][3] - b[r][3]) for r in range(3))
    return rot, tra


class _Keys:
    """Readable keys, unique across the repository."""

    def __init__(self):
        self.used = {}

    def assign(self, name, master_id, model_state, identity):
        base = slug(name)
        if len(base) > KEY_MAX - 12:                     # room for a master id or a counter after it
            base = base[:KEY_MAX - 12].rsplit("-", 1)[0]
        key = base
        if key in self.used and self.used[key] != identity:
            key = f"{base}-{slug(str(master_id))}" if master_id else None
            n = 2
            while key is None or (key in self.used and self.used[key] != identity):
                key = f"{base}-{n}"
                n += 1
        if model_state not in PRIMARY_STATES:
            key = f"{key}@{slug(model_state)}"
        self.used[key] = identity
        return key
