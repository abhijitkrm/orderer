# VENDORED — upstream matcher spec

orderer extends the [matcher](https://github.com/abhijitkrm/matcher) contract.
Its semantics spec and golden corpus are vendored **verbatim** — never edit
them here. Semantics changes go to matcher first, then get re-vendored by
bumping the pin below.

- **upstream**: `matcher`
- **repo**: `https://github.com/abhijitkrm/matcher`
- **commit**: `79d1964c1b3d8723de1b91f48ddda8c6b8350660`
- **paths**: `spec/matcher=spec vectors/matcher=vectors`

| Local | Upstream | Contents |
|---|---|---|
| `spec/matcher/` | `spec/` | SPEC.md (semantics), SCHEMA.md (vector format), BENCH.md (core bench protocol), JOURNAL.md (journal + `matcher-snap/1`) |
| `vectors/matcher/` | `vectors/` | 41 golden vectors (core, tif, edge, engine) + their manifest |

`docs/VENDORED.sha256` holds the checksum of every vendored file.
`scripts/vendored.sh` verifies the local copy against it and, when
`../matcher` is checked out, against the pinned commit itself.

## Re-vendoring

```bash
git -C ../matcher checkout <new-sha>
rm -rf spec/matcher vectors/matcher
cp ../matcher/spec/*.md spec/matcher/ && cp -R ../matcher/vectors/. vectors/matcher/
# bump the commit above, then:
scripts/vendored.sh --update && scripts/vendored.sh
```

Then re-run every implementation's golden suite (`scripts/verify.sh`) and
re-vendor orderer's `spec/` + `vectors/` into each `orderer-*` repo.
