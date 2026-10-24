#!/usr/bin/env python3
"""Fork-only helper around the App Store Connect API for the TestFlight path.

    asc.py check              <KEY_ID> <ISSUER_ID> <AuthKey.p8>   key usable? bundle id registered? app record present?
    asc.py register-bundle-id <KEY_ID> <ISSUER_ID> <AuthKey.p8>   registers com.onkelenno.opentara (iOS) if missing
    asc.py builds             <KEY_ID> <ISSUER_ID> <AuthKey.p8>   latest builds of the app with processing state

Needs python3-jwt and python3-cryptography (ES256) plus requests. The .p8 never leaves the box.
"""
import json
import sys
import time

import jwt
import requests

BUNDLE_ID = "com.onkelenno.opentara"
API = "https://api.appstoreconnect.apple.com/v1"


def token(key_id: str, issuer_id: str, p8_path: str) -> str:
    with open(p8_path, encoding="utf-8") as fh:
        key = fh.read()
    now = int(time.time())
    return jwt.encode(
        {"iss": issuer_id, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
        key, algorithm="ES256", headers={"kid": key_id, "typ": "JWT"},
    )


def call(tok: str, method: str, path: str, **kw):
    r = requests.request(method, API + path, headers={"Authorization": f"Bearer {tok}"}, timeout=30, **kw)
    if r.status_code >= 400:
        try:
            errs = r.json().get("errors", [])
            msg = "; ".join(f"{e.get('status')} {e.get('code')}: {e.get('title')} – {e.get('detail')}" for e in errs)
        except ValueError:
            msg = r.text[:500]
        sys.exit(f"{method} {path} -> HTTP {r.status_code}: {msg}")
    return r.json() if r.content else {}


def find_bundle_id(tok):
    data = call(tok, "GET", "/bundleIds", params={"filter[identifier]": BUNDLE_ID}).get("data", [])
    return next((d for d in data if d["attributes"]["identifier"] == BUNDLE_ID), None)


def find_app(tok):
    data = call(tok, "GET", "/apps", params={"filter[bundleId]": BUNDLE_ID}).get("data", [])
    return data[0] if data else None


def cmd_check(tok):
    apps = call(tok, "GET", "/apps", params={"limit": 20, "fields[apps]": "name,bundleId,sku"}).get("data", [])
    print(f"key works, team has {len(apps)} app record(s):")
    for a in apps:
        at = a["attributes"]
        print(f"  {a['id']:>12}  {at['bundleId']:<32} {at['name']}")
    b = find_bundle_id(tok)
    print(f"bundle id {BUNDLE_ID}: " + (f"registered (id {b['id']}, name '{b['attributes']['name']}')" if b else "NOT registered -> run register-bundle-id"))
    app = find_app(tok)
    if app:
        print(f"app record: id {app['id']}, name '{app['attributes']['name']}' -> TestFlight upload can run")
    else:
        print("app record: MISSING -> create it in App Store Connect (browser): Apps -> + -> Neue App, iOS, bundle id above")
    return 0


def cmd_register(tok):
    b = find_bundle_id(tok)
    if b:
        print(f"already registered: {BUNDLE_ID} (id {b['id']})")
        return 0
    body = {"data": {"type": "bundleIds", "attributes": {"identifier": BUNDLE_ID, "name": "OpenTara", "platform": "IOS"}}}
    created = call(tok, "POST", "/bundleIds", json=body)["data"]
    print(f"registered {BUNDLE_ID} as id {created['id']} (no capabilities; OpenTara needs none)")
    return 0


def cmd_builds(tok):
    app = find_app(tok)
    if not app:
        sys.exit(f"no app record for {BUNDLE_ID} yet")
    builds = call(tok, "GET", "/builds", params={
        "filter[app]": app["id"], "sort": "-uploadedDate", "limit": 10,
        "fields[builds]": "version,processingState,uploadedDate,expired,minOsVersion",
        "include": "preReleaseVersion", "fields[preReleaseVersions]": "version",
    })
    versions = {i["id"]: i["attributes"]["version"] for i in builds.get("included", []) if i["type"] == "preReleaseVersions"}
    rows = builds.get("data", [])
    if not rows:
        print(f"app '{app['attributes']['name']}' (id {app['id']}): no builds uploaded yet")
        return 0
    print(f"app '{app['attributes']['name']}' (id {app['id']}):")
    for bld in rows:
        at = bld["attributes"]
        pv = bld.get("relationships", {}).get("preReleaseVersion", {}).get("data") or {}
        print(f"  {versions.get(pv.get('id'), '?'):>7} ({at['version']:>4})  {at['processingState']:<10} uploaded {at['uploadedDate']}  expired={at['expired']}")
    return 0


def main(argv):
    if len(argv) != 5 or argv[1] not in ("check", "register-bundle-id", "builds"):
        sys.exit(__doc__)
    tok = token(argv[2], argv[3], argv[4])
    return {"check": cmd_check, "register-bundle-id": cmd_register, "builds": cmd_builds}[argv[1]](tok)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
