import std/[algorithm, json, os, osproc, posix, strtabs, strutils, tables,
    tempfiles, unittest]
import nim_sqlite
import ../src/facet/database
import ../src/facet/taxonomy
import ../src/facet/ignore
import ../src/facet/scanner
import ../src/facet/metadata
import ../src/facet/query

let facetExe = getAppDir() / "facet"

proc runFilemeta(args: varargs[string]): tuple[output: string, exitCode: int] =
  var arguments = @[facetExe]
  for argument in args:
    arguments.add argument
  let (stdoutText, errCode) = execCmdEx(quoteShellCommand(arguments))
  result.output = stdoutText.strip()
  result.exitCode = errCode

proc runGit(isolatedHome: string, args: varargs[string]): tuple[
    output: string, exitCode: int] =
  ## Runs `git` with an isolated HOME/XDG_CONFIG_HOME and no system config, so
  ## the host's global/system gitignore configuration cannot affect the oracle.
  var arguments = @["git", "-c", "core.excludesFile=", "-c", "safe.directory=*"]
  for argument in args:
    arguments.add argument
  let cmd = quoteShellCommand(arguments)
  let env = newStringTable()
  env["HOME"] = isolatedHome
  env["XDG_CONFIG_HOME"] = isolatedHome / ".config"
  env["GIT_CONFIG_NOSYSTEM"] = "1"
  env["LC_ALL"] = "C"
  env["PATH"] = getEnv("PATH")
  let (stdoutText, errCode) = execCmdEx(cmd, env = env)
  result.output = stdoutText.strip()
  result.exitCode = errCode

proc summaryCount(output, field: string): int =
  for line in output.splitLines():
    if line.startsWith(field & ":"):
      return parseInt(line.split(':')[1].strip())
  raise newException(ValueError, "missing scan counter: " & field & " in " & output)

proc legacyCatalogue(root: string): DbConn =
  createDir(root / ".facet")
  result = openDatabase(root / ".facet" / "catalogue.db")
  result.execScript("""
    CREATE TABLE files (
      id INTEGER PRIMARY KEY, path TEXT NOT NULL UNIQUE,
      device INTEGER NOT NULL, inode INTEGER NOT NULL, size INTEGER NOT NULL,
      mtime_ns INTEGER NOT NULL, first_seen INTEGER NOT NULL, last_seen INTEGER NOT NULL,
      state TEXT NOT NULL DEFAULT 'PRESENT', hash_algorithm TEXT, hash_value TEXT,
      hash_time INTEGER, UNIQUE(device, inode));
    CREATE INDEX idx_files_path ON files(path);
    CREATE INDEX custom_size ON files(size);
    CREATE TABLE attribute_definitions (
      id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, type TEXT NOT NULL,
      required INTEGER NOT NULL DEFAULT 0, description TEXT, min_value REAL, max_value REAL);
    CREATE TABLE enum_values (
      id INTEGER PRIMARY KEY, attribute_id INTEGER NOT NULL REFERENCES attribute_definitions(id) ON DELETE CASCADE,
      value TEXT NOT NULL, UNIQUE(attribute_id, value));
    CREATE TABLE attribute_values (
      file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
      attribute_id INTEGER NOT NULL REFERENCES attribute_definitions(id) ON DELETE CASCADE,
      value_text TEXT, value_integer INTEGER, value_real REAL, value_boolean INTEGER,
      PRIMARY KEY(file_id, attribute_id));
    CREATE TABLE attribute_history (
      id INTEGER PRIMARY KEY, file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
      attribute_id INTEGER NOT NULL REFERENCES attribute_definitions(id) ON DELETE CASCADE,
      old_value TEXT, new_value TEXT, changed_at INTEGER NOT NULL);
    INSERT INTO files VALUES(7, 'a.file', 11, 12, 5, 13, 14, 15, 'PRESENT', 'sha256', 'kept', 16);
    INSERT INTO files VALUES(9, 'gone.file', 11, 20, 8, 21, 22, 23, 'MISSING', NULL, NULL, NULL);
    INSERT INTO attribute_definitions VALUES(4, 'rating', 'enum', 0, 'kept description', NULL, NULL);
    INSERT INTO attribute_definitions VALUES(5, 'count', 'integer', 0, '', 0.0, 0.0);
    INSERT INTO enum_values VALUES(6, 4, 'BLUE');
    INSERT INTO attribute_values VALUES(7, 4, 'BLUE', NULL, NULL, NULL);
    INSERT INTO attribute_values VALUES(9, 5, NULL, 0, NULL, NULL);
    INSERT INTO attribute_history VALUES(8, 7, 4, '', 'BLUE', 25);
    INSERT INTO attribute_history VALUES(10, 9, 5, NULL, '0', 26);
    PRAGMA user_version = 1;
  """)

proc v2Catalogue(root: string): DbConn =
  createDir(root / ".facet")
  result = openDatabase(root / ".facet" / "catalogue.db")
  result.execScript("""
    CREATE TABLE files (
      id INTEGER PRIMARY KEY, path TEXT NOT NULL,
      device INTEGER NOT NULL, inode INTEGER NOT NULL, size INTEGER NOT NULL,
      mtime_ns INTEGER NOT NULL, first_seen INTEGER NOT NULL, last_seen INTEGER NOT NULL,
      state TEXT NOT NULL DEFAULT 'PRESENT', hash_algorithm TEXT, hash_value TEXT,
      hash_time INTEGER, UNIQUE(device, inode));
    CREATE INDEX idx_files_device_inode ON files(device, inode);
    CREATE INDEX idx_files_path ON files(path);
    CREATE UNIQUE INDEX idx_files_present_path ON files(path) WHERE state = 'PRESENT';
    CREATE INDEX idx_files_state ON files(state);
    CREATE TABLE attribute_definitions (
      id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, type TEXT NOT NULL,
      required INTEGER NOT NULL DEFAULT 0, description TEXT, min_value REAL, max_value REAL);
    CREATE TABLE enum_values (
      id INTEGER PRIMARY KEY, attribute_id INTEGER NOT NULL REFERENCES attribute_definitions(id) ON DELETE CASCADE,
      value TEXT NOT NULL, UNIQUE(attribute_id, value));
    CREATE TABLE attribute_values (
      file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
      attribute_id INTEGER NOT NULL REFERENCES attribute_definitions(id) ON DELETE CASCADE,
      value_text TEXT, value_integer INTEGER, value_real REAL, value_boolean INTEGER,
      PRIMARY KEY(file_id, attribute_id));
    CREATE TABLE attribute_history (
      id INTEGER PRIMARY KEY, file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
      attribute_id INTEGER NOT NULL REFERENCES attribute_definitions(id) ON DELETE CASCADE,
      old_value TEXT, new_value TEXT, changed_at INTEGER NOT NULL);
    CREATE INDEX idx_attribute_values_file ON attribute_values(file_id);
    CREATE INDEX idx_attribute_values_attr ON attribute_values(attribute_id);
    CREATE INDEX idx_history_file ON attribute_history(file_id);
    INSERT INTO files VALUES(7, 'a.file', 11, 12, 5, 13, 14, 15, 'PRESENT', NULL, NULL, NULL);
    INSERT INTO files VALUES(9, 'gone.file', 11, 20, 8, 21, 22, 23, 'MISSING', NULL, NULL, NULL);
    INSERT INTO attribute_definitions VALUES(4, 'rating', 'enum', 0, 'kept description', NULL, NULL);
    INSERT INTO attribute_definitions VALUES(5, 'count', 'integer', 0, '', 0.0, 0.0);
    INSERT INTO enum_values VALUES(6, 4, 'BLUE');
    INSERT INTO attribute_values VALUES(7, 4, 'BLUE', NULL, NULL, NULL);
    INSERT INTO attribute_values VALUES(9, 5, NULL, 0, NULL, NULL);
    INSERT INTO attribute_history VALUES(8, 7, 4, '', 'BLUE', 25);
    INSERT INTO attribute_history VALUES(10, 9, 5, NULL, '0', 26);
    PRAGMA user_version = 2;
  """)

suite "facet CLI":
  test "renames, swaps, disappearance and reappearance preserve identity":
    let base = createTempDir("facet-moves-", "")
    defer: removeDir(base)
    let root = base / "repo"
    createDir(root)
    writeFile(root / "a.file", "first")
    writeFile(root / "b.file", "second")
    require runFilemeta("scan", root).exitCode == 0
    require runFilemeta("taxonomy", "add", "note", "string", root).exitCode == 0
    require runFilemeta("set", "a.file", "note", "first identity",
        root).exitCode == 0
    require runFilemeta("set", "b.file", "note", "second identity",
        root).exitCode == 0
    let db = openDatabase(root / ".facet" / "catalogue.db")
    defer: db.close()
    let identities = db.all("SELECT id, device, inode, first_seen FROM files ORDER BY id")
    let history = db.all("SELECT * FROM attribute_history ORDER BY id")
    moveFile(root / "a.file", base / "holding")
    moveFile(root / "b.file", root / "a.file")
    moveFile(base / "holding", root / "b.file")
    let swapped = runFilemeta("scan", root)
    require swapped.exitCode == 0
    check summaryCount(swapped.output, "Moved") == 2
    check "second identity" in runFilemeta("get", "a.file", root).output
    check "first identity" in runFilemeta("history", "b.file", root).output
    moveFile(root / "b.file", root / "renamed.file")
    check summaryCount(runFilemeta("scan", root).output, "Moved") == 1
    check "first identity" in runFilemeta("get", "renamed.file", root).output
    moveFile(root / "renamed.file", base / "absent")
    check summaryCount(runFilemeta("scan", root).output, "Missing") == 1
    check summaryCount(runFilemeta("scan", root).output, "Missing") == 0
    check "MISSING" in runFilemeta("get", "renamed.file", root).output
    moveFile(base / "absent", root / "renamed.file")
    let returned = runFilemeta("scan", root)
    require returned.exitCode == 0
    check summaryCount(returned.output, "Added") == 0
    check summaryCount(returned.output, "Updated") == 1
    check db.all("SELECT id, device, inode, first_seen FROM files ORDER BY id") == identities
    check db.all("SELECT * FROM attribute_history ORDER BY id") == history
    writeFile(root / "renamed.file", "changed size")
    check summaryCount(runFilemeta("scan", root).output, "Updated") == 1
    check summaryCount(runFilemeta("scan", root).output, "Unchanged") == 2

  test "scan rolls back failures and excludes internal and symlink trees":
    let base = createTempDir("facet-scan-failure-", "")
    defer: removeDir(base)
    let root = base / "repo"
    createDir(root / "sub")
    writeFile(root / "sub" / "a.file", "hello")
    require runFilemeta("scan", root).exitCode == 0
    createDir(root / ".facet" / "hidden")
    writeFile(root / ".facet" / "hidden" / "private", "ignored")
    createSymlink(base, root / "linked-tree")
    let db = openDatabase(root / ".facet" / "catalogue.db")
    defer: db.close()
    let before = db.all("SELECT * FROM files ORDER BY id")
    writeFile(root / "new.file", "new")
    db.execScript("CREATE TRIGGER reject_scan BEFORE INSERT ON files BEGIN SELECT RAISE(ABORT, 'scan rejected'); END;")
    check runFilemeta("scan", root).exitCode != 0
    check db.all("SELECT * FROM files ORDER BY id") == before
    db.exec("DROP TRIGGER reject_scan")
    if geteuid() != 0:
      let permissions = getFilePermissions(root / "sub")
      setFilePermissions(root / "sub", {})
      try:
        check runFilemeta("scan", root).exitCode != 0
        check db.all("SELECT * FROM files ORDER BY id") == before
      finally:
        setFilePermissions(root / "sub", permissions)
    else:
      skip()
    let recovered = runFilemeta("scan", root)
    require recovered.exitCode == 0
    check summaryCount(recovered.output, "Scanned") == 2
    check summaryCount(recovered.output, "Added") == 1
    check db.all("SELECT COUNT(*) FROM files")[0][0].fromDb(int) == 2
    check db.all("PRAGMA foreign_key_check").len == 0

  test "scan skips existing non-regular entries":
    let root = createTempDir("facet-special-", "")
    defer: removeDir(root)
    writeFile(root / "regular", "kept")
    require mkfifo((root / "pipe").cstring, Mode(0o600)) == 0
    let sock = posix.socket(posix.AF_UNIX, posix.SOCK_STREAM, 0)
    require sock.int32 >= 0
    var address: Sockaddr_un
    address.sun_family = posix.TSa_Family(posix.AF_UNIX)
    let sockPath = root / "socket"
    copyMem(addr address.sun_path[0], sockPath.cstring, sockPath.len + 1)
    require posix.bindSocket(sock, cast[ptr SockAddr](addr address),
        posix.SockLen(sizeof(address))) == 0
    defer:
      discard posix.close(sock)
    require runFilemeta("init", root).exitCode == 0
    require runFilemeta("taxonomy", "add", "note", "string", root).exitCode == 0
    let response = runFilemeta("scan", root)
    checkpoint response.output
    require response.exitCode == 0
    check summaryCount(response.output, "Scanned") == 1
    check runFilemeta("list", root).output == "regular"
    check runFilemeta("set", "pipe", "note", "x", root).exitCode != 0
    check runFilemeta("set", "socket", "note", "x", root).exitCode != 0

  test "scan honors gitignore/facetignore discovery, negation, and CLI overrides":
    let base = createTempDir("facet-ignore-", "")
    defer: removeDir(base)
    let root = base / "repo"
    createDir(root / "build")
    createDir(root / "sub")
    writeFile(root / "kept.txt", "a")
    writeFile(root / "ignored.log", "b")
    writeFile(root / "keep.log", "c")
    writeFile(root / "build" / "generated.txt", "d")
    writeFile(root / "sub" / "local.tmp", "e")
    writeFile(root / ".gitignore", "*.log\n!keep.log\nbuild/\n")
    writeFile(root / "sub" / ".facetignore", "*.tmp\n")
    require runFilemeta("scan", root).exitCode == 0
    let tracked = runFilemeta("list", root).output.splitLines()
    check "kept.txt" in tracked
    check "keep.log" in tracked
    check "ignored.log" notin tracked
    check "build/generated.txt" notin tracked
    check "sub/local.tmp" notin tracked
    check ".gitignore" in tracked

    removeDir(root / ".facet")
    let verbose = runFilemeta("scan", "--verbose-ignore", root)
    require verbose.exitCode == 0
    check "Ignored: ignored.log" in verbose.output

    removeDir(root / ".facet")
    let unfiltered = runFilemeta("scan", "--no-ignore", root)
    require unfiltered.exitCode == 0
    let allTracked = runFilemeta("list", root).output.splitLines()
    check "ignored.log" in allTracked
    check "build/generated.txt" in allTracked
    check "sub/local.tmp" in allTracked

    removeDir(root / ".facet")
    let overridePath = base / "override.txt"
    writeFile(overridePath, "!ignored.log\nkept.txt\n")
    require runFilemeta("scan", "--ignore-file", overridePath, root).exitCode == 0
    let overridden = runFilemeta("list", root).output.splitLines()
    check "ignored.log" in overridden
    check "kept.txt" notin overridden
    check "build/generated.txt" notin overridden

    let missing = runFilemeta("scan", "--ignore-file", base / "absent.txt", root)
    check missing.exitCode != 0

  test "ignore patterns agree with git":
    let base = createTempDir("facet-ignore-git-", "")
    defer: removeDir(base)
    let root = base / "repo"
    let home = base / "home"
    createDir(home)
    createDir(root / "foo")
    createDir(root / "a" / "b")
    createDir(root / "sub")
    createDir(root / "onlydir")
    createDir(root / "walled")
    createDir(root / "sub2")
    writeFile(root / "foo" / "keep.txt", "keep")
    writeFile(root / "foo" / "drop.txt", "drop")
    writeFile(root / "space", "space")
    writeFile(root / "7.log", "digit")
    writeFile(root / "a" / "b" / "nested", "nested")
    writeFile(root / "anchored.txt", "root anchored")
    writeFile(root / "sub" / "anchored.txt", "not anchored here")
    writeFile(root / "onlydir" / "inside.txt", "inside a dir-only pattern")
    writeFile(root / "#literal", "hash literal")
    writeFile(root / "!literal", "bang literal")
    writeFile(root / "file with space.txt", "escaped space")
    writeFile(root / "b1.txt", "in range")
    writeFile(root / "b5.txt", "in range")
    writeFile(root / "b9.txt", "outside range")
    writeFile(root / "walled" / "note.txt", "should stay excluded")
    writeFile(root / "walled" / ".gitignore", "!note.txt\n")
    writeFile(root / "sub2" / "nested.log", "nested rule scoped here")
    writeFile(root / "nested.log", "root level, untouched by nested rule")
    writeFile(root / "sub2" / ".gitignore", "nested.log\n")
    writeFile(root / ".gitignore", """
foo/**
!foo/keep.txt
space 
[[:digit:]].log
**/nested
/anchored.txt
onlydir/
\#literal
\!literal
file\ with\ space.txt
b[1-5].txt
walled/
""")
    require runGit(home, "init", "-q", root).exitCode == 0
    let oracle = runGit(home, "-C", root, "ls-files", "--others",
        "--exclude-standard")
    require oracle.exitCode == 0
    require runFilemeta("scan", root).exitCode == 0
    let facetTracked = runFilemeta("list", root).output.splitLines().sorted()
    let gitTracked = (if oracle.output.len == 0: newSeq[string]() else:
      oracle.output.splitLines()).sorted()
    check facetTracked == gitTracked
    # Sanity checks pinning the intent of each pattern, independent of the
    # git oracle, so a regression in one pattern cannot hide behind another.
    check "sub/anchored.txt" in facetTracked
    check "anchored.txt" notin facetTracked
    check "onlydir/inside.txt" notin facetTracked
    check "#literal" notin facetTracked
    check "!literal" notin facetTracked
    check "file with space.txt" notin facetTracked
    check "b1.txt" notin facetTracked
    check "b5.txt" notin facetTracked
    check "b9.txt" in facetTracked
    check "walled/note.txt" notin facetTracked
    check "sub2/nested.log" notin facetTracked
    check "nested.log" in facetTracked

  test "ignore untracks a file and excludes it from future scans":
    let base = createTempDir("facet-ignore-cmd-", "")
    defer: removeDir(base)
    let root = base / "repo"
    createDir(root / "sub")
    writeFile(root / "a.file", "hello")
    writeFile(root / "sub" / "b.file", "world")
    require runFilemeta("scan", root).exitCode == 0
    require runFilemeta("taxonomy", "add", "note", "string", root).exitCode == 0
    require runFilemeta("set", "a.file", "note", "keep me", root).exitCode == 0
    let db = openDatabase(root / ".facet" / "catalogue.db")
    defer: db.close()
    let fileId = queryFileByPath(db, "a.file").get.id

    let ignored = runFilemeta("ignore", "a.file", root)
    require ignored.exitCode == 0
    check "a.file" in ignored.output
    check readFile(root / ".facetignore") == "/a.file\n"
    check db.all("SELECT * FROM files WHERE id = ?", fileId).len == 0
    check db.all("SELECT * FROM attribute_values WHERE file_id = ?",
        fileId).len == 0
    check db.all("SELECT * FROM attribute_history WHERE file_id = ?",
        fileId).len == 0
    check "a.file" notin runFilemeta("list", root).output.splitLines()

    let rescanned = runFilemeta("scan", root)
    require rescanned.exitCode == 0
    check "a.file" notin runFilemeta("list", root).output.splitLines()
    check "sub/b.file" in runFilemeta("list", root).output.splitLines()

    require runFilemeta("ignore", "sub/b.file", root).exitCode == 0
    check readFile(root / ".facetignore") == "/a.file\n/sub/b.file\n"

    check runFilemeta("ignore", "a.file", root).exitCode != 0
    check runFilemeta("ignore", "untracked", root).exitCode != 0

  test "set-time registration respects replacement and hard-link identities":
    let base = createTempDir("facet-register-", "")
    defer: removeDir(base)
    let root = base / "repo"
    createDir(root)
    writeFile(root / "a.file", "old")
    writeFile(base / "replacement", "new")
    require runFilemeta("init", root).exitCode == 0
    require runFilemeta("taxonomy", "add", "note", "string", root).exitCode == 0
    require runFilemeta("set", "a.file", "note", "old", root).exitCode == 0
    createHardlink(root / "a.file", root / "b.file")
    check "old" in runFilemeta("get", "b.file", root).output
    check "old" in runFilemeta("history", "b.file", root).output
    require runFilemeta("set", "b.file", "note", "shared", root).exitCode == 0
    let db = openDatabase(root / ".facet" / "catalogue.db")
    defer: db.close()
    check db.all("SELECT COUNT(*) FROM files")[0][0].fromDb(int) == 1
    check db.all("SELECT path FROM files")[0][0].fromDb(string) == "a.file"
    moveFile(root / "a.file", base / "old")
    moveFile(base / "replacement", root / "a.file")
    let before = db.all("SELECT * FROM files ORDER BY id")
    db.execScript("CREATE TRIGGER reject_replacement BEFORE INSERT ON attribute_history BEGIN SELECT RAISE(ABORT, 'rejected'); END;")
    check runFilemeta("set", "a.file", "note", "new", root).exitCode != 0
    check db.all("SELECT * FROM files ORDER BY id") == before
    db.exec("DROP TRIGGER reject_replacement")
    require runFilemeta("set", "a.file", "note", "new", root).exitCode == 0
    check db.all("SELECT COUNT(*) FROM files")[0][0].fromDb(int) == 2
    require runFilemeta("scan", root).exitCode == 0
    check "shared" in runFilemeta("get", "b.file", root).output
    check "new" in runFilemeta("get", "a.file", root).output
    check "shared" notin runFilemeta("history", "a.file", root).output

  test "version-one migration preserves rows, constraints and relationships":
    let root = createTempDir("facet-migration-", "")
    defer: removeDir(root)
    let db = legacyCatalogue(root)
    defer: db.close()
    let tables = @["files", "attribute_definitions", "enum_values",
        "attribute_values", "attribute_history"]
    var before: seq[seq[ResultRow]]
    for table in tables:
      before.add db.all("SELECT * FROM " & table & " ORDER BY rowid")
    let response = runFilemeta("status", root)
    checkpoint response.output
    require response.exitCode == 0
    check db.all("PRAGMA user_version")[0][0].fromDb(int) == 3
    for index, table in tables:
      check db.all("SELECT * FROM " & table & " ORDER BY rowid") == before[index]
    check db.all("PRAGMA foreign_key_check").len == 0
    check db.all("SELECT name FROM sqlite_master WHERE name = 'custom_size'").len == 1
    check db.all("SELECT min_integer, max_integer FROM attribute_definitions ORDER BY id").len == 2
    check db.all("PRAGMA foreign_key_list(attribute_values)")[1][2].fromDb(
        string) == "files"
    db.exec("UPDATE files SET state = 'MISSING' WHERE id = 7")
    db.exec("INSERT INTO files(path, device, inode, size, mtime_ns, first_seen, last_seen) VALUES('a.file', 11, 99, 1, 1, 1, 1)")
    expect SqliteError:
      db.exec("INSERT INTO files(path, device, inode, size, mtime_ns, first_seen, last_seen) VALUES('a.file', 11, 100, 1, 1, 1, 1)")
    expect SqliteError:
      db.exec("INSERT INTO files(path, device, inode, size, mtime_ns, first_seen, last_seen) VALUES('other', 11, 99, 1, 1, 1, 1)")

  test "failed migration rolls back schema and data, future versions are rejected":
    let root = createTempDir("facet-migration-fail-", "")
    defer: removeDir(root)
    let db = legacyCatalogue(root)
    defer: db.close()
    db.exec("PRAGMA foreign_keys = OFF")
    db.exec("INSERT INTO attribute_values(file_id, attribute_id, value_text) VALUES(999, 4, 'orphan')")
    let schemaBefore = db.all("SELECT type, name, sql FROM sqlite_master ORDER BY name")
    let filesBefore = db.all("SELECT * FROM files ORDER BY id")
    let valuesBefore = db.all("SELECT * FROM attribute_values ORDER BY file_id, attribute_id")
    check runFilemeta("status", root).exitCode != 0
    check db.all("PRAGMA user_version")[0][0].fromDb(int) == 1
    check db.all("SELECT type, name, sql FROM sqlite_master ORDER BY name") == schemaBefore
    check db.all("SELECT * FROM files ORDER BY id") == filesBefore
    check db.all("SELECT * FROM attribute_values ORDER BY file_id, attribute_id") == valuesBefore
    db.exec("DELETE FROM attribute_values WHERE file_id = 999")
    require runFilemeta("status", root).exitCode == 0
    check db.all("PRAGMA user_version")[0][0].fromDb(int) == 3
    db.exec("PRAGMA user_version = 99")
    check runFilemeta("status", root).exitCode != 0
    check db.all("PRAGMA user_version")[0][0].fromDb(int) == 99
    check db.all("SELECT * FROM files ORDER BY id") == filesBefore

  test "version-two migration adds integer bound columns without rewriting data":
    let root = createTempDir("facet-migration-v2-", "")
    defer: removeDir(root)
    let db = v2Catalogue(root)
    defer: db.close()
    let filesBefore = db.all("SELECT * FROM files ORDER BY rowid")
    let definitionsBefore = db.all("SELECT id, name, type, required, description, min_value, max_value FROM attribute_definitions ORDER BY rowid")
    let valuesBefore = db.all("SELECT * FROM attribute_values ORDER BY rowid")
    let historyBefore = db.all("SELECT * FROM attribute_history ORDER BY rowid")
    require runFilemeta("status", root).exitCode == 0
    check db.all("PRAGMA user_version")[0][0].fromDb(int) == 3
    check db.all("SELECT * FROM files ORDER BY rowid") == filesBefore
    check db.all("SELECT id, name, type, required, description, min_value, max_value FROM attribute_definitions ORDER BY rowid") == definitionsBefore
    check db.all("SELECT * FROM attribute_values ORDER BY rowid") == valuesBefore
    check db.all("SELECT * FROM attribute_history ORDER BY rowid") == historyBefore
    check db.all("SELECT min_integer, max_integer FROM attribute_definitions ORDER BY rowid")[
        0][0].kind == sqliteNull
    check db.all("PRAGMA foreign_key_check").len == 0
    # Idempotent: opening an already-migrated v3 catalogue changes nothing further.
    require runFilemeta("status", root).exitCode == 0
    check db.all("PRAGMA user_version")[0][0].fromDb(int) == 3

  test "version-two migration rolls back added columns on foreign-key failure":
    let root = createTempDir("facet-migration-v2-fail-", "")
    defer: removeDir(root)
    let db = v2Catalogue(root)
    defer: db.close()
    db.exec("PRAGMA foreign_keys = OFF")
    db.exec("INSERT INTO attribute_values(file_id, attribute_id, value_text) VALUES(999, 4, 'orphan')")
    let schemaBefore = db.all("SELECT type, name, sql FROM sqlite_master ORDER BY name")
    check runFilemeta("status", root).exitCode != 0
    check db.all("PRAGMA user_version")[0][0].fromDb(int) == 2
    check db.all("SELECT type, name, sql FROM sqlite_master ORDER BY name") == schemaBefore
    db.exec("DELETE FROM attribute_values WHERE file_id = 999")
    require runFilemeta("status", root).exitCode == 0
    check db.all("PRAGMA user_version")[0][0].fromDb(int) == 3
    check db.all("SELECT min_integer, max_integer FROM attribute_definitions").len == 2

  test "replacement retains old identity and does not inherit metadata":
    let base = createTempDir("facet-replace-", "")
    defer: removeDir(base)
    let root = base / "repo"
    createDir(root)
    writeFile(root / "a.file", "old")
    writeFile(base / "replacement", "new identity")
    require runFilemeta("init", root).exitCode == 0
    require runFilemeta("taxonomy", "add", "note", "string", root).exitCode == 0
    require runFilemeta("set", "a.file", "note", "old metadata",
        root).exitCode == 0
    let db = openDatabase(root / ".facet" / "catalogue.db")
    defer: db.close()
    let oldId = db.all("SELECT id FROM files")[0][0].fromDb(int)
    let oldHistory = db.all("SELECT * FROM attribute_history ORDER BY id")
    moveFile(root / "a.file", base / "old")
    moveFile(base / "replacement", root / "a.file")
    let response = runFilemeta("scan", root)
    checkpoint response.output
    require response.exitCode == 0
    check summaryCount(response.output, "Added") == 1
    check summaryCount(response.output, "Missing") == 1
    check db.all("SELECT state FROM files WHERE id = ?", oldId)[0][0].fromDb(
        string) == "MISSING"
    check db.all("SELECT COUNT(*) FROM files WHERE path = 'a.file'")[0][
        0].fromDb(int) == 2
    check db.all("SELECT * FROM attribute_history ORDER BY id") == oldHistory
    check parseJson(runFilemeta("get", "a.file", "--json", root).output)[
        "attributes"].len == 0
    check runFilemeta("history", "a.file", root).output == ""
    require runFilemeta("set", "a.file", "note", "new metadata",
        root).exitCode == 0
    moveFile(root / "a.file", base / "new")
    require runFilemeta("scan", root).exitCode == 0
    check "new metadata" in runFilemeta("get", "a.file", root).output
    check "old metadata" notin runFilemeta("history", "a.file", root).output
    db.exec("UPDATE files SET last_seen = 1 WHERE path = 'a.file'")
    check "new metadata" in runFilemeta("get", "a.file", root).output
    check summaryCount(runFilemeta("scan", root).output, "Missing") == 0
    check db.all("PRAGMA foreign_key_check").len == 0

  test "hard links share one stable canonical identity":
    let root = createTempDir("facet-links-", "")
    defer: removeDir(root)
    writeFile(root / "b.file", "same identity")
    createHardlink(root / "b.file", root / "a.file")
    let first = runFilemeta("scan", root)
    checkpoint first.output
    require first.exitCode == 0
    check summaryCount(first.output, "Added") == 1
    check summaryCount(first.output, "Scanned") == 1
    let db = openDatabase(root / ".facet" / "catalogue.db")
    defer: db.close()
    check db.all("SELECT COUNT(*) FROM files")[0][0].fromDb(int) == 1
    check db.all("SELECT path FROM files")[0][0].fromDb(string) == "a.file"
    let before = db.all("SELECT last_seen FROM files")[0][0].fromDb(int64)
    createHardlink(root / "b.file", root / "0.file")
    let second = runFilemeta("scan", root)
    require second.exitCode == 0
    check summaryCount(second.output, "Added") == 0
    check summaryCount(second.output, "Moved") == 0
    check summaryCount(second.output, "Unchanged") == 1
    check db.all("SELECT last_seen FROM files")[0][0].fromDb(int64) > before
    check db.all("SELECT path FROM files")[0][0].fromDb(string) == "a.file"
    removeFile(root / "a.file")
    let third = runFilemeta("scan", root)
    require third.exitCode == 0
    check summaryCount(third.output, "Moved") == 1
    check db.all("SELECT path FROM files")[0][0].fromDb(string) == "0.file"
    check db.all("PRAGMA foreign_key_check").len == 0

  test "metadata and registration roll back when audit insertion fails":
    let root = createTempDir("facet-atomic-", "")
    defer: removeDir(root)
    writeFile(root / "a.file", "hello")
    writeFile(root / "new.file", "new")
    require runFilemeta("init", root).exitCode == 0
    require runFilemeta("taxonomy", "add", "note", "string", root).exitCode == 0
    require runFilemeta("set", "a.file", "note", "original", root).exitCode == 0
    let db = openDatabase(root / ".facet" / "catalogue.db")
    defer: db.close()
    let filesBefore = db.all("SELECT * FROM files ORDER BY id")
    let valuesBefore = db.all("SELECT * FROM attribute_values ORDER BY file_id, attribute_id")
    let historyBefore = db.all("SELECT * FROM attribute_history ORDER BY id")
    db.execScript("CREATE TRIGGER reject_history BEFORE INSERT ON attribute_history BEGIN SELECT RAISE(ABORT, 'audit rejected'); END;")
    check runFilemeta("set", "a.file", "note", "changed", root).exitCode != 0
    check db.all("SELECT * FROM attribute_values ORDER BY file_id, attribute_id") == valuesBefore
    check db.all("SELECT * FROM attribute_history ORDER BY id") == historyBefore
    check runFilemeta("unset", "a.file", "note", root).exitCode != 0
    check db.all("SELECT * FROM attribute_values ORDER BY file_id, attribute_id") == valuesBefore
    check db.all("SELECT * FROM attribute_history ORDER BY id") == historyBefore
    check runFilemeta("set", "new.file", "note", "first", root).exitCode != 0
    check db.all("SELECT * FROM files ORDER BY id") == filesBefore
    check db.all("SELECT * FROM attribute_values ORDER BY file_id, attribute_id") == valuesBefore
    check runFilemeta("set", "a.file", "note", "original", root).exitCode == 0
    db.exec("DROP TRIGGER reject_history")
    check runFilemeta("set", "new.file", "note", "first", root).exitCode == 0
    check runFilemeta("set", "a.file", "note", "changed", root).exitCode == 0
    check runFilemeta("unset", "a.file", "note", root).exitCode == 0

  test "audit preserves canonical values, empty strings and SQL NULL":
    let root = createTempDir("facet-audit-", "")
    defer: removeDir(root)
    writeFile(root / "a.file", "hello")
    require runFilemeta("init", root).exitCode == 0
    require runFilemeta("taxonomy", "add", "note", "string", root).exitCode == 0
    require runFilemeta("taxonomy", "add", "count", "integer", root).exitCode == 0
    require runFilemeta("taxonomy", "add", "rating", "enum", "RED", "BLUE",
        root).exitCode == 0
    let db = openDatabase(root / ".facet" / "catalogue.db")
    defer: db.close()
    for (attribute, first, canonical, second) in [("note", "", "", "next"), (
        "count", "03", "3", "4"), ("rating", "RED", "RED", "BLUE")]:
      require runFilemeta("set", "a.file", attribute, first, root).exitCode == 0
      require runFilemeta("set", "a.file", attribute, canonical,
          root).exitCode == 0
      require runFilemeta("set", "a.file", attribute, second, root).exitCode == 0
      require runFilemeta("unset", "a.file", attribute, root).exitCode == 0
      let rows = db.all("SELECT old_value, new_value, changed_at FROM attribute_history JOIN attribute_definitions ON attribute_id = attribute_definitions.id WHERE name = ? ORDER BY attribute_history.id", attribute)
      require rows.len == 3
      check rows[0][0].kind == sqliteNull
      check rows[0][1].fromDb(string) == canonical
      check rows[1][0].fromDb(string) == canonical
      check rows[1][1].fromDb(string) == second
      check rows[2][0].fromDb(string) == second
      check rows[2][1].kind == sqliteNull
      check rows[0][2].fromDb(int64) <= rows[1][2].fromDb(int64)
      check rows[1][2].fromDb(int64) <= rows[2][2].fromDb(int64)

  test "path containment, lookup-only reads and deleted path forms":
    let base = createTempDir("facet-paths-", "")
    defer: removeDir(base)
    let root = base / "repo"
    createDir(root / "sub")
    createDir(base / "repo-sibling")
    writeFile(root / "sub" / "a.file", "hello")
    writeFile(root / "untracked", "hello")
    writeFile(root / "back\\slash", "hello")
    writeFile(base / "outside", "outside")
    writeFile(base / "repo-sibling" / "outside", "outside")
    createSymlink(base / "outside", root / "link")
    createSymlink(base / "repo-sibling", root / "linked-dir")
    createSymlink(root / "untracked", root / "inside-link")
    require runFilemeta("init", root).exitCode == 0
    require runFilemeta("taxonomy", "add", "note", "string", root).exitCode == 0
    require runFilemeta("set", "sub/a.file", "note", "kept", root).exitCode == 0
    let db = openDatabase(root / ".facet" / "catalogue.db")
    defer: db.close()
    for path in [base / "outside", "../outside", base / "repo-sibling" /
        "outside", "link", "linked-dir/outside", "inside-link"]:
      check runFilemeta("get", path, root).exitCode != 0
      check runFilemeta("history", path, root).exitCode != 0
      check runFilemeta("set", path, "note", "rejected", root).exitCode != 0
      check runFilemeta("unset", path, "note", root).exitCode != 0
    for command in ["get", "history"]:
      check runFilemeta(command, "untracked", root).exitCode != 0
    check runFilemeta("unset", "untracked", "note", root).exitCode != 0
    check db.all("SELECT COUNT(*) FROM files")[0][0].fromDb(int) == 1
    check db.all("SELECT COUNT(*) FROM attribute_history")[0][0].fromDb(int) == 1
    block:
      let previous = getCurrentDir()
      setCurrentDir(root / "sub")
      defer: setCurrentDir(previous)
      check "kept" in runFilemeta("get", "a.file").output
      check "kept" in runFilemeta("history", "./a.file").output
      check runFilemeta("set", "a.file", "note", "cwd").exitCode == 0
      check runFilemeta("unset", "./a.file", "note").exitCode == 0
      check runFilemeta("set", "sub/a.file", "note", "kept", root).exitCode == 0
    removeFile(root / "sub" / "a.file")
    let expectedHistory = runFilemeta("history", "sub/a.file", root)
    require expectedHistory.exitCode == 0
    for path in [root / "sub" / "a.file", "sub/a.file", "./sub/a.file"]:
      let response = runFilemeta("get", path, "--json", root)
      require response.exitCode == 0
      check parseJson(response.output)["attributes"]["note"].getStr == "kept"
      check runFilemeta("history", path, root) == expectedHistory
    block:
      let previous = getCurrentDir()
      setCurrentDir(root / "sub")
      defer: setCurrentDir(previous)
      check "kept" in runFilemeta("get", "./a.file").output
      check runFilemeta("history", "a.file") == expectedHistory
    let backslashSet = runFilemeta("set", "back\\slash", "note", "literal", root)
    checkpoint backslashSet.output
    require backslashSet.exitCode == 0
    check parseJson(runFilemeta("get", "back\\slash", "--json", root).output)[
        "path"].getStr == "back\\slash"

  test "opening commands do not create a catalogue":
    let root = createTempDir("facet-no-catalogue-", "")
    defer: removeDir(root)
    writeFile(root / "a.file", "hello")
    for command in ["get", "history"]:
      check runFilemeta(command, "a.file", root).exitCode != 0
      check not dirExists(root / ".facet")
    for command in ["status", "list"]:
      check runFilemeta(command, root).exitCode != 0
      check not dirExists(root / ".facet")
    check runFilemeta("find", "note == x", root).exitCode != 0
    check runFilemeta("taxonomy", "list", root).exitCode != 0
    check runFilemeta("set", "a.file", "note", "x", root).exitCode != 0
    check runFilemeta("unset", "a.file", "note", root).exitCode != 0
    check not dirExists(root / ".facet")

  test "enum creation is atomic":
    let root = createTempDir("facet-enum-atomic-", "")
    defer: removeDir(root)
    require runFilemeta("init", root).exitCode == 0
    let db = openDatabase(root / ".facet" / "catalogue.db")
    defer: db.close()
    check runFilemeta("taxonomy", "add", "colors", "enum", "red", "red",
        "blue", root).exitCode != 0
    check db.all("SELECT * FROM attribute_definitions").len == 0
    check db.all("SELECT * FROM enum_values").len == 0
    db.execScript("CREATE TRIGGER reject_enum BEFORE INSERT ON enum_values " &
        "WHEN NEW.value = 'blue' BEGIN SELECT RAISE(ABORT, 'rejected'); END;")
    check runFilemeta("taxonomy", "add", "colors", "enum", "red", "blue",
        root).exitCode != 0
    check db.all("SELECT * FROM attribute_definitions").len == 0
    check db.all("SELECT * FROM enum_values").len == 0
    db.exec("DROP TRIGGER reject_enum")
    require runFilemeta("taxonomy", "add", "colors", "enum", "red", "blue",
        root).exitCode == 0
    check db.all("SELECT * FROM attribute_definitions").len == 1
    check db.all("SELECT * FROM enum_values").len == 2

  test "non-finite numbers never mutate catalogue":
    let root = createTempDir("facet-nonfinite-", "")
    defer: removeDir(root)
    writeFile(root / "new.file", "hello")
    require runFilemeta("init", root).exitCode == 0
    require runFilemeta("taxonomy", "add", "ratio", "real", "--min", "0",
        "--max", "1", root).exitCode == 0
    let db = openDatabase(root / ".facet" / "catalogue.db")
    defer: db.close()
    let filesBefore = db.all("SELECT * FROM files ORDER BY id")
    let valuesBefore = db.all("SELECT * FROM attribute_values ORDER BY file_id, attribute_id")
    let historyBefore = db.all("SELECT * FROM attribute_history ORDER BY id")
    for raw in ["nan", "NaN", "inf", "-inf", "1e9999"]:
      check runFilemeta("set", "new.file", "ratio", raw, root).exitCode != 0
      check db.all("SELECT * FROM files ORDER BY id") == filesBefore
      check db.all("SELECT * FROM attribute_values ORDER BY file_id, attribute_id") == valuesBefore
      check db.all("SELECT * FROM attribute_history ORDER BY id") == historyBefore
      check runFilemeta("taxonomy", "add", "invalid", "real", "--min", raw,
          root).exitCode != 0
      check db.all("SELECT * FROM attribute_definitions WHERE name = 'invalid'").len == 0
    check runFilemeta("set", "new.file", "ratio", "0.5", root).exitCode == 0

  test "taxonomy add rejects missing bound operands and reversed bounds":
    let root = createTempDir("facet-bounds-cli-", "")
    defer: removeDir(root)
    require runFilemeta("init", root).exitCode == 0
    let db = openDatabase(root / ".facet" / "catalogue.db")
    defer: db.close()
    check runFilemeta("taxonomy", "add", "trailing-min", "integer", "--min",
        root).exitCode != 0
    check db.all("SELECT * FROM attribute_definitions WHERE name = 'trailing-min'").len == 0
    check runFilemeta("taxonomy", "add", "trailing-max", "integer", "--max",
        root).exitCode != 0
    check db.all("SELECT * FROM attribute_definitions WHERE name = 'trailing-max'").len == 0
    check runFilemeta("taxonomy", "add", "reversed", "integer", "--min", "5",
        "--max", "1", root).exitCode != 0
    check db.all("SELECT * FROM attribute_definitions WHERE name = 'reversed'").len == 0

  test "query truth tables, precedence, literals and malformed input":
    let root = createTempDir("facet-logic-", "")
    defer: removeDir(root)
    require runFilemeta("init", root).exitCode == 0
    for attribute in ["left", "right", "third", "note", "weight"]:
      require runFilemeta("taxonomy", "add", attribute, "string",
          root).exitCode == 0
    for name in ["ff", "ft", "tf", "tt", "missing"]:
      writeFile(root / name, name)
    require runFilemeta("scan", root).exitCode == 0
    for name in ["ff", "ft", "tf", "tt"]:
      require runFilemeta("set", name, "left", $name[0], root).exitCode == 0
      require runFilemeta("set", name, "right", $name[1], root).exitCode == 0
      require runFilemeta("set", name, "third", "t", root).exitCode == 0
    template expectQuery(expression: string, expected: seq[string]) =
      block:
        let response = runFilemeta("find", expression, root)
        check response.exitCode == 0
        check (if response.output.len == 0: newSeq[string]() else: response.output.splitLines()) == expected
    expectQuery("left == t or right == t", @["ft", "tf", "tt"])
    expectQuery("right == t OR left == t", @["ft", "tf", "tt"])
    expectQuery("left == t and right == t", @["tt"])
    expectQuery("right == t AND left == t", @["tt"])
    expectQuery("left == t or right == t or third == t", @["ff", "ft", "tf", "tt"])
    expectQuery("left == t and right == t and third == t", @["tt"])
    expectQuery("left == t or right == t and third == f", @["tf", "tt"])
    expectQuery("left == f and right == t or third == f", @["ft"])
    require runFilemeta("set", "tf", "note", "BLUE", root).exitCode == 0
    require runFilemeta("set", "ft", "note", "RED", root).exitCode == 0
    expectQuery("note == \"BLUE\" or note == \"RED\"", @["ft", "tf"])
    expectQuery("note == \"RED\" or note == \"BLUE\"", @["ft", "tf"])
    for value in ["hello world", "a \"quote\" and \\ slash\n", "", "and"]:
      require runFilemeta("set", "ff", "note", value, root).exitCode == 0
      expectQuery("note==" & $(%value), @["ff"])
    expectQuery("absent==\"\"", newSeq[string]())
    expectQuery("absent!=\"\"", newSeq[string]())
    require runFilemeta("set", "tt", "weight", "3", root).exitCode == 0
    for expression in ["weight>=3", "weight<=3", "weight>2", "weight<4",
        "weight!=4", "weight==3"]:
      expectQuery(expression, @["tt"])
    for expression in ["", "note", "note ==", "note = x", "note === x",
        "note <> x", "note == x and", "note == x xor note == y",
        "note == x note == y", "note == \"unterminated", "note == \"bad\\q\"",
        "note == and", "note == \"x\"junk", "== x y",
        "note == x or or note == y"]:
      let response = runFilemeta("find", expression, root)
      check response.exitCode != 0
      check "Error:" in response.output

  test "JSON strings round trip without changing field types":
    let root = createTempDir("facet-json-", "")
    defer: removeDir(root)
    let name = "quoted\".file"
    writeFile(root / name, "hello")
    require runFilemeta("init", root).exitCode == 0
    require runFilemeta("taxonomy", "add", "note\"", "string", root).exitCode == 0
    require runFilemeta("taxonomy", "add", "count", "integer", root).exitCode == 0
    require runFilemeta("set", name, "count", "3", root).exitCode == 0
    for value in ["a \"quoted\" note", "back\\slash", "first\nsecond\tend\r", ""]:
      require runFilemeta("set", name, "note\"", value, root).exitCode == 0
      let response = runFilemeta("get", name, "--json", root)
      require response.exitCode == 0
      let data = parseJson(response.output)
      check data["path"].getStr == name
      check data["state"].getStr == "PRESENT"
      check data["size"].getInt == 5
      check data["modified"].kind == JInt
      check data["attributes"]["note\""].getStr == value
      check data["attributes"]["count"].getStr == "3"

  test "optional numeric bounds retain SQL NULL":
    let root = createTempDir("facet-bounds-", "")
    defer: removeDir(root)
    writeFile(root / "a.file", "hello")
    require runFilemeta("init", root).exitCode == 0
    let db = openDatabase(root / ".facet" / "catalogue.db")
    defer: db.close()
    for kind in ["integer", "real"]:
      require runFilemeta("taxonomy", "add", kind, kind, root).exitCode == 0
      let bounds = db.all("SELECT min_value, max_value FROM attribute_definitions WHERE name = ?",
          kind)[0]
      check bounds[0].kind == sqliteNull
      check bounds[1].kind == sqliteNull
      for value in ["-3", "3"]:
        check runFilemeta("set", "a.file", kind, value, root).exitCode == 0
    require runFilemeta("taxonomy", "add", "minimum", "real", "--min", "0",
        root).exitCode == 0
    require runFilemeta("taxonomy", "add", "maximum", "integer", "--max", "0",
        root).exitCode == 0
    require runFilemeta("taxonomy", "add", "zero", "integer", "--min", "0",
        "--max", "0", root).exitCode == 0
    check db.all("SELECT min_value, max_value FROM attribute_definitions WHERE name = 'minimum'")[
        0][1].kind == sqliteNull
    check db.all("SELECT min_value, max_value FROM attribute_definitions WHERE name = 'maximum'")[
        0][0].kind == sqliteNull
    check runFilemeta("set", "a.file", "minimum", "3.5", root).exitCode == 0
    check runFilemeta("set", "a.file", "minimum", "-1", root).exitCode != 0
    check runFilemeta("set", "a.file", "maximum", "-3", root).exitCode == 0
    check runFilemeta("set", "a.file", "maximum", "1", root).exitCode != 0
    check runFilemeta("set", "a.file", "zero", "0", root).exitCode == 0
    check runFilemeta("set", "a.file", "zero", "1", root).exitCode != 0
    check runFilemeta("set", "a.file", "zero", "-1", root).exitCode != 0

  test "integer bounds and queries preserve int64 precision":
    let root = createTempDir("facet-int64-", "")
    defer: removeDir(root)
    writeFile(root / "sample", "hello")
    require runFilemeta("init", root).exitCode == 0
    require runFilemeta("taxonomy", "add", "bounded", "integer", "--max",
        "9007199254740992", root).exitCode == 0
    check runFilemeta("set", "sample", "bounded", "9007199254740993",
        root).exitCode != 0
    check runFilemeta("set", "sample", "bounded", "9007199254740992",
        root).exitCode == 0
    check runFilemeta("taxonomy", "add", "bounded", "integer", "--min", "1.5",
        root).exitCode != 0
    check runFilemeta("taxonomy", "add", "bounded", "integer", "--min", "1e3",
        root).exitCode != 0
    require runFilemeta("taxonomy", "add", "count", "integer",
        root).exitCode == 0
    require runFilemeta("set", "sample", "count", "9007199254740993",
        root).exitCode == 0
    check runFilemeta("find", "count<=9007199254740992", root).output == ""
    check runFilemeta("find", "count>9007199254740992", root).output == "sample"
    check runFilemeta("find", "count==9007199254740993", root).output == "sample"
    check runFilemeta("find", "count==09007199254740993", root).output == ""
    require runFilemeta("set", "sample", "count", $low(int64), root).exitCode == 0
    check runFilemeta("find", "count<0", root).output == "sample"
    check runFilemeta("find", "count>=" & $low(int64), root).output == "sample"
    require runFilemeta("set", "sample", "count", $high(int64),
        root).exitCode == 0
    check runFilemeta("find", "count<=" & $high(int64), root).output == "sample"
    check runFilemeta("find", "count<3.5", root).output == ""

  test "repository initialisation and scan":
    let base = createTempDir("facet-init-", "")
    defer: removeDir(base)
    let root = base / "repo"
    createDir(root)
    writeFile(root / "a.file", "hello")

    let initRes = runFilemeta("init", root)
    check initRes.exitCode == 0
    check dirExists(root / ".facet")

    let scanRes = runFilemeta("scan", root)
    check scanRes.exitCode == 0
    check "Scanned:" in scanRes.output

  test "taxonomy validation and metadata assignment":
    let base = createTempDir("facet-tax-", "")
    defer: removeDir(base)
    let root = base / "repo"
    createDir(root)
    writeFile(root / "a.file", "hello")

    discard runFilemeta("init", root)
    discard runFilemeta("taxonomy", "add", "rating", "enum", "RED", "GREEN",
        "BLUE", root)
    discard runFilemeta("taxonomy", "add", "weight", "integer", "--min", "0",
        "--max", "5", root)

    let setOk = runFilemeta("set", root / "a.file", "rating", "BLUE", root)
    check setOk.exitCode == 0

    let badEnum = runFilemeta("set", root / "a.file", "rating", "PURPLE", root)
    check badEnum.exitCode != 0

    let setWeight = runFilemeta("set", root / "a.file", "weight", "3", root)
    check setWeight.exitCode == 0

    let badWeight = runFilemeta("set", root / "a.file", "weight", "99", root)
    check badWeight.exitCode != 0

  test "history and query filter":
    let base = createTempDir("facet-query-", "")
    defer: removeDir(base)
    let root = base / "repo"
    createDir(root)
    writeFile(root / "a.file", "hello")

    discard runFilemeta("init", root)
    discard runFilemeta("taxonomy", "add", "rating", "enum", "RED", "GREEN",
        "BLUE", root)
    discard runFilemeta("taxonomy", "add", "weight", "integer", "--min", "0",
        "--max", "5", root)
    discard runFilemeta("set", root / "a.file", "rating", "BLUE", root)
    discard runFilemeta("set", root / "a.file", "weight", "3", root)

    let historyRes = runFilemeta("history", root / "a.file", root)
    check historyRes.exitCode == 0
    check "rating" in historyRes.output or "weight" in historyRes.output

    let findRes = runFilemeta("find", "rating == \"BLUE\" and weight >= 3", root)
    check findRes.exitCode == 0
    check "a.file" in findRes.output

suite "facet database":
  test "file rows share identity and state codecs":
    let root = createTempDir("facet-identity-", "")
    defer: removeDir(root)
    let db = initDatabase(root)
    defer: db.close()
    let now = utcNowNs()
    let presentId = insertFileRecord(db, "present.file", 11, 21, 5, 1, now, now)
    let missingId = insertFileRecord(db, "missing.file", 11, 22, 6, 2, now, now)
    markMissing(db, missingId)

    let listed = listFiles(db)
    require listed.len == 2
    let byPath = queryFileByPath(db, "present.file")
    require byPath.isSome
    let bySignature = queryFileBySignature(db, 11, 21)
    require bySignature.isSome
    check byPath.get.id == presentId
    check bySignature.get.id == presentId
    check byPath.get == bySignature.get
    check identity(byPath.get) == (device: 11'u64, inode: 21'u64)
    check byPath.get.state == fsPresent

    let missing = queryFileByPath(db, "missing.file")
    require missing.isSome
    check missing.get.id == missingId
    check missing.get.state == fsMissing
    check identity(missing.get) != identity(byPath.get)

    check queryFileByPath(db, "absent.file").isNone

  test "distinct device/inode pairs form distinct identity keys":
    var lookup = initTable[FileIdentity, string]()
    lookup[(device: 1'u64, inode: 2'u64)] = "a"
    lookup[(device: 1'u64, inode: 3'u64)] = "b"
    lookup[(device: 2'u64, inode: 2'u64)] = "c"
    check lookup.len == 3
    check lookup[(device: 1'u64, inode: 2'u64)] == "a"
    check lookup[(device: 1'u64, inode: 3'u64)] == "b"
    check lookup[(device: 2'u64, inode: 2'u64)] == "c"

suite "facet query":
  test "typed clause parsing converts tokens to operator and logic enums":
    let clauses = parseQueryClauses("left == t or right >= 3 and third != x")
    require clauses.len == 3
    check clauses[0].attribute == "left"
    check clauses[0].operator == qoEqual
    check clauses[0].expected == "t"
    check clauses[0].nextLogic == qlOr
    check clauses[1].attribute == "right"
    check clauses[1].operator == qoGreaterEqual
    check clauses[1].expected == "3"
    check clauses[1].nextLogic == qlAnd
    check clauses[2].attribute == "third"
    check clauses[2].operator == qoNotEqual
    check clauses[2].expected == "x"
    check clauses[2].nextLogic == qlEnd

  test "batched queries preserve identity and comparison semantics":
    let root = createTempDir("facet-batched-query-", "")
    defer: removeDir(root)
    let db = initDatabase(root)
    defer: db.close()
    addTaxonomyAttribute(db, "tag", "string")
    addTaxonomyAttribute(db, "count", "integer")
    addTaxonomyAttribute(db, "flag", "boolean")
    addTaxonomyAttribute(db, "weight", "real")
    let now = utcNowNs()

    proc withValue(path: string, device, inode: uint64, tag: string,
        count: int64, flag: bool, weight: float64): int =
      result = insertFileRecord(db, path, device, inode, 1, now, now, now)
      let tagDef = fetchAttributeDef(db, "tag").get
      let countDef = fetchAttributeDef(db, "count").get
      let flagDef = fetchAttributeDef(db, "flag").get
      let weightDef = fetchAttributeDef(db, "weight").get
      let tagCols = encodeAttributeValue(AttributeValue(kind: akString, text: tag))
      let countCols = encodeAttributeValue(AttributeValue(kind: akInteger,
          integer: count))
      let flagCols = encodeAttributeValue(AttributeValue(kind: akBoolean,
          boolean: flag))
      let weightCols = encodeAttributeValue(AttributeValue(kind: akReal, real: weight))
      for (defId, cols) in [(tagDef.id, tagCols), (countDef.id, countCols),
          (flagDef.id, flagCols), (weightDef.id, weightCols)]:
        db.exec("INSERT INTO attribute_values(file_id, attribute_id, value_text, value_integer, value_real, value_boolean) VALUES(?, ?, ?, ?, ?, ?)",
            result, defId, cols.text, cols.integer, cols.real, cols.boolean)

    # Repeated attribute value across many files, plus one file with an
    # absent attribute (no row) and one with an explicit empty string.
    discard withValue("a.file", 1, 1, "red", 5, true, 1.5)
    discard withValue("b.file", 1, 2, "red", 9007199254740993'i64, false, 2.5)
    let noTagId = insertFileRecord(db, "c.file", 1, 3, 1, now, now, now)
    let countDef = fetchAttributeDef(db, "count").get
    db.exec("INSERT INTO attribute_values(file_id, attribute_id, value_integer) VALUES(?, ?, ?)",
        noTagId, countDef.id, 1'i64)
    discard withValue("d.file", 1, 4, "", 0, true, 0.0)

    # PRESENT and MISSING identities sharing one path: must not be
    # deduplicated by the batched loader.
    let sharedPresentId = withValue("shared.file", 1, 5, "blue", 1, true, 1.0)
    markMissing(db, sharedPresentId)
    discard insertFileRecord(db, "shared.file", 1, 6, 1, now, now, now)

    template expectMatches(expression: string, expected: seq[string]) =
      check findFilesForExpression(db, expression) == expected

    expectMatches("tag == red", @["a.file", "b.file"])
    expectMatches("tag == \"\"", @["d.file"])
    expectMatches("count == 9007199254740993", @["b.file"])
    expectMatches("flag == true", @["a.file", "d.file", "shared.file"])
    expectMatches("weight >= 1.5", @["a.file", "b.file"])
    expectMatches("tag == red or flag == true",
        @["a.file", "b.file", "d.file", "shared.file"])
    expectMatches("tag == red and flag == true", @["a.file"])
    expectMatches("tag == missing", newSeq[string]())

suite "facet numeric":
  test "integer real boundary comparison":
    check compareIntegerToReal(3, 3.5) == -1
    check compareIntegerToReal(-3, -3.5) == 1
    check compareIntegerToReal(9007199254740993'i64, 9007199254740992.0) == 1
    check compareIntegerToReal(high(int64), 9223372036854775808.0) == -1
    check compareIntegerToReal(low(int64), -9223372036854775808.0) == 0
    check compareIntegerToReal(3, 3.0) == 0
    check compareIntegerToReal(4, 3.5) == 1

suite "facet ignore":
  test "posix bracket classes match their byte ranges under C locale":
    template checkClass(pattern: string, matching: openArray[char],
        nonMatching: openArray[char]) =
      let rules = parseIgnoreRules(pattern, "probe")
      require rules.len == 1
      for c in matching:
        check isPathIgnored(@[], rules, $c, false).isSome
      for c in nonMatching:
        check isPathIgnored(@[], rules, $c, false).isNone
    checkClass("[[:alnum:]]", ['a', 'Z', '5'], ['!', ' ', '_'])
    checkClass("[[:alpha:]]", ['a', 'Z'], ['5', '!', '_'])
    checkClass("[[:blank:]]", [' ', '\t'], ['a', '\n'])
    checkClass("[[:cntrl:]]", ['\x00', '\x1F', '\x7F'], ['a', ' '])
    checkClass("[[:digit:]]", ['0', '9'], ['a', ' '])
    checkClass("[[:graph:]]", ['a', '!'], [' ', '\t'])
    checkClass("[[:lower:]]", ['a', 'z'], ['A', '5'])
    checkClass("[[:print:]]", ['a', ' '], ['\t', '\x7F'])
    checkClass("[[:punct:]]", ['!', '.', '-'], ['a', ' ', '5'])
    checkClass("[[:space:]]", [' ', '\t', '\n'], ['a', '5'])
    checkClass("[[:upper:]]", ['A', 'Z'], ['a', '5'])
    checkClass("[[:xdigit:]]", ['0', '9', 'a', 'f', 'A', 'F'], ['g', 'G', ' '])

  test "negated posix class excludes its byte range":
    let rules = parseIgnoreRules("[![:digit:]]", "probe")
    require rules.len == 1
    check isPathIgnored(@[], rules, "5", false).isNone
    check isPathIgnored(@[], rules, "a", false).isSome

  test "repeated wildcard segments do not blow up and resolve deterministically":
    let rules = parseIgnoreRules("*a*a*a*a*a*a*a*a*a*a*a*b", "probe")
    require rules.len == 1
    let nonMatching = "a".repeat(30)
    check isPathIgnored(@[], rules, nonMatching, false).isNone
    let matching = "a".repeat(30) & "b"
    check isPathIgnored(@[], rules, matching, false).isSome

  test "literalIgnoreRule escapes globs and matches only the exact path":
    for relPath in ["a[b].txt", "note*.md", "!bang.txt", "#hash.txt",
        "trailing.txt ", "back\\slash"]:
      let line = literalIgnoreRule(relPath)
      let rules = parseIgnoreRules(line, "probe")
      require rules.len == 1
      check isPathIgnored(@[], rules, relPath, false).isSome
    # A glob-like path must not match a different path via reinterpretation.
    let starRule = parseIgnoreRules(literalIgnoreRule("note*.md"), "probe")
    check isPathIgnored(@[], starRule, "note-other.md", false).isNone

suite "facet scanner":
  test "snapshot rejects changed file types":
    let root = createTempDir("facet-snapshot-", "")
    defer: removeDir(root)
    writeFile(root / "changing", "regular")
    require "changing" in iterTrackedFiles(root)
    discard snapshotRegularFile(root, "changing")
    removeFile(root / "changing")
    require mkfifo((root / "changing").cstring, Mode(0o600)) == 0
    expect ValueError:
      discard snapshotRegularFile(root, "changing")

  test "snapshot rejects a regular path replaced by a symlink":
    let base = createTempDir("facet-snapshot-symlink-", "")
    defer: removeDir(base)
    let root = base / "repo"
    createDir(root)
    writeFile(root / "target", "elsewhere")
    writeFile(root / "changing", "regular")
    discard snapshotRegularFile(root, "changing")
    removeFile(root / "changing")
    createSymlink(root / "target", root / "changing")
    expect ValueError:
      discard snapshotRegularFile(root, "changing")

suite "facet values":
  test "typed values retain canonical representations":
    for sample in [("string", "", ""), ("integer", "03", "3"),
                   ("boolean", "YES", "true"), ("real", "3", "3.0")]:
      let definition = AttributeDef(name: "sample", kind: parseAttributeKind(
          sample[0]))
      let value = parseAttributeValue(definition, sample[1])
      check canonicalText(value) == sample[2]
