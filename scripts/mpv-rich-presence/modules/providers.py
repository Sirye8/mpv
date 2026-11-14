# SPDX-License-Identifier: AGPL-3.0-or-later
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import unicodedata
import urllib.parse as url
from urllib.error import HTTPError
import urllib.request
from account import AccountError, NoRedirect, graphql

TMDB_RELAY = "https://mpv-anilist-login.si-based.workers.dev/metadata"
# AcoustID identifies the application with this client key. Lookup does not use a user key.
ACOUSTID_CLIENT = "wiBIFjWvX2"


def match_name(value):
    return " ".join(
        re.findall(r"[^\W_]+", unicodedata.normalize("NFKC", value).casefold())
    )


VIDEO_RELEASE = (
    r"(?:\d{3,4}p|4k|uhd|bluray|web(?:[- ]?dl|rip)?|hdtv|remux|hdr|dvdrip|"
    r"proper|repack\d*|remastered|extended|imax|se|director['’ ]s[ ._-]+cut|"
    r"theatrical(?:[ ._-]+cut)?|unrated|criterion|special[ ._-]+edition)"
)


def video_query(label):
    """Extract a public title and common episode/year markers from a basename."""
    if not label or re.search(r"[/\\?&#\x00-\x1f]|://", label):
        return "", "", None, None
    title = re.sub(
        r"\.(mkv|mp4|avi|mov|webm|m4v|ts|mpg|mpeg|wmv)$", "", label, flags=re.I
    )
    title = re.sub(r"^\[[^]]+\]\s*", "", title).replace("_", " ")
    episode = re.search(
        r"(?<!\w)(?:s(\d{1,2})[ ._-]*e(\d{1,3})|(\d{1,2})x(\d{2,3}))(?!\d)", title, re.I
    )
    date = re.search(r"(?<!\d)(\d{4}-\d{2}-\d{2})(?!\d)", title)
    end = min((m.start() for m in (episode, date) if m), default=len(title))
    title = title[:end].replace(".", " ").replace("_", " ").strip(" -")
    years = list(re.finditer(r"(?<!\w)((?:18|19|20)\d{2})(?!\w)", title))
    year = ""
    if years and years[-1].start() > 0:
        match = years[-1]
        tail = title[match.end() :].strip(" ()[]{}-")
        if not tail or re.match(
            VIDEO_RELEASE + r"\b", tail, re.I
        ):
            title, year = title[: match.start()].strip(" ([{-"), match[1]
    title = re.split(
        r"(?i)\s+[\[(]?(?:\d{3,4}p|4k|uhd|bluray|web[- ]?dl|webrip|hdtv|remux)\b",
        title,
        maxsplit=1,
    )[0]
    numbers = (episode[1] or episode[3], episode[2] or episode[4]) if episode else None
    return (
        " ".join(title.split()),
        year,
        numbers,
        date[1] if date and not numbers else None,
    )


def generic_clip(label):
    stem = re.sub(r"\.[a-z0-9]{2,5}$", "", label, flags=re.I)
    return bool(
        re.match(
            r"(?i)^(?:img|vid|dsc|dji|pxl|mov|mvi|gopr|g[hp]0\d)[ _.-]*\d"
            r"|^(?:screen[ _.-]*(?:recording|capture)|untitled|test[ _.-]*clip|sample)(?:[ _.(\[-]|$)",
            stem,
        )
    )


def wikidata_movies(query, throttle):
    api = "https://www.wikidata.org/w/api.php"
    data = fetch(
        api,
        dict(
            action="wbsearchentities",
            search=query,
            language="en",
            format="json",
            limit=12,
        ),
    )
    wanted = match_name(query)
    matches = {
        row["id"]: row
        for row in data["search"]
        if re.fullmatch(r"Q[1-9]\d*", row.get("id", ""))
        and (
            match_name(row.get("label", "")) == wanted
            or match_name(row.get("match", {}).get("text", "")) == wanted
        )
    }
    if not matches:
        return []
    throttle("wikidata")
    entities = fetch(
        api,
        dict(
            action="wbgetentities", ids="|".join(matches), props="claims", format="json"
        ),
    )["entities"]

    def values(claims, prop):
        return [
            statement.get("mainsnak", {}).get("datavalue", {}).get("value", {})
            for statement in claims.get(prop, [])
            if statement.get("rank") != "deprecated"
        ]

    result = []
    for entity_id, row in matches.items():
        claims = entities.get(entity_id, {}).get("claims", {})
        if not any(v.get("id") in {"Q11424", "Q24869"} for v in values(claims, "P31")):
            continue
        years = sorted(
            {
                date[1]
                for v in values(claims, "P577")
                if (date := re.match(r"\+(\d{4})-", v.get("time", "")))
            }
        )
        name = row["label"]
        result.append(
            dict(
                id=entity_id,
                kind="movie",
                name=name,
                match=query,
                title=name + (f" ({years[0]})" if years else ""),
                year=years[0] if years else "",
                years=years,
                link="https://www.wikidata.org/wiki/" + entity_id,
            )
        )
    return result


USER_AGENT = "mpv-rich-presence/1.0 (https://github.com/Sirye8/mpv-rich-presence)"


def fetch(base, params=None, headers=None, body=None, *, timeout=8):
    if params:
        base += "?" + url.urlencode(params)
    headers = dict(headers or {})
    headers["User-Agent"] = USER_AGENT
    with urllib.request.build_opener(NoRedirect).open(
        urllib.request.Request(base, data=body, headers=headers), timeout=timeout
    ) as r:
        payload = r.read(2_000_001)
    if len(payload) > 2_000_000:
        raise AccountError("Provider response was too large.")
    return json.loads(payload)


def tmdb_request(path, settings, params=None):
    token = settings.get("tmdb_key")
    try:
        if token:
            return fetch(
                "https://api.themoviedb.org/3" + path,
                params,
                {"Authorization": "Bearer " + token},
            )
        return fetch(TMDB_RELAY + path, params)
    except (OSError, ValueError):
        raise AccountError(
            "TMDB is unavailable. Check the connection or try again later."
        ) from None


def public_query(text):
    text = text.strip()
    if not text or len(text) > 180 or re.search(r"[/\\:?&#\x00-\x1f]", text):
        raise AccountError(
            "Enter a title or provider ID without paths or URL parameters."
        )
    return text


def musicbrainz_terms(**fields):
    terms = []
    for name, text in fields.items():
        if text:
            text = text.strip()
            if len(text) > 180 or re.search(
                r"[\x00-\x1f]|://|^(?:[/\\]|[A-Za-z]:[/\\])", text
            ):
                raise AccountError("Enter music tags without a file path or URL.")
            text = text.replace("\\", "\\\\").replace('"', '\\"')
            terms.append(f'{name}:"{text}"')
    return " AND ".join(terms)


def musicbrainz_artist(item):
    return "".join(
        a.get("name", "") + a.get("joinphrase", "")
        for a in item.get("artist-credit", [])
    )


MUSIC_SUFFIX = re.compile(
    r"\s*(?:[\[(]\s*|\s[-–]\s*|\s+)(?:(?:feat(?:uring)?|ft)\.?\s+.+|"
    r"(?:\d{4}\s+)?(?:digital\s+)?remaster(?:ed)?(?:\s+(?:in\s+)?\d{4})?(?:\s+version)?|"
    r"from\s+(?:the\s+)?(?:series|film|movie|motion picture)\s+[^)\]]+[)\]])"
    r"[\])]?\s*$",
    re.I,
)


def music_title(title):
    title = title.strip()
    while match := MUSIC_SUFFIX.search(title):
        title = title[: match.start()].rstrip()
    return title


def music_names(name, *, album=False):
    """Keep the full tag and recognize paired native and romanized names."""
    name = music_title(name)
    variants = [name]
    parts = re.split(r"\s+[-–|]\s+|\s*[~～／/]\s*", name, maxsplit=1)
    if len(parts) == 2:
        scripts = [
            {
                unicodedata.name(ch, "").startswith("LATIN ")
                for ch in part
                if ch.isalpha()
            }
            for part in parts
        ]
        if {frozenset(script) for script in scripts} == {
            frozenset({True}),
            frozenset({False}),
        }:
            variants.extend(parts)
        elif (
            not album
            and re.search("[~～]", name)
            and len(match_name(parts[1]).split()) >= 3
        ):
            variants.append(parts[1])
    if album:
        edition = re.sub(
            r"\s*[(\[]\s*(?:bonus|deluxe|expanded)(?: edition| version)?\s*[)\]]\s*$",
            "",
            name,
            flags=re.I,
        )
        if edition != name:
            variants.append(edition.rstrip())
        # Stores sometimes append the composer's credit to the score title.
        score = re.sub(r"(\(original (?:score|soundtrack))\s+by\s+[^)]+\)$",
                       r"\1)", name, flags=re.I)
        if score != name:
            variants.append(score)
        wrapped = re.search(r"(?i)(?:album|アルバム)\s*[「『](.+?)[」』]$", name)
        theme = re.search(r"(?i)\s*[(（]\s*TV\s*(?:アニメ|anime\b)", name)
        if wrapped:
            variants.append(wrapped[1])
        if theme:
            variants.append(name[: theme.start()])
        if re.fullmatch(r"I{2,4}", name):
            variants.append("l" * len(name))
        if re.fullmatch(r"l{2,4}", name):
            variants.append("I" * len(name))
    return tuple(dict.fromkeys(part for part in variants if part))


def same_music_name(first, second, *, album=False):
    return bool(
        {match_name(name) for name in music_names(first, album=album)}
        & {match_name(name) for name in music_names(second, album=album)}
    )


def music_search_field(field, name):
    terms = []
    for value in music_names(name, album=field != "recording"):
        try:
            terms.append(musicbrainz_terms(**{field: value}))
        except AccountError:
            continue
    return "(" + " OR ".join(terms) + ")" if terms else ""


def music_artists(credit):
    return [
        part.strip()
        for part in re.split(
            r"[;\x00]|\s+(?:feat(?:uring)?|ft)\.?\s+", credit, flags=re.I
        )
        if part.strip()
    ]


def same_music_credit(expected, item):
    actual = item.get("artist", "")
    if match_name(expected) == match_name(actual):
        return True
    names = {
        match_name(part) for part in (item.get("artist_names") or music_artists(actual))
    }
    if {match_name(part) for part in music_artists(expected)} == names:
        return bool(expected)
    # These separators can also be part of a band's name. Only split when the
    # recording actually credits multiple artists.
    return (
        len(names) > 1
        and {
            match_name(part)
            for credit in music_artists(expected)
            for part in re.split(r",\s*|\s+(?:&|x|and)\s+", credit, flags=re.I)
        }
        == names
    )


def music_edition(release):
    group = release.get("release-group") or {}
    return dict(
        release=release.get("id"),
        album=release.get("title", ""),
        release_group=group.get("id"),
        group_title=group.get("title", ""),
        release_date=release.get("date") or "",
    )


def prefer_music_date(editions, date):
    if not re.fullmatch(r"\d{4}(?:-\d{2}-\d{2})?", date):
        return editions
    dated = [row for row in editions if row.get("release_date", "").startswith(date)]
    if not dated:
        return editions
    groups = {row.get("release_group") for row in dated} - {None}
    return dated + [
        row
        for row in editions
        if row not in dated and row.get("release_group") in groups
    ]


def musicbrainz_album(artist, album, date, throttle):
    """Find artwork for a tagged edition, including translated album titles."""
    query = music_search_field("release", album)
    if not query:
        return None
    throttle("musicbrainz")
    credits = music_artists(artist)
    if not credits:
        return None
    rows = fetch(
        "https://musicbrainz.org/ws/2/release/",
        {
            "query": query + " AND " + musicbrainz_terms(artist=credits[0]),
            "fmt": "json",
            "limit": 8,
        },
        timeout=4,
    )["releases"]
    matches = [
        music_edition(r)
        for r in rows
        if same_music_name(r["title"], album, album=True)
        and same_music_credit(
            artist,
            dict(artist=musicbrainz_artist(r), artist_names=[c["name"] for c in r.get("artist-credit", [])]),
        )
    ]
    matches = prefer_music_date(matches, date)
    groups = {r["release_group"] or r["release"] for r in matches}
    if len(groups) != 1:
        return None
    edition = matches[0]
    return dict(
        provider="musicbrainz",
        kind="recording",
        artist=artist,
        album=album,
        release=edition["release"],
        release_group=edition["release_group"],
        art_releases=[row["release"] for row in matches[1:4]],
        link="https://musicbrainz.org/release/" + edition["release"],
    )


def musicbrainz_match(rows, title, artist, album, duration, date=""):
    matching = [
        row
        for row in rows
        if same_music_name(row["name"], title)
        and (not artist or same_music_credit(artist, row))
        and (
            not duration
            or not row.get("duration_ms")
            or abs(row["duration_ms"] / 1000 - duration) <= 5
        )
    ]
    releases = (
        [
            row
            for row in matching
            if same_music_name(row.get("album", ""), album, album=True)
            or same_music_name(row.get("group_title", ""), album, album=True)
        ]
        if album
        else []
    )
    pool = prefer_music_date(releases, date) if releases else matching
    timed = [row for row in pool if row.get("duration_ms")]
    pool = timed or pool
    if not pool:
        return None

    groups = {row.get("release_group") for row in pool}
    group = next(iter(groups)) if len(groups) == 1 else None
    if len({row["id"] for row in pool}) == 1:
        hit = dict(
            pool[0], provider="musicbrainz", album=album or pool[0].get("album", "")
        )
        hit.pop("release", None)
    elif releases and group:
        # The tagged album is identifiable even when its editions use different recording IDs.
        hit = dict(
            provider="musicbrainz",
            kind="recording",
            name=title,
            artist=artist,
            album=album,
            link="https://musicbrainz.org/release-group/" + group,
        )
    else:
        return None
    hit["release_group"] = group
    # For an album tag, only probe editions that agree with that tag. For an
    # untagged album, use artwork only if all candidate editions agree.
    if (releases and (group or len(pool) == 1)) or (not album and group):
        hit["art_releases"] = list(
            dict.fromkeys(row["release"] for row in pool if row.get("release"))
        )[:4]
    else:
        hit.pop("release_group", None)
    return hit


def music_art_sources(hit):
    releases = [
        ("release", release)
        for release in [hit.get("release"), *hit.get("art_releases", [])]
        if release
    ]
    sources = (
        releases[:1] + [("release-group", hit.get("release_group"))] + releases[1:]
    )
    return tuple(
        dict.fromkeys(
            (kind, ident)
            for kind, ident in sources
            if ident
            and re.fullmatch(
                r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", ident
            )
        )
    )


def cover_art_image(source, deadline):
    """Resolve CAA redirects to a verified public HTTPS image."""
    kind, ident = source
    address = f"https://coverartarchive.org/{kind}/{ident}/front-250"
    opener = urllib.request.build_opener(NoRedirect)
    for _ in range(3):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("Cover Art Archive timed out.")
        request = urllib.request.Request(
            address, method="HEAD", headers={"User-Agent": USER_AGENT}
        )
        try:
            with opener.open(request, timeout=min(remaining, 2.5)) as response:
                return (
                    address
                    if response.headers.get_content_type().startswith("image/")
                    else ""
                )
        except HTTPError as exc:
            with exc:
                if exc.code in (404, 410):
                    return ""
                location = exc.headers.get("Location")
                if exc.code not in (301, 302, 303, 307, 308) or not location:
                    raise
                target = url.urlsplit(url.urljoin(address, location))
                if (
                    target.scheme not in ("http", "https")
                    or not target.hostname
                    or target.netloc != target.hostname
                    or (
                        target.hostname != "coverartarchive.org"
                        and not target.hostname.endswith(".archive.org")
                        and target.hostname != "archive.org"
                    )
                ):
                    return ""
                address = target._replace(scheme="https", fragment="").geturl()
    return ""


def music_art(sources):
    # Probe a release and its album together. Only try additional editions
    # if neither of those has art, and preserve the preferred source order.
    failed = None
    deadline = time.monotonic() + 4
    pool = ThreadPoolExecutor(max_workers=2)
    try:
        for start in range(0, len(sources), 2):
            pending = [
                pool.submit(cover_art_image, s, deadline)
                for s in sources[start : start + 2]
            ]
            for result in pending:
                try:
                    if cover := result.result():
                        return cover
                except OSError as exc:
                    failed = exc
    finally:
        pool.shutdown(wait=False, cancel_futures=True)
    if failed:
        raise failed
    return ""


def candidates(provider, query, settings, throttle, *, artist="", album=""):
    query = query.strip() if provider == "musicbrainz" else public_query(query)
    if not query:
        return []
    throttle(provider)
    if provider == "wikidata":
        return wikidata_movies(query, throttle)
    if provider == "anilist":
        data = graphql(
            """query($q:String!){Page(perPage:10){media(search:$q,type:ANIME){
            id format seasonYear title{romaji english native} coverImage{large}}}}""",
            {"q": query},
        )
        return [
            dict(
                id=m["id"],
                name=m["title"]["romaji"],
                title="%s (%s, %s)"
                % (m["title"]["romaji"], m["seasonYear"] or "?", m["format"]),
                kind="anime",
            )
            for m in data["Page"]["media"]
        ]
    if provider in ("tmdb-movie", "tmdb-tv"):
        kind = provider.split("-")[1]
        params = {"query": query}
        year = re.search(r" \((\d{4})\)$", query)
        if year:
            params.update(query=query[: year.start()])
            params["year" if kind == "movie" else "first_air_date_year"] = year[1]
        data = tmdb_request("/search/" + kind, settings, params)
        return [
            dict(
                id=m["id"],
                kind=kind,
                name=m.get("title") or m["name"],
                year=(m.get("release_date") or m.get("first_air_date") or "")[:4],
                title="%s (%s)"
                % (
                    m.get("title") or m["name"],
                    (m.get("release_date") or m.get("first_air_date") or "?")[:4],
                ),
            )
            for m in data["results"][:10]
        ]
    if provider == "tvmaze":
        rows = fetch("https://api.tvmaze.com/search/shows", {"q": query})
        return [
            dict(
                id=m["id"],
                kind="tv",
                name=m["name"],
                year=(m.get("premiered") or "")[:4],
                show_type=m.get("type", ""),
                title="%s (%s, %s, %s)"
                % (
                    m["name"],
                    (m.get("premiered") or "?")[:4],
                    m.get("language") or "?",
                    (m.get("network") or m.get("webChannel") or {}).get("name", "?"),
                ),
                cover=(m.get("image") or {}).get("original", ""),
                link=m["url"],
            )
            for m in [r["show"] for r in rows[:10]]
        ]
    if provider == "musicbrainz":
        credits = music_artists(artist)
        terms = [music_search_field("recording", query)]
        if not terms[0]:
            return []
        if credits:
            terms.append(musicbrainz_terms(artist=credits[0]))
        search = " AND ".join(terms)
        if album_query := music_search_field("release", album):
            search = f"({search}) OR ({search} AND {album_query})^4"
        rows = fetch(
            "https://musicbrainz.org/ws/2/recording/",
            {
                "query": search,
                "fmt": "json",
                "limit": 20,
            },
            timeout=4,
        )
        result = []
        for m in rows.get("recordings", []):
            releases = m.get("releases") or []
            if album:
                matching = [
                    r
                    for r in releases
                    if same_music_name(r["title"], album, album=True)
                    or same_music_name(
                        (r.get("release-group") or {}).get("title", ""),
                        album,
                        album=True,
                    )
                ]
                releases = matching or releases
            for release in releases[: 8 if album else 3] or [{}]:
                release_title = release.get("title", "")
                result.append(
                    dict(
                        id=m["id"],
                        kind="recording",
                        name=m["title"],
                        title=m["title"]
                        + (" · " + release_title if release_title else ""),
                        **music_edition(release),
                        artist=musicbrainz_artist(m),
                        artist_names=[c["name"] for c in m.get("artist-credit", [])],
                        duration_ms=m.get("length"),
                        link="https://musicbrainz.org/recording/" + m["id"],
                    )
                )
        return result
    raise AccountError("Unsupported provider.")


def fingerprint(path, settings, throttle, valid=lambda: None):
    if not os.path.isfile(path):
        raise AccountError("Fingerprinting needs a local audio file.")
    bundled = (
        Path(__file__).resolve().parents[1]
        / "runtime"
        / ("fpcalc.exe" if os.name == "nt" else "fpcalc")
    )
    executable = str(bundled) if bundled.is_file() else shutil.which("fpcalc")
    if not executable:
        raise AccountError(
            "fpcalc is unavailable. Install the packaged build or add fpcalc to PATH."
        )
    valid()
    with subprocess.Popen(
        [executable, "-json", "-length", "120", os.path.abspath(path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    ) as process:
        deadline = time.monotonic() + 35
        try:
            while True:
                valid()
                if time.monotonic() >= deadline:
                    raise AccountError("Fingerprinting timed out.")
                try:
                    output, _ = process.communicate(timeout=0.25)
                    break
                except subprocess.TimeoutExpired:
                    continue
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()
        if process.returncode:
            raise AccountError("fpcalc could not read this file.")
    fp = json.loads(output)
    throttle("acoustid")
    valid()
    data = fetch(
        "https://api.acoustid.org/v2/lookup",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        body=url.urlencode(
            {
                "client": settings.get("acoustid_key") or ACOUSTID_CLIENT,
                "meta": "recordings releasegroups",
                "duration": int(fp["duration"]),
                "fingerprint": fp["fingerprint"],
            }
        ).encode("ascii"),
    )
    if data.get("status") != "ok":
        raise AccountError(
            "AcoustID rejected the lookup. Check your key and try again."
        )
    rows = []
    for hit in data.get("results", []):
        for recording in hit.get("recordings", []):
            if not recording.get("title"):
                continue
            artists = [
                entry["name"]
                for entry in recording.get("artists", [])
                if entry.get("name")
            ]
            groups = [
                group
                for group in recording.get("releasegroups", [])
                if group.get("id") and group.get("title")
            ]
            rows.append(
                dict(
                    id=recording["id"],
                    kind="recording",
                    name=recording["title"],
                    title=recording["title"]
                    + (" · " + ", ".join(artists) if artists else ""),
                    artist=", ".join(artists),
                    artist_names=artists,
                    groups=groups,
                    score=hit.get("score", 0),
                    link="https://musicbrainz.org/recording/" + recording["id"],
                )
            )
    return rows[:30]


def fingerprint_match(rows, title, artist, album):
    confident = {row["id"]: row for row in rows if row["score"] >= 0.9}
    tagged = [
        row
        for row in confident.values()
        if (not title or same_music_name(row["name"], title))
        and (not artist or same_music_credit(artist, row))
    ]
    # Tags can resolve tied database entries. A sole result can repair a bad tag.
    if len(tagged) == 1:
        hit = dict(tagged[0])
    elif len(confident) == 1:
        hit = dict(next(iter(confident.values())))
    else:
        return None
    return fingerprint_details(hit, album)


def fingerprint_details(hit, album=""):
    hit = dict(hit, provider="acoustid")
    groups = hit.pop("groups", [])
    matched = [g for g in groups if same_music_name(g["title"], album, album=True)]
    groups = matched or [g for g in groups if g.get("type") == "Album"]
    if len(groups) == 1:
        hit["album"] = groups[0]["title"]
        hit["release_group"] = groups[0]["id"]
    return hit


def details(provider, hit, settings, throttle, episode, airdate=None):
    if provider in ("musicbrainz", "acoustid"):
        item = (
            fingerprint_details(hit)
            if provider == "acoustid"
            else dict(hit, provider=provider)
        )
        try:
            if cover := music_art(music_art_sources(item)):
                item["cover"] = cover
        except OSError:
            pass
        return item
    item = dict(hit, provider=provider)
    if provider.startswith("tmdb-"):
        kind = hit["kind"]
        series = settings.get("tmdb_series") if kind=="tv" else None
        if series:
            data = series(hit["id"])
        else:
            throttle(provider)
            data = tmdb_request("/%s/%d" % (kind, hit["id"]), settings)
        item["name"] = data.get("title") or data.get("name") or hit["name"]
        item["year"] = (data.get("release_date") or data.get("first_air_date") or "")[
            :4
        ]
        item["genre"] = ", ".join(
            g["name"] for g in data.get("genres", []) if g.get("name")
        )
        if kind == "tv" and episode:
            throttle(provider)
            season, number = map(int, episode)
            ep = tmdb_request(
                "/tv/%d/season/%d/episode/%d" % (hit["id"], season, number), settings
            )
            item["episode_title"] = ep.get("name", "")
            # Both the direct API and the relay return an episode name only
            # after a successful lookup of this exact season and episode.
            if item["episode_title"]:
                item["numbering"] = "S%02dE%02d" % (season, number)
        if data.get("poster_path"):
            item["cover"] = "https://image.tmdb.org/t/p/w500" + data["poster_path"]
        item["link"] = "https://www.themoviedb.org/%s/%d" % (kind, hit["id"])
    if provider == "tvmaze" and episode:
        throttle(provider)
        data = fetch(
            "https://api.tvmaze.com/shows/%d/episodebynumber" % hit["id"],
            {"season": episode[0], "number": episode[1]},
        )
        item["episode_title"] = data.get("name", "")
        item["numbering"] = "S%02dE%02d" % tuple(map(int, episode))
    elif provider == "tvmaze" and airdate:
        throttle(provider)
        matches = fetch(
            "https://api.tvmaze.com/shows/%d/episodesbydate" % hit["id"],
            {"date": airdate},
        )
        if len(matches) == 1:
            item["episode_title"] = matches[0].get("name", "")
            item["numbering"] = airdate
    return item
