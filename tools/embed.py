#!/usr/bin/env python3
"""Re-embed bin/fanctld into fanctl-install.sh.

The installer carries its own copy of the daemon so it can run from a
single curl, which means the two can drift. Run this after editing
bin/fanctld, and in CI to check they still match:

    tools/embed.py            rewrite the installer
    tools/embed.py --check    exit 1 if it is stale
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
INSTALLER = ROOT / "fanctl-install.sh"
DAEMON = ROOT / "bin" / "fanctld"
DELIM = "FANCTLD_EOF"

BLOCK = re.compile(
    r"(cat > /usr/local/bin/fanctld <<'%s'\n).*?(\n%s\n)" % (DELIM, DELIM),
    re.DOTALL,
)


def main():
    check = "--check" in sys.argv
    installer = INSTALLER.read_text()
    body = DAEMON.read_text().rstrip("\n")

    if DELIM in body:
        sys.exit(f"{DAEMON} contains the heredoc delimiter {DELIM}")

    match = BLOCK.search(installer)
    if not match:
        sys.exit(f"embedded block not found in {INSTALLER}")

    if match.group(0)[len(match.group(1)):-len(match.group(2))] == body:
        print("installer is up to date")
        return

    if check:
        sys.exit("installer is stale - run tools/embed.py")

    INSTALLER.write_text(
        installer[:match.start()]
        + match.group(1) + body + match.group(2)
        + installer[match.end():]
    )
    print("installer updated")


if __name__ == "__main__":
    main()
