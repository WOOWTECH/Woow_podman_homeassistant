"""tests/shims/shimlib.py: shared state helpers for the podman and systemctl doubles."""
import json
import os


def state():
    s = os.environ.get("SHIM_STATE")
    if not s:
        raise SystemExit("shim: SHIM_STATE is not set")
    return s


def path(*p):
    return os.path.join(state(), *p)


def read_json(p, default=None):
    try:
        with open(p, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def container(name):
    d = read_json(path("containers", name, "inspect.json"))
    if isinstance(d, list):
        return d[0] if d else None
    return d


def save_container(name, obj):
    os.makedirs(path("containers", name), exist_ok=True)
    with open(path("containers", name, "inspect.json"), "w", encoding="utf-8") as f:
        json.dump([obj], f)


def names():
    d = path("containers")
    return sorted(os.listdir(d)) if os.path.isdir(d) else []


def sync_ports():
    """$SHIM_STATE/ports holds the listeners of the running containers, for the ss double."""
    lines = []
    for n in names():
        c = container(n)
        if not c or not c.get("State", {}).get("Running"):
            continue
        p = path("containers", n, "ports")
        if os.path.exists(p):
            with open(p, encoding="utf-8") as f:
                lines += [x.rstrip("\n") for x in f if x.strip()]
    with open(path("ports"), "w", encoding="utf-8") as f:
        f.write("".join(x + "\n" for x in lines))
