#!/usr/bin/env python3
"""Start isolated HA-MCP, hiding tools unsupported by this HA installation."""

import json
import os
import sys
from urllib.request import Request, urlopen

URL = os.environ.get("HOMEASSISTANT_URL", "http://127.0.0.1:8123").rstrip("/")
TOKEN = os.environ.get("HOMEASSISTANT_TOKEN", "")
if not TOKEN:
    sys.exit("HOMEASSISTANT_TOKEN is required")


def get(path):
    request = Request(URL + path, headers={"Authorization": "Bearer " + TOKEN})
    with urlopen(request, timeout=10) as response:
        return json.load(response)


present = set()
try:
    info = get("/api/config")
    present.update(name.split(".", 1)[0] for name in info.get("components", []))
    entries = get("/api/config/config_entries/entry")
    present.update(entry.get("domain") for entry in entries if isinstance(entry, dict))
except Exception as exc:  # HA may still be starting; use conservative visibility.
    print(f"HA-MCP: HA capability probe unavailable ({type(exc).__name__}); hiding optional tools", file=sys.stderr)

disabled = {"ha_get_addon", "ha_manage_addon", "ha_get_app", "ha_manage_app"}
if "hacs" not in present:
    disabled.update({"ha_get_hacs_info", "ha_manage_hacs"})
if "assist_pipeline" not in present:
    disabled.add("ha_manage_pipeline")
if not present.intersection({"zha", "zwave_js", "matter", "thread"}):
    disabled.add("ha_manage_radio")
disabled.update(filter(None, os.environ.get("WOOW_MCP_EXTRA_DISABLED", "").split(",")))
os.environ["DISABLED_TOOLS"] = ",".join(sorted(disabled))
print("HA-MCP: disabled unsupported tools: " + os.environ["DISABLED_TOOLS"], flush=True)
os.execv("/opt/woow/ha-mcp/bin/ha-mcp-web", ["ha-mcp-web"])
