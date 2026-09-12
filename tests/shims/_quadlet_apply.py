#!/usr/bin/env python3
"""tests/shims/_quadlet_apply.py: what Quadlet would do when a generated unit starts or stops.

    _quadlet_apply.py <unit> start|stop

Starting reads the installed .container file and writes the container the double would have
created (`podman run --replace --rm`): name, image, label, mounts, devices, stop timeout and
the health port. Stopping removes it again, because Quadlet runs containers with --rm.
"""
import os
import re
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import shimlib  # noqa: E402


def parse(qfile):
    kv = {}
    with open(qfile, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            kv.setdefault(k, []).append(v)
    return kv


def main():
    unit, action = sys.argv[1], sys.argv[2]
    if not unit.endswith(".service"):
        return 0
    home = os.environ["HOME"]
    qfile = os.path.join(home, ".config/containers/systemd", unit[: -len(".service")] + ".container")
    if not os.path.exists(qfile):
        return 0
    kv = parse(qfile)
    name = (kv.get("ContainerName") or [unit[: -len(".service")]])[0]
    if action == "stop":
        shutil.rmtree(shimlib.path("containers", name), ignore_errors=True)
        shimlib.sync_ports()
        return 0
    image = (kv.get("Image") or [""])[0]
    mounts = []
    for v in kv.get("Volume", []):
        src, _, rest = v.partition(":")
        dst = rest.split(":")[0]
        if src.startswith("/") or src.startswith("%h"):
            mounts.append({"Type": "bind", "Source": src.replace("%h", home), "Destination": dst})
        else:
            mounts.append({"Type": "volume", "Name": src.replace(".volume", ""),
                           "Source": shimlib.path("volumes", src.replace(".volume", "")), "Destination": dst})
    args = " ".join(kv.get("PodmanArgs", []))
    m = re.search(r"--stop-timeout=(\d+)", args)
    obj = {
        "Name": name,
        "Image": "sha256:" + image.replace("/", "_").replace(":", "_"),
        "ImageName": image,
        "State": {"Running": True, "Status": "running", "StartedAt": "2026-09-12T00:00:00Z",
                  "Health": {"Status": "healthy"}},
        "Config": {"Labels": {"PODMAN_SYSTEMD_UNIT": unit}, "CreateCommand": [], "Env": [],
                   "StopTimeout": int(m.group(1)) if m else 10, "Timezone": (kv.get("Timezone") or [""])[0],
                   "Healthcheck": {"Test": ["CMD", "x"]} if kv.get("HealthCmd") else None},
        "HostConfig": {"NetworkMode": (kv.get("Network") or ["bridge"])[0],
                       "Privileged": "--privileged" in args, "Devices": []},
        "Mounts": mounts,
    }
    shimlib.save_container(name, obj)
    with open(shimlib.path("containers", name, "devices"), "w", encoding="utf-8") as f:
        for v in kv.get("AddDevice", []):
            parts = v.split(":")
            f.write((parts[1] if len(parts) > 1 else parts[0]) + "\n")
    ports = []
    for v in kv.get("HealthCmd", []):
        hit = re.search(r"127\.0\.0\.1:(\d+)", v)
        if hit:
            ports.append("tcp %s python3 4242" % hit.group(1))
    for v in kv.get("PublishPort", []):
        hit = re.search(r":(\d+):", v)
        if hit:
            ports.append("tcp %s rootlessport 4243" % hit.group(1))
    with open(shimlib.path("containers", name, "ports"), "w", encoding="utf-8") as f:
        f.write("".join(p + "\n" for p in ports))
    shimlib.sync_ports()
    return 0


if __name__ == "__main__":
    sys.exit(main())
