# Facet Design

This document describes the internal architecture of Facet: module
responsibilities, the catalogue schema, and the control flow of its main
operations.

## Goals and Non-Goals

Facet catalogues Linux regular files under a root directory and lets users
attach typed, schema-validated metadata ("attributes") to them, tracking
attribute changes over time. It identifies files by `(device, inode)` so that
renames and moves don't lose associated metadata.

Non-goals: cross-filesystem identity, non-regular files (directories, symlinks,
devices), and distributed/multi-writer catalogues.

## Module Overview

```mermaid
flowchart LR
    facet["facet.nim<br/>(CLI entry point)"]
    database["facet/database.nim<br/>(schema, connection,<br/>file records)"]
    scanner["facet/scanner.nim<br/>(filesystem walk,<br/>reconciliation)"]
    ignore["facet/ignore.nim<br/>(gitignore-style<br/>pattern matching)"]
    taxonomy["facet/taxonomy.nim<br/>(attribute definitions,<br/>validation)"]
    metadata["facet/metadata.nim<br/>(attribute get/set/unset,<br/>history, file details)"]
    query["facet/query.nim<br/>(find expression<br/>parsing and evaluation)"]
    errors["facet/errors.nim<br/>(exception types)"]

    facet --> database
    facet --> scanner
    facet --> taxonomy
    facet --> metadata
    facet --> query
    scanner --> database
    scanner --> ignore
    metadata --> database
    metadata --> taxonomy
    query --> database
```

- **`facet.nim`**: parses `commandLineParams()`, dispatches to one handler per
  subcommand, and formats output (including colorized `--help` text). All
  `CatchableError`s raised deeper in the stack are caught here, printed as
  `Error: <msg>`, and turned into exit code 1.
- **`database.nim`**: owns the SQLite connection lifecycle, schema
  creation/migration, and low-level CRUD for the `files` table. Also owns root
  detection (`detectRoot`) and path normalization/containment checks
  (`normalizeRelativePath`).
- **`scanner.nim`**: walks the filesystem under a root, applying ignore rules,
  and reconciles the walk results against the catalogue inside a single
  transaction.
- **`ignore.nim`**: standalone gitignore-style pattern parser and matcher used
  by the scanner. No database dependency.
- **`taxonomy.nim`**: CRUD for attribute _definitions_ (name, type, min/max,
  enum values) and value validation/normalization per type.
- **`metadata.nim`**: attribute _values_ on files — resolving/registering a
  file's identity, setting/unsetting values (with history), and rendering file
  details (text or JSON).
- **`query.nim`**: tokenizes and evaluates `facet find` expressions against
  attribute values.
- **`errors.nim`**: a small exception hierarchy (`FilemetaError` and
  `ValidationError`/`NotFoundError`/`UsageError` subtypes) for future structured
  error handling; current command handlers mostly raise plain `ValueError`.

## Data Model

The catalogue is a single SQLite database at `<root>/.facet/catalogue.db`, using
WAL journaling and `PRAGMA foreign_keys = ON`.

```mermaid
erDiagram
    FILES ||--o{ ATTRIBUTE_VALUES : has
    FILES ||--o{ ATTRIBUTE_HISTORY : has
    ATTRIBUTE_DEFINITIONS ||--o{ ATTRIBUTE_VALUES : constrains
    ATTRIBUTE_DEFINITIONS ||--o{ ATTRIBUTE_HISTORY : constrains
    ATTRIBUTE_DEFINITIONS ||--o{ ENUM_VALUES : allows

    FILES {
        int id PK
        text path
        int device
        int inode
        int size
        int mtime_ns
        int first_seen
        int last_seen
        text state "PRESENT | MISSING"
    }
    ATTRIBUTE_DEFINITIONS {
        int id PK
        text name UK
        text type "string|integer|real|boolean|enum"
        int required
        text description
        real min_value
        real max_value
    }
    ENUM_VALUES {
        int id PK
        int attribute_id FK
        text value
    }
    ATTRIBUTE_VALUES {
        int file_id PK_FK
        int attribute_id PK_FK
        text value_text
        int value_integer
        real value_real
        int value_boolean
    }
    ATTRIBUTE_HISTORY {
        int id PK
        int file_id FK
        int attribute_id FK
        text old_value
        text new_value
        int changed_at
    }
```

Notes:

- `files` has a `UNIQUE(device, inode)` constraint — one row per physical file —
  and a partial unique index `idx_files_present_path` enforcing at most one
  `PRESENT` row per path at a time. `MISSING` rows for the same path can coexist
  historically.
- `attribute_values` stores one typed column per possible value kind; exactly
  one is populated per row, selected by the corresponding
  `attribute_definitions.type`.
- `attribute_history` retains every change, including unset (`new_value` `NULL`)
  and initial-set (`old_value` `NULL`) events, distinguishing SQL `NULL` from an
  empty string.
- Schema version is tracked via `PRAGMA user_version`. Version 1 predates
  hash-related columns being dropped; `initDatabase` migrates version 1 to
  version 2 by rebuilding the `files` table without `hash_algorithm`,
  `hash_value`, and `hash_time`, preserving indexes/triggers and validating
  foreign keys post-migration.

## File Identity Resolution

`resolveFileId` (in `metadata.nim`) is the shared path used by `get`, `set`,
`unset`, and `history` to map a `PATH` argument to a `files.id`:

```mermaid
flowchart TD
    A[normalizeRelativePath: reject paths<br/>outside root or through symlinks] --> B{Row exists for<br/>this path?}
    B -- yes, and not registering --> C[Return existing row id]
    B -- no or registering --> D[lstat the file]
    D -- ENOENT/ENOTDIR --> E{Row already<br/>found for path?}
    E -- yes --> C
    E -- no --> F[raise: file not found in catalogue]
    D -- success, not regular file --> G[raise: not a regular file]
    D -- success --> H{Row exists by<br/>device+inode?}
    H -- yes, not registering --> C
    H -- yes, registering --> I[Update canonical path/size/mtime;<br/>return existing id]
    H -- no, not registering --> F
    H -- no, registering --> J{Path row exists with<br/>different identity?}
    J -- yes --> K[Mark old row MISSING]
    J --> L[Insert new file row,<br/>state=PRESENT]
```

`register = false` (used by `get`/`history`/`unset`) never creates a row;
`register = true` (used by `set`) will insert or update as needed so a value can
be attached before the next `scan`.

## Scan Reconciliation

`scanRepository` walks the tree (`iterTrackedFiles`, applying ignore rules from
`ignore.nim`), then performs reconciliation in one transaction:

1. Snapshot every on-disk regular file's `(device, inode)`, path, size, and
   mtime.
2. Mark all currently `PRESENT` rows `MISSING` up front.
3. For each snapshot signature:
   - If known by `(device, inode)`: update path/size/mtime and mark `PRESENT`
     again; classify as moved, updated, or unchanged.
   - Otherwise: insert a new row (`added`).
4. Any row that was `PRESENT` before the scan and not matched this pass stays
   `MISSING` (`missing`).

See the sequence diagram in the
[User Guide](user-guide.md#scanning-and-ignore-rules) for the ignore-matching
flow applied while walking.

## Attribute Write Path

`setAttribute` and `unsetAttribute` (in `metadata.nim`) both run inside a single
`db.transaction`, ensuring the attribute value change and its history entry are
atomic:

```mermaid
sequenceDiagram
    participant CLI as facet.nim
    participant Meta as metadata.nim
    participant Tax as taxonomy.nim
    participant DB as SQLite

    CLI->>Meta: setAttribute(db, root, path, name, rawValue)
    Meta->>Tax: fetchAttributeDef(name)
    Tax-->>Meta: AttributeDef
    Meta->>Tax: validateAttributeValue(def, rawValue)
    Tax-->>Meta: validated value
    Meta->>Meta: resolveFileId(register=true)
    Meta->>DB: SELECT current value
    alt value unchanged
        Meta-->>CLI: no-op
    else value changed
        Meta->>DB: UPSERT attribute_values
        Meta->>DB: INSERT attribute_history
        Meta-->>CLI: "Updated: path attribute"
    end
```

## Query Evaluation

`facet find` tokenizes the expression (respecting double-quoted string literals
with JSON-style escapes), parses it into `(attr, op, value, logic)` clauses
left-to-right, then evaluates every catalogued file against the clause chain:
consecutive `AND` clauses form a group that must all match, and each `OR` starts
a new group; a file matches if any group fully matches. Numeric operators parse
both sides as floats; non-numeric operands fall back to string
equality/inequality only.

## Error Handling

Lower layers raise built-in exceptions (chiefly `ValueError`) or the
`errors.nim` hierarchy on invalid input, missing catalogues, or constraint
violations. `main()` in `facet.nim` is the single catch point: any
`CatchableError` is reported as `Error: <message>` on stderr with exit code 1,
keeping error formatting centralized and command handlers free of try/except
boilerplate.

## Testing Strategy

The regression suite (`tests/test_facet.nim`) drives the built `facet` binary
against disposable temporary roots — it never touches the workspace's own
`.facet` catalogue. This validates the CLI end-to-end (argument parsing,
catalogue creation, scanning, attribute mutation, queries) rather than
unit-testing modules in isolation.
