#!/usr/bin/env python3
"""Copy a verified source snapshot off File Provider roots before Go compilation."""
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(__file__).resolve().parent.parent / "Bridge"
destination = pathlib.Path(sys.argv[1])
destination.mkdir(parents=True, exist_ok=True)
records = {}
for path in sorted(root.rglob("*")):
    if not path.is_file() or any(p in {".cache", ".DS_Store"} for p in path.relative_to(root).parts):
        continue
    first = path.read_bytes()
    second = path.read_bytes()
    if first != second or (path.suffix == ".go" and b"package " not in first):
        raise SystemExit("Source changed or failed hydration: " + str(path))
    relative = path.relative_to(root)
    target = destination / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(first)
    records[relative.as_posix()] = hashlib.sha256(first).hexdigest()
(destination.parent / "bridge-snapshot.json").write_text(json.dumps(records, indent=2, sort_keys=True) + "\n")
print("Verified source snapshot: " + str(len(records)) + " files")
