#!/usr/bin/env python3
"""Re-embed bin/fanctl and bin/fanctld into fanctl-install.sh.

The installer carries its own copy of both programs so it can run from a
single curl, which means the copies can drift. Run this after editing
either one, and in CI to check they still match:

    tools/embed.py            rewrite the installer
    tools/embed.py --check    exit 1 if it is stale
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
INSTALLER = ROOT / "fanctl-install.sh"
EMBEDS = [
    (ROOT / "bin" / "fanctl", "/usr/local/bin/fanctl", "FANCTL_EOF"),
    (ROOT / "bin" / "fanctld", "/usr/local/bin/fanctld", "FANCTLD_EOF"),
]


def embed(installer, source, target, delim):
    """Return the installer with the heredoc for target replaced by source."""
    block = re.compile(
        r"(cat > %s <<'%s'\n)(?:.*?\n)?(%s\n)"
        % (re.escape(target), delim, delim),
        re.DOTALL,
    )
    body = source.read_text().rstrip("\n")
    if delim in body:
        sys.exit(f"{source} contains the heredoc delimiter {delim}")

    match = block.search(installer)
    if not match:
        sys.exit(f"embedded block for {target} not found in {INSTALLER}")

    return (installer[:match.start()]
            + match.group(1) + body + "\n" + match.group(2)
            + installer[match.end():])


def main():
    check = "--check" in sys.argv
    original = INSTALLER.read_text()

    updated = original
    for source, target, delim in EMBEDS:
        updated = embed(updated, source, target, delim)

    if updated == original:
        print("installer is up to date")
        return

    if check:
        sys.exit("installer is stale - run tools/embed.py")

    INSTALLER.write_text(updated)
    print("installer updated")


if __name__ == "__main__":
    main()
