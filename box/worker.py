#!/usr/bin/env python3
"""Box side of the hub: pull tasks from Cloady, do the heavy work here, push
results and local artifacts back. No inbound port required on Box.

Stdlib only. Playwright screenshots are delegated to screenshot.js (Node).

Config: /workspace/cloady-hub/.env  (APP_URL, HUB_TOKEN, optional overrides)
"""

import base64
import glob
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = "/workspace"
RUNTIME = os.path.join(HERE, "runtime")
LOG = os.path.join(RUNTIME, "worker.log")
MAX_PUBLISH_BYTES = 480 * 1024


def load_env():
    cfg = {"APP_URL": "", "HUB_TOKEN": "", "POLL_SECONDS": "15",
           "PUBLISH_EVERY": "600", "WORKER_NAME": "box-main"}
    p = os.path.join(HERE, ".env")
    if os.path.exists(p):
        for line in open(p, encoding="utf-8"):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                cfg[k.strip()] = v.strip()
    for k in list(cfg):
        if os.environ.get(k):
            cfg[k] = os.environ[k]
    return cfg


def log(msg):
    os.makedirs(RUNTIME, exist_ok=True)
    line = f"[{datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')}] {msg}"
    print(line, flush=True)
    with open(LOG, "a", encoding="utf-8") as f:
        f.write(line + "\n")


def api(cfg, method, path, payload=None, timeout=25):
    url = cfg["APP_URL"].rstrip("/") + path
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, method=method, headers={
        "X-Hub-Token": cfg["HUB_TOKEN"],
        "Content-Type": "application/json",
        "User-Agent": "cloady-box-worker/1.0",
    })
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8") or "{}")


def text_of(path, limit=60000):
    try:
        with open(path, "rb") as f:
            raw = f.read(limit)
        return raw.decode("utf-8", "replace")
    except OSError:
        return ""


def publish(cfg, aid, kind, title, body="", url=None, binary=None, ctype=None, meta=None):
    payload = {"id": aid, "kind": kind, "title": title, "meta": meta or {}}
    if binary is not None:
        payload["bodyBase64"] = base64.b64encode(binary).decode("ascii")
        payload["contentType"] = ctype or "application/octet-stream"
    else:
        payload["body"] = body
        payload["contentType"] = ctype or "text/plain; charset=utf-8"
    if url:
        payload["url"] = url
    return api(cfg, "POST", "/api/publish", payload)


def publish_all(cfg):
    """Republish local artifacts. Cheap and idempotent: this is what rebuilds
    the panel after Cloady redeploys and clears its in-memory state."""
    n = 0

    for p in sorted(glob.glob(ROOT + "/digests/*.txt"))[-7:]:
        day = os.path.basename(p).replace(".txt", "")
        publish(cfg, f"digest:{day}", "digest", f"每日头条 · {day}",
                text_of(p), meta={"path": p})
        n += 1

    for pattern, kind, prefix in [
        ("/eb5-tracker/reports/*.md", "eb5", "eb5"),
        ("/eb5-tracker/tier2_reports/*.md", "eb5-tier2", "eb5t2"),
    ]:
        for p in sorted(glob.glob(ROOT + pattern))[-7:]:
            name = os.path.basename(p).replace(".md", "")
            publish(cfg, f"{prefix}:{name}", kind, f"{kind} · {name}",
                    text_of(p), ctype="text/markdown; charset=utf-8", meta={"path": p})
            n += 1

    for p in sorted(glob.glob(ROOT + "/magazine/publish/*.txt")):
        name = os.path.basename(p).replace(".txt", "")
        publish(cfg, f"magazine:{name}", "magazine", f"杂志发布 · {name}",
                text_of(p, 4000), url=text_of(p, 4000).strip() or None, meta={"path": p})
        n += 1

    for p, kind in [("/nyt_topstories.md", "nyt"), ("/freenews_trending.json", "trending")]:
        full = ROOT + p
        if os.path.isfile(full):
            publish(cfg, f"{kind}:current", kind, kind.upper() + " · 最新",
                    text_of(full, 30000), meta={"path": full})
            n += 1

    return n


def do_fetch(url):
    if not isinstance(url, str) or not re.match(r"^https?://", url):
        raise ValueError("payload.url must be an http(s) URL")
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (box-hub)"})
    with urllib.request.urlopen(req, timeout=20) as r:
        raw = r.read(200000)
        final, status, ctype = r.geturl(), r.status, r.headers.get("Content-Type", "")
    text = raw.decode("utf-8", "replace")
    title = re.search(r"<title[^>]*>(.*?)</title>", text, re.I | re.S)
    clean = re.sub(r"\s+", " ", re.sub(r"<[^>]+>", " ", text)).strip()
    return {"status": status, "finalUrl": final, "contentType": ctype,
            "bytes": len(raw), "title": title.group(1).strip()[:200] if title else None,
            "preview": clean[:400]}


def do_screenshot(cfg, url, tid):
    if not isinstance(url, str) or not re.match(r"^https?://", url):
        raise ValueError("payload.url must be an http(s) URL")
    os.makedirs(RUNTIME, exist_ok=True)
    out = os.path.join(RUNTIME, f"shot-{tid}.jpg")
    js = os.path.join(HERE, "screenshot.js")
    proc = subprocess.run(["node", js, url, out], cwd=ROOT, capture_output=True,
                          text=True, timeout=120)
    if proc.returncode != 0:
        raise RuntimeError("playwright: " + (proc.stderr or proc.stdout).strip()[:500])
    data = open(out, "rb").read()
    if len(data) > MAX_PUBLISH_BYTES:
        raise RuntimeError(f"screenshot too large ({len(data)} B) for the hub")
    aid = f"screenshot:{tid}"
    publish(cfg, aid, "screenshot", f"截图 · {url[:80]}", binary=data,
            ctype="image/jpeg", url=url, meta={"bytes": len(data), "task": tid})
    os.remove(out)
    return {"artifact": aid, "bytes": len(data), "url": url}


def handle(cfg, t):
    """Only a fixed allowlist of task types runs here. Never exec arbitrary
    commands coming from a public webhook."""
    kind, p = t["type"], t.get("payload") or {}
    if kind == "echo":
        return {"echo": p, "worker": cfg["WORKER_NAME"]}
    if kind == "fetch":
        return do_fetch(p.get("url"))
    if kind == "screenshot":
        return do_screenshot(cfg, p.get("url"), t["id"])
    if kind == "republish":
        return {"published": publish_all(cfg)}
    if kind.startswith("github."):
        # GitHub push / issue events: record them, refresh artifacts so the
        # panel reflects the new deployment immediately.
        published = publish_all(cfg)
        return {"event": kind, "repo": p.get("repo"), "sha": p.get("sha"),
                "note": "acknowledged on Box", "published": published}
    if kind in ("command", "message"):
        return {"reply": f"已收到：{(p.get('text') or '')[:200]}",
                "note": "wire a real bot token in worker.py to send platform replies"}
    raise ValueError(f"unsupported task type: {kind}")


def main():
    cfg = load_env()
    if not cfg["APP_URL"] or not cfg["HUB_TOKEN"]:
        log("FATAL: APP_URL / HUB_TOKEN missing from .env")
        sys.exit(2)
    poll = max(5, int(cfg["POLL_SECONDS"]))
    every = max(60, int(cfg["PUBLISH_EVERY"]))
    log(f"worker start url={cfg['APP_URL']} name={cfg['WORKER_NAME']} poll={poll}s publish={every}s")

    last_publish, processed, errors = 0, 0, 0
    while True:
        try:
            now = time.time()
            if now - last_publish >= every:
                n = publish_all(cfg)
                log(f"published {n} artifacts")
                last_publish = now

            got = api(cfg, "POST", "/api/tasks/claim",
                      {"worker": cfg["WORKER_NAME"], "limit": 5})
            for t in got.get("claimed", []):
                tid, kind = t["id"], t["type"]
                try:
                    result = handle(cfg, t)
                    api(cfg, "POST", "/api/result", {"id": tid, "ok": True, "result": result})
                    processed += 1
                    log(f"done {tid} [{kind}] -> {str(result)[:160]}")
                except Exception as e:
                    errors += 1
                    log(f"FAIL {tid} [{kind}]: {type(e).__name__}: {e}")
                    api(cfg, "POST", "/api/result",
                        {"id": tid, "ok": False, "error": f"{type(e).__name__}: {e}"})
        except KeyboardInterrupt:
            log("stopped by signal")
            return
        except Exception as e:
            errors += 1
            log(f"loop error: {type(e).__name__}: {e}")
        time.sleep(poll)


if __name__ == "__main__":
    main()
