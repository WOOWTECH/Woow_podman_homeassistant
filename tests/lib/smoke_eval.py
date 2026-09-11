#!/usr/bin/env python3
"""tests/lib/smoke_eval.py: the evaluation half of tests/smoke.sh (stdlib only).

smoke.sh gathers raw facts (HTTP codes, listeners, container inspect, API responses) into a
KEY=VALUE file and a work dir. This script adds what it reads from the config dir (registry
counts in .storage, zigpy device freshness from zigbee.db, ERROR lines in home-assistant.log),
builds the snapshot, optionally compares it with an earlier one, prints the report and exits
0 (all passed), 1 (a critical check failed) or 2 (only degraded checks failed).
"""
import argparse
import json
import os
import re
import sqlite3
import sys
import time

CRIT, DEGR, INFO = "critical", "degraded", "info"
# Config entries whose regression is always critical: the Zigbee radio and the Apple Home bridge.
CRITICAL_ENTRY_DOMAINS = {"zha", "homekit"}
LOG_LINE = re.compile(r"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d(?:\.\d+)? ERROR (?:\([^)]*\) )?(.*)$")


def load_facts(path):
    facts = {}
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            key, sep, value = line.rstrip("\n").partition("=")
            if sep:
                facts[key] = value.strip()
    return facts


def read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def storage_counts(cfg):
    out = {}
    st = os.path.join(cfg, ".storage")
    er = read_json(os.path.join(st, "core.entity_registry"))
    if isinstance(er, dict):
        ents = er.get("data", {}).get("entities", [])
        out["entities"] = len(ents)
        out["entities_enabled"] = sum(1 for e in ents if not e.get("disabled_by"))
    dr = read_json(os.path.join(st, "core.device_registry"))
    if isinstance(dr, dict):
        devs = dr.get("data", {}).get("devices", [])
        out["devices"] = len(devs)
        out["zha_devices"] = sum(
            1 for d in devs if any(i and i[0] == "zha" for i in d.get("identifiers", []))
        )
    ce = read_json(os.path.join(st, "core.config_entries"))
    if isinstance(ce, dict):
        out["config_entries"] = len(ce.get("data", {}).get("entries", []))
    return out


def zigpy_counts(cfg):
    db = os.path.join(cfg, "zigbee.db")
    if not os.path.exists(db):
        return {}
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=5)
        try:
            names = [r[0] for r in con.execute(
                "select name from sqlite_master where type='table' and name like 'devices_v%'")]
            names.sort(key=lambda n: int(re.sub(r"\D", "", n) or 0))
            if not names:
                return {}
            seen = [r[0] for r in con.execute(f'select last_seen from "{names[-1]}"')]
        finally:
            con.close()
    except sqlite3.Error as e:
        return {"error": str(e)}
    now = time.time()
    fresh = sum(1 for x in seen if isinstance(x, (int, float)) and now - x < 3600)
    return {"devices": len(seen), "seen_1h": fresh}


def log_errors(cfg):
    path = os.path.join(cfg, "home-assistant.log")
    count, sigs = 0, set()
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                m = LOG_LINE.match(line)
                if m:
                    count += 1
                    sigs.add(re.sub(r"\d+", "N", m.group(1).strip())[:120])
    except OSError:
        return {"readable": False}
    return {"readable": True, "count": count, "signatures": sorted(sigs)}


def api_data(facts, work):
    out = {f"{k}_code": facts.get(f"api_{k}_code", "000") for k in ("config", "entries", "template")}
    if out["config_code"] == "200":
        c = read_json(os.path.join(work, "api_config.json"))
        if isinstance(c, dict):
            out["state"] = c.get("state")
            out["version"] = c.get("version")
    if out["entries_code"] == "200":
        e = read_json(os.path.join(work, "api_entries.json"))
        if isinstance(e, list):
            out["entries"] = {
                x.get("entry_id"): {"domain": x.get("domain"), "title": x.get("title"), "state": x.get("state")}
                for x in e if isinstance(x, dict) and x.get("entry_id")
            }
    if out["template_code"] == "200":
        try:
            with open(os.path.join(work, "api_template.txt"), encoding="utf-8") as f:
                nums = [int(x) for x in f.read().split()]
            if len(nums) == 4:
                out.update(states=nums[0], unavailable=nums[1], zha=nums[2], zha_unavailable=nums[3])
        except (OSError, ValueError):
            pass
    return out


def image_version(image):
    """2026.9.1 from ghcr.io/home-assistant/home-assistant:2026.9.1; '' for floating tags."""
    if not image or "@" in image:
        return ""
    tail = image.rsplit("/", 1)[-1]
    tag = tail.split(":", 1)[1] if ":" in tail else ""
    return tag if re.match(r"^\d+\.\d+", tag) else ""


def build_snapshot(facts, work, cfg):
    return {
        "format": 1,
        "taken_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "facts": facts,
        "storage": storage_counts(cfg),
        "zigpy": zigpy_counts(cfg),
        "log": log_errors(cfg),
        "api": api_data(facts, work) if facts.get("token") == "1" else None,
    }


def evaluate(cur, pre, strict):
    rows = []

    def add(name, cls, ok, detail):
        rows.append((name, cls, ok, detail))

    f = cur["facts"]
    quadlet = f.get("mode") == "quadlet"
    http_ok = f.get("http_local") == "200"
    add("http.local", CRIT, http_ok, f"GET 127.0.0.1:{f.get('port')}/manifest.json -> {f.get('http_local')}")
    add("port.ha", CRIT, f.get("tcp_ha") == "1", f"TCP {f.get('port')} listening: {f.get('tcp_ha') == '1'}")
    if quadlet:
        add("unit.active", CRIT, f.get("unit_active") == "active", f"homeassistant.service is {f.get('unit_active') or '?'}")
        nr = f.get("unit_nrestarts", "")
        add("unit.restarts", DEGR, nr in ("", "0"), f"NRestarts={nr or '?'}")
        add("container.label", CRIT, f.get("ctr_label") == "homeassistant.service",
            f"PODMAN_SYSTEMD_UNIT={f.get('ctr_label') or '<none>'}")
        want = f.get("want_image", "")
        add("container.image", CRIT, bool(want) and f.get("ctr_image") == want,
            f"{f.get('ctr_image') or '<no container>'} (unit wants {want or '<no unit>'})")
        add("container.stop_timeout", DEGR, f.get("ctr_stop_timeout") == "300", f"StopTimeout={f.get('ctr_stop_timeout') or '?'}")
        health = f.get("ctr_health", "")
        add("container.health", DEGR, health in ("healthy", "starting"), f"health={health or 'none'}")
    add("container.config_mount", CRIT, f.get("ctr_config_src") == f.get("want_config_src"),
        f"/config <- {f.get('ctr_config_src') or '<none>'} (HA_CONFIG_DIR {f.get('want_config_src')})")
    want_ver = image_version(f.get("want_image") or f.get("ctr_image"))
    if http_ok and want_ver:
        add("config.ha_version", CRIT if quadlet else INFO, f.get("ha_version_file") == want_ver,
            f".HA_VERSION={f.get('ha_version_file') or '?'} (image {want_ver})")
    if f.get("radio_dev"):
        add("radio", CRIT, f.get("radio_ok") == "1", f"{f.get('radio_dev')} is a character device in the container: {f.get('radio_ok') == '1'}")
    api = cur.get("api")
    if api is None:
        add("api", INFO, None, "no token in ~/.config/homeassistant/smoke.header: API checks skipped")
    else:
        add("api.reachable", CRIT, api.get("config_code") == "200", f"GET /api/config -> {api.get('config_code')}")
        if api.get("config_code") == "200":
            add("api.state", CRIT, api.get("state") == "RUNNING", f"state={api.get('state')}")
            if quadlet and want_ver:
                add("api.version", CRIT, api.get("version") == want_ver, f"version={api.get('version')} (image {want_ver})")
    if f.get("public_url"):
        url = f["public_url"]
        add("public.manifest", CRIT, f.get("public_manifest") == "200", f"GET {url}/manifest.json -> {f.get('public_manifest')}")
        code = f.get("public_api")
        hint = " (400: http.trusted_proxies rejects the proxy)" if code == "400" else ""
        add("public.trusted_proxy", CRIT, code == "401", f"GET {url}/api/ -> {code}, want 401{hint}")
    if f.get("matter_enabled") == "1":
        add("matter.http", DEGR, f.get("http_matter") == "200", f"GET 127.0.0.1:5580/ -> {f.get('http_matter')}")
    if pre is not None:
        compare(cur, pre, strict, add)
    return rows


def compare(cur, pre, strict, add):
    f, pf = cur["facts"], pre.get("facts", {})
    cs, ps = cur.get("storage", {}), pre.get("storage", {})
    for key in ("devices", "zha_devices"):
        if key in ps:
            add(f"compare.storage.{key}", CRIT, cs.get(key, -1) >= ps[key], f"{cs.get(key, 'unreadable')} (before {ps[key]})")
    if "entities" in ps:
        add("compare.storage.entities", DEGR, cs.get("entities", -1) >= ps["entities"] * 0.98,
            f"{cs.get('entities', 'unreadable')} (before {ps['entities']})")
    listeners = (
        ("tcp_21064", "HomeKit TCP 21064", CRIT),
        ("tcp_9584", "HA-MCP TCP 9584", DEGR),
        ("tcp_5580", "Matter TCP 5580", DEGR),
        ("udp_5353", "mDNS UDP 5353", DEGR),
        ("udp_1900", "SSDP UDP 1900", DEGR),
    )
    for key, label, cls in listeners:
        if pf.get(key) == "1":
            add(f"compare.{key}", cls, f.get(key) == "1", f"{label} listening: {f.get(key) == '1'} (was listening)")
    for key, label, cls in (("http_homekit", "HomeKit HAP", CRIT), ("http_hamcp", "HA-MCP", DEGR)):
        if pf.get(key, "000") != "000":
            add(f"compare.{key}", cls, f.get(key, "000") != "000", f"{label} HTTP {f.get(key)} (before {pf.get(key)})")
    if pf.get("http_matter") == "200":
        add("compare.matter", DEGR, f.get("http_matter") == "200", f"Matter server HTTP {f.get('http_matter')} (before 200)")
    if pf.get("mdns_hap", "").strip():
        add("compare.mdns_hap", DEGR, bool(f.get("mdns_hap", "").strip()),
            f"_hap._tcp SRV ports: {f.get('mdns_hap') or 'none'} (before {pf.get('mdns_hap')})")
    pz, cz = pre.get("zigpy", {}), cur.get("zigpy", {})
    if "seen_1h" in pz:
        add("compare.zigpy_seen", DEGR, cz.get("seen_1h", -1) >= pz["seen_1h"] - 5,
            f"{cz.get('seen_1h', '?')} Zigbee devices seen in the last hour (before {pz['seen_1h']})")
    pl, cl = pre.get("log", {}), cur.get("log", {})
    if pl.get("readable") and cl.get("readable"):
        new = sorted(set(cl.get("signatures", [])) - set(pl.get("signatures", [])))
        detail = f"{cl.get('count')} ERROR lines (before {pl.get('count')})"
        detail += "; new: " + " | ".join(new[:5]) if new else "; no new error signatures"
        add("compare.log_errors", DEGR, not new, detail)
    pa, ca = pre.get("api") or {}, cur.get("api") or {}
    if pa.get("entries"):
        now = ca.get("entries")
        if now is None:
            add("compare.entries", CRIT, False, "config entries were readable before and are not now (token? API?)")
        else:
            loaded_before = {k: v for k, v in pa["entries"].items() if v.get("state") == "loaded"}
            ok_count = 0
            for eid, e in sorted(loaded_before.items(), key=lambda kv: (kv[1].get("domain") or "", kv[0])):
                state = now.get(eid, {}).get("state", "missing")
                if state == "loaded":
                    ok_count += 1
                    continue
                cls = CRIT if strict or e.get("domain") in CRITICAL_ENTRY_DOMAINS else DEGR
                add(f"compare.entry.{e.get('domain')}", cls, False, f"'{e.get('title')}' ({eid[:8]}) is {state}, was loaded")
            add("compare.entries", INFO, True, f"{ok_count}/{len(loaded_before)} previously loaded config entries are loaded")
    if "states" in pa and "states" in ca:
        tol = max(1, round(pa["states"] * 0.02))
        add("compare.states", DEGR, abs(ca["states"] - pa["states"]) <= tol, f"{ca['states']} states (before {pa['states']}, allowed +-{tol})")
        add("compare.unavailable", DEGR, ca["unavailable"] <= pa["unavailable"] + 5,
            f"{ca['unavailable']} unavailable (before {pa['unavailable']}, allowed +5)")
        add("compare.zha_unavailable", DEGR, ca["zha_unavailable"] <= pa["zha_unavailable"] + 3,
            f"{ca['zha_unavailable']} of {ca['zha']} zha entities unavailable (before {pa['zha_unavailable']}, allowed +3)")


def report(rows, summary_only):
    crit = [r for r in rows if r[2] is False and r[1] == CRIT]
    degr = [r for r in rows if r[2] is False and r[1] == DEGR]
    rc = 1 if crit else 2 if degr else 0
    if summary_only:
        names = ", ".join(r[0] for r in crit + degr)
        print(f"{len(crit)} critical, {len(degr)} degraded failing" + (f": {names}" if names else ""))
        return rc
    for name, cls, ok, detail in rows:
        tag = "SKIP" if ok is None else "PASS" if ok else "FAIL"
        print(f"{tag:4}  {cls:8}  {name:30}  {detail}")
    passed = sum(1 for r in rows if r[2])
    print(f"smoke: {passed} passed, {len(crit)} critical and {len(degr)} degraded failure(s) -> exit {rc}")
    return rc


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--facts", required=True)
    ap.add_argument("--work", required=True)
    ap.add_argument("--config-dir", required=True)
    ap.add_argument("--snapshot")
    ap.add_argument("--compare")
    ap.add_argument("--strict", action="store_true")
    ap.add_argument("--summary-only", action="store_true")
    a = ap.parse_args()
    cur = build_snapshot(load_facts(a.facts), a.work, a.config_dir)
    pre = None
    if a.compare:
        pre = read_json(a.compare)
        if not isinstance(pre, dict) or "facts" not in pre:
            print(f"smoke: {a.compare} is not a smoke snapshot", file=sys.stderr)
            return 1
    rows = evaluate(cur, pre, a.strict)
    if a.snapshot:
        old = os.umask(0o077)
        try:
            with open(a.snapshot, "w", encoding="utf-8") as f:
                json.dump(cur, f, indent=1, sort_keys=True)
                f.write("\n")
        finally:
            os.umask(old)
    return report(rows, a.summary_only)


if __name__ == "__main__":
    sys.exit(main())
