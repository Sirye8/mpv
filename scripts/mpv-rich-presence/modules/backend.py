# SPDX-License-Identifier: AGPL-3.0-or-later
"""Optional off-thread account and metadata worker, one per interested player."""

import contextlib
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import sqlite3
import sys
import threading
import time

# mpv starts Python in isolated mode. Load siblings only from this installation.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from account import (
    AccountError,
    EntryChanged,
    SessionExpired,
    Vault,
    authorize,
    graphql,
    read_entry,
    save_progress,
)
from providers import (
    candidates,
    details,
    fingerprint,
    fingerprint_match,
    match_name,
    music_art,
    music_art_sources,
    music_artists,
    music_names,
    music_title,
    musicbrainz_album,
    musicbrainz_match,
    tmdb_request,
    video_query,
    generic_clip,
)

PUBLIC_EXCHANGE = "https://mpv-anilist-login.si-based.workers.dev"
MUSIC_RETRY_DELAYS = (5, 15)
VIDEO_RETRY_DELAYS = (5, 15)


def tv_rule_matches(rule, titles, year, provider_id, provider):
    if provider_id and (provider != "tmdb-tv" or str(rule["hit"]["id"]) != provider_id):
        return False
    if year and rule.get("year") and str(rule["year"]) != str(year):
        return False
    return all(title in rule["titles"] for title in titles) if titles else rule.get("dedicated", False)


@contextlib.contextmanager
def serialized(directory):
    path = directory / "anilist-write.lock"
    with open(path, "a+b") as f:
        if os.name == "nt":
            import msvcrt

            if f.tell() == 0:
                f.write(b"0")
                f.flush()
            f.seek(0)
            msvcrt.locking(f.fileno(), msvcrt.LK_LOCK, 1)
        else:
            import fcntl

            fcntl.flock(f, fcntl.LOCK_EX)
        yield


class Worker:
    def __init__(self, db_path, window, settings):
        self.db_path = db_path
        self.db = sqlite3.connect(db_path, isolation_level=None, timeout=4)
        self.notice_page = ""
        self.directory = Path(db_path).parent
        self.window = window
        self.settings = settings
        self.vault = Vault()
        self.previous = None
        self.tracking_probe = None
        self.resolved = None
        self.lookup_retry = 0
        self.music_attempts = 0
        self.video_attempts = 0
        self.expected = None
        self.data_generation = None
        self.cache_generation = None
        self.lookup_pool = None
        self.artwork_pool = None
        self.lookup_valid = None

    def get(self, category, scope, default=None):
        row = self.db.execute(
            "SELECT value FROM records WHERE category=? AND scope=?", (category, scope)
        ).fetchone()
        return json.loads(row[0]) if row else ({} if default is None else default)

    def put(self, category, scope, value):
        self.db.execute(
            "INSERT INTO records VALUES(?,?,?) ON CONFLICT(category,scope) "
            "DO UPDATE SET value=excluded.value WHERE records.value<>excluded.value",
            (category, scope, json.dumps(value)),
        )

    def delete(self, category, scope):
        self.db.execute(
            "DELETE FROM records WHERE category=? AND scope=?", (category, scope)
        )

    @contextlib.contextmanager
    def transaction(self):
        self.db.execute("BEGIN IMMEDIATE")
        try:
            yield
        except BaseException:
            self.db.rollback()
            raise
        else:
            self.db.commit()

    def reply(self, **fields):
        with self.transaction():
            account = self.get("account", "current")
            player = self.get("player", self.window)
            generation, session = account.get("generation"), player.get("session")
            if self.expected and self.expected != (generation, session):
                return
            response = self.get("response", self.window)
            if (response.get("generation"), response.get("context")) != (
                generation,
                session,
            ):
                response = {}

            if "message" in fields and (
                self.notice_page or fields["message"] != response.get("message")
            ):
                fields["notice"] = secrets.token_hex(8)
                fields["notice_page"] = self.notice_page
            response.update(fields)
            response["context"] = self.get("player", self.window).get("session")
            response["generation"] = self.get("account", "current").get("generation")
            self.put("response", self.window, response)

    def context(self, job, media=False):
        account = self.get("account", "current")
        if job.get("account") != account.get("generation"):
            raise AccountError("Account changed. Review the action again.")
        player = self.get("player", self.window)
        if job.get("session") != player.get("session", 0) or (
            media
            and (job.get("media") != player.get("media") or not player.get("allowed"))
        ):
            raise AccountError("Playback or privacy settings changed.")
        return account, player

    def credential(self, account):
        if account.get("expired"):
            raise SessionExpired("Session expired. Reconnect to AniList.")
        token = self.vault.read(account.get("generation", ""))
        if not token:
            raise AccountError("Reconnect to AniList in this window.")
        return token

    def cycle(self, account, player):
        series = "%s/%s" % (account["id"], player["media"])
        return "%s/%s/%d" % (
            series,
            player["episode"],
            self.get("cycle", series).get("number", 0),
        )

    def clear_proposals(self, scope):
        self.db.execute(
            "DELETE FROM records WHERE category='pending' AND scope LIKE ?",
            (scope + "/%",),
        )

    def remember_entry(
        self, account, player, entry, *, prepare_rewatch=False, keep_status=False
    ):
        scope = f"{account['id']}/{player['media']}"
        previous = self.get("entry", scope)
        if (
            entry.get("id") is not None
            and entry.get("id") == previous.get("id")
            and (entry.get("updatedAt") or 0) < (previous.get("updatedAt") or 0)
        ):
            raise AccountError("AniList progress changed. Refresh and review the edit.")
        cycle = self.get("cycle", scope)
        marker = [entry["id"], entry["repeat"]]
        phase = cycle.get("phase")
        same_rewatch = cycle.get("rewatch") == marker
        repeating = entry["status"] == "REPEATING"
        preparing = (
            prepare_rewatch
            and entry["status"] == "COMPLETED"
            and player["episode"] == "1"
            and player["tracking"].get("rewatch")
        )
        if repeating or preparing:
            if not same_rewatch or (preparing and phase == "active"):
                cycle["number"] = cycle.get("number", 0) + 1
                self.clear_proposals(scope)
            phase = "active" if repeating else "ready"
            self.put("cycle", scope, dict(cycle, rewatch=marker, phase=phase))
        elif (
            not (
                same_rewatch
                and (
                    (phase == "ready" and entry["status"] == "COMPLETED")
                    or (phase == "active" and entry["status"] in ("PAUSED", "DROPPED"))
                )
            )
            and phase
        ):
            self.put("cycle", scope, {"number": cycle.get("number", 0)})

        if previous and any(
            previous.get(field) != entry.get(field)
            for field in ("id", "progress", "status", "repeat", "updatedAt")
        ):
            self.clear_proposals(scope)
        cached = dict(entry, checked=time.time())
        if keep_status or (
            entry["id"] == previous.get("id")
            and entry["status"] is not None
            and entry["status"] == previous.get("keep_tracking_status")
        ):
            cached["keep_tracking_status"] = entry["status"]
        self.put("entry", scope, cached)
        return cached

    def tracked_context(self, job, episode, key=None):
        account, player = self.context(job, True)
        if (
            not player.get("watch_episode")
            or player.get("episode") != str(episode)
            or episode < 1
            or (player["total"] and episode > player["total"])
            or (key is not None and self.cycle(account, player) != key)
        ):
            raise AccountError("Return to the matched episode and review the update.")
        return account, player

    @staticmethod
    def active_tracking(player, modes):
        return (
            player.get("watch_episode")
            and player.get("watch")
            and player.get("allowed")
            and player.get("active")
            and player["tracking"].get("mode") in modes
            and abs(time.time() * 1000 - player.get("wall", 0)) <= 3000
        )

    def watch_record_applies(self, player, watch):
        return player["tracking"].get("resume", True) or (
            watch.get("owner") == self.window
            and watch.get("session") == player["session"]
        )

    def reached_threshold(self, player, watch):
        return self.watch_record_applies(player, watch) and (
            watch.get("elapsed", 0) >= 60 * player["tracking"].get("threshold", 15)
        )

    def finish_write(self, scope, intent, result):
        with self.transaction():
            self.remember_entry(
                intent["account"], intent["player"], result, keep_status=intent["keep_status"]
            )
            self.put("history", intent["key"], {
                "progress": result["progress"], "time": time.time(),
                "window": intent["window"], "session": intent["player"]["session"],
            })
            self.clear_proposals(scope)
            self.delete("write-intent", scope)

    def recover_write(self, account, scope, intent):
        base = intent["base"]
        entry = read_entry(self.credential(account), base["viewer"], base["media"])
        expected = intent["expected"]
        if entry["id"] and all(entry[field] == value for field, value in expected.items()):
            self.finish_write(scope, intent, entry)
            return entry
        with self.transaction():
            self.remember_entry(intent["account"], intent["player"], entry)
            pending = self.get("pending", intent["key"])
            if pending:
                self.put("pending", intent["key"], dict(pending, needs_review=True))
            self.delete("write-intent", scope)
        raise AccountError("Previous update could not be confirmed. Review the current list entry.")

    def write(self, job):
        with serialized(self.directory):
            account, p = self.context(job, True)
            base = job["base"]
            if (
                base.get("viewer") != account["id"]
                or base.get("session") != p["session"]
                or base.get("media") != p["media"]
            ):
                raise AccountError("The draft no longer belongs to this entry.")
            proposal = job.get("tracked_proposal")
            automatic = job.get("automatic")
            if (automatic and not proposal) or (
                proposal
                and (
                    proposal["account"] != account["generation"]
                    or proposal["episode"] != job["target"]
                )
            ):
                raise AccountError("This proposal has expired.")

            def validate():
                with self.transaction():
                    if not proposal:
                        self.context(job, True)
                        return
                    key = proposal["key"]
                    _, player = self.tracked_context(job, proposal["episode"], key)
                    if (
                        self.get("pending", key) != proposal
                        or self.get("skipped", key)
                        or self.get("history", key)
                        or (
                            proposal.get("start_rewatch")
                            and not player["tracking"].get("rewatch")
                        )
                        or (
                            proposal.get("repeat_count") is not None
                            and player["total"] != proposal["episode"]
                        )
                    ):
                        raise AccountError("This proposal has expired.")
                    if automatic and (
                        not self.active_tracking(player, ("auto",))
                        or not self.reached_threshold(player, self.get("watch", key))
                    ):
                        raise AccountError("Automatic tracking is no longer eligible.")

            validate()
            token = self.credential(account)
            scope = f"{account['id']}/{p['media']}"
            if unresolved := self.get("write-intent", scope):
                self.recover_write(account, scope, unresolved)
                raise AccountError("Previous update was confirmed. Refresh before making another change.")
            expected = dict(progress=job["target"])
            if job.get("status") is not None:
                expected["status"] = job["status"]
            if job.get("repeat_count") is not None:
                expected["repeat"] = job["repeat_count"]
            intent = dict(
                account=account, player={k: p[k] for k in ("media", "session", "episode", "tracking")},
                key=proposal["key"] if proposal else self.cycle(account, p),
                window=self.window, base=base, expected=expected,
                keep_status=bool(proposal and job.get("keep_status") and
                                 expected.get("status", base["status"]) == base["status"]),
            )

            def record_intent():
                with self.transaction():
                    self.put("write-intent", scope, intent)

            options = {"status": job.get("status")}
            if job.get("repeat_count") is not None:
                options["repeat_count"] = job["repeat_count"]
            try:
                result = save_progress(
                    token,
                    base,
                    job["target"],
                    p["total"],
                    validate,
                    before_send=record_intent,
                    **options,
                )
            except EntryChanged as exc:
                with self.transaction():
                    self.context(job, True)
                    self.remember_entry(account, p, exc.entry)
                self.reply(entry=dict(exc.entry, session=p["session"]), proposal=None)
                raise
            self.finish_write(scope, intent, result)
            self.reply(
                entry=dict(result, session=p["session"]),
                proposal=None,
                read_state="ready",
                last_write=time.time(),
                message="Progress saved.",
            )

    def throttle(self, provider):
        with self.transaction():
            if self.lookup_valid:
                self.lookup_valid()
            now = time.time()
            when = max(now, self.get("rate", provider).get("next", 0))
            self.put(
                "rate",
                provider,
                {"next": when + (1.1 if provider == "musicbrainz" else 0.5)},
            )
        time.sleep(max(0, when - now))
        if self.lookup_valid:
            self.lookup_valid()

    def cached_fetch(self, key, field, request, valid, *, catalog=False):
        hours = self.settings.get("catalog_cache_hours", 24)
        if catalog and hours == 0:
            valid()
            return request()
        epoch = self.get("generation", "data")
        cache_epoch = self.get("generation", "cache")
        owner = secrets.token_hex(16)
        while True:
            valid()
            with self.transaction():
                if self.get("generation", "data") != epoch:
                    raise AccountError("Saved data changed. Search again.")
                cached = self.get("cache", key)
                expires = cached.get("expires", 0)
                if catalog and cached.get(field) and "fetched" in cached:
                    expires = min(expires,cached["fetched"]+hours*3600)
                if field in cached and expires > time.time():
                    return cached[field]
                if self.get("flight", key).get("expires", 0) <= time.time():
                    self.put(
                        "flight", key, {"owner": owner, "expires": time.time() + 90}
                    )
                    break
            time.sleep(0.2)
        try:
            valid()
            result = request()
            with self.transaction():
                valid()
                if (
                    epoch != self.get("generation", "data")
                    or cache_epoch != self.get("generation", "cache")
                    or self.get("flight", key).get("owner") != owner
                ):
                    raise AccountError("The search was superseded.")
                self.put(
                    "cache",
                    key,
                    {
                        field: result,
                        "expires": time.time() + ((hours * 3600 if catalog else 86400) if result else 300),
                        "fetched": time.time(),
                    },
                )
                if catalog:
                    self.db.execute(
                        "DELETE FROM records WHERE category='cache' AND scope IN ("
                        "SELECT scope FROM records WHERE category='cache' AND scope GLOB 'tv-catalog/*' "
                        "ORDER BY json_extract(value,'$.expires') DESC LIMIT -1 OFFSET 512)"
                    )
            return result
        finally:
            with self.transaction():
                if self.get("flight", key).get("owner") == owner:
                    self.delete("flight", key)

    def handle(self, job):
        op = job["op"]
        account, p = self.context(
            job, op in ("read", "write", "search", "select", "accept", "rearm")
        )
        if op == "connect":
            broker = self.settings.get("broker", "")
            if not broker and not self.settings.get("personal"):
                if str(self.settings.get("client_id")) != "55822":
                    raise AccountError(
                        "Configure the exchange for your custom AniList client."
                    )
                broker = PUBLIC_EXCHANGE
            def valid():
                if self.get("account", "current").get("generation") != job.get("account"):
                    raise AccountError("Account changed. Start sign-in again.")
                if job.get("attempt") and (
                    self.get("signin-request", self.window).get("id") != job["attempt"] or
                    self.get("signin-cancel", self.window).get("id") == job["attempt"]
                ):
                    raise AccountError("Sign-in cancelled.")

            def review(token):
                valid()
                viewer = graphql("query{Viewer{id name avatar{medium}}}", {}, token)["Viewer"]
                if not isinstance(viewer, dict) or type(viewer.get("id")) is not int or not isinstance(viewer.get("name"), str):
                    raise AccountError("AniList did not return an account profile.")
                return viewer

            def connect(token, viewer):
                with serialized(self.directory):
                    valid()
                    generation = secrets.token_hex(16)
                    persistent = self.vault.write(generation, token, remember=not job.get("session_only", False))
                    try:
                        with self.transaction():
                            valid()
                            self.put("account", "current", dict(
                                id=viewer["id"], name=viewer["name"], avatar=viewer.get("avatar"),
                                generation=generation, persistent=persistent, window=self.window,
                            ))
                    except Exception:
                        self.vault.forget(generation, persistent)
                        raise
                    if account.get("generation"):
                        self.vault.forget(account["generation"], account.get("persistent"))
                self.reply(
                    entry=None, proposal=None, offline=False,
                    message="Connected." if persistent else "Connected for this session.",
                )
                return persistent

            try:
                self.reply(signin=job.get("attempt"), offline=False)
                authorize(
                    self.settings.get("client_id"), valid, vault=self.vault, broker=broker,
                    progress=lambda message: self.reply(message=message),
                    review=review, connect=connect,
                )
            finally:
                self.reply(signin=None)
        elif op in ("disconnect", "reset"):
            with serialized(self.directory):
                self.context(job)
                if account.get("generation"):
                    self.vault.forget(account["generation"], account.get("persistent"))
                with self.transaction():
                    self.delete("account", "current")
                    self.db.execute(
                        "DELETE FROM records WHERE category IN ('job','response')"
                    )
                    if account.get("id"):
                        categories = ["pending", "write-intent"]
                        if job.get("forget_history"):
                            categories += [
                                "watch",
                                "history",
                                "skipped",
                                "entry",
                                "cycle",
                            ]
                        for category in categories:
                            self.db.execute(
                                "DELETE FROM records WHERE category=? AND scope LIKE ?",
                                (category, str(account["id"]) + "/%"),
                            )
                    if op == "reset":
                        self.db.execute("DELETE FROM records WHERE category!='player'")
                        self.put("generation", "cache", {"id": secrets.token_hex(16)})
                        self.put("generation", "data", {"id": secrets.token_hex(12)})
            self.reply(
                message="Restored configuration defaults."
                if op == "reset"
                else "Disconnected."
            )
        elif op == "read":
            if not account.get("id") or not p.get("media"):
                raise AccountError(
                    "Choose a matched anime and connect an account first."
                )
            scope = f"{account['id']}/{p['media']}"
            previous = self.get("entry", scope)
            cached = dict(previous, session=p["session"]) if previous else None
            self.reply(read_state="loading", entry=cached, offline=False)
            try:
                with serialized(self.directory):
                    intent = self.get("write-intent", scope)
                    entry = (self.recover_write(account, scope, intent) if intent else
                             read_entry(self.credential(account), account["id"], p["media"]))
            except AccountError:
                self.reply(read_state="offline", entry=cached, offline=True)
                raise
            with self.transaction():
                self.context(job, True)
                self.remember_entry(account, p, entry)
            notice = {} if job.get("quiet") else {"message": "Progress refreshed."}
            self.reply(
                entry=dict(entry, session=p["session"]),
                offline=False,
                read_state="ready",
                last_read=time.time(),
                **notice,
            )
        elif op == "rearm":
            if (
                not p.get("tracking", {}).get("rewatch")
                or not account.get("id")
                or not p.get("media")
            ):
                raise AccountError("Enable rewatch tracking for a matched entry first.")
            with self.transaction():
                self.context(job, True)
                scope = str(account["id"]) + "/" + str(p["media"])
                cycle = self.get("cycle", scope)
                self.put("cycle", scope, dict(cycle, number=cycle.get("number", 0) + 1))
                self.clear_proposals(scope)
            self.previous = None
            self.tracking_probe = None
            self.reply(proposal=None, message="New viewing cycle started.")
        elif op == "write":
            self.write(job)
        elif op in ("accept", "skip"):
            key = job["proposal"]
            prop = self.get("pending", key)
            if (
                not prop
                or not account.get("id")
                or not key.startswith(str(account["id"]) + "/")
                or prop["account"] != account["generation"]
                or ("revision" in job and job["revision"] != prop.get("revision", ""))
            ):
                raise AccountError("This proposal has expired.")
            if op == "accept":
                if prop.get("offline") or "status" not in prop:
                    raise AccountError(
                        "Return to the matched episode and refresh its progress to apply."
                    )
                self.tracked_context(job, prop["episode"], key)
                base = dict(prop["base"], session=p["session"])
                keep_status = job.get("keep_status", False)
                if keep_status and (not base["id"] or prop["status"] != "CURRENT"):
                    raise AccountError(
                        "Choose the proposed status to apply this update."
                    )
                self.write(
                    dict(
                        job,
                        base=base,
                        target=prop["episode"],
                        tracked_proposal=prop,
                        status=None if keep_status else prop["status"],
                        repeat_count=prop.get("repeat_count"),
                    )
                )
            else:
                with self.transaction():
                    self.context(job)
                    if self.get("pending", key) != prop:
                        raise AccountError("This proposal has expired.")
                    self.put("skipped", key, {"skip": True})
                    self.delete("pending", key)
                self.reply(proposal=None, message="Skipped.")
        elif op == "clear":
            category = job["category"]
            with serialized(self.directory), self.transaction():
                if category in (
                    "appearance",
                    "privacy",
                    "exclude",
                    "tracking",
                    "match",
                    "provider",
                    "sources",
                    "panel",
                    "panel-theme",
                    "folder-filter",
                    "recognition-options",
                    "tv-rule",
                ):
                    removed = self.get(category, job["scope"])
                    if category == "match" and job.get("field"):
                        if job["field"] not in ("id", "not_anime", "offset", "episode"):
                            raise AccountError("Unknown match field.")
                        remaining = dict(removed)
                        remaining.pop(job["field"], None)
                        if job["field"]=="id":
                            remaining.pop("episode", None)
                        if remaining:
                            self.put(category, job["scope"], remaining)
                        else:
                            self.delete(category, job["scope"])
                    else:
                        self.delete(category, job["scope"])
                    restricted = (
                        removed.get("blocked")
                        or removed.get("block_lookup")
                        or removed.get("mode") in ("hidden", "generic")
                    )
                    if category in ("privacy", "exclude") and restricted:
                        # Keep open files hidden even when removing their folder exclusion.
                        for (raw,) in self.db.execute(
                            "SELECT value FROM records WHERE category='player'"
                        ):
                            path = json.loads(raw).get("scope_path")
                            scope = job["scope"]
                            applies = (
                                scope == "global"
                                or scope == "file:" + str(path)
                                or (
                                    scope.startswith("folder:")
                                    and path
                                    and path.startswith(scope[7:].rstrip("/") + "/")
                                )
                            )
                            if path and applies:
                                self.put(
                                    "privacy",
                                    "file:" + path,
                                    {"mode": "hidden", "block_lookup": True},
                                )
                elif category in (
                    "watch",
                    "pending",
                    "history",
                    "skipped",
                    "entry",
                ) and account.get("id"):
                    prefix = str(account["id"]) + "/"
                    scope = job.get("scope")
                    if scope and not scope.startswith(prefix):
                        raise AccountError("Account scope changed.")
                    where, target = (
                        ("scope=?", scope) if scope else ("scope LIKE ?", prefix + "%")
                    )
                    categories = (
                        ("watch", "pending", "skipped")
                        if category == "watch"
                        else (category,)
                    )
                    if category == "skipped":
                        self.db.execute(
                            f"UPDATE records SET value=json_remove(value,'$.retry') WHERE category='watch' "
                            f"AND scope IN (SELECT scope FROM records WHERE category='skipped' AND {where})",
                            (target,),
                        )
                    self.db.executemany(
                        f"DELETE FROM records WHERE category=? AND {where}",
                        ((name, target) for name in categories),
                    )
                elif category == "cache":
                    self.put("generation", "cache", {"id": secrets.token_hex(16)})
                    if job.get("scope"):
                        self.delete("cache", job["scope"])
                    else:
                        self.db.execute("DELETE FROM records WHERE category='cache'")
                else:
                    raise AccountError("Nothing to clear for this account.")
                self.put("generation", "data", {"id": secrets.token_hex(12)})
            self.previous = None
            self.reply(message="Local records cleared.", proposal=None, results=[])
        elif op == "search":
            provider = job["provider"]
            query = job.get("query", "")
            request = job["request"]
            key = (
                provider
                + "/"
                + hashlib.sha256(
                    (p["path"] if provider == "acoustid" else query).encode()
                ).hexdigest()
            )

            def valid():
                self.context(job, True)
                if self.get("search-request", self.window).get("id") != request:
                    raise AccountError("Search was superseded.")

            def fetch_results():
                if provider == "acoustid":
                    return fingerprint(p["path"], self.settings, self.throttle, valid)
                return candidates(provider, query, self.settings, self.throttle)

            try:
                valid()
                hits = self.cached_fetch(key, "results", lambda: fetch_results()[:24], valid)
            except (AccountError, OSError, ValueError) as exc:
                valid()
                error = str(exc) if isinstance(exc, AccountError) else "The provider could not finish this search."
                self.reply(search=dict(id=request, state="failed", error=error, results=[]))
            else:
                valid()
                self.reply(search=dict(id=request, state="ready", provider=provider, results=hits))
        elif op == "select":
            response = self.get("response", self.window)
            previous = response.get("search", {})
            if (
                response.get("context") != p["session"]
                or previous.get("id") != job.get("request")
                or previous.get("id") != self.get("search-request", self.window).get("id")
                or job["candidate"] not in previous.get("results", [])
            ):
                raise AccountError("Search again for this file.")
            scope = {
                "file": "file:" + p["path"],
                "folder": "folder:" + os.path.dirname(p["path"]).replace("\\", "/"),
                "global": "global",
                "tv-rule": "folder:" + os.path.dirname(p["path"]).replace("\\", "/"),
                "tv-dedicated": "folder:" + os.path.dirname(p["path"]).replace("\\", "/"),
            }[job["scope"]]
            provider = previous["provider"]
            selected = job["candidate"]
            is_tv = provider in ("tmdb-tv", "tvmaze")
            if provider == "anilist":
                with self.transaction():
                    self.context(job, True)
                    if self.get("search-request", self.window).get("id") != job["request"]:
                        raise AccountError("Search again for this file.")
                    correction = self.get("match", scope)
                    if correction.get("id") != selected["id"]:
                        correction.pop("episode", None)
                    self.put("match", scope, dict(correction, id=selected["id"], not_anime=False))
                self.reply(message="Match saved.")
                return
            title, year, episode, airdate = video_query(os.path.basename(p["path"]))
            if is_tv and job["scope"] in ("tv-rule", "tv-dedicated"):
                if not p.get("recognition_options", {}).get("tv_rules") or not title or not (episode or airdate):
                    raise AccountError("Enable TV folder rules and open a file named with its series and episode.")
                hit = details(provider, selected, self.settings, self.throttle, None)
                # Keep only the series identity and the alias explicitly approved for this folder.
                rule = dict(
                    provider=provider, hit=selected, year=hit.get("year") or year,
                    dedicated=job["scope"]=="tv-dedicated",
                    titles=sorted({match_name(title), match_name(hit["name"])}),
                )
                with self.transaction():
                    self.context(job, True)
                    if self.get("search-request", self.window).get("id") != job["request"]:
                        raise AccountError("Search again for this file.")
                    rules = self.get("tv-rule", scope)
                    if rule["dedicated"]:
                        rules = {key: dict(value, dedicated=False) for key, value in rules.items()}
                    rules[f"{provider}:{selected['id']}"] = rule
                    self.put("tv-rule", scope, rules)
                    self.put("refresh", self.window, {"id": secrets.token_hex(8)})
                self.reply(message="TV rule saved for matching files in this folder.")
                return
            if is_tv and job["scope"] != "file":
                raise AccountError("Save this TV episode for the current file.")
            hit = details(provider, selected, self.settings, self.throttle, episode, airdate)
            with self.transaction():
                self.context(job, True)
                if self.get("search-request", self.window).get("id") != job["request"]:
                    raise AccountError("Search again for this file.")
                self.put("provider", scope, hit)
                self.put("match", scope, {"not_anime": True})
            self.reply(message="Match saved.")
        else:
            raise AccountError("Unknown action.")

    def recognize_music(self, p, source, refresh, publish, valid, artwork_only=None):
        title = music_title(p.get("track_title") or p["title"])
        artist = p.get("artist", "")
        album = p.get("album", "")
        album_artist = p.get("album_artist") or next(iter(music_artists(artist)), "")
        date = p.get("release_date", "")
        duration = p.get("duration", 0)
        automatic = p["source"] == "auto"
        failed = False

        def cached(stage, terms, request):
            nonlocal failed
            key = (
                "music-v4:"
                + stage
                + "/"
                + hashlib.sha256(json.dumps([terms, refresh]).encode()).hexdigest()
            )
            try:
                return self.cached_fetch(key, "hit", request, valid)
            except (AccountError, OSError, ValueError):
                valid()
                failed = True
                return None

        def publish_cover(hit, sources):
            if sources and (cover := cached("cover", sources, lambda: music_art(sources))):
                publish(dict(hit, cover=cover))
                return True
            return False

        def tagged_name(name, *, is_album=False):
            return [match_name(part) for part in music_names(name, album=is_album)]

        hit = None
        if artwork_only:
            hit, include_album, override = artwork_only
            if override is None:
                # The same preferred release and album probes as the inline path.
                sources = music_art_sources(hit)
                if publish_cover(hit,sources):
                    return failed
                if include_album and album and album_artist:
                    release = cached(
                        "album", [tagged_name(album, is_album=True), album_artist.casefold(), date],
                        lambda: musicbrainz_album(album_artist, album, date, self.throttle),
                    )
                    if release and (alternate := music_art_sources(release)) != sources:
                        publish_cover(hit,alternate)
            else:
                publish_cover(hit,override)
            return failed
        if source == "musicbrainz" and re.fullmatch(
            r"[0-9a-fA-F-]{36}", p.get("recording", "")
        ):
            hit = dict(
                provider=source,
                kind="recording",
                id=p["recording"],
                name=title,
                artist=artist,
                album=album,
                release=p.get("release"),
                link="https://musicbrainz.org/recording/" + p["recording"],
            )
        elif source == "musicbrainz" and title and (artist or not automatic):
            hit = cached(
                "track",
                [
                    tagged_name(title),
                    artist.casefold(),
                    tagged_name(album, is_album=True),
                    round(duration),
                    date,
                ],
                lambda: musicbrainz_match(
                    candidates(
                        source,
                        title,
                        self.settings,
                        self.throttle,
                        artist=artist,
                        album=album,
                    ),
                    title,
                    artist,
                    album,
                    duration,
                    date,
                ),
            )

        if hit:
            publish(hit)
            if self.artwork_pool is not None:
                self.defer_artwork(p, refresh, hit, True)
                return failed
        sources = music_art_sources(hit or {})
        if hit and publish_cover(hit, sources):
            return False

        if source == "musicbrainz" and album and album_artist:
            release = cached(
                "album",
                [tagged_name(album, is_album=True), album_artist.casefold(), date],
                lambda: musicbrainz_album(album_artist, album, date, self.throttle),
            )
            if release:
                if not hit:
                    hit = dict(release, name=title, artist=artist, album=album)
                    publish(hit)
                alternative = music_art_sources(release)
                if self.artwork_pool is not None:
                    self.defer_artwork(p, refresh, hit, False, alternative)
                    return failed
                if alternative != sources and publish_cover(hit, alternative):
                    return False

        path = p.get("path", "")
        if not hit and automatic and p.get("recognition_options", {}).get("confirm_fingerprint") and os.path.isfile(path):
            publish(None, fingerprint_available=True)
            return False
        if not hit and (automatic or source == "acoustid") and os.path.isfile(path):
            stat = os.stat(path)
            hit = cached(
                "fingerprint",
                [path, stat.st_size, stat.st_mtime_ns, title, artist, album],
                lambda: fingerprint_match(
                    fingerprint(path, self.settings, self.throttle, valid),
                    title,
                    artist,
                    album,
                ),
            )
            if hit:
                publish(hit)
                if self.artwork_pool is not None:
                    self.defer_artwork(p, refresh, hit, False)
                    return failed
                sources = music_art_sources(hit)
                if publish_cover(hit, sources):
                    return False
        if not hit:
            publish(None, unavailable=failed)
        return failed

    def video_details(self, provider, row, episode, airdate, valid, refresh=None):
        def series(identifier):
            def fetch_series():
                self.throttle(provider)
                return tmdb_request(f"/tv/{identifier}", self.settings)

            key = f"tv-catalog/tmdb-series/{identifier}"
            if refresh:
                key += "/" + refresh.get("id","")
            return self.cached_fetch(key, "series", fetch_series, valid, catalog=True)
        settings = dict(self.settings, tmdb_series=series) if provider == "tmdb-tv" else self.settings
        return details(provider, row, settings, self.throttle, episode, airdate)

    @staticmethod
    def recognition_context(sample):
        return tuple(
                sample.get(field)
                for field in (
                    "session",
                    "source",
                    "title",
                    "track_title",
                    "artist",
                    "album",
                    "album_artist",
                    "release_date",
                    "folder_title",
                    "folder_year",
                    "folder_episode",
                    "folder_has_episode",
                    "allowed",
                    "recognition_options",
                    "embedded_title",
                    "filename",
                    "tmdb",
                    "recording",
                    "release",
                    "channel",
                    "page",
                    "live",
                )
        )

    def recognize(self, p, artwork_only=None):
        try:
            return self.recognize_current(p, artwork_only)
        finally:
            self.lookup_valid = None

    def recognize_current(self, p, artwork_only):
        profile_source = p.get("source", "original")
        refresh = self.get("refresh", self.window)
        if refresh != getattr(self, "last_refresh", None):
            self.resolved = None
            self.lookup_retry = 0
            self.last_refresh = refresh
        context = self.recognition_context

        key = context(p)
        if not artwork_only and key == self.resolved:
            if not self.lookup_retry or time.monotonic() < self.lookup_retry:
                return
        else:
            self.music_attempts = 0
            self.video_attempts = 0
        self.resolved = key
        self.lookup_retry = 0
        if profile_source == "original" or not p.get("allowed"):
            return
        raw = p.get("title", "")
        source = profile_source
        artist = p.get("artist", "")
        album = p.get("album", "")
        generation = self.get("generation", "data")
        cache_generation = self.get("generation", "cache")

        def valid():
            if (
                refresh != self.get("refresh", self.window)
                or key != context(self.get("player", self.window))
                or generation != self.get("generation", "data")
                or cache_generation != self.get("generation", "cache")
            ):
                raise AccountError("Playback or privacy settings changed.")

        valid()
        self.lookup_valid = valid
        ambiguous = False

        def publish(hit, *, unavailable=False, fingerprint_available=False):
            with self.transaction():
                valid()
                self.put(
                    "auto",
                    self.window,
                    dict(
                        session=p["session"],
                        source=profile_source,
                        title=raw,
                        track_title=p.get("track_title", ""),
                        artist=artist,
                        album=album,
                        hit=hit or {},
                        unavailable=unavailable,
                        ambiguous=ambiguous and not hit and not unavailable,
                        fingerprint_available=fingerprint_available,
                    ),
                )

        verify_movie = source == "verify-movie"
        verify_tv = source == "verify-tv"
        video_profile = source in ("movie-tv", "movie", "tv")
        if video_profile and (not p["video"] or p.get("remote")):
            publish(None)
            return
        title, year, episode, airdate = raw, "", None, None
        if p["video"] and not p.get("remote"):
            title, year, episode, airdate = video_query(raw)
            filename = video_query(p.get("filename", ""))
            missing_tv_season = False
            if (
                filename[2]
                or filename[3]
                or not title
                or (filename[1] and (verify_movie or not year or year == filename[1]))
            ):
                title, year, episode, airdate = filename
            sidecar_allowed = p.get("recognition_options", {}).get("sidecar_metadata")
            if source == "auto" and p.get("folder_title") and (
                not title or match_name(title) == match_name(filename[0])
            ):
                # A bare episode needs a season from the filename or folder to
                # query the TV catalog. AniList already handled absolute numbers.
                if p.get("folder_has_episode") and not p.get("folder_episode"):
                    missing_tv_season = True
                    if not sidecar_allowed:
                        publish(None)
                        return
                # A movie folder needs a unique TMDB title. Never fall
                # through to TV with a bare feature label.
                if not p.get("folder_has_episode"):
                    source = "tmdb-movie"
                title = p["folder_title"]
                year = p.get("folder_year", "")
                episode = p.get("folder_episode") or episode
                airdate = None
            options = p.get("recognition_options", {})
            path = p.get("path")
            if path and options.get("sidecar_metadata") and profile_source in ("auto", "movie-tv", "movie", "tv", "verify-tv", "verify-movie"):
                try:
                    with Path(path).with_suffix(".mpv-rp.json").open("rb") as sidecar:
                        contents = sidecar.read(4097)
                    metadata = json.loads(contents) if len(contents)<=4096 else {}
                    if not isinstance(metadata, dict):
                        metadata = {}
                    kind, identifier = metadata.get("kind"), metadata.get("tmdb")
                    if kind in ("movie", "tv") and type(identifier) is int and 0 < identifier < 2**31 and (
                        profile_source in ("auto", "movie-tv", kind, f"verify-{kind}")
                    ):
                        if kind == "tv" and all(type(metadata.get(k)) is int and 0 <= metadata[k] <= 999 for k in ("season", "episode")) and metadata["episode"] > 0:
                            episode = (str(metadata["season"]), str(metadata["episode"]))
                        p = dict(p, tmdb=str(identifier), sidecar_selected=True)
                        source = "tmdb-" + kind
                        video_profile = False
                except (OSError, ValueError):
                    pass
            if missing_tv_season and not p.get("sidecar_selected"):
                publish(None)
                return
            if (path and options.get("tv_rules") and profile_source in ("auto", "tv", "movie-tv", "verify-tv")
                and (episode or airdate) and not p.get("sidecar_selected")):
                filename_title = filename[0]
                embedded = video_query(p.get("embedded_title", ""))[0]
                titles = {match_name(t) for t in (filename_title, embedded) if t}
                folder = "folder:" + os.path.dirname(path).replace("\\", "/")
                rules = [(rule["provider"], rule["hit"]) for rule in self.get("tv-rule", folder).values()
                         if tv_rule_matches(rule, titles, year, p.get("tmdb", ""), rule["provider"])]
                if len(rules) == 1:
                    provider, selected = rules[0]
                    try:
                        hit = self.cached_fetch(
                            f"tv-rule/{provider}/{selected['id']}/{episode or airdate}", "hit",
                            lambda: self.video_details(provider, selected, episode, airdate, valid, refresh), valid,
                        )
                        if hit and hit.get("numbering"):
                            publish(hit)
                            return
                    except (AccountError, OSError, ValueError, KeyError):
                        valid()
        if (
            source == "auto"
            and p["video"]
            and not p.get("remote")
            and not p.get("tmdb", "").isdigit()
        ):
            # A short clip with a bare title is weak evidence of a feature film.
            length = p.get("duration", 0)
            if generic_clip(p.get("filename", "")) or (
                0 < length < 35 * 60 and not (year or episode or airdate)
            ):
                publish(None)
                return
        mixed_title = (
            source in ("auto", "movie-tv")
            and p["video"]
            and not p.get("remote")
            and not (episode or airdate)
        )
        if video_profile:
            tv_profile = source == "tv" or (source == "movie-tv" and not mixed_title)
            source = "tvmaze" if tv_profile else "wikidata"
        if source == "auto":
            if p.get("remote"):
                if not p.get("page") and not p.get("channel"):
                    publish(None)
                    return
                source = "stream"
            elif not p["video"]:
                source = "musicbrainz"
            elif episode or airdate:
                source = "tvmaze"
            else:
                source = "wikidata"
        if verify_movie and not p.get("sidecar_selected"):
            source = "tmdb-movie"
        elif verify_tv and not p.get("sidecar_selected"):
            source = "tmdb-tv"
        if source in ("musicbrainz", "acoustid"):
            if not p["video"] and not p.get("remote"):
                failed = self.recognize_music(p, source, refresh, publish, valid, artwork_only)
                if artwork_only:
                    return failed
                if failed and self.music_attempts < len(MUSIC_RETRY_DELAYS):
                    self.lookup_retry = (
                        time.monotonic() + MUSIC_RETRY_DELAYS[self.music_attempts]
                    )
                    self.music_attempts += 1
            else:
                publish(None)
            return

        hit = None
        if source == "stream":
            hit = dict(
                provider=source,
                kind="stream",
                name=p.get("channel") or raw,
                stream_title=raw,
                live=p.get("live", False),
                link=p.get("page", ""),
            )
            if not hit["link"]:
                del hit["link"]
        elif (
            source in ("tmdb-movie", "tmdb-tv", "tvmaze", "wikidata")
            and p["video"]
            and not p.get("remote")
        ):
            if not verify_movie and not p.get("tmdb", "").isdigit() and (
                not title or re.search(r"[/\\?&#\x00-\x1f]|://", title)
            ):
                publish(None)
                return
            cache_key = (
                "v4:"
                + profile_source
                + ":"
                + source
                + "/"
                + hashlib.sha256(
                    json.dumps(
                        [
                            title,
                            artist,
                            album,
                            p.get("album_artist"),
                            p.get("tmdb"),
                            bool(p.get("sidecar_selected")),
                            year,
                            episode,
                            airdate,
                            bool(verify_tv and p.get("anime_runtime_conflict")),
                            refresh,
                        ]
                    ).encode()
                ).hexdigest()
            )

            def fetch_hit():
                nonlocal ambiguous
                if (
                    (not verify_movie or p.get("sidecar_selected"))
                    and source.startswith("tmdb-")
                    and p.get("tmdb", "").isdigit()
                ):
                    chosen = dict(
                        id=int(p["tmdb"]),
                        kind=source.split("-")[1],
                        name=title,
                        title=title,
                    )
                    return self.video_details(source,chosen,episode,airdate,valid,refresh)

                def matching(provider):
                    nonlocal ambiguous
                    valid()
                    query = title.replace(":", " ")
                    if provider.startswith("tmdb-") and year:
                        query += f" ({year})"
                    def search():
                        return candidates(provider,query,self.settings,self.throttle,artist=artist,album=album)
                    if provider in ("tmdb-tv","tvmaze"):
                        digest = hashlib.sha256(json.dumps([provider,query,refresh]).encode()).hexdigest()
                        rows = self.cached_fetch(f"tv-catalog/search/{digest}","results",search,valid,catalog=True)
                    else:
                        rows = search()
                    exact = [
                        r
                        for r in rows
                        if match_name(r.get("match", r["name"])) == match_name(title)
                    ]
                    if provider == "tvmaze" and not exact and episode:
                        # TVmaze sometimes returns a longer official title. Only
                        # accept it when the requested episode title agrees too.
                        names = re.split(
                            r"(?i)(?<!\w)(?:s\d{1,2}[ ._-]*e\d{1,3}|\d{1,2}x\d{2,3})(?!\d)",
                            p.get("filename", ""),
                            maxsplit=1,
                        )
                        episode_label = match_name(names[-1]) if len(names) == 2 else ""
                        if episode_label:
                            exact = [
                                dict(r, episode_label=episode_label)
                                for r in rows
                                if match_name(r["name"]).startswith(match_name(title) + " ")
                            ]
                    if year and (
                        provider in ("wikidata", "tvmaze", "tmdb-movie")
                        or verify_movie
                        or verify_tv
                    ):
                        exact = [
                            r for r in exact if year in r.get("years", [r.get("year")])
                        ]
                    ambiguous = ambiguous or len({str(row.get("id")) for row in exact})>1
                    return exact

                if verify_movie:
                    if not title or not year or episode or airdate:
                        return None
                    movies = matching("tmdb-movie")
                    if len(movies) != 1:
                        return None
                    valid()
                    movie = details(
                        "tmdb-movie", movies[0], self.settings, self.throttle, None
                    )
                    genres = movie.get("genre", "").casefold().split(", ")
                    if (
                        movie.get("year") == year
                        and match_name(movie["name"]) == match_name(title)
                        and genres != [""]
                        and "animation" not in genres
                    ):
                        return movie
                    return None

                def describe(provider, row):
                    valid()
                    show = self.video_details(provider, row, episode, airdate, valid,refresh)
                    if episode and provider.startswith(("tmdb-tv", "tvmaze")) and not show.get("numbering"):
                        return None
                    if label := row.get("episode_label"):
                        name = match_name(show.get("episode_title", ""))
                        if not name or not (label == name or label.startswith(name + " ")):
                            return None
                    return show

                def tv_match(provider, hits, eligible=lambda _: True):
                    if len(hits) > 3 or (len(hits) != 1 and any(not row.get("episode_label") for row in hits)):
                        return None
                    matches = []
                    for row in hits:
                        try:
                            show = describe(provider, row)
                        except (AccountError, OSError, ValueError):
                            if not row.get("episode_label"):
                                raise
                            continue
                        if show and eligible(show):
                            matches.append(show)
                    return matches[0] if len(matches) == 1 else None

                if verify_tv:
                    if not title or not episode:
                        return None
                    failure = None
                    for provider in ("tmdb-tv", "tvmaze"):
                        def eligible(show):
                            if p.get("anime_runtime_conflict"):
                                return True
                            if provider == "tmdb-tv":
                                return bool(show.get("genre")) and "animation" not in show["genre"].casefold()
                            return show.get("show_type") in ("Scripted", "Reality", "Talk Show")

                        try:
                            if show := tv_match(provider, matching(provider), eligible):
                                return show
                        except (AccountError, OSError, ValueError) as error:
                            failure = error
                    if failure:
                        raise failure
                    return None

                failure = None

                def preferred_tmdb(fallback):
                    nonlocal failure
                    preferred = "tmdb-movie" if fallback == "wikidata" else "tmdb-tv"
                    if not mixed_title and p.get("tmdb", "").isdigit():
                        tmdb_hits = [
                            dict(
                                id=int(p["tmdb"]),
                                kind=preferred.split("-")[1],
                                name=title,
                            )
                        ]
                    else:
                        try:
                            tmdb_hits = matching(preferred)
                        except (AccountError, OSError, ValueError) as error:
                            failure = error
                            tmdb_hits = []
                    if len(tmdb_hits) == 1:
                        valid()
                        try:
                            return describe(preferred, tmdb_hits[0])
                        except (AccountError, OSError, ValueError) as error:
                            failure = error
                    return None

                if (
                    (profile_source == "auto" or video_profile)
                    and source in ("wikidata", "tvmaze")
                    and (not airdate or profile_source == "movie")
                ):
                    preferred = preferred_tmdb(source)
                    if preferred:
                        return preferred

                provider = source
                try:
                    exact = matching(provider)
                except (AccountError, OSError, ValueError) as error:
                    if not mixed_title:
                        raise
                    failure = error
                    exact = []
                if not exact and (
                    (profile_source == "auto" and provider == "wikidata") or mixed_title
                ):
                    provider = "tvmaze"
                    if mixed_title:
                        preferred = preferred_tmdb(provider)
                        if preferred:
                            return preferred
                    exact = matching(provider)
                if provider == "tvmaze" and episode:
                    if show := tv_match(provider, exact):
                        return show
                elif len(exact) == 1:
                    if hit := describe(provider, exact[0]):
                        return hit
                if failure:
                    raise failure
                return None

            try:
                def resolve_video():
                    result = fetch_hit()
                    return {"hit":result, "ambiguous":True} if ambiguous and not result else result

                hit = self.cached_fetch(cache_key, "hit", resolve_video, valid)
                if hit and hit.get("ambiguous") is True:
                    ambiguous = True
                    hit = None
            except (AccountError, OSError, ValueError, KeyError):
                valid()
                publish(None, unavailable=True)
                if self.video_attempts < len(VIDEO_RETRY_DELAYS):
                    self.lookup_retry = time.monotonic() + VIDEO_RETRY_DELAYS[self.video_attempts]
                    self.video_attempts += 1
                return
        publish(hit)

    def sample(self, credit_only=False):
        epoch = self.get("generation", "data")
        p = self.get("player", self.window)
        a = self.get("account", "current")
        self.expected = (a.get("generation"), p.get("session"))
        prev = self.previous
        key = (
            self.cycle(a, p)
            if a.get("id") and p.get("watch_episode") and p.get("active")
            else None
        )
        self.previous = (p, a.get("generation"), key)
        if not prev or not a.get("id") or not p.get("active") or key is None:
            return
        before, generation, previous_key = prev
        if (
            not before.get("active")
            or previous_key != key
            or generation != a["generation"]
            or any(
                before.get(k) != p.get(k)
                for k in ("session", "media", "episode", "seek", "speed", "tracking")
            )
        ):
            return
        dt = p["time"] - before["time"]
        pos = p["pos"] - before["pos"]
        if not (
            0 < dt <= 2.5
            and pos > 0
            and abs(pos - dt * p["speed"]) < max(0.4, dt * p["speed"] * 0.3)
        ):
            return
        if abs(time.time() * 1000 - p["wall"]) > 3000 or not re.fullmatch(
            r"[1-9]\d*", p["episode"]
        ):
            return
        with self.transaction():
            if (
                self.get("generation", "data") != epoch
                or self.get("account", "current").get("generation") != a["generation"]
                or self.get("player", self.window) != p
                or self.cycle(a, p) != key
            ):
                self.previous = None
                return
            watch = self.get("watch", key)
            if (
                watch.get("owner") not in (None, self.window)
                and 0 <= p["time"] - watch.get("owner_time", 0) < 2.75
            ):
                return
            if watch.get("owner") not in (None, self.window):
                watch["end"] = p["time"]
            # Intersect intervals with the last credited endpoint across all windows.
            end = watch.get("end", 0)
            if end > p["time"]:
                end = p["time"]
            start = max(before["time"], end)
            credit = min(dt, max(0, p["time"] - start))
            if not self.watch_record_applies(p, watch):
                watch["elapsed"] = 0
                watch.pop("first_watched", None)
                watch.pop("last_watched", None)
                watch.pop("segments", None)
                watch.pop("coverage", None)
            elapsed = watch.get("elapsed", 0)
            if credit:
                if elapsed == 0:
                    watch["first_watched"] = p["wall"] - credit * 1000
                watch["last_watched"] = p["wall"]
            elapsed += credit
            if credit and p["tracking"].get("coverage"):
                first, last = p["pos"] - pos * credit / dt, p["pos"]
                segments = watch.get("segments", [])
                merged = []
                for left, right in sorted([*segments, [first, last]]):
                    if merged and left <= merged[-1][1] + 0.001:
                        merged[-1][1] = max(merged[-1][1], right)
                    else:
                        merged.append([left, right])
                # Avoid an unbounded record if a file has many discontinuities.
                if len(merged)<=4096:
                    watch["segments"] = merged
                    watch["coverage"] = sum(right - left for left, right in merged)
            self.put(
                "watch",
                key,
                dict(
                    watch,
                    elapsed=elapsed,
                    end=p["time"],
                    owner=self.window,
                    owner_time=p["time"],
                    session=p["session"],
                ),
            )
        if credit and not credit_only:
            self.propose(a, p)

    def propose(self, a, p):
        if (
            not a.get("id")
            or a.get("expired")
            or not self.active_tracking(p, ("ask", "auto"))
        ):
            return
        self.expected = (a["generation"], p["session"])
        episode = int(p["episode"])
        key = self.cycle(a, p)
        scope = f"{a['id']}/{p['media']}"
        if self.get("write-intent", scope):
            if time.monotonic() >= getattr(self, "recovery_retry", 0):
                self.recovery_retry = time.monotonic() + 15
                with serialized(self.directory):
                    current = self.get("account", "current")
                    intent = self.get("write-intent", scope)
                    if current.get("generation")==a["generation"] and intent:
                        self.recover_write(current, scope, intent)
            return
        probe = (
            *self.expected,
            p["media"],
            episode,
            bool(p["tracking"].get("rewatch")),
        )
        now = time.time()
        needs_probe = not self.tracking_probe or (
            self.tracking_probe[0] != probe or self.tracking_probe[1] <= now
        )
        watch = self.get("watch", key)
        enough_time = self.reached_threshold(p, watch)
        done = self.get("history", key) or self.get("skipped", key)
        job = dict(account=a["generation"], session=p["session"], media=p["media"])
        epoch = self.get("generation", "data")
        prop = self.get("pending", key)
        review = (
            prop
            and not prop.get("offline")
            and "status" in prop
            and prop.get("account") == a["generation"]
        )
        ready = enough_time and not done and not review and watch.get("retry", 0) <= now
        if ready:
            with self.transaction():
                self.tracked_context(job, episode, key)
                watch = self.get("watch", key)
                if watch.get("retry", 0) > now:
                    ready = False
                else:
                    self.put("watch", key, dict(watch, retry=now + 60))
        if not needs_probe and not ready:
            if review and not done:
                self.reply(proposal=prop)
            return

        # Observe remote rewatch cycles when an episode starts, even if an
        # older viewing already has time or progress recorded for that episode.
        self.tracking_probe = (probe, now + 60)
        try:
            entry = read_entry(self.credential(a), a["id"], p["media"])
        except SessionExpired:
            raise
        except AccountError:
            if ready and p["tracking"].get("keep_pending"):
                with self.transaction():
                    self.tracked_context(job, episode, key)
                    if epoch == self.get("generation", "data"):
                        self.put(
                            "pending",
                            key,
                            dict(
                                key=key,
                                window=self.window,
                                media=p["media"],
                                title=p.get("match_title", ""),
                                episode=episode,
                                offline=True,
                                account=a["generation"],
                                base={"session": p["session"]},
                            ),
                        )
            if ready:
                raise
            return

        with self.transaction():
            _, current = self.tracked_context(job, episode, key)
            if epoch != self.get("generation", "data"):
                return
            cached_entry = self.remember_entry(a, current, entry, prepare_rewatch=True)
            self.tracking_probe = (probe, float("inf"))
            if self.cycle(a, current) != key or not ready:
                return
            if not self.active_tracking(
                current, ("ask", "auto")
            ) or not self.reached_threshold(current, self.get("watch", key)):
                return
            mode = current["tracking"]["mode"]
            existing = self.get("pending", key)
            if (
                (
                    existing
                    and not existing.get("offline")
                    and "status" in existing
                    and existing.get("account") == a["generation"]
                )
                or self.get("history", key)
                or self.get("skipped", key)
            ):
                return

            remote_status = entry["status"]
            cycle = self.get("cycle", f"{a['id']}/{p['media']}")
            start_rewatch = (
                remote_status == "COMPLETED"
                and episode == 1
                and current["tracking"].get("rewatch")
                and cycle.get("phase") == "ready"
            )
            if entry["progress"] >= episode and not start_rewatch:
                self.put("history", key, {"progress": entry["progress"]})
                self.delete("pending", key)
                return

            status_accepted = (
                entry["id"]
                and remote_status is not None
                and remote_status == cached_entry.get("keep_tracking_status")
            )
            active_status = remote_status in ("CURRENT", "REPEATING") or status_accepted
            resume_rewatch = (
                remote_status in ("PAUSED", "DROPPED")
                and cycle.get("phase") == "active"
            )
            rewatching = start_rewatch or resume_rewatch or remote_status == "REPEATING"
            finish_rewatch = rewatching and episode == current["total"]
            status = None
            if finish_rewatch:
                status = "COMPLETED"
            elif start_rewatch or resume_rewatch:
                status = "REPEATING"
            elif not active_status:
                status = "CURRENT"
            repeat_count = min(entry["repeat"] + 1, 1000) if finish_rewatch else None
            base = dict(entry, session=p["session"])
            can_advance = (
                entry["id"]
                and active_status
                and not start_rewatch
                and not resume_rewatch
                and entry["progress"] + 1 == episode
            )
            prop = dict(
                revision=secrets.token_hex(8),
                title=p.get("match_title", ""),
                media=p["media"],
                window=self.window,
                key=key,
                episode=episode,
                before=entry["progress"],
                base=base,
                account=a["generation"],
                status=status,
                repeat_count=repeat_count,
                start_rewatch=start_rewatch,
                needs_review=mode == "ask" or not can_advance,
            )
            self.put("pending", key, prop)

        if mode == "auto" and can_advance:
            try:
                self.write(
                    dict(
                        job,
                        base=base,
                        target=episode,
                        automatic=True,
                        tracked_proposal=prop,
                        status=status,
                        repeat_count=repeat_count,
                    )
                )
            except (AccountError, OSError, sqlite3.Error):
                with self.transaction():
                    if self.get("pending", key) == prop:
                        self.put("pending", key, dict(prop, needs_review=True))
                raise
        else:
            self.reply(proposal=prop)

    def credit_loop(self, stop):
        # A separate SQLite connection keeps the monotonic sampler independent
        # of browser approval, provider requests and AniList response times.
        counter = Worker(self.db_path, self.window, self.settings)
        try:
            while not stop.is_set():
                try:
                    epoch = counter.get("generation", "data")
                    if counter.data_generation != epoch or counter.get(
                        "cancel", self.window
                    ):
                        counter.previous = None
                        counter.data_generation = epoch
                    counter.sample(credit_only=True)
                except (AccountError, sqlite3.Error, KeyError, ValueError):
                    counter.previous = None
                stop.wait(0.25)
        finally:
            counter.db.close()

    def defer_artwork(self,p,refresh,hit,include_album,sources=None):
        def render():
            worker = Worker(self.db_path,self.window,self.settings)
            try:
                for delay in (0,*MUSIC_RETRY_DELAYS):
                    until=time.monotonic()+delay
                    while True:
                        if (self.lookup_stop.is_set() or refresh!=worker.get("refresh",self.window) or
                            epoch!=worker.get("generation","cache") or
                            worker.recognition_context(p)!=worker.recognition_context(worker.get("player",self.window))):
                            return
                        remaining=until-time.monotonic()
                        if remaining<=0:
                            break
                        self.lookup_stop.wait(min(.25,remaining))
                    if not worker.recognize(p,artwork_only=(hit,include_album,sources)):
                        return
            except (AccountError,OSError,ValueError,sqlite3.Error):
                pass
            finally:
                worker.db.close()
        with self.artwork_lock:
            if self.artwork_context != (self.recognition_context(p), refresh):
                return
            if self.artwork_future:
                self.artwork_future.cancel()
            epoch=self.artwork_epoch
            self.artwork_future=self.artwork_pool.submit(render)

    def run(self):
        stop = threading.Event()
        self.lookup_stop=stop
        self.lookup_pool = ThreadPoolExecutor(max_workers=2,thread_name_prefix="lookup")
        self.artwork_pool = ThreadPoolExecutor(max_workers=2,thread_name_prefix="artwork")
        self.artwork_lock=threading.Lock()
        self.artwork_future=None
        self.artwork_context=None
        self.artwork_epoch=None
        sampler = threading.Thread(target=self.credit_loop, args=(stop,), daemon=True)
        sampler.start()
        try:
            self.operations()
        finally:
            stop.set()
            sampler.join()
            self.lookup_pool.shutdown(wait=False,cancel_futures=True)
            self.artwork_pool.shutdown(wait=False,cancel_futures=True)
            self.db.close()

    def operations(self):
        lookups = []
        lookup_context = None
        retry_at = 0
        attempts = (0,0)
        while True:
            row = None
            job = None
            self.expected = None
            self.notice_page = ""
            try:
                epoch = self.get("generation", "data")
                if self.data_generation != epoch:
                    self.previous = None
                    self.tracking_probe = None
                    self.data_generation = epoch
                cache_epoch = self.get("generation", "cache")
                if self.cache_generation != cache_epoch:
                    self.resolved = None
                    self.lookup_retry = 0
                    self.cache_generation = cache_epoch
                cancellation = self.get("cancel", self.window)
                if cancellation:
                    with self.transaction():
                        self.db.execute(
                            "DELETE FROM records WHERE category='pending' AND json_extract(value,'$.window')=? AND json_extract(value,'$.base.session')=?",
                            (self.window, cancellation.get("session")),
                        )
                        self.db.execute(
                            "DELETE FROM records WHERE category='job' AND json_extract(value,'$.window')=? AND json_extract(value,'$.session')=?",
                            (self.window, cancellation.get("session")),
                        )
                        self.delete("cancel", self.window)
                    self.previous = None

                row = self.db.execute(
                    "SELECT scope,value FROM records WHERE category='job' AND json_extract(value,'$.window')=? ORDER BY rowid LIMIT 1",
                    (self.window,),
                ).fetchone()
                if row:
                    with self.transaction():
                        if self.get("job", row[0]):
                            self.delete("job", row[0])
                        else:
                            row = None
                if row:
                    job = json.loads(row[1])
                    self.notice_page = job.get("notice_page", "")
                    if job["op"] not in ("connect", "disconnect", "reset"):
                        self.expected = (job.get("account"), job.get("session"))
                    self.handle(job)
                else:
                    p = self.get("player", self.window)
                    if self.lookup_pool is None:
                        self.recognize(p)
                    else:
                        context = (self.recognition_context(p),self.get("refresh",self.window),cache_epoch)
                        if context!=lookup_context:
                            lookup_context,retry_at,attempts=context,0,(0,0)
                            with self.artwork_lock:
                                self.artwork_context=context[:2]
                                self.artwork_epoch=context[2]
                                if self.artwork_future:
                                    self.artwork_future.cancel()
                        for running in lookups[:]:
                            key, future = running
                            if future.done():
                                lookups.remove(running)
                                if key==context and not future.cancelled():
                                    retry_at,attempts=future.result()
                        if p.get("allowed") and p.get("source","original")!="original" and retry_at is not None and (
                            time.monotonic()>=retry_at and len(lookups)<2 and all(key!=context for key,_ in lookups)
                        ):
                            future=self.lookup_pool.submit(self.background_lookup,p,attempts,context[1:])
                            lookups.append((context,future))
                            retry_at=None
                    a = self.get("account", "current")
                    self.propose(a, p)
            except AccountError as exc:
                if isinstance(exc, SessionExpired) and self.expected:
                    with self.transaction():
                        current = self.get("account", "current")
                        if current.get("generation") == self.expected[
                            0
                        ] and not current.get("expired"):
                            self.put("account", "current", dict(current, expired=True))
                if job:
                    if job.get("quiet") or job.get("account") != self.get(
                        "account", "current"
                    ).get("generation"):
                        continue
                self.reply(message=str(exc), offline=True)
            except Exception:
                if not job or not job.get("quiet"):
                    self.reply(
                        message="Operation failed. Check the connection and settings."
                    )
            time.sleep(0.25)

    def background_lookup(self,p,attempts,epochs):
        worker=Worker(self.db_path,self.window,self.settings)
        worker.artwork_pool=self.artwork_pool
        worker.defer_artwork=self.defer_artwork
        try:
            if (worker.get("refresh",self.window),worker.get("generation","cache"))!=epochs:
                return None,attempts
            worker.last_refresh=worker.get("refresh",self.window)
            worker.resolved=worker.recognition_context(p)
            worker.music_attempts,worker.video_attempts=attempts
            worker.lookup_retry=time.monotonic()
            worker.recognize(p)
            return worker.lookup_retry or None,(worker.music_attempts,worker.video_attempts)
        except (AccountError,OSError,ValueError,KeyError,sqlite3.Error):
            return None,attempts
        finally:
            worker.db.close()


def watch_owner(pid):
    # The worker may be blocked in a browser or network request when mpv is
    # killed. The OS closes both SQLite connections when the watchdog exits.
    if os.name == "nt":
        import ctypes
        from ctypes import wintypes

        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
        kernel.OpenProcess.restype = wintypes.HANDLE
        kernel.WaitForSingleObject.argtypes = (wintypes.HANDLE, wintypes.DWORD)
        kernel.WaitForSingleObject.restype = wintypes.DWORD
        kernel.CloseHandle.argtypes = (wintypes.HANDLE,)
        handle = kernel.OpenProcess(0x00100000, False, pid)  # SYNCHRONIZE
        if not handle:
            error = ctypes.get_last_error()
            if error == 87:  # ERROR_INVALID_PARAMETER: the process already exited
                sys.exit(0)
            raise ctypes.WinError(error)

        def wait():
            kernel.WaitForSingleObject(handle, 0xFFFFFFFF)  # INFINITE
            kernel.CloseHandle(handle)
            os._exit(0)
    else:

        def wait():
            while os.getppid() == pid:
                time.sleep(0.25)
            os._exit(0)

    threading.Thread(target=wait, daemon=True).start()


if __name__ == "__main__":
    if len(sys.argv) > 5:
        watch_owner(int(sys.argv[5]))
    settings = json.loads(sys.argv[3]) if len(sys.argv) > 3 else json.load(sys.stdin)
    config = (
        Path(sys.argv[4])
        if len(sys.argv) > 4
        else (Path(sys.argv[1]).parent.parent / "script-opts" / "rich-presence.conf")
    )
    if config.is_file():
        for line in config.read_text(encoding="utf-8-sig").splitlines():
            key, sep, value = line.partition("=")
            if sep and key.strip() in ("tmdb_key", "acoustid_key"):
                settings[key.strip()] = value.strip().strip('"')
    Worker(sys.argv[1], sys.argv[2], settings).run()
