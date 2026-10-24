#!/usr/bin/env python3
"""Fork-only helper around the App Store Connect API for the TestFlight path.

    asc.py check              <KEY_ID> <ISSUER_ID> <AuthKey.p8>   key usable? bundle id registered? app record present?
    asc.py register-bundle-id <KEY_ID> <ISSUER_ID> <AuthKey.p8>   registers com.onkelenno.opentara (iOS) if missing
    asc.py builds             <KEY_ID> <ISSUER_ID> <AuthKey.p8>   latest builds of the app with processing state
    asc.py issue-signing      <KEY_ID> <ISSUER_ID> <AuthKey.p8>   new iOS distribution certificate + App Store profile,
                                                                   .p12 next to the .p8, and the three signing secrets
                                                                   (ASC_DIST_P12, ASC_DIST_P12_PASSWORD,
                                                                   ASC_PROVISIONING_PROFILE) in the fork

Needs python3-jwt and python3-cryptography (ES256), requests, openssl and gh. The .p8 and the
certificate's private key never leave the box; the GitHub secrets hold copies for the runner.
"""
import base64
import json
import os
import secrets as pysecrets
import subprocess
import sys
import time

import jwt
import requests

BUNDLE_ID = "com.onkelenno.opentara"
API = "https://api.appstoreconnect.apple.com/v1"
TEAM_NAME = "Onkel Enno Verkaufsautomaten GmbH"
PROFILE_NAME = "OpenTara Enno AppStore CI"
REPO = os.environ.get("OPENTARA_REPO", "onkelennovending/opentara")


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


def cmd_issue_signing(tok, p8_path):
    """Certificate + profile through the API, .p12 with openssl, secrets with gh."""
    out_dir = os.path.dirname(os.path.abspath(p8_path))
    os.umask(0o077)
    key_path = os.path.join(out_dir, "dist.key")
    csr_path = os.path.join(out_dir, "dist.csr")
    subprocess.run(["openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", key_path, "-out", csr_path,
                    "-subj", f"/CN=OpenTara CI Distribution/O={TEAM_NAME}/C=DE"], check=True, capture_output=True)
    with open(csr_path, encoding="utf-8") as fh:
        csr = fh.read()
    cert = call(tok, "POST", "/certificates", json={"data": {"type": "certificates", "attributes": {
        "certificateType": "IOS_DISTRIBUTION", "csrContent": csr}}})["data"]
    print(f"certificate {cert['id']}: {cert['attributes']['name']}, expires {cert['attributes']['expirationDate']}")
    pem_path = os.path.join(out_dir, "dist.pem")
    der = base64.b64decode(cert["attributes"]["certificateContent"])
    subprocess.run(["openssl", "x509", "-inform", "DER", "-out", pem_path], input=der, check=True, capture_output=True)

    bundle = find_bundle_id(tok) or sys.exit(f"{BUNDLE_ID} is not registered; run register-bundle-id first")
    profile = call(tok, "POST", "/profiles", json={"data": {"type": "profiles",
        "attributes": {"name": PROFILE_NAME, "profileType": "IOS_APP_STORE"},
        "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle["id"]}},
                          "certificates": {"data": [{"type": "certificates", "id": cert["id"]}]}}}})["data"]
    print(f"profile {profile['id']}: {profile['attributes']['name']} ({profile['attributes']['uuid']}), "
          f"expires {profile['attributes']['expirationDate']}")
    profile_path = os.path.join(out_dir, "opentara.mobileprovision")
    with open(profile_path, "wb") as fh:
        fh.write(base64.b64decode(profile["attributes"]["profileContent"]))

    password = pysecrets.token_hex(16)
    p12_path = os.path.join(out_dir, "dist.p12")
    base = ["openssl", "pkcs12", "-export", "-inkey", key_path, "-in", pem_path, "-name", cert["attributes"]["name"],
            "-out", p12_path, "-passout", f"pass:{password}"]
    # -legacy (RC2/3DES) keeps macOS `security import` happy; fall back to the OpenSSL 3 default.
    if subprocess.run(base + ["-legacy"], capture_output=True).returncode != 0:
        subprocess.run(base, check=True, capture_output=True)
    with open(os.path.join(out_dir, "dist.p12.password"), "w", encoding="utf-8") as fh:
        fh.write(password)

    def set_secret(name, value):
        subprocess.run(["gh", "secret", "set", name, "--repo", REPO, "--body", value], check=True)
        print(f"secret {name} set in {REPO}")
    with open(p12_path, "rb") as fh:
        set_secret("ASC_DIST_P12", base64.b64encode(fh.read()).decode())
    set_secret("ASC_DIST_P12_PASSWORD", password)
    with open(profile_path, "rb") as fh:
        set_secret("ASC_PROVISIONING_PROFILE", base64.b64encode(fh.read()).decode())
    print("done – the next TestFlight run uses the new certificate and profile; "
          "revoke the old certificate in the portal once that run is green")
    return 0


def main(argv):
    commands = {"check": cmd_check, "register-bundle-id": cmd_register, "builds": cmd_builds}
    if len(argv) != 5 or argv[1] not in (*commands, "issue-signing"):
        sys.exit(__doc__)
    tok = token(argv[2], argv[3], argv[4])
    if argv[1] == "issue-signing":
        return cmd_issue_signing(tok, argv[4])
    return commands[argv[1]](tok)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
