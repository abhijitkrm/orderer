#!/usr/bin/env bash
# manifest.sh — vectors/manifest.json completeness check.
#
# Every entry's files must exist; every file under vectors/ (outside the
# vendored vectors/matcher/, which has its own manifest) must be listed —
# no orphans. Included manifests are checked the matcher way (.cmd + .evt).
set -euo pipefail
cd "$(dirname "$0")/../vectors"
python3 - <<'EOF'
import json, os, sys

mf = json.load(open('manifest.json'))
assert mf.get('format') == 'orderer-vectors-manifest/1', 'bad manifest format'
missing, listed = [], set()

for inc in mf.get('includes', []):
    sub = json.load(open(inc))
    base = os.path.dirname(inc)
    for v in sub['vectors']:
        for ext in ('.cmd.jsonl', '.evt.jsonl'):
            p = os.path.join(base, v['file'] + ext)
            if not os.path.isfile(p):
                missing.append(p)
    print(f"{inc}: {len(sub['vectors'])} vectors")

for v in mf['vectors']:
    for f in v['files']:
        listed.add(f)
        if not os.path.isfile(f):
            missing.append(f)

skip = {os.path.dirname(i) for i in mf.get('includes', [])}
orphans = []
for d, _, files in os.walk('.'):
    rel = os.path.relpath(d)
    if any(rel == s or rel.startswith(s + os.sep) for s in skip):
        continue
    for f in files:
        p = os.path.normpath(os.path.join(rel, f))
        if p != 'manifest.json' and not f.startswith('.') and p not in listed:
            orphans.append(p)

if missing:
    print('missing:\n  ' + '\n  '.join(missing)); sys.exit(1)
if orphans:
    print('not in manifest:\n  ' + '\n  '.join(sorted(orphans))); sys.exit(1)
print(f"manifest.json: {len(mf['vectors'])} orderer vectors, {len(listed)} files, complete")
EOF
