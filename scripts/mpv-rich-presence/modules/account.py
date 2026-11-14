# SPDX-License-Identifier: AGPL-3.0-or-later
import base64
import hashlib
import html
import json
import os
import re
import secrets
import socket
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from http.server import BaseHTTPRequestHandler, HTTPServer

USER_AGENT = "mpv-rich-presence (https://github.com/Sirye8/mpv-rich-presence)"


class AccountError(Exception):
    pass


class SessionExpired(AccountError):
    pass


class EntryChanged(AccountError):
    def __init__(self, entry):
        super().__init__("AniList progress changed. Refresh and review the edit.")
        self.entry = entry


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None


def graphql(query, variables, token=None):
    headers = {
        "User-Agent": USER_AGENT,
        "Content-Type": "application/json",
        "Accept": "application/json",
    }
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(
        "https://graphql.anilist.co",
        headers=headers,
        data=json.dumps({"query": query, "variables": variables}).encode(),
    )
    try:
        with urllib.request.build_opener(NoRedirect).open(req, timeout=8) as response:
            result = json.load(response)
    except urllib.error.HTTPError as exc:
        if exc.code == 401:
            raise SessionExpired("Session expired. Reconnect to AniList.") from None
        if exc.code == 429:
            raise AccountError("AniList rate limit reached. Try again later.") from None
        raise AccountError("AniList request failed (HTTP %d)." % exc.code) from None
    except (ValueError, OSError):
        raise AccountError("AniList is offline or timed out.") from None
    if result.get("errors") or not isinstance(result.get("data"), dict):
        raise AccountError("AniList rejected the request.")
    return result["data"]


def read_entry(token, viewer, media, call=graphql):
    # Page returns an empty list for a missing entry. Query errors stay errors.
    data = call(
        """query($viewer:Int!,$media:Int!){Page(perPage:1){
        mediaList(userId:$viewer,mediaId:$media){id userId mediaId progress status repeat updatedAt}}}""",
        {"viewer": viewer, "media": media},
        token,
    )
    entries = data["Page"]["mediaList"]
    if not isinstance(entries, list):
        raise AccountError("AniList returned an incomplete list.")
    if not entries:
        return dict(
            id=None,
            viewer=viewer,
            media=media,
            progress=0,
            status=None,
            repeat=0,
            updatedAt=None,
        )
    entry = dict(entries[0])
    if entry.pop("userId") != viewer or entry.pop("mediaId") != media:
        raise AccountError("The entry belongs to a different viewer or media.")
    return dict(entry, viewer=viewer, media=media)


def save_progress(
    token, base, target, total, valid, call=graphql, status=None, repeat_count=None,
    before_send=lambda: None,
):
    if type(target) is not int or target < 0 or (total and target > total):
        raise AccountError("Progress is out of range.")
    if status is not None and status not in (
        "CURRENT",
        "COMPLETED",
        "REPEATING",
        "PAUSED",
        "DROPPED",
        "PLANNING",
    ):
        raise AccountError("Unknown list status.")
    if repeat_count is not None and (
        type(repeat_count) is not int or not 0 <= repeat_count <= 1000
    ):
        raise AccountError("Rewatch count is out of range.")

    def confirmed(row):
        return (
            row["progress"] == target
            and (status is None or row["status"] == status)
            and (repeat_count is None or row["repeat"] == repeat_count)
        )

    fresh = read_entry(token, base["viewer"], base["media"], call)
    if any(fresh[k] != base.get(k) for k in fresh):
        raise EntryChanged(fresh)
    valid()
    if base["id"] and confirmed(fresh):
        return fresh
    field, value = ("id", base["id"]) if base["id"] else ("mediaId", base["media"])
    variables = {"id": value, "progress": target}
    arguments = field + ":$id,progress:$progress"
    declarations = "$id:Int!,$progress:Int!"
    if status is not None:
        variables["status"] = status
        arguments += ",status:$status"
        declarations += ",$status:MediaListStatus!"
    if repeat_count is not None:
        variables["repeat"] = repeat_count
        arguments += ",repeat:$repeat"
        declarations += ",$repeat:Int!"
    query = (
        "mutation("
        + declarations
        + "){SaveMediaListEntry("
        + arguments
        + "){id userId mediaId progress status repeat updatedAt}}"
    )
    before_send()
    try:
        row = dict(call(query, variables, token)["SaveMediaListEntry"])
    except SessionExpired:
        raise
    except AccountError:
        # Never repeat a mutation whose acknowledgement was lost.
        row = read_entry(token, base["viewer"], base["media"], call)
        if not confirmed(row):
            raise AccountError(
                "Update unconfirmed. Refresh before trying again."
            ) from None
        return row
    if row.pop("userId") != base["viewer"] or row.pop("mediaId") != base["media"]:
        raise AccountError("Unexpected mutation result. Refresh the entry.")
    if not confirmed(row):
        raise AccountError("Update unconfirmed. Refresh before trying again.")
    return dict(row, viewer=base["viewer"], media=base["media"])


def signin_page(title, description, content=""):
    return f"""<!doctype html><html lang="en"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{html.escape(title)} | mpv Rich Presence</title>
<style>
:root {{color-scheme:dark;font:16px system-ui,sans-serif;background:#0b1622;color:#e5edf5}}
body {{margin:0;min-height:100vh;display:grid;place-items:center}}
main {{box-sizing:border-box;width:min(92vw,30rem);padding:2rem;background:#152232;border:1px solid #293b50;border-radius:20px}}
header {{font-size:.85rem;font-weight:700;color:#71caff}}
h1 {{font-size:1.55rem;margin:.6rem 0}} p {{line-height:1.55;color:#bacadd}}
.profile {{display:flex;align-items:center;gap:1rem;margin:1.4rem 0}}
img {{width:3.5rem;height:3.5rem;border-radius:50%;object-fit:cover}}
form {{display:flex;gap:.65rem;flex-wrap:wrap;align-items:center}}
button,a {{font:inherit;color:#8ad1ff}} button {{cursor:pointer;border:1px solid #426480;border-radius:10px;background:#1b3046;padding:.65rem .9rem}}
button.primary {{background:#68c4ff;color:#0b1622;border-color:transparent;font-weight:700}}
:focus-visible {{outline:3px solid #a6ddff;outline-offset:3px}}
</style><main><header>mpv Rich Presence · AniList</header>
<h1>{html.escape(title)}</h1><p>{html.escape(description)}</p>{content}</main></html>"""


def callback_server(state, port=47653, code_flow=False, exchange=None, review=None, connect=None):
    class Callback(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def send_body(self, code, body):
            self.send_response(code)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header(
                "Content-Security-Policy",
                "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; "
                "img-src https://s4.anilist.co; connect-src 'self'; form-action 'self'; frame-ancestors 'none'",
            )
            self.end_headers()
            self.wfile.write(body.encode())

        def show_review(self, token):
            try:
                viewer = review(token)
            except (AccountError, OSError, ValueError, KeyError) as exc:
                self.server.error = str(exc) if isinstance(exc, AccountError) else "AniList did not return an account profile."
                self.send_body(502, signin_page("Sign-in failed", self.server.error))
                return
            self.server.provisional = (token, viewer)
            name = html.escape(viewer["name"])
            avatar = (viewer.get("avatar") or {}).get("medium") or ""
            image = (f'<img src="{html.escape(avatar, quote=True)}" alt="">'
                     if avatar.startswith("https://s4.anilist.co/") else "")
            self.send_body(200, signin_page("Connect your AniList account",
                "Confirm the account you want to use for watch tracking in mpv.",
                f"""<script>history.replaceState(null,"","/callback");
                addEventListener("load",()=>setTimeout(()=>{{
                    const form=document.querySelector("form");
                    if(form){{const p=document.createElement("p");
                    p.textContent="This sign-in expired. Return to mpv and choose Connect again.";
                    form.replaceWith(p);}}
                }}, {max(0, int((self.server.deadline-time.monotonic())*1000))}));</script>
                <div class="profile">{image}<strong>{name}</strong></div>
                <form action="/confirm" method="post"><input type="hidden" name="state" value="{state}">
                <button class="primary" name="action" value="connect">Connect as {name}</button>
                <button name="action" value="switch">Use another account</button>
                <button name="action" value="cancel">Cancel</button></form>"""))

        def do_GET(self):
            request = urllib.parse.urlsplit(self.path)
            if self.headers.get("Host") != "127.0.0.1:%d" % self.server.server_port:
                return self.send_error(403)
            if request.path != "/callback":
                return self.send_error(404)
            if code_flow:
                params = urllib.parse.parse_qs(request.query)
                if not secrets.compare_digest(params.get("state", [""])[0], state):
                    return self.send_error(400)
                if review and params.get("error"):
                    self.server.error = "AniList authorization was declined."
                    return self.send_body(400, signin_page("Authorization declined",
                        "Return to mpv and choose Connect to try again."))
                if not params.get("code") or self.server.provisional:
                    return self.send_error(400)
                code = params["code"][0]
                if exchange:
                    self.server.code = code
                    try:
                        token = exchange(code, None, False)
                    except ClientSecretRequired:
                        self.send_body(
                            200,
                            f"""<title>mpv Rich Presence</title>
                        <script>history.replaceState(null,"","/callback")</script>
                        <h2>Connect a personal AniList application</h2>
                        <p>AniList requires the secret for the application you registered. This form runs on your computer.
                        Only the owner of that application should enter its secret.</p>
                        <form action="/finish" method="post"><input type="hidden" name="state" value="{state}">
                        <label>Personal client secret <input type="password" name="secret" required autocomplete="off"></label>
                        <p><label><input type="checkbox" name="remember"> Save in my OS credential store</label></p>
                        <button>Finish sign-in</button></form>""",
                        )
                        return
                    except (AccountError, OSError) as exc:
                        self.server.error = (
                            str(exc)
                            if isinstance(exc, AccountError)
                            else "Sign-in failed during the code exchange."
                        )
                        self.send_body(502, signin_page("Sign-in failed", self.server.error))
                        return
                    if review:
                        return self.show_review(token)
                        self.server.result = token
                else:
                    self.server.result = code
                self.send_body(
                    200,
                    "<title>mpv Rich Presence</title>Return to mpv to see the sign-in result.",
                )
                return
            self.send_body(
                200,
                """<title>mpv Rich Presence</title><p id="message">Finishing sign-in...</p>
<script>const fragment=location.hash.slice(1);history.replaceState(null,"","/callback");
fetch("/callback",{method:"POST",body:fragment}).then(r=>document.querySelector("p").textContent=
r.ok?"Return to mpv. You can close this tab.":"Sign-in failed. Try connecting again in mpv.");</script>""",
            )

        def do_POST(self):
            origin = "http://127.0.0.1:%d" % self.server.server_port
            path = "/finish" if code_flow else "/callback"
            # Browsers may send a null Origin for a same-site form under a
            # no-referrer policy. The form still carries the nonce from the
            # state-verified callback. Reject foreign hosts and origins.
            allowed_origins = (origin, "null", None) if code_flow else (origin,)
            if (
                (self.path != path and not (review and self.path=="/confirm"))
                or self.headers.get("Host") != origin.removeprefix("http://")
                or self.headers.get("Origin") not in allowed_origins
            ):
                return self.send_error(403)
            try:
                size = int(self.headers.get("Content-Length", "0"))
                if not 0 < size <= 16384:
                    raise ValueError()
                result = urllib.parse.parse_qs(self.rfile.read(size).decode("ascii"))
                if not secrets.compare_digest(result["state"][0], state):
                    raise ValueError()
                if self.path=="/confirm":
                    if not self.server.provisional:
                        return self.send_error(400)
                    if time.monotonic()>=self.server.deadline:
                        self.server.error = "Sign-in timed out."
                        return self.send_body(410, signin_page("Sign-in expired", "Return to mpv and choose Connect again."))
                    token, viewer = self.server.provisional
                    self.server.provisional = None
                    action = result.get("action", [""])[0]
                    if action == "switch":
                        self.server.error = "Switch accounts on AniList, then reconnect."
                        return self.send_body(200, signin_page("Use another account",
                            "Switch accounts on AniList, then return to mpv and choose Connect again.",
                            '<a href="https://anilist.co/" rel="noreferrer" target="_blank">Open AniList</a>'))
                    if action != "connect":
                        self.server.error = "Sign-in cancelled."
                        return self.send_body(200, signin_page("Sign-in cancelled",
                            "You can close this tab and return to mpv."))
                    try:
                        persistent = connect(token, viewer)
                    except Exception as exc:
                        self.server.error = str(exc) if isinstance(exc, AccountError) else "mpv could not save this connection."
                        return self.send_body(502, signin_page("Connection failed", self.server.error))
                    self.server.result = token
                    return self.send_body(200, signin_page(
                        "Connected" if persistent else "Connected for this session",
                        f"You are connected as {viewer['name']}. Return to mpv or close this tab."))
                if code_flow:
                    if not exchange or not getattr(self.server, "code", None):
                        return self.send_error(400)
                    try:
                        token = exchange(
                            self.server.code, result["secret"][0], "remember" in result
                        )
                    except (AccountError, OSError):
                        self.server.error = "AniList declined the code exchange. Reconnect with your current credentials."
                        self.send_body(400, self.server.error)
                        return
                    if review:
                        return self.show_review(token)
                    self.server.result = token
                    self.send_body(200, "Connected. Return to mpv.")
                    return
                token = result["access_token"][0]
                if not token.isascii() or any(c.isspace() for c in token):
                    raise ValueError()
                self.server.result = token
            except (KeyError, ValueError):
                return self.send_error(400)
            self.send_body(200, "Connected")

    class LoopbackServer(HTTPServer):
        allow_reuse_address = False

        def server_bind(self):
            if os.name == "nt":
                self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
            super().server_bind()

    server = LoopbackServer(("127.0.0.1", port), Callback)
    server.timeout = 1
    server.error = None
    server.result = None
    server.provisional = None
    server.deadline = time.monotonic() + 180
    return server


class ClientSecretRequired(AccountError):
    pass


def exchange_code(client_id, code, verifier, secret=None):
    fields = dict(
        grant_type="authorization_code",
        client_id=client_id,
        redirect_uri="http://127.0.0.1:47653/callback",
        code=code,
        code_verifier=verifier,
    )
    if secret:
        fields["client_secret"] = secret
    request = urllib.request.Request(
        "https://anilist.co/api/v2/oauth/token",
        data=urllib.parse.urlencode(fields).encode(),
        headers={
            "Accept": "application/json",
            "User-Agent": "mpv-rich-presence (https://github.com/Sirye8/mpv-rich-presence)",
        },
    )
    try:
        with urllib.request.build_opener(NoRedirect).open(
            request, timeout=10
        ) as response:
            return json.load(response)["access_token"]
    except urllib.error.HTTPError as exc:
        if exc.code == 401:
            raise ClientSecretRequired(
                "AniList requires client authentication."
            ) from None
        raise AccountError("AniList declined the authorization code.") from None


def wake_exchange(
    broker, client_id, valid, open_url, *, clock=time.monotonic, sleep=time.sleep
):
    """Wake an idle service only after Connect. No account data is sent."""
    deadline = clock() + 100
    while clock() < deadline:
        valid()
        try:
            request = urllib.request.Request(
                broker + "/health", headers={"User-Agent": USER_AGENT}
            )
            with open_url(request, timeout=8) as response:
                health = json.load(response)
            if (
                health.get("service") != "mpv-anilist-login"
                or str(health.get("client_id")) != str(client_id)
                or health.get("redirect_uri") != broker + "/callback"
            ):
                raise AccountError(
                    "The sign-in service is configured for a different AniList client."
                )
            if health.get("configured") is False:
                raise AccountError(
                    "The sign-in service is missing its AniList credential."
                )
            return
        except urllib.error.HTTPError as exc:
            if exc.code not in (429, 502, 503, 504):
                raise AccountError(
                    f"Sign-in service health check failed (HTTP {exc.code})."
                ) from None
        except (OSError, ValueError):
            pass
        sleep(min(2, max(0, deadline - clock())))
    raise AccountError(
        "The sign-in service did not wake up. Select Connect to try again."
    )


def authorize(
    client_id, valid, flow="pkce", vault=None, broker="", progress=lambda message: None,
    review=None, connect=None,
):
    if not str(client_id).isdigit():
        raise AccountError("Set anilist_client_id in rich-presence.conf first.")
    state = secrets.token_urlsafe(32)
    verifier = secrets.token_urlsafe(48)
    code_flow = flow == "pkce"
    redirect = "http://127.0.0.1:47653/callback"
    if broker and not re.fullmatch(r"https://[a-zA-Z0-9.-]+", broker):
        raise AccountError("The public sign-in service needs an HTTPS origin.")

    def broker_post(path, payload):
        req = urllib.request.Request(
            broker + path,
            data=json.dumps(payload).encode(),
            headers={
                "Content-Type": "application/json",
                "Accept": "application/json",
                "User-Agent": USER_AGENT,
            },
        )
        try:
            with urllib.request.build_opener(NoRedirect).open(
                req, timeout=15
            ) as response:
                return json.load(response)
        except urllib.error.HTTPError as exc:
            try:
                message = json.loads(exc.read(2048)).get("error", "")
            except (ValueError, OSError):
                message = ""
            if isinstance(message, str) and message.startswith(
                ("AniList code exchange failed (HTTP ", "Sign-in failed at ")
            ):
                raise AccountError(message[:180]) from None
            raise AccountError(
                f"Sign-in service rejected {path[1:]} (HTTP {exc.code}). Reconnect in mpv."
            ) from None

    def exchange(code, secret, remember):
        valid()
        if broker:
            return broker_post("/redeem", {"ticket": code, "verifier": verifier})[
                "access_token"
            ]
        key = "client-" + str(client_id)
        credential = secret or (vault.read(key) if vault else None)
        if not credential:
            raise ClientSecretRequired("Personal application secret required.")
        token = exchange_code(client_id, code, verifier, credential)
        if secret and remember and vault:
            vault.write(key, secret)
        return token

    with callback_server(state, code_flow=code_flow, exchange=exchange, review=review, connect=connect) as server:
        params = dict(
            client_id=client_id,
            response_type="code" if code_flow else "token",
            state=state,
            redirect_uri=redirect,
        )
        if code_flow:
            params["code_challenge_method"] = "S256"
            params["code_challenge"] = (
                base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest())
                .rstrip(b"=")
                .decode()
            )
        query = urllib.parse.urlencode(params)
        url = "https://anilist.co/api/v2/oauth/authorize?" + query
        if broker:
            progress("Connecting to AniList sign-in…")
            wake_exchange(
                broker, client_id, valid, urllib.request.build_opener(NoRedirect).open
            )
            valid()
            url = broker_post(
                "/start", {"challenge": params["code_challenge"], "state": state}
            )["authorize"]
            if not url.startswith(
                "https://anilist.co/api/v2/oauth/authorize?"
            ) or urllib.parse.parse_qs(urllib.parse.urlsplit(url).query).get(
                "client_id"
            ) != [str(client_id)]:
                raise AccountError("Invalid authorization URL from sign-in service.")
        progress("Approve access in your browser, then return to mpv.")
        if not webbrowser.open(url):
            raise AccountError("Could not open your browser.")
        limit = server.deadline = time.monotonic() + 180
        while time.monotonic() < limit and not server.result and not server.error:
            valid()
            server.handle_request()
        if server.error:
            raise AccountError(server.error)
        if not server.result:
            raise AccountError("Sign-in timed out.")
        return server.result


class Vault:
    """Keep a session copy when no OS credential service is available."""

    def __init__(self):
        self.session = {}
        self.keyring = None
        try:
            if os.name == "nt":
                from windows_vault import WindowsVault

                self.keyring = WindowsVault()
            else:
                from keyring.backends.SecretService import Keyring

                self.keyring = Keyring()
        except (ImportError, RuntimeError):
            pass

    def write(self, key, value, remember=True):
        self.session[key] = value
        if self.keyring and remember:
            try:
                self.keyring.set_password("mpv-rich-presence", key, value)
                return True
            except Exception:
                pass
        return False

    def read(self, key):
        if key in self.session:
            return self.session[key]
        if self.keyring:
            try:
                return self.keyring.get_password("mpv-rich-presence", key)
            except Exception:
                pass
        return None

    def forget(self, key, persistent):
        if persistent:
            if not self.keyring:
                raise AccountError("Unlock the OS credential store to disconnect.")
            if self.keyring.get_password("mpv-rich-presence", key) is not None:
                self.keyring.delete_password("mpv-rich-presence", key)
        self.session.pop(key, None)
