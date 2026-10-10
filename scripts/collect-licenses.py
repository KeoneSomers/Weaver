"""Collect pinned dependency notices into the installed application's bundle."""
from pathlib import Path
import shutil

root = Path(__file__).resolve().parents[1]
destination = root / "zig-out" / "licenses" / "dependencies"
count = 0
for source_root in (root / "zig-pkg", root / "vendor" / "libgit2" / "deps", root / "vendor" / "nfd" / "3ps" / "wayland-protocols"):
    if not source_root.exists():
        continue
    for source in sorted(source_root.rglob("*")):
        if not source.is_file():
            continue
        upper = source.name.upper()
        if not (upper.startswith(("LICENSE", "COPYING", "NOTICE")) or upper == "COPYRIGHT"):
            continue
        if source.suffix.lower() in (".c", ".h", ".zig", ".rs", ".py"):
            continue
        target = destination / source_root.name / source.relative_to(source_root)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        count += 1
if not count:
    raise SystemExit("No dependency licenses found; build Weaver before packaging.")
print(f"Collected {count} pinned dependency notices.")
