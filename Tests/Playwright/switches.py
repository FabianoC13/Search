#!/usr/bin/env python3
"""PlaywrightSwitches.swift's `release` and `all`, from Playwright's
chromiumSwitches.ts at a release (./playwright.sh switches).

The file is read as text for its string literals, never run. `attach`, which
is chosen by hand, is left as it is, and what changed upstream since the last
pin is printed, for a look at `attach` again.

Usage: switches.py chromiumSwitches.ts RELEASE PlaywrightSwitches.swift
"""
import re
import sys

STRING = re.compile(r"'((?:[^'\\]|\\.)*)'|\"((?:[^\"\\]|\\.)*)\"|`((?:[^`\\]|\\.)*)`")


def without_comments(text):
    out, i, quote = [], 0, None
    while i < len(text):
        c = text[i]
        if quote:
            out.append(c)
            if c == "\\":
                out.append(text[i + 1])
                i += 2
                continue
            if c == quote:
                quote = None
        elif c in "'\"`":
            quote = c
            out.append(c)
        elif text.startswith("//", i):
            while i < len(text) and text[i] != "\n":
                i += 1
            continue
        elif text.startswith("/*", i):
            i = text.index("*/", i) + 2
            continue
        else:
            out.append(c)
        i += 1
    return "".join(out)


def bracketed(text, start):
    """What is between the [ at or after `start` and the ] that closes it."""
    first = text.index("[", start)
    depth, quote = 0, None
    for j in range(first, len(text)):
        c = text[j]
        if quote:
            if c == quote and text[j - 1] != "\\":
                quote = None
        elif c in "'\"`":
            quote = c
        elif c == "[":
            depth += 1
        elif c == "]":
            depth -= 1
            if depth == 0:
                return text[first + 1:j]
    raise SystemExit("no ] for the [ at %d" % first)


def elements(body):
    """The array's elements: split at its own commas, not those in calls."""
    parts, depth, quote, current = [], 0, None, []
    for i, c in enumerate(body):
        if quote:
            if c == quote and body[i - 1] != "\\":
                quote = None
        elif c in "'\"`":
            quote = c
        elif c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == "," and depth == 0:
            parts.append("".join(current))
            current = []
            continue
        current.append(c)
    parts.append("".join(current))
    return [p.strip() for p in parts if p.strip()]


def literals(text):
    return ["".join(groups) for groups in STRING.findall(text)]


def read(path):
    text = without_comments(open(path, encoding="utf-8").read())
    lists = {}
    for match in re.finditer(r"\b(\w+)\s*=\s*(?:\(\)\s*=>\s*)?\[", text):
        lists[match.group(1)] = [s for s in literals(bracketed(text, match.end() - 1)) if s]
    at = text.find("chromiumSwitches")
    arrow = text.find("=>", at) if at >= 0 else -1
    if arrow < 0:
        raise SystemExit("no chromiumSwitches in %s" % path)
    switches = []
    for element in elements(bracketed(text, arrow)):
        # A ternary keeps its non-empty side: `cond ? '' : '--x'`.
        given = [s for s in literals(element) if s.startswith("--")]
        if not given:
            continue
        switch = given[-1]
        joined = re.search(r"\+\s*(\w+)(?:\(\))?\s*\.join\(", element)
        if joined:
            switch += ",".join(lists.get(joined.group(1), []))
        switch = switch[2:]
        if switch not in switches:
            switches.append(switch)
    return switches


def features(switches, name):
    for switch in switches:
        if switch.startswith(name + "="):
            return switch.split("=", 1)[1].split(",")
    return []


def main():
    source, release, target = sys.argv[1:4]
    switches = read(source)
    swift = open(target, encoding="utf-8").read()
    block = re.search(r"(    static let all: \[String\] = \[\n)(.*?)(\n    \])", swift, re.S)
    before = re.findall(r'"([^"]*)"', block.group(2))
    lines = "\n".join('        "%s",' % s for s in switches)
    swift = swift[:block.start(2)] + lines + swift[block.end(2):]
    swift = re.sub(r'static let release = "[^"]*"', 'static let release = "%s"' % release, swift)
    open(target, "w", encoding="utf-8").write(swift)

    def names(listed):
        return [s.split("=", 1)[0] for s in listed]

    added = [s for s in names(switches) if s not in names(before)]
    gone = [s for s in names(before) if s not in names(switches)]
    print("PlaywrightSwitches.swift: %d switches from Playwright %s" % (len(switches), release))
    for word, found in (("new", added), ("gone", gone)):
        for switch in found:
            print("  %s switch: %s" % (word, switch))
    for name in ("disable-features", "enable-features"):
        was, now = features(before, name), features(switches, name)
        for feature in now:
            if feature not in was:
                print("  new in %s: %s" % (name, feature))
        for feature in was:
            if feature not in now:
                print("  gone from %s: %s" % (name, feature))
    if added or gone or any(features(before, n) != features(switches, n) for n in ("disable-features", "enable-features")):
        print("Look at `attach` again: it is chosen by hand.")


if __name__ == "__main__":
    main()
