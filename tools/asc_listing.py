#!/usr/bin/env python3
"""Fills the App Store listing from appstore/ via the App Store Connect API.

    python3 tools/asc_listing.py --issuer <uuid> --key-id G334M8PQ9Z            # dry run
    python3 tools/asc_listing.py --issuer <uuid> --key-id G334M8PQ9Z --apply    # write
    python3 tools/asc_listing.py ... --apply --skip-screenshots --only en-US,ru

Sources: appstore/metadata/<locale>.json (name, subtitle, keywords, promotional_text, description)
and appstore/screenshots[-6.5]/<locale>/*.png (6.9" and 6.5" iPhone, uploaded in file-name order).
Missing localizations are created. Screenshot slots already holding the same processed files are left alone; others are replaced.
Apple's transient 5xx errors are retried, so a failed run can simply be re-run.
Never submits for review. Support URL, privacy policy URL, and copyright are set only when passed.

Key: an App Store Connect API key (.p8, App Manager or better), found in ~/Downloads, ~/private_keys,
or ~/.appstoreconnect/private_keys. The issuer id is passed in or read from ASC_ISSUER_ID; never stored.
Signing uses openssl (no PyJWT needed).
"""
import argparse
import base64
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import time
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
BUNDLE_ID = "com.solo.shotsy"
API = "https://api.appstoreconnect.apple.com/v1"
META = ROOT / "appstore" / "metadata"
# Screenshot slot -> folder: 6.9" (1320x2868) and 6.5" (1284x2778, resized from the 6.9" set).
SHOT_SETS = {"APP_IPHONE_67": ROOT / "appstore" / "screenshots",
             "APP_IPHONE_65": ROOT / "appstore" / "screenshots-6.5"}
EDITABLE_VERSION = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED",
                    "INVALID_BINARY"}
EDITABLE_INFO = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED",
                 "INVALID_BINARY", "WAITING_FOR_REVIEW"}
LIMITS = {"name": 30, "subtitle": 30, "keywords": 100, "promotionalText": 170, "description": 4000}


# ------------------------------------------------------------------ auth + requests

def _b64(raw):
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def find_key(key_id, given):
    if given:
        return pathlib.Path(given)
    for folder in (pathlib.Path.home() / "private_keys", pathlib.Path.home() / ".appstoreconnect/private_keys",
                   pathlib.Path.home() / "Downloads"):
        candidate = folder / f"AuthKey_{key_id}.p8"
        if candidate.exists():
            return candidate
    sys.exit(f"No AuthKey_{key_id}.p8 found. Pass --key.")


def token(issuer, key_id, key_path):
    """Nineteen-minute ES256 JWT signed with openssl (DER signature converted to raw r||s)."""
    now = int(time.time())
    signing_input = ".".join(_b64(json.dumps(p, separators=(",", ":")).encode()) for p in (
        {"alg": "ES256", "kid": key_id, "typ": "JWT"},
        {"iss": issuer, "iat": now, "exp": now + 19 * 60, "aud": "appstoreconnect-v1"}))
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(key_path)], input=signing_input.encode(),
                         capture_output=True, check=True).stdout
    body = der[2:] if der[1] < 0x80 else der[3:]

    def take(buf):
        n = buf[1]
        return buf[2:2 + n].lstrip(b"\x00").rjust(32, b"\x00"), buf[2 + n:]

    r, rest = take(body)
    s, _ = take(rest)
    return f"{signing_input}.{_b64(r + s)}"


class Client:
    def __init__(self, issuer, key_id, key_path):
        self.args = (issuer, key_id, key_path)
        self.minted = 0
        self.jwt = None

    def call(self, path, method="GET", payload=None):
        if time.time() - self.minted > 15 * 60:
            self.jwt, self.minted = token(*self.args), time.time()
        url = path if path.startswith("http") else f"{API}/{path}"
        data = json.dumps(payload).encode() if payload is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", f"Bearer {self.jwt}")
        if data:
            req.add_header("Content-Type", "application/json")
        for attempt in range(5):
            try:
                with urllib.request.urlopen(urllib.request.Request(
                        url, data=data, method=method, headers=dict(req.header_items())), timeout=60) as r:
                    raw = r.read()
                    return json.loads(raw) if raw else {}
            except urllib.error.HTTPError as e:
                if e.code >= 500 and attempt < 4:  # Apple's API has transient 500s; back off and retry
                    time.sleep(5 * (attempt + 1))
                    continue
                self.fail(method, url, e)
            except (urllib.error.URLError, TimeoutError):
                if attempt == 4:
                    raise
                time.sleep(5 * (attempt + 1))

    @staticmethod
    def fail(method, url, e):
        detail = e.read().decode(errors="replace")
        try:
            detail = "\n".join(f"  {x.get('title')}: {x.get('detail')}" for x in json.loads(detail)["errors"])
        except Exception:
            pass
        sys.exit(f"{method} {url}\n{e.code} {e.reason}\n{detail}")


# ------------------------------------------------------------------ screenshots

def upload_screenshot(api, set_id, path):
    blob = path.read_bytes()
    made = api.call("appScreenshots", "POST", {"data": {
        "type": "appScreenshots", "attributes": {"fileName": path.name, "fileSize": len(blob)},
        "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}}}})["data"]
    for op in made["attributes"]["uploadOperations"]:
        req = urllib.request.Request(op["url"], data=blob[op["offset"]:op["offset"] + op["length"]],
                                     method=op["method"])
        for h in op.get("requestHeaders", []):
            req.add_header(h["name"], h["value"])
        with urllib.request.urlopen(req, timeout=120) as r:
            r.read()
    api.call(f"appScreenshots/{made['id']}", "PATCH", {"data": {
        "type": "appScreenshots", "id": made["id"],
        "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(blob).hexdigest()}}})
    return made["id"]


def wait_processed(api, ids):
    pending = set(ids)
    for _ in range(80):
        for sid in list(pending):
            state = api.call(f"appScreenshots/{sid}")["data"]["attributes"]["assetDeliveryState"]["state"]
            if state == "COMPLETE":
                pending.discard(sid)
            elif state == "FAILED":
                sys.exit(f"Apple rejected screenshot {sid} in processing.")
        if not pending:
            return
        time.sleep(3)
    sys.exit(f"Still processing after four minutes: {sorted(pending)}")


def replace_screenshots(api, loc_id, display_type, files):
    sets = api.call(f"appStoreVersionLocalizations/{loc_id}/appScreenshotSets"
                    f"?filter[screenshotDisplayType]={display_type}")["data"]
    if sets:
        set_id = sets[0]["id"]
        existing = api.call(f"appScreenshotSets/{set_id}/appScreenshots?limit=10")["data"]
        # Already there from an earlier run (same files, same order, processed): leave it.
        if ([x["attributes"]["fileName"] for x in existing] == [f.name for f in files]
                and all(x["attributes"]["assetDeliveryState"]["state"] == "COMPLETE" for x in existing)):
            return False
        for old in existing:
            api.call(f"appScreenshots/{old['id']}", "DELETE")
    else:
        set_id = api.call("appScreenshotSets", "POST", {"data": {
            "type": "appScreenshotSets", "attributes": {"screenshotDisplayType": display_type},
            "relationships": {"appStoreVersionLocalization": {"data": {
                "type": "appStoreVersionLocalizations", "id": loc_id}}}}})["data"]["id"]
    ids = [upload_screenshot(api, set_id, f) for f in files]
    wait_processed(api, ids)
    api.call(f"appScreenshotSets/{set_id}/relationships/appScreenshots", "PATCH",
             {"data": [{"type": "appScreenshots", "id": i} for i in ids]})
    return True


# ------------------------------------------------------------------ main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--issuer", default=os.environ.get("ASC_ISSUER_ID"), help="uuid from Users and Access > Integrations")
    ap.add_argument("--key-id", default=os.environ.get("ASC_KEY_ID"), help="the id in AuthKey_<id>.p8")
    ap.add_argument("--key", help="path to the .p8; searched for if unset")
    ap.add_argument("--only", help="comma separated locales, e.g. en-US,ru")
    ap.add_argument("--support-url")
    ap.add_argument("--marketing-url")
    ap.add_argument("--privacy-url")
    ap.add_argument("--copyright", help='e.g. "2026 Javoxir Abdumalikov"')
    ap.add_argument("--skip-screenshots", action="store_true")
    ap.add_argument("--apply", action="store_true", help="actually write; otherwise print and stop")
    args = ap.parse_args()
    if not args.issuer or not args.key_id:
        sys.exit("Need --issuer and --key-id (or ASC_ISSUER_ID / ASC_KEY_ID).")

    listings = {}
    for path in sorted(META.glob("*.json")):
        d = json.loads(path.read_text("utf-8"))
        fields = {"name": d["name"], "subtitle": d["subtitle"], "keywords": d["keywords"],
                  "promotionalText": d["promotional_text"], "description": d["description"]}
        for k, v in fields.items():
            if len(v) > LIMITS[k]:
                sys.exit(f"{path.stem} {k} is {len(v)}/{LIMITS[k]}")
        listings[d["locale"]] = fields
    only = set(args.only.split(",")) if args.only else None
    if only:
        listings = {k: v for k, v in listings.items() if k in only}

    api = Client(args.issuer, args.key_id, find_key(args.key_id, args.key))
    apps = api.call(f"apps?filter[bundleId]={BUNDLE_ID}")["data"]
    if not apps:
        sys.exit(f"No app with bundle id {BUNDLE_ID} on this account.")
    app = apps[0]
    print(f"{app['attributes']['name']}  ({BUNDLE_ID})  primary {app['attributes']['primaryLocale']}")

    infos = api.call(f"apps/{app['id']}/appInfos")["data"]
    info = next((i for i in infos if i["attributes"].get("appStoreState", i["attributes"].get("state"))
                 in EDITABLE_INFO), None) or infos[0]
    versions = [v for v in api.call(f"apps/{app['id']}/appStoreVersions?limit=20")["data"]
                if v["attributes"]["platform"] == "IOS" and v["attributes"]["appStoreState"] in EDITABLE_VERSION]
    if not versions:
        sys.exit("No editable iOS version.")
    version = versions[0]
    print(f"version {version['attributes']['versionString']}  state {version['attributes']['appStoreState']}")

    info_locs = {l["attributes"]["locale"]: l for l in
                 api.call(f"appInfos/{info['id']}/appInfoLocalizations?limit=50")["data"]}
    ver_locs = {l["attributes"]["locale"]: l for l in
                api.call(f"appStoreVersions/{version['id']}/appStoreVersionLocalizations?limit=50")["data"]}

    version_extra = {k: v for k, v in (("supportUrl", args.support_url), ("marketingUrl", args.marketing_url)) if v}
    for locale, f in listings.items():
        info_body = {k: f[k] for k in ("name", "subtitle")}
        if args.privacy_url:
            info_body["privacyPolicyUrl"] = args.privacy_url
        ver_body = {k: f[k] for k in ("description", "keywords", "promotionalText")} | version_extra
        il, vl = info_locs.get(locale), ver_locs.get(locale)
        info_diff = {k: v for k, v in info_body.items() if not il or il["attributes"].get(k) != v}
        ver_diff = {k: v for k, v in ver_body.items() if not vl or vl["attributes"].get(k) != v}
        shots = {t: sorted((folder / locale).glob("*.png")) for t, folder in SHOT_SETS.items()}
        print(f"{locale:8} info {'new' if not il else 'edit'}: {', '.join(info_diff) or '-'} | "
              f"version {'new' if not vl else 'edit'}: {', '.join(ver_diff) or '-'} | "
              f"screenshots: {'skip' if args.skip_screenshots else ' + '.join(str(len(f)) for f in shots.values())}")
        if not args.apply:
            continue

        if not il:
            api.call("appInfoLocalizations", "POST", {"data": {
                "type": "appInfoLocalizations", "attributes": {"locale": locale, **info_body},
                "relationships": {"appInfo": {"data": {"type": "appInfos", "id": info["id"]}}}}})
        elif info_diff:
            api.call(f"appInfoLocalizations/{il['id']}", "PATCH", {"data": {
                "type": "appInfoLocalizations", "id": il["id"], "attributes": info_diff}})

        if not vl:
            # Adding the app-info language makes Apple create an empty version localization too.
            vl = next((l for l in api.call(f"appStoreVersions/{version['id']}/appStoreVersionLocalizations"
                                           "?limit=50")["data"] if l["attributes"]["locale"] == locale), None)
            if vl:
                api.call(f"appStoreVersionLocalizations/{vl['id']}", "PATCH", {"data": {
                    "type": "appStoreVersionLocalizations", "id": vl["id"], "attributes": ver_body}})
        if not vl:
            vl = api.call("appStoreVersionLocalizations", "POST", {"data": {
                "type": "appStoreVersionLocalizations", "attributes": {"locale": locale, **ver_body},
                "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions",
                                                               "id": version["id"]}}}}})["data"]
        elif ver_diff:
            api.call(f"appStoreVersionLocalizations/{vl['id']}", "PATCH", {"data": {
                "type": "appStoreVersionLocalizations", "id": vl["id"], "attributes": ver_diff}})

        if not args.skip_screenshots:
            for display_type, files in shots.items():
                if files:
                    replace_screenshots(api, vl["id"], display_type, files)
        print(f"         done")

    if args.copyright and args.apply and version["attributes"].get("copyright") != args.copyright:
        api.call(f"appStoreVersions/{version['id']}", "PATCH", {"data": {
            "type": "appStoreVersions", "id": version["id"], "attributes": {"copyright": args.copyright}}})
        print(f"copyright set: {args.copyright}")
    if not args.apply:
        print("\nDry run. Re-run with --apply to write.")


if __name__ == "__main__":
    main()
