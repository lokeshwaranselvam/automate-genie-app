"""Fetch pinned public browser runtimes. No employee data or ERP calls."""
import hashlib
import io
import json
from pathlib import Path
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]

def prepare():
    destination = ROOT / 'web' / 'face' / 'vendor'
    for entry in json.loads((ROOT / 'tool' / 'face_assets.json').read_text()):
        targets = entry.get('files', [entry.get('path')])
        base = destination / entry.get('directory', '')
        if all((base / name).is_file() and hashlib.sha256((base / name).read_bytes()).hexdigest() == entry['checksums'][name] for name in targets):
            continue
        print('Preparing browser face asset:', entry['url'])
        with urllib.request.urlopen(entry['url'], timeout=120) as response:
            data = response.read()
        if hashlib.sha256(data).hexdigest() != entry['sha256']:
            raise ValueError('Browser face asset checksum mismatch')
        base.mkdir(parents=True, exist_ok=True)
        if 'files' in entry:
            with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
                for name in entry['files']:
                    target = base / name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_bytes(archive.extractfile('package/' + name).read())
        else:
            target = base / entry['path']
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)


if __name__ == '__main__':
    prepare()
