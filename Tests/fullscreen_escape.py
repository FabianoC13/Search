#!/usr/bin/env python3
"""One Escape leaves a page's full screen, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/fullscreen_escape.py`.
Nothing goes full screen: the page's own word that it is going
(Tab.immersed), as Forms' script sends it, is sent from Search's own world
on the page, the page's view is given the keys, and
Escape is pressed through the app's own event queue, so the window's key
monitor sees it first, as a real press. A video's full screen took two
presses to leave (fab, 22 Oct 2026): WebKit's full-screen window isn't a
browser's, its keys went to the browser in front, and Escape there put
away what was left up behind the video, the find bar or the address
field, before the page had it. Checked here: with a page filling the
screen, the first Escape reaches the page and leaves the find bar, the
field and a peek where they are, alone or in a pair, with the page's own
Escape listener on it too; a key the page doesn't use is still kept
quiet (#402); and with no page filling the screen, Escape still puts
those away. WebKit's own part, the video leaving on that key, is checked
by hand on a release candidate.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("fullscreen-escape")
ESC = "\u001b"
CMD_L = 37

# Every key the page sees; "keep" makes it the page's own Escape listener,
# which takes the key for itself as a player's does.
LISTEN = """
window.__keys = [];
if (!window.__listening) {
  window.__listening = true;
  ['keydown', 'keyup'].forEach(function (type) {
    window.addEventListener(type, function (e) {
      window.__keys.push(type + ':' + e.key);
      if (window.__keep && e.key === 'Escape') e.preventDefault();
    }, true);
  });
}
window.__keep = KEEP;
1
"""


def listen(tab, keep=False):
    sv.ev(tab, LISTEN.replace("KEEP", "true" if keep else "false"))


def saw(tab):
    """What the page saw since last asked."""
    keys = sv.ev(tab, "JSON.stringify(window.__keys)")
    sv.ev(tab, "window.__keys = []; 1")
    return keys or ""


def keys_to(tab):
    """The page's view has the keys, as a click on the video leaves them;
    an x it doesn't use, so the page sees nothing to remember."""
    return sv.cmd({"do": "key", "id": tab, "text": "x"})


def esc():
    sv.cmd({"do": "press", "code": 53, "chars": ESC}); time.sleep(0.4)


def immerse(tab, on):
    # install/combined's bench has no `layouts`: the page's own word that it
    # is going, as Forms' script sends it from requestFullscreen.
    sv.cmd({"do": "eval", "id": tab, "world": "search",
            "js": "window.webkit.messageHandlers.officeForms.postMessage({kind: 'fullscreen', on: %s}); 1" % ("true" if on else "false")})
    time.sleep(0.6)


def state():
    p = sv.cmd({"do": "probe"}); st = sv.sp("state")
    return {"finding": st["finding"], "field": p["field"], "peek": p["peek"],
            "quieted": p["keysQuieted"], "responder": p["responder"]}


def find_bar():
    sv.cmd({"do": "find", "text": "a"})


def run(t, name, split):
    sv.setup(sidebar=True, splitView=split); sv.launch()
    a = sv.page("a")
    if split:
        b = sv.page("b")
        sv.sp("pair", id=b, **{"with": a}, side="right"); time.sleep(0.8)
        sv.sp("focus", id=a); time.sleep(0.4)
    time.sleep(0.6)
    listen(a)

    # Not filling the screen: Escape is the window's, as before.
    find_bar(); keys_to(a); saw(a)
    esc(); s = state()
    t.ok(f"{name}: no full screen, Escape closes the find bar", not s["finding"], s)
    t.ok(f"{name}: no full screen, the page doesn't see that Escape", "keydown:Escape" not in saw(a), s)

    immerse(a, True)
    # The find bar left up behind the video.
    find_bar(); keys_to(a); saw(a)
    before = state()
    esc(); s = state()
    seen = saw(a)
    t.ok(f"{name}: full screen, the first Escape reaches the page", "keydown:Escape" in seen, (seen, s))
    t.ok(f"{name}: full screen, the find bar behind stays", s["finding"], s)
    t.ok(f"{name}: full screen, nothing comes back to be kept quiet", s["quieted"] == before["quieted"], (before, s))

    # The page's own Escape listener, taking the key: still the page's.
    listen(a, keep=True)
    find_bar(); keys_to(a); saw(a)
    esc(); s = state()
    seen = saw(a)
    t.ok(f"{name}: with the page's own Escape listener, the first Escape reaches it", "keydown:Escape" in seen, (seen, s))
    t.ok(f"{name}: with the page's own Escape listener, the find bar stays", s["finding"], s)
    listen(a)

    # A key the page doesn't use is still kept quiet, full screen or not.
    quiet = keys_to(a)
    t.ok(f"{name}: full screen, a key the page doesn't use is kept quiet (#402)",
         quiet.get("sentBackUnused") == 1 and quiet.get("quieted") == 1, quiet)

    # The address field left up behind the video.
    sv.cmd({"do": "press", "code": CMD_L, "chars": "l", "mods": ["cmd"]}); time.sleep(0.5)
    up = state()["field"]
    keys_to(a); saw(a)
    s = state()
    if up and s["field"]:
        esc(); s = state()
        seen = saw(a)
        t.ok(f"{name}: full screen, the first Escape reaches the page, not the field behind", "keydown:Escape" in seen and s["field"], (seen, s))
    else:
        print(f"  --  {name}: the field didn't stay up behind the page here; not checked", up, s)
    if s["field"]:
        immerse(a, False); esc(); immerse(a, True)

    # A peek left up over the tab.
    if not split:
        sv.cmd({"do": "peek", "url": f"{sv.BASE}/peeked"}); time.sleep(1.0)
        keys_to(a); saw(a)
        esc(); s = state()
        seen = saw(a)
        t.ok(f"{name}: full screen, the first Escape reaches the page, and the peek stays", "keydown:Escape" in seen and s["peek"] != "", (seen, s))
        sv.cmd({"do": "peek", "url": "close"}); time.sleep(0.4)

    # Back from full screen, Escape is the window's again.
    immerse(a, False)
    find_bar(); keys_to(a); saw(a)
    esc(); s = state()
    t.ok(f"{name}: back from full screen, Escape closes the find bar", not s["finding"], s)
    t.ok(f"{name}: back from full screen, the page doesn't see that Escape", "keydown:Escape" not in saw(a), s)

    if split:
        # The other pane of the pair filling the screen.
        sv.sp("focus", id=b); time.sleep(0.4)
        listen(b)
        immerse(b, True)
        find_bar(); keys_to(b); saw(b)
        esc(); s = state()
        seen = saw(b)
        t.ok(f"{name}: the right pane full screen, the first Escape reaches it", "keydown:Escape" in seen and s["finding"], (seen, s))
        immerse(b, False)
    sv.quit()


def main():
    t = sv.T()
    try:
        run(t, "alone", False)
        run(t, "Split View pair", True)
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
