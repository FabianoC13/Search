#!/usr/bin/env python3
"""Closing the last tab that isn't a pin leaves an empty tab, not a pin (#537),
and a local text file WebKit can't name opens as text, not as a download
(#525), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/last_tab.py`. It runs in
split_view.py's test world, with its harness: started hidden, everything
removed afterwards.
"""
import os
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

t = sv.T()
def tabs(): return sv.cmd({"do": "tabs"})["tabs"]
def cmd_w(): sv.cmd({"do": "press", "code": 13, "chars": "w", "mods": ["cmd"]}); time.sleep(0.8)
folder = tempfile.mkdtemp()
try:
    sv.setup(); sv.launch()
    pin = sv.cmd({"do": "open", "url": f"{sv.BASE}/a"})["id"]; time.sleep(0.7)
    sv.cmd({"do": "pin", "id": pin})
    page = sv.cmd({"do": "open", "url": f"{sv.BASE}/b"})["id"]; time.sleep(0.7)
    # Everything else goes, so the page is the last tab that isn't a pin.
    for tab in tabs():
        if tab["id"] not in (pin, page):
            sv.cmd({"do": "select", "id": tab["id"]}); time.sleep(0.3); cmd_w()
    sv.cmd({"do": "select", "id": page}); time.sleep(0.4)
    cmd_w()
    now = tabs()
    active = [x for x in now if x["active"]]
    t.ok("the page is closed", all(x["id"] != page for x in now), now)
    t.ok("an empty tab is in front, not the pin", len(active) == 1 and active[0]["id"] != pin and active[0]["url"] == "", now)

    # A Makefile: WebKit calls it application/octet-stream.
    make = os.path.join(folder, "Makefile")
    open(make, "w").write("all:\n\techo hello from the makefile\n")
    shown = sv.cmd({"do": "open", "url": "file://" + make})["id"]; time.sleep(1.5)
    text = sv.cmd({"do": "text", "id": shown}).get("text", "")
    t.ok("a Makefile opens as text", "hello from the makefile" in text, text[:200])
    t.ok("no copy of it in Downloads", not os.path.exists(os.path.expanduser("~/Downloads/Makefile")))
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
