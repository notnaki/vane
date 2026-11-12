#!/usr/bin/env python3
"""Validate a decoded Apple profile and generate only Vane's restricted grants.

Called by make-app.sh after security cms decodes the supplied signed profile.
No provisioning profiles, certificates or secrets are fetched by this script.
"""
import datetime
import hashlib
import os
import plistlib
import re
import subprocess
import sys


def generate(profile, base, container, identity, available_identities, now=None, environment=None):
    now = now or datetime.datetime.now(datetime.timezone.utc)
    expiry = profile.get("ExpirationDate")
    if not isinstance(expiry, datetime.datetime):
        raise ValueError("provisioning profile has no expiration")
    if expiry.tzinfo is None:
        expiry = expiry.replace(tzinfo=datetime.timezone.utc)
    if expiry <= now:
        raise ValueError("provisioning profile is expired")
    if "OSX" not in profile.get("Platform", []):
        raise ValueError("provisioning profile does not authorize macOS")
    teams = profile.get("TeamIdentifier", [])
    if len(teams) != 1 or not re.fullmatch(r"[A-Z0-9]{10}", teams[0]):
        raise ValueError("profile must authorize one explicit Apple team")
    team = teams[0]
    app = team + ".io.github.notnaki.vane"
    grants = profile.get("Entitlements", {})
    if grants.get("com.apple.application-identifier") != app:
        raise ValueError("profile must authorize Vane's exact application identifier")
    if grants.get("com.apple.developer.team-identifier") != team:
        raise ValueError("profile team identifiers do not match")
    if not container.startswith("iCloud.") or "*" in container or container not in grants.get("com.apple.developer.icloud-container-identifiers", []):
        raise ValueError("requested CloudKit container is not explicitly authorized")
    services = grants.get("com.apple.developer.icloud-services", [])
    if isinstance(services, str):
        services = [services]
    if not isinstance(services, list) or not any(service in services for service in ("CloudKit", "*")):
        raise ValueError("profile does not authorize CloudKit")
    environments = grants.get("com.apple.developer.icloud-container-environment", [])
    if isinstance(environments, str):
        environments = [environments]
    if not isinstance(environments, list):
        raise ValueError("profile has no authorized CloudKit environment")
    if environment is None:
        environment = next((value for value in ("Development", "Production") if value in environments), None)
    if environment not in ("Development", "Production") or environment not in environments:
        raise ValueError("requested CloudKit environment is not authorized")
    push = grants.get("com.apple.developer.aps-environment")
    if push not in ("development", "production"):
        raise ValueError("profile does not authorize macOS remote notifications")
    groups = grants.get("keychain-access-groups", [])
    if not isinstance(groups, list) or not any(group in groups for group in (app, team + ".*")):
        raise ValueError("profile must authorize Vane's Keychain group within its own team")
    identities = re.findall(r'([0-9A-Fa-f]{40})\s+"([^"]+)"', available_identities)
    matches = [(digest.upper(), name) for digest, name in identities
               if identity.upper() == digest.upper() or identity == name]
    if len(matches) != 1:
        raise ValueError("SIGN_ID must exactly identify one valid local signing identity")
    fingerprint = matches[0][0]
    certificates = {hashlib.sha1(data).hexdigest().upper() for data in profile.get("DeveloperCertificates", [])}
    if fingerprint not in certificates:
        raise ValueError("signing certificate is not authorized by this profile")
    result = dict(base)
    result.update({
        "com.apple.application-identifier": app,
        "com.apple.developer.team-identifier": team,
        "com.apple.developer.icloud-container-identifiers": [container],
        "com.apple.developer.icloud-services": ["CloudKit"],
        "com.apple.developer.icloud-container-environment": environment,
        "com.apple.developer.aps-environment": push,
        "keychain-access-groups": [app],
    })
    # Development profiles can authorize a debugger. That privilege is never copied.
    result.pop("get-task-allow", None)
    result.pop("com.apple.security.get-task-allow", None)
    return result


def main():
    if len(sys.argv) != 6:
        raise ValueError("usage: icloud-entitlements.py decoded-profile base-entitlements output container signing-identity")
    decoded, base, output, container, identity = sys.argv[1:]
    with open(decoded, "rb") as stream:
        profile = plistlib.load(stream)
    with open(base, "rb") as stream:
        entitlements = plistlib.load(stream)
    identities = subprocess.check_output(["security", "find-identity", "-v", "-p", "codesigning"], text=True)
    result = generate(profile, entitlements, container, identity, identities,
                      environment=os.environ.get("VANE_ICLOUD_ENVIRONMENT"))
    with open(output, "wb") as stream:
        os.fchmod(stream.fileno(), 0o600)
        plistlib.dump(result, stream)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError, plistlib.InvalidFileException) as error:
        print("iCloud provisioning rejected: " + str(error), file=sys.stderr)
        sys.exit(1)
