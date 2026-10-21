"""Build and package the Flutter PWA. Run from any directory with Python 3."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PUBLIC_KEYS = {"URL", "SITE_URL", "GOOGLE_MAPS_WEB_API_KEY", "FIREBASE_WEB_API_KEY", "FIREBASE_WEB_APP_ID", "FIREBASE_WEB_PROJECT_ID", "FIREBASE_WEB_MESSAGING_SENDER_ID", "FIREBASE_WEB_AUTH_DOMAIN", "FIREBASE_WEB_STORAGE_BUCKET", "FIREBASE_WEB_VAPID_KEY"}
DEFAULT_MAPS_KEY = "AIzaSyCEkjoOnXRf6c9Xzml2QPNvZoq2LuG06JI"

def public_environment(path):
    values = {}
    for line in path.read_text(encoding="utf-8-sig").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if key not in PUBLIC_KEYS:
            raise ValueError(f"{key} is not approved for public browser assets. Remove secrets from .env before building.")
        values[key] = value.strip().strip("\"'")
    for key in ("URL", "SITE_URL"):
        if not values.get(key, "").startswith("https://"):
            raise ValueError(f"{key} must be the configured HTTPS ERP URL.")
    return values

def prepare_release(output, values):
    firebase_names = {"apiKey": "FIREBASE_WEB_API_KEY", "appId": "FIREBASE_WEB_APP_ID", "projectId": "FIREBASE_WEB_PROJECT_ID", "messagingSenderId": "FIREBASE_WEB_MESSAGING_SENDER_ID", "authDomain": "FIREBASE_WEB_AUTH_DOMAIN", "storageBucket": "FIREBASE_WEB_STORAGE_BUCKET"}
    firebase = {key: values[name] for key, name in firebase_names.items() if values.get(name)}
    required = {"apiKey", "appId", "projectId", "messagingSenderId"}
    if firebase and not required.issubset(firebase):
        raise ValueError("Supply a complete Firebase WEB app configuration, or omit it. Android app IDs cannot be reused.")
    config = {"mapsApiKey": values.get("GOOGLE_MAPS_WEB_API_KEY") or DEFAULT_MAPS_KEY, "firebase": firebase or None}
    (output / "pwa-config.js").write_text("self.GENIE_WEB_CONFIG = " + json.dumps(config) + ";\n", encoding="utf-8")
    # Flutter bundles .env. Deliver only explicitly public, validated values.
    (output / "assets" / ".env").write_text("".join(f"{key}={value}\n" for key, value in values.items()), encoding="utf-8")
    assets = []
    digest = hashlib.sha256()
    for path in sorted(output.rglob("*")):
        if not path.is_file():
            continue
        name = path.relative_to(output).as_posix()
        # Never preload native-only face models, source maps, or push workers.
        if name.endswith(".map") or name.startswith(("assets/assets/face_recognition/", "push/")) or name in {"pwa-assets.js", "pwa-sw.js", "flutter_service_worker.js"}:
            continue
        assets.append(name)
        digest.update(name.encode())
        digest.update(path.read_bytes())
    version = digest.hexdigest()[:20]
    (output / "pwa-assets.js").write_text("self.GENIE_BUILD = " + json.dumps(version) + ";\nself.GENIE_ASSETS = " + json.dumps(assets) + ";\n", encoding="utf-8")
    return version, len(assets)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-href", default="/genie/", help="Host this path on the ERP HTTPS origin. Must start and end with /.")
    args = parser.parse_args()
    if not re.fullmatch(r"/(?:[A-Za-z0-9_-]+/)*", args.base_href):
        parser.error("Use an absolute directory path such as /genie/ or /.")
    values = public_environment(ROOT / ".env")
    flutter = shutil.which("flutter")
    if not flutter:
        raise SystemExit("Flutter is not on PATH.")
    subprocess.run([flutter, "build", "web", "--release", "--no-wasm-dry-run", "--no-web-resources-cdn", "--base-href", args.base_href], cwd=ROOT, check=True)
    output = ROOT / "build" / "web"
    version, count = prepare_release(output, values)
    dist = ROOT / "dist"
    dist.mkdir(exist_ok=True)
    archive = dist / "automate-genie-pwa.zip"
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as bundle:
        for path in sorted(output.rglob("*")):
            if path.is_file() and not path.name.endswith(".map"):
                bundle.write(path, path.relative_to(output))
    print(f"PWA release {version}: {count} public shell assets")
    print(f"Build: {output}")
    print(f"Package: {archive}")
    print(f"Deploy to your ERP HTTPS origin at {args.base_href}. Backend web-platform support is required before login.")
    if not values.get("FIREBASE_WEB_APP_ID"):
        print("Web push awaits Firebase WEB app configuration and a public VAPID key. Other app functions can start without it.")

if __name__ == "__main__":
    main()
