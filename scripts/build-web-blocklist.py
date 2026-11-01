#!/usr/bin/env python3
"""Turns EasyList and EasyPrivacy into the rule list Web blocks ads and trackers with.

Usage: build-web-blocklist.py <output.json> <easylist.txt> <easyprivacy.txt>

Fetch the two lists from https://easylist.to first. Only whole-site rules are kept, because WebKit
compiles those quickly and they're what stops most trackers. Anything else in a list is ignored, so
nothing from a downloaded file reaches the output except a checked host name.

The lists are used under CC BY-SA 3.0 or later, and the app credits them in Web Settings.
"""

import json
import re
import sys

# Below WebKit's limit of about 150,000. A larger list means a longer first compile on a phone.
LIMIT = 120_000
HOST = r"[a-z0-9-]+(?:\.[a-z0-9-]+)+"
BLOCK = re.compile(rf"^\|\|({HOST})\^(\$third-party)?$")
ALLOW = re.compile(rf"^@@\|\|({HOST})\^")


def rule(host, third_party):
    # Matches the host and its subdomains, on any scheme, and nothing that merely contains the name.
    trigger = {"url-filter": "^[^:]+://+([^:/]+\\.)?" + host.replace(".", "\\.") + "[:/]"}
    if third_party:
        trigger["load-type"] = ["third-party"]
    return {"trigger": trigger, "action": {"type": "block"}}


def covered(host, blocked, allowed):
    """True if a parent's rule already stops this host on every page this rule would."""
    parts = host.split(".")
    for start in range(1, len(parts) - 1):
        parent = ".".join(parts[start:])
        if parent in blocked and parent not in allowed and (blocked[host] or not blocked[parent]):
            return True
    return False


def main():
    output, *sources = sys.argv[1:]
    blocked = {}
    allowed = set()
    for source in sources:
        with open(source, encoding="utf-8", errors="replace") as file:
            for line in file:
                line = line.strip().lower()
                if match := ALLOW.match(line):
                    allowed.add(match[1])
                elif match := BLOCK.match(line):
                    # A rule for every page beats a rule for other sites' pages only.
                    blocked[match[1]] = blocked.get(match[1], True) and bool(match[2])
    hosts = [host for host in sorted(blocked) if host not in allowed and not covered(host, blocked, allowed)]
    if len(hosts) > LIMIT:
        sys.exit(f"{len(hosts)} sites is over the limit of {LIMIT}")
    with open(output, "w", encoding="utf-8") as file:
        json.dump([rule(host, blocked[host]) for host in hosts], file, separators=(",", ":"))
    print(f"{len(hosts)} sites, {len(allowed)} exceptions")


if __name__ == "__main__":
    main()
