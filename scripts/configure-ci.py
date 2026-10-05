#!/usr/bin/env python3
"""Write non-secret Xcode identifiers from environment; never prints credentials."""
import os
import re
from pathlib import Path

team = os.environ.get("TEAMID", "AAAAAAAAAA")
app = os.environ.get("APP_ID_IOS", "com.jazztin98.jazzwg")
if not re.fullmatch(r"[A-Z0-9]{10}", team):
    raise SystemExit("TEAMID must be the ten-character Apple Developer Team ID.")
if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", app):
    raise SystemExit("APP_ID_IOS must be a valid reverse-domain bundle identifier.")
Path("Sources/WireGuardApp/Config/Developer.xcconfig").write_text(
    f"DEVELOPMENT_TEAM = {team}\nAPP_ID_IOS = {app}\nAPP_ID_MACOS = {app}.macos\n"
)
