#!/usr/bin/env python3
"""Downloads every Mixamo motion, baked on one or more characters, as skinless 60 fps FBX files.

Signed in at mixamo.com, run `copy(localStorage.access_token)` in the browser's console, then
`pbpaste > ~/.config/mixamo/token` (or export MIXAMO_TOKEN). The token lasts about a day; on a 401 the script
stops and a rerun with a fresh token resumes where it left off.

    python3 Tools/mixamo/download.py --list-characters
    python3 Tools/mixamo/download.py --character "Y Bot" --character mine --limit 3
    python3 Tools/mixamo/download.py --character "Y Bot" --character mine

Writes <out>/catalog.json (every motion) and per character <out>/<Character>/<Name> [<id8>].fbx with an
index.json (one entry per downloaded clip) and failed.json. Stdlib only.
"""

import argparse
import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://www.mixamo.com/api/v1"
TOKEN_FILE = os.path.expanduser("~/.config/mixamo/token")
PAGE = 100   # the most the site returns a page
ORDERS = ["", "id", "name", "-name", "-id", "created_at", "-created_at", "", "id", "name"]
print_lock = threading.Lock()


def log(*parts):
    with print_lock:
        print(*parts, flush=True)


class Unauthorized(Exception):
    pass


def token():
    value = os.environ.get("MIXAMO_TOKEN", "").strip()
    if not value and os.path.exists(TOKEN_FILE):
        with open(TOKEN_FILE) as f:
            value = f.read().strip().strip('"')
    if not value:
        sys.exit(f"No token: put it in {TOKEN_FILE} or MIXAMO_TOKEN (see the top of this file).")
    return value


class Client:
    def __init__(self, bearer):
        self.headers = {"Authorization": f"Bearer {bearer}", "X-Api-Key": "mixamo2",
                        "Accept": "application/json", "Content-Type": "application/json"}

    def request(self, method, path, body=None, attempts=6):
        url = path if path.startswith("http") else API + path
        data = json.dumps(body).encode() if body is not None else None
        delay = 2.0
        for attempt in range(attempts):
            try:
                req = urllib.request.Request(url, data=data, method=method, headers=self.headers)
                with urllib.request.urlopen(req, timeout=60) as r:
                    text = r.read()
                    return json.loads(text) if text else {}
            except urllib.error.HTTPError as e:
                if e.code == 401:
                    raise Unauthorized()
                if e.code in (429, 500, 502, 503, 504) and attempt < attempts - 1:
                    time.sleep(delay)
                    delay = min(delay * 2, 120)
                    continue
                raise RuntimeError(f"{method} {url}: HTTP {e.code} {e.read()[:300]!r}")
            except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
                if attempt < attempts - 1:
                    time.sleep(delay)
                    delay = min(delay * 2, 120)
                    continue
                raise RuntimeError(f"{method} {url}: {e}")

    def get(self, path):
        return self.request("GET", path)

    def listing(self, kind, order, query=""):
        """One pass over a type's pages in one order, and the count the site gives."""
        results, page = [], 1
        while True:
            q = urllib.parse.urlencode({"page": page, "limit": PAGE, "order": order, "type": kind, "query": query})
            j = self.get(f"/products?{q}")
            results += j.get("results", [])
            pagination = j.get("pagination", {})
            if page >= pagination.get("num_pages", 1):
                return results, pagination.get("num_results", len(results))
            page += 1

    def products(self, kind, query=""):
        """Every product of a type ("Motion", "Character"). The site's paging is not stable in any order (a pass
        repeats some products and skips others), so passes in several orders are merged until every one is there."""
        found, total = {}, 0
        for order in ORDERS:
            results, total = self.listing(kind, order, query)
            for p in results:
                found.setdefault(p["id"], p)
            if len(found) >= total:
                break
        if len(found) < total:
            log(f"(the listing gave {len(found)} of {total} {kind} products)")
        return list(found.values())


def save_json(path, value):
    tmp = path + ".part"
    with open(tmp, "w") as f:
        json.dump(value, f, indent=1, ensure_ascii=False)
    os.replace(tmp, path)


def load_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return default


def safe(name):
    return re.sub(r'[/\\:*?"<>|\x00-\x1f]', "_", name).strip() or "unnamed"


def catalog(client, out, refresh):
    path = os.path.join(out, "catalog.json")
    motions = None if refresh else load_json(path, None)
    if motions is None:
        log("Listing Mixamo motions ...")
        motions = [{"id": p["id"], "name": p.get("name", ""), "description": p.get("description", "")}
                   for p in client.products("Motion")]
        save_json(path, motions)
    log(f"{len(motions)} motions in the catalogue")
    return motions


def characters(client):
    """(id, name) of the default characters and the account's own; `primary` is the one selected on the site."""
    found = [(p["id"], p.get("name", "")) for p in client.products("Character")]
    primary = None
    try:
        j = client.get("/characters/primary")
        primary = (j.get("primary_character_id"), j.get("primary_character_name", ""))
    except (RuntimeError, AttributeError) as e:
        log(f"(no primary character: {e})")
    return found, primary


def resolve(client, spec):
    found, primary = characters(client)
    if spec == "mine":
        if not primary or not primary[0]:
            sys.exit("No selected character on the account; pass its id or name instead of 'mine'.")
        return primary
    for cid, name in found + ([primary] if primary else []):
        if spec == cid or spec.lower() == name.lower():
            return cid, name
    sys.exit(f"No character {spec!r}; --list-characters shows the ones this account sees.")


def export(client, cid, motion, fps):
    detail = client.get(f"/products/{motion['id']}?similar=0&character_id={cid}")
    details = detail.get("details", {})
    gms = dict(details["gms_hash"])
    # The motion's default parameters (as the site bakes it without touching the sliders).
    gms["params"] = ",".join(str(p[1]) for p in gms.get("params", []))
    job = client.request("POST", "/animations/export", {
        "character_id": cid,
        "gms_hash": [gms],
        "preferences": {"format": "fbx7", "skin": "false", "fps": str(fps), "reducekf": "0"},
        "product_name": motion["name"],
        "type": "Motion",
    })
    start = time.time()
    while True:
        time.sleep(1.0)
        j = client.get(f"/characters/{cid}/monitor")
        # The monitor is the character's: until it shows this job, its status is an earlier one's.
        status = j.get("status") if j.get("job_uuid") == job.get("job_uuid") else "processing"
        if status == "completed":
            return j["job_result"], details
        if status == "failed":
            raise RuntimeError(f"export failed: {j.get('message') or j}")
        if time.time() - start > 300:
            raise RuntimeError("export did not finish in 5 minutes")


def fetch(url, path):
    tmp = path + ".part"
    with urllib.request.urlopen(url, timeout=300) as r, open(tmp, "wb") as f:
        while chunk := r.read(1 << 20):
            f.write(chunk)
    os.replace(tmp, path)
    return os.path.getsize(path)


def run_character(client, cid, name, motions, out, fps, pause, retry_failed, stop):
    folder = os.path.join(out, safe(name))
    os.makedirs(folder, exist_ok=True)
    index_path, failed_path = os.path.join(folder, "index.json"), os.path.join(folder, "failed.json")
    index = {e["id"]: e for e in load_json(index_path, [])}
    failed = {e["id"]: e for e in load_json(failed_path, [])}
    todo = [m for m in motions if m["id"] not in index and (retry_failed or m["id"] not in failed)]
    log(f"[{name}] {len(index)} done, {len(failed)} failed before, {len(todo)} to go")
    done_bytes, started = 0, time.time()
    for n, m in enumerate(todo, 1):
        if stop.is_set():
            return
        file = f"{safe(m['name'])} [{m['id'][:8]}].fbx"
        try:
            url, details = export(client, cid, m, fps)
            size = fetch(url, os.path.join(folder, file))
            done_bytes += size
            index[m["id"]] = {"id": m["id"], "name": m["name"], "description": m["description"], "file": file,
                              "duration": details.get("duration"), "loopable": details.get("loopable"),
                              "fps": fps, "bytes": size}
            failed.pop(m["id"], None)
            save_json(index_path, sorted(index.values(), key=lambda e: (e["name"], e["id"])))
            rate = (time.time() - started) / n
            log(f"[{name}] {n}/{len(todo)} {m['name']} ({size / 1e6:.1f} MB) "
                f"- {done_bytes / 1e9:.2f} GB, ~{rate * (len(todo) - n) / 3600:.1f} h left")
        except Unauthorized:
            log(f"[{name}] token expired or invalid: refresh it and rerun to resume")
            stop.set()
            return
        except Exception as e:  # noqa: BLE001 - log any failure and move on
            failed[m["id"]] = {"id": m["id"], "name": m["name"], "error": str(e)[:500]}
            log(f"[{name}] {n}/{len(todo)} {m['name']} FAILED: {e}")
        save_json(failed_path, list(failed.values()))
        time.sleep(pause)
    log(f"[{name}] finished: {len(index)} clips, {len(failed)} failed")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--character", action="append", default=[],
                    help='character name or id, or "mine" (the one selected on the site); repeatable')
    ap.add_argument("--out", default=os.path.expanduser("~/MixamoAnimations"))
    ap.add_argument("--fps", type=int, default=60)
    ap.add_argument("--limit", type=int, help="only the first N motions (trial runs)")
    ap.add_argument("--query", help="only motions whose name contains this")
    ap.add_argument("--pause", type=float, default=1.0, help="seconds between exports")
    ap.add_argument("--list-characters", action="store_true")
    ap.add_argument("--dry-run", action="store_true", help="list the motions and stop")
    ap.add_argument("--refresh", action="store_true", help="list the catalogue again")
    ap.add_argument("--retry-failed", action="store_true")
    args = ap.parse_args()

    client = Client(token())
    os.makedirs(args.out, exist_ok=True)
    try:
        if args.list_characters:
            found, primary = characters(client)
            for cid, name in found:
                log(f"{cid}  {name}")
            log(f"selected on the site: {primary}")
            return
        motions = catalog(client, args.out, args.refresh)
        if args.query:
            motions = [m for m in motions if args.query.lower() in m["name"].lower()]
        motions.sort(key=lambda m: (m["name"], m["id"]))
        if args.limit:
            motions = motions[:args.limit]
        if args.dry_run:
            for m in motions[:20]:
                log(f"{m['id']}  {m['name']}  - {m['description']}")
            log(f"... {len(motions)} motions")
            return
        if not args.character:
            sys.exit("Pass --character (for example --character \"Y Bot\" --character mine).")
        targets = [resolve(client, spec) for spec in args.character]
    except Unauthorized:
        sys.exit("The token was refused: sign in at mixamo.com again and copy a fresh one.")

    stop = threading.Event()
    threads = [threading.Thread(target=run_character, args=(client, cid, name, motions, args.out, args.fps,
                                                            args.pause, args.retry_failed, stop))
               for cid, name in dict(targets).items()]
    for t in threads:
        t.start()
    try:
        for t in threads:
            t.join()
    except KeyboardInterrupt:
        stop.set()
        log("Stopping after the current clips ...")
        for t in threads:
            t.join()
    sys.exit(1 if stop.is_set() else 0)


if __name__ == "__main__":
    main()
