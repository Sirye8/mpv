# SPDX-License-Identifier: AGPL-3.0-or-later
"""Move panel settings between installs with the v2.0.0 database schema."""

import argparse
import json
import os
from pathlib import Path
import re
import sqlite3

FORMAT = "mpv-rich-presence-settings"
FORMAT_VERSION = 1
MAX_BYTES = 8 * 1024 * 1024
SOURCES = frozenset("auto anime movie-tv movie tv original local tmdb-movie tmdb-tv tvmaze wikidata musicbrainz acoustid stream".split())
POSITIONS = frozenset(f"{side}-{edge}" for side in ("top", "bottom") for edge in ("left", "center", "right"))
LAYOUTS = frozenset(f"{name}_layout" for name in "anime audio video movie tv recording stream".split())
APPEARANCE = {
    "preset": {"original", "clean", "detailed", "private"},
    "language": {"original", "english", "romaji", "native"},
    "numbering": {"relative", "original", "both"},
    "timer": {"progress", "remaining", "session", "off"},
    "compact": {"name", "details", "state"},
    **dict.fromkeys("group episode art badge tooltip button details state spoilers custom".split(), bool),
    **dict.fromkeys("headline details_template state_template large_url details_url state_url".split(), str),
    "buttons": lambda value: isinstance(value, list) and len(value) <= 2 and all(
        isinstance(button, dict) and set(button) == {"label", "url"}
        and all(isinstance(part, str) for part in button.values()) for button in value
    ),
}


def integer(low, high):
    return lambda value: type(value) is int and low <= value <= high


def strings(value):
    return isinstance(value, list) and all(isinstance(item, str) and "\0" not in item for item in value)


FIELDS = {
    "appearance": APPEARANCE,
    "exclude": {"blocked": bool},
    "privacy": {"mode": {"full", "hidden", "generic"}, "block_lookup": bool},
    "sources": {"source": SOURCES},
    "tracking": {
        "mode": {"off", "manual", "ask", "auto"}, "threshold": integer(1, 1440),
        "ask_timing": {"threshold", "end", "leave"}, "ask_position": POSITIONS,
        "ask_leave_position": POSITIONS | {"center"},
        "ask_timeout": lambda value: type(value) is int and (value == 0 or 5 <= value <= 300),
        **dict.fromkeys("without_sharing resume rewatch keep_pending coverage".split(), bool),
    },
    "panel": {"position": POSITIONS, "yield_idle_pin": bool},
    "panel-theme": {
        "preset": {"glass", "midnight", "graphite", "custom"},
        **dict.fromkeys(("background", "accent"), lambda value: isinstance(value, str) and bool(re.fullmatch("[0-9a-fA-F]{6}", value))),
        "opacity": integer(40, 100), "strength": integer(2, 32), "blur": bool,
        "method": {"classic", "gaussian", "box"},
    },
    "folder-filter": {"mode": {"disabled", "whitelist", "blacklist"}, "folders": strings},
    "recognition-options": dict.fromkeys(("tv_rules", "sidecar_metadata", "confirm_fingerprint"), bool),
    "match": {"id": integer(1, 2**31-1), "offset": integer(-9999, 9999),
              "episode": integer(1, 9999), "not_anime": bool},
    "watch-retention": {"months": integer(0, 120)},
    "save-scopes": {page: {"global", "folder", "file"} for page in
                    ("Appearance", "Recognition & folders", "Privacy & windows", "AniList")},
}
GLOBAL_ONLY = {"panel", "panel-theme", "folder-filter", "recognition-options", "watch-retention", "save-scopes"}
PIN_FIELDS = {
    **dict.fromkeys("provider kind name title match year numbering genre cover link artist album notation episode_title stream_title recording group_title release_date show_type".split(), str),
    "id": lambda value: type(value) in (int, str), "live": bool,
    **dict.fromkeys(("release", "release_group"), lambda value: value is None or isinstance(value, str)),
    "duration_ms": lambda value: value is None or (type(value) is int and 0 <= value < 2**31),
    "score": lambda value: type(value) in (int, float) and 0 <= value <= 1,
    "years": strings, "artist_names": strings,
    "release_candidates": list, "artwork": list, "covers": list,
}
TV_FIELDS = {"provider": {"tmdb-tv", "tvmaze"}, "hit": dict, "year": str, "dedicated": bool, "titles": strings}
CATEGORIES = frozenset(FIELDS) | {"provider", "tv-rule"}
PRIVATE_CATEGORIES = frozenset("account watch cycle history pending skipped entry cache rate job player auto response pin write-intent flight generation watch-completed watch-sweep watch-finished watch-eof cancel refresh search-request signin-request signin-cancel".split())


def data_path(path):
    path = Path(os.path.expandvars(path)).expanduser()
    if not path.is_absolute() or path.suffix.lower() != ".json":
        raise ValueError("Enter an absolute path to a .json file.")
    return path


def scope_valid(category, scope):
    if not isinstance(scope, str) or len(scope)>8192 or "\0" in scope:
        return False
    if category in GLOBAL_ONLY:
        return scope == "global"
    if category == "tv-rule":
        return scope.startswith("folder:") and len(scope)>7
    return scope == "global" or any(scope.startswith(prefix) and len(scope)>len(prefix)
                                   for prefix in ("file:", "folder:"))


def supports(rule, value):
    if isinstance(rule, (set, frozenset)):
        return isinstance(value, str) and value in rule
    return isinstance(value, rule) if isinstance(rule, type) else rule(value)


def split_fields(category, value, legacy):
    """Return usable fields and everything else for a later export."""
    active, unused = {}, {}
    rules = PIN_FIELDS if category == "provider" else FIELDS.get(category, {})
    for key, item in value.items():
        if category == "appearance" and key in LAYOUTS and isinstance(item, dict):
            valid, extra = split_fields("appearance", {k:v for k,v in item.items() if k not in LAYOUTS}, legacy)
            extra.update((k,v) for k,v in item.items() if k in LAYOUTS)
            if valid:
                active[key] = valid
            if extra:
                unused[key] = extra
        elif category == "tv-rule" and isinstance(item, dict):
            rule = {k:v for k,v in item.items() if k in TV_FIELDS and supports(TV_FIELDS[k],v)}
            hit, extra = split_fields("provider", rule.get("hit", {}), legacy)
            if (rule.keys() >= {"provider", "titles", "hit"} and hit.keys() >= {"id", "name"}
                and key == f"{rule['provider']}:{hit['id']}"):
                active[key] = dict(rule, hit=hit)
                extra_rule = {k:v for k,v in item.items() if k not in rule}
                if extra:
                    extra_rule["hit"] = extra
                if extra_rule:
                    unused[key] = extra_rule
            else:
                unused[key] = item
        elif key in rules and (item is not None or category=="provider") and supports(rules[key], item) and not (
            legacy and (category in ("watch-retention", "save-scopes") or
                        (category == "panel-theme" and (key == "method" or (key == "strength" and item > 12))))
        ):
            active[key] = item
        else:
            unused[key] = item
    return active, unused


def overlay(old, new):
    result = dict(old)
    for key, value in new.items():
        result[key] = overlay(result[key], value) if isinstance(result.get(key), dict) and isinstance(value, dict) else value
    return result


def _safe_provider(value):
    for key in ("cover", "link"):
        if value.get(key) and not re.fullmatch(r"https?://[^\s\\\"@]+",value[key]):
            return False
    return True


def export_settings(db, path):
    path = data_path(path)
    records = {}
    categories = sorted(CATEGORIES | {"settings-transfer"})
    placeholders = ",".join("?" for _ in categories)
    for category, scope, raw in db.execute(
        f"SELECT category,scope,value FROM records WHERE category IN ({placeholders}) ORDER BY category,scope",categories
    ):
        if category in CATEGORIES:
            records.setdefault((category, scope), {})["current"] = json.loads(raw)
        elif category == "settings-transfer":
            extra = json.loads(raw)
            key = (extra["category"], extra["scope"])
            records.setdefault(key, {})["extra"] = extra["value"]
    rows = [{"category": category, "scope": scope, "value": overlay(parts.get("extra", {}), parts.get("current", {}))}
            for (category, scope), parts in sorted(records.items())]
    payload = (json.dumps({"format": FORMAT, "version": FORMAT_VERSION, "records": rows},
                          ensure_ascii=False, indent=2, allow_nan=False) + "\n").encode("utf-8")
    if len(payload) > MAX_BYTES:
        raise ValueError("The settings export exceeds 8 MB.")
    try:
        with path.open("xb") as file:
            try:
                file.write(payload)
                file.flush()
            except OSError:
                file.close()
                path.unlink(missing_ok=True)
                raise
    except FileExistsError as exc:
        raise ValueError("That file already exists. Choose a new export path.") from exc
    return len(rows)


def import_settings(db, path, *, legacy=False):
    with data_path(path).open("rb") as file:
        payload = file.read(MAX_BYTES + 1)
    if len(payload) > MAX_BYTES:
        raise ValueError("The settings file exceeds 8 MB.")
    data = json.loads(payload.decode("utf-8-sig"))
    if (not isinstance(data, dict) or data.get("format") != FORMAT or type(data.get("version")) is not int
        or data["version"] != FORMAT_VERSION
        or not isinstance(data.get("records"), list)):
        raise ValueError("This file is not a supported Rich Presence settings export.")
    keys, rows, ignored = set(), [], []
    for row in data["records"]:
        if not isinstance(row, dict):
            raise ValueError("The export contains an invalid settings record.")
        category, scope, value = (row.get(key) for key in ("category", "scope", "value"))
        if (not isinstance(category, str) or not re.fullmatch(r"[a-z][a-z0-9-]{0,63}", category)
            or category in PRIVATE_CATEGORIES or category == "settings-transfer"
            or not scope_valid(category, scope) or not isinstance(value, dict) or (category,scope) in keys):
            raise ValueError("The export contains duplicate or invalid settings records.")
        keys.add((category,scope))
        active, unused = split_fields(category, value, legacy)
        if category == "provider" and not _safe_provider(active):
            raise ValueError("The export contains an invalid provider link.")
        if category == "tv-rule" and any(not _safe_provider(rule["hit"]) for rule in active.values()):
            raise ValueError("The export contains an invalid TV rule link.")
        if active:
            rows.append((category,scope,active))
        if unused:
            ignored.extend(f"{category}.{key}" for key in unused)
        db.execute("DELETE FROM records WHERE category='settings-transfer' AND scope=?", (json.dumps([category,scope]),))
        if unused:
            db.execute("INSERT INTO records VALUES ('settings-transfer',?,?)",
                       (json.dumps([category,scope]), json.dumps(dict(category=category,scope=scope,value=unused), allow_nan=False)))
    for category, scope, value in rows:
        db.execute("INSERT INTO records VALUES (?,?,?) ON CONFLICT(category,scope) DO UPDATE SET value=excluded.value",
                   (category,scope,json.dumps(value, allow_nan=False)))
    return len(rows), sorted(set(ignored))


def summary(result):
    count, ignored = result
    message = f"Imported {count} settings records."
    if ignored:
        message += " Preserved for a newer version: " + ", ".join(ignored[:12])
        message += f" and {len(ignored)-12} more." if len(ignored)>12 else "."
    return message


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("export", "import"))
    parser.add_argument("database", type=Path)
    parser.add_argument("file")
    parser.add_argument("--target", default="2.0.0",
                        help="installed version for import, defaults to 2.0.0")
    args = parser.parse_args()
    version = re.fullmatch(r"v?(\d+)\.(\d+)(?:\.(\d+))?", args.target)
    if not version or int(version[1]) < 2:
        parser.error("Specify a target version of 2.0.0 or later.")
    try:
        if not args.database.is_file():
            raise ValueError("Open and close mpv once to initialize its settings database.")
        with sqlite3.connect(args.database, timeout=4) as db:
            if args.operation == "export":
                print(f"Exported {export_settings(db,args.file)} settings records.")
            else:
                db.execute("BEGIN IMMEDIATE")
                print(summary(import_settings(db,args.file,legacy=int(version[1])==2 and int(version[2])==0)))
    except (OSError, sqlite3.Error, ValueError, RecursionError) as exc:
        parser.exit(1, f"{exc}\n")


if __name__ == "__main__":
    main()
