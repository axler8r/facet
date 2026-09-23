# Filemeta

Filemeta catalogues Linux regular files and typed metadata in
`.facet/catalogue.db` under a selected root.

## Build and Test

Use the Make targets, which invoke the project's Nix development shell:

```sh
make build
make test
make release
make test-existing
```

`test-existing` compiles and runs the regression suite without rebuilding the
application, so it can validate the release executable. Tests use disposable
roots, never the workspace catalogue. Permission-denied traversal coverage
requires a non-root test process. Individual tests can be selected with
`TEST_ARGS='"facet CLI::exact test name"'`.

## Commands and Paths

```sh
./dist/facet init /path/to/root
./dist/facet scan /path/to/root
./dist/facet scan --no-ignore /path/to/root
./dist/facet scan --ignore-file /path/to/extra.ignore --verbose-ignore /path/to/root
./dist/facet taxonomy add note string /path/to/root
./dist/facet set a.file note 'hello world' /path/to/root
./dist/facet get a.file --json /path/to/root
./dist/facet history a.file /path/to/root
./dist/facet find 'note == "hello world"' /path/to/root
./dist/facet ignore a.file /path/to/root
```

With an explicit root, relative file paths are relative to that root. Without
one, paths are relative to the working directory and the catalogue root is
detected by searching upward. Absolute paths and lexical `./` forms work even
after a tracked file is removed. Literal backslashes remain Linux filename
characters. Paths outside the root and symlink paths are rejected.

Only `init` and `scan` create catalogues. Other commands require an existing
catalogue. `get`, `history`, and `unset` never register files; `set` can
register an in-root regular file before scanning. Value changes, registration,
and audit insertion share a transaction. Assigning the same canonical value adds
no audit event. New audit rows use SQL NULL for absent endpoints, distinct from
empty strings. The text history display retains its existing empty endpoint
format.

## Identity and Scanning

- A device/inode pair identifies one record. Renames preserve its ID,
  attributes, and history. Replacing a path with a different identity does not
  inherit its metadata; the old record remains MISSING unless found elsewhere in
  the scan.
- Hard links share one record. Scans retain its canonical path while that link
  exists; otherwise they choose the lexicographically first in-root path.
  Existing noncanonical hard links can resolve metadata through their identity.
- Path lookups prefer PRESENT records, then the MISSING record with greatest
  `last_seen`, breaking ties by greatest ID. Older records are retained in
  SQLite by ID; path-based CLI commands do not expose every historical identity.
- Scan counters count identities, not hard-link directory entries. `Missing`
  counts new transitions only, and every observed identity refreshes
  `last_seen`.
- Scans exclude the root's entire `.facet` and `.git` trees and do not follow
  symlinks. Stable non-regular entries (FIFOs, sockets, etc.) present at
  discovery time are silently skipped, not tracked. If an accepted entry changes
  away from a regular file before reconciliation completes (e.g. it is replaced
  by a FIFO or symlink), the scan aborts rather than silently omitting or
  misclassifying it: this is not a filesystem-wide atomic snapshot.
  Traversal/stat failures likewise abort rather than infer removals.
  Reconciliation is transactional, including swaps and reused paths.

### Ignoring paths

- Every traversed directory's `.gitignore` and `.facetignore` are read and
  applied to its subtree, using full gitignore pattern syntax (wildcards, `**`,
  `!` negation, trailing `/` for directory-only, leading `/` anchoring). Later
  rules within a directory, and deeper directories, take precedence.
- `--no-ignore` disables this automatic `.gitignore`/`.facetignore` discovery;
  explicit `--ignore-file PATH` rules are still applied.
- `--ignore-file PATH` adds rules from PATH, applied repo-wide with the highest
  precedence (after discovered files). Repeat the flag to layer multiple files
  in order; PATH must exist or the scan fails.
- `--verbose-ignore` prints one `Ignored: PATH (matched PATTERN from SOURCE)`
  line per skipped path.
- `facet ignore PATH` untracks a currently tracked `PATH`: it appends a
  root-anchored, escaped literal-match rule for it to `.facetignore` (creating
  the file if needed), then deletes the file's catalogue row, attribute
  values, and history. Future scans exclude the path via that rule instead of
  re-adding it.

Pattern matching supports `*`, `?`, `[...]` bracket expressions (including POSIX
classes such as `[[:digit:]]`), `**` (including a trailing `foo/**`, which
matches only descendants of `foo`, not `foo` itself), anchoring, directory-only
patterns, and backslash-escaped `#`, `!`, and spaces, matching `git`'s behavior
for these constructs. Matching is byte-oriented under a `C` locale; it does not
implement Unicode-aware collation, global Git excludes, or Git's tracked-file
semantics.

Device/inode identity cannot distinguish inode recycling from reappearance.
Scanning is a filesystem snapshot, not a filesystem-wide lock; concurrent file
changes may require another scan. Reads reflect the catalogue until scanning or
explicit registration updates it.

## Schema and Compatibility

Version-1 catalogues migrate automatically to version 2 when opened, including
by a read command. The transaction preserves file IDs, metadata, history,
hashes, and foreign-key relationships, and validates foreign keys before
committing. Only PRESENT paths are unique; device/inode uniqueness remains.
Migration failures roll back; unsupported future versions are rejected. Back up
important catalogues before upgrading and do not use older executables after
migration.

Absent numeric bounds are stored as SQL NULL. Existing zero/zero definitions are
ambiguous and are **not** rewritten: inspect them explicitly and, where
intended, correct `min_value`/`max_value` in a backed-up catalogue to NULL.
Removing a taxonomy definition is not a repair method: it cascades to its
values/history. Historical empty audit endpoints are similarly left unchanged.

Catalogues at schema version 3 store `integer` attribute bounds as exact
`min_integer`/`max_integer` columns rather than `REAL`. Migrating from version 1
or 2 adds these columns without rewriting existing `min_value`/`max_value`
bounds on `integer` attributes created before the upgrade: those are compared
exactly against stored integers without ever rounding the integer to float.
`real` values and bounds must be finite; `nan`/`inf`/`-inf` are rejected and
never stored. `taxonomy add` for `enum` attributes rejects duplicate values and
never partially creates a definition: definition and enum-value rows are
inserted in a single transaction.

JSON preserves the existing field names and types: numeric `size` and
`modified`, string `path` and `state`, and string-valued `attributes`, now
correctly escaped.

Queries support `==`, `!=`, `<`, `<=`, `>`, `>=`, with AND precedence over OR
(case-insensitive connectives). Operators need not have surrounding spaces. Use
JSON-style double-quoted literals for whitespace, empty strings, or reserved
words; standard JSON escapes are supported. Attribute identifiers start with a
letter or underscore, followed by letters, digits, underscores, dots, or
hyphens. Equality retains string comparison semantics; ordering compares two
integer operands exactly via `int64`, an integer against a decimal/exponent
operand via exact-integer-to-float comparison (never rounding the integer), and
two non-integer operands via `float64`. Non-finite or unparsable ordering
operands never match. Missing attributes do not satisfy comparisons, including
`!=`. Malformed expressions are rejected; parentheses and other query features
are not supported.
