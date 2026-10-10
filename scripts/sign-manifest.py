"""Sign exact UTF-8 manifest bytes. Keep the Ed25519 seed in CI secrets."""
import argparse, hashlib, json, os
from pathlib import Path
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

p = argparse.ArgumentParser()
p.add_argument('--repo', required=True)
p.add_argument('--version', required=True)
p.add_argument('--directory', default='dist')
args = p.parse_args()
root = Path(args.directory)
assets = []
for platform, pattern in [('windows-x86_64', '*.exe'), ('macos-aarch64', '*macos-aarch64*.dmg'), ('macos-x86_64', '*macos-x86_64*.dmg'), ('linux-x86_64', '*.AppImage')]:
    matches = [x for x in root.glob(pattern) if x.name != 'weaver-setup.exe']
    if len(matches) != 1:
        raise SystemExit(f'Expected one installer for {platform}, got {matches}')
    asset = matches[0]
    assets.append(dict(platform=platform, filename=asset.name, sha256=hashlib.sha256(asset.read_bytes()).hexdigest(),
                       url=f'https://github.com/{args.repo}/releases/download/v{args.version}/{asset.name}'))
payload = json.dumps(dict(version=args.version, notes=f'Weaver {args.version}', assets=assets), separators=(',', ':'), ensure_ascii=False)
seed = bytes.fromhex(os.environ['WEAVER_UPDATE_PRIVATE_KEY'])
key = Ed25519PrivateKey.from_private_bytes(seed)
public = key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw).hex()
if public != os.environ['WEAVER_UPDATE_PUBLIC_KEY'].lower():
    raise SystemExit('Update private key does not match the public key compiled into Weaver.')
signature = key.sign(payload.encode()).hex()
(root / 'weaver-update.json').write_text(json.dumps(dict(payload=payload, signature=signature), separators=(',', ':')), encoding='utf-8')
