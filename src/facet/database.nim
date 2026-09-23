import std/[os, options, strutils, times]
import nim_sqlite

export nim_sqlite

const
  CatalogSchemaVersion* = 3
  MissingState* = "MISSING"
  PresentState* = "PRESENT"

type
  FileIdentity* = tuple[device, inode: uint64]

  FileState* = enum
    fsPresent, fsMissing

  FileRecord* = object
    id*: int
    path*: string
    device*: uint64
    inode*: uint64
    size*: int64
    mtimeNs*: int64
    firstSeen*: int64
    lastSeen*: int64
    state*: FileState

  Summary* = object
    scanned*: int
    added*: int
    updated*: int
    moved*: int
    missing*: int
    unchanged*: int

func identity*(record: FileRecord): FileIdentity =
  (device: record.device, inode: record.inode)

func stateText*(state: FileState): string =
  ## Storage vocabulary for `files.state`; explicit mapping so a future enum
  ## reordering cannot silently change persisted strings.
  case state
  of fsPresent: PresentState
  of fsMissing: MissingState

func parseFileState*(text: string): FileState =
  case text
  of PresentState: fsPresent
  of MissingState: fsMissing
  else: raise newException(ValueError, "unsupported file state: " & text)

func cataloguePath*(root: string): string =
  root / ".facet" / "catalogue.db"

proc detectRoot*(startDir = getCurrentDir(), explicitRoot = ""): string =
  if explicitRoot.len > 0:
    return absolutePath(explicitRoot)
  var current = absolutePath(startDir)
  while true:
    if fileExists(current / ".facet" / "catalogue.db"):
      return current
    let parent = parentDir(current)
    if parent == current:
      break
    current = parent
  result = absolutePath(startDir)

proc normalizeRelativePath*(root: string, filePath: string): string =
  let absRoot = normalizedPath(absolutePath(root))
  let absFile = normalizedPath(absolutePath(filePath, absRoot))
  result = relativePath(absFile, absRoot)
  if result == ".." or result.startsWith("../") or result.isAbsolute:
    raise newException(ValueError, "path is outside catalogue root: " & filePath)
  if result in ["", "."]:
    raise newException(ValueError, "expected a file path")
  var current = absRoot
  for component in result.split('/'):
    current = current / component
    if symlinkExists(current):
      raise newException(ValueError, "symlinks are not tracked: " & filePath)

proc utcNowNs*(): int64 =
  let now = getTime()
  result = now.toUnix * 1_000_000_000'i64 + now.nanosecond

proc migrateVersionOne(db: DbConn) =
  db.exec("PRAGMA foreign_keys = OFF")
  try:
    db.transaction:
      if db.value("PRAGMA user_version").get.fromDb(int) == 1:
        let objects = db.all("SELECT sql FROM sqlite_master WHERE tbl_name = 'files' AND type IN ('index', 'trigger') AND sql IS NOT NULL")
        db.execScript("""
          CREATE TABLE files_migrating (
            id INTEGER PRIMARY KEY, path TEXT NOT NULL,
            device INTEGER NOT NULL, inode INTEGER NOT NULL, size INTEGER NOT NULL,
            mtime_ns INTEGER NOT NULL, first_seen INTEGER NOT NULL, last_seen INTEGER NOT NULL,
            state TEXT NOT NULL DEFAULT 'PRESENT', hash_algorithm TEXT, hash_value TEXT,
            hash_time INTEGER, UNIQUE(device, inode));
          INSERT INTO files_migrating
            SELECT id, path, device, inode, size, mtime_ns, first_seen, last_seen,
                   state, hash_algorithm, hash_value, hash_time FROM files;
          DROP TABLE files;
          ALTER TABLE files_migrating RENAME TO files;
        """)
        for schemaObject in objects:
          db.execScript(schemaObject[0].fromDb(string))
        db.exec("CREATE UNIQUE INDEX idx_files_present_path ON files(path) WHERE state = 'PRESENT'")
        if db.all("PRAGMA foreign_key_check").len > 0:
          raise newException(ValueError, "catalogue migration failed foreign-key validation")
        db.exec("PRAGMA user_version = 2")
  finally:
    db.exec("PRAGMA foreign_keys = ON")

proc migrateVersionTwo(db: DbConn) =
  db.transaction:
    if db.value("PRAGMA user_version").get.fromDb(int) == 2:
      db.exec("ALTER TABLE attribute_definitions ADD COLUMN min_integer INTEGER")
      db.exec("ALTER TABLE attribute_definitions ADD COLUMN max_integer INTEGER")
      if db.all("PRAGMA foreign_key_check").len > 0:
        raise newException(ValueError, "catalogue migration failed foreign-key validation")
      db.exec("PRAGMA user_version = 3")

proc initDatabase*(root: string): DbConn =
  let dbPath = cataloguePath(root)
  createDir(root / ".facet")
  result = openDatabase(dbPath)
  var ready = false
  defer:
    if not ready: result.close()
  let version = result.value("PRAGMA user_version").get.fromDb(int)
  if version notin [0, 1, 2, CatalogSchemaVersion]:
    raise newException(ValueError, "unsupported catalogue schema version: " & $version)
  result.exec("PRAGMA journal_mode = WAL")
  result.exec("PRAGMA foreign_keys = ON")
  result.exec("PRAGMA synchronous = NORMAL")
  result.exec("PRAGMA busy_timeout = 5000")

  if version == 1:
    migrateVersionOne(result)
    migrateVersionTwo(result)
  elif version == 2:
    migrateVersionTwo(result)
  elif version == 0:
    if result.value("SELECT COUNT(*) FROM sqlite_master").get.fromDb(int) != 0:
      raise newException(ValueError, "unversioned nonempty catalogue is not supported")
    result.execScript("""
      CREATE TABLE files (
        id INTEGER PRIMARY KEY,
        path TEXT NOT NULL,
        device INTEGER NOT NULL,
        inode INTEGER NOT NULL,
        size INTEGER NOT NULL,
        mtime_ns INTEGER NOT NULL,
        first_seen INTEGER NOT NULL,
        last_seen INTEGER NOT NULL,
        state TEXT NOT NULL DEFAULT 'PRESENT',
        hash_algorithm TEXT,
        hash_value TEXT,
        hash_time INTEGER,
        UNIQUE(device, inode)
      );

      CREATE INDEX idx_files_device_inode ON files(device, inode);
      CREATE INDEX idx_files_path ON files(path);
      CREATE UNIQUE INDEX idx_files_present_path ON files(path) WHERE state = 'PRESENT';
      CREATE INDEX idx_files_state ON files(state);

      CREATE TABLE attribute_definitions (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL UNIQUE,
        type TEXT NOT NULL,
        required INTEGER NOT NULL DEFAULT 0,
        description TEXT,
        min_value REAL,
        max_value REAL,
        min_integer INTEGER,
        max_integer INTEGER
      );

      CREATE TABLE enum_values (
        id INTEGER PRIMARY KEY,
        attribute_id INTEGER NOT NULL REFERENCES attribute_definitions(id) ON DELETE CASCADE,
        value TEXT NOT NULL,
        UNIQUE(attribute_id, value)
      );

      CREATE TABLE attribute_values (
        file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
        attribute_id INTEGER NOT NULL REFERENCES attribute_definitions(id) ON DELETE CASCADE,
        value_text TEXT,
        value_integer INTEGER,
        value_real REAL,
        value_boolean INTEGER,
        PRIMARY KEY(file_id, attribute_id)
      );

      CREATE TABLE attribute_history (
        id INTEGER PRIMARY KEY,
        file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
        attribute_id INTEGER NOT NULL REFERENCES attribute_definitions(id) ON DELETE CASCADE,
        old_value TEXT,
        new_value TEXT,
        changed_at INTEGER NOT NULL
      );

      CREATE INDEX idx_attribute_values_file ON attribute_values(file_id);
      CREATE INDEX idx_attribute_values_attr ON attribute_values(attribute_id);
      CREATE INDEX idx_history_file ON attribute_history(file_id);
      PRAGMA user_version = 3;
    """)
  ready = true

proc openCatalogue*(root: string): DbConn =
  if not fileExists(cataloguePath(root)):
    raise newException(ValueError, "catalogue not found; run init or scan: " & root)
  result = initDatabase(root)

const fileColumns = "id, path, device, inode, size, mtime_ns, first_seen, last_seen, state"

func decodeFileRecord(row: ResultRow): FileRecord =
  ## Shared decoder for the `fileColumns` SELECT layout, used by every
  ## file-row reader so identity/state conversion happens in exactly one
  ## place.
  FileRecord(
    id: row[0].fromDb(int),
    path: row[1].fromDb(string),
    device: cast[uint64](row[2].fromDb(int64)),
    inode: cast[uint64](row[3].fromDb(int64)),
    size: row[4].fromDb(int64),
    mtimeNs: row[5].fromDb(int64),
    firstSeen: row[6].fromDb(int64),
    lastSeen: row[7].fromDb(int64),
    state: parseFileState(row[8].fromDb(string)))

proc listFiles*(db: DbConn): seq[FileRecord] =
  let rows = db.all("SELECT " & fileColumns & " FROM files ORDER BY path")
  for row in rows:
    result.add decodeFileRecord(row)

proc fileCount*(db: DbConn): int =
  result = db.value("SELECT COUNT(*) FROM files").get.fromDb(int)

proc queryFileByPath*(db: DbConn, path: string): Option[FileRecord] =
  let rows = db.all("SELECT " & fileColumns &
      " FROM files WHERE path = ? ORDER BY (state = 'PRESENT') DESC, last_seen DESC, id DESC LIMIT 1", path)
  if rows.len == 0:
    return none(FileRecord)
  result = some(decodeFileRecord(rows[0]))

proc queryFileBySignature*(db: DbConn, device: uint64, inode: uint64): Option[FileRecord] =
  let rows = db.all("SELECT " & fileColumns &
      " FROM files WHERE device = ? AND inode = ?", int64(device), int64(inode))
  if rows.len == 0:
    return none(FileRecord)
  result = some(decodeFileRecord(rows[0]))

proc insertFileRecord*(db: DbConn, path: string, device: uint64, inode: uint64,
    size: int64, mtimeNs: int64, firstSeen: int64, lastSeen: int64): int =
  db.exec("INSERT INTO files(path, device, inode, size, mtime_ns, first_seen, last_seen, state) VALUES(?, ?, ?, ?, ?, ?, ?, 'PRESENT')",
      path, int64(device), int64(inode), size, mtimeNs, firstSeen, lastSeen)
  result = db.value("SELECT last_insert_rowid()").get.fromDb(int)

proc updateFileRecord*(db: DbConn, id: int, path: string, size: int64,
    mtimeNs: int64, lastSeen: int64, state: FileState = fsPresent) =
  db.exec("UPDATE files SET path = ?, size = ?, mtime_ns = ?, last_seen = ?, state = ? WHERE id = ?",
      path, size, mtimeNs, lastSeen, stateText(state), id)

proc markMissing*(db: DbConn, id: int) =
  db.exec("UPDATE files SET state = 'MISSING' WHERE id = ?", id)

proc markPresent*(db: DbConn, id: int, lastSeen: int64) =
  db.exec("UPDATE files SET state = 'PRESENT', last_seen = ? WHERE id = ?",
      lastSeen, id)

proc fileStateCounts*(db: DbConn): tuple[present: int, missing: int] =
  result.present = db.value("SELECT COUNT(*) FROM files WHERE state = 'PRESENT'").get.fromDb(int)
  result.missing = db.value("SELECT COUNT(*) FROM files WHERE state = 'MISSING'").get.fromDb(int)
