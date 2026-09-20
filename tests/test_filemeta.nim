import std/[json, os, osproc, posix, strutils, tempfiles, unittest]
import nim_sqlite

let filemetaExe = getCurrentDir() / "filemeta"

proc shellQuote(arg: string): string =
  "'" & arg.replace("'", "'\"'\"'") & "'"

proc runFilemeta(args: varargs[string]): tuple[output: string, exitCode: int] =
  var cmd = shellQuote(filemetaExe)
  for arg in args:
    cmd.add " "
    cmd.add shellQuote(arg)
  let (stdoutText, errCode) = execCmdEx(cmd)
  result.output = stdoutText.strip()
  result.exitCode = errCode

proc summaryCount(output, field: string): int =
  for line in output.splitLines():
    if line.startsWith(field & ":"):
      return parseInt(line.split(':')[1].strip())
  raise newException(ValueError, "missing scan counter: " & field & " in " & output)

proc legacyCatalogue(root: string): DbConn =
  createDir(root / ".filemeta")
  result = openDatabase(root / ".filemeta" / "catalogue.db")
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

suite "filemeta CLI":
  test "renames, swaps, disappearance and reappearance preserve identity":
    let base = createTempDir("filemeta-moves-", "")
    defer: removeDir(base)
    let root = base / "repo"
    createDir(root)
    writeFile(root / "a.file", "first")
    writeFile(root / "b.file", "second")
    require runFilemeta("scan", root).exitCode == 0
    require runFilemeta("taxonomy", "add", "note", "string", root).exitCode == 0
    require runFilemeta("set", "a.file", "note", "first identity", root).exitCode == 0
    require runFilemeta("set", "b.file", "note", "second identity", root).exitCode == 0
    let db = openDatabase(root / ".filemeta" / "catalogue.db")
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
    let base = createTempDir("filemeta-scan-failure-", "")
    defer: removeDir(base)
    let root = base / "repo"
    createDir(root / "sub")
    writeFile(root / "sub" / "a.file", "hello")
    require runFilemeta("scan", root).exitCode == 0
    createDir(root / ".filemeta" / "hidden")
    writeFile(root / ".filemeta" / "hidden" / "private", "ignored")
    createSymlink(base, root / "linked-tree")
    let db = openDatabase(root / ".filemeta" / "catalogue.db")
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

  test "set-time registration respects replacement and hard-link identities":
    let base = createTempDir("filemeta-register-", "")
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
    let db = openDatabase(root / ".filemeta" / "catalogue.db")
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
    let root = createTempDir("filemeta-migration-", "")
    defer: removeDir(root)
    let db = legacyCatalogue(root)
    defer: db.close()
    let tables = @["files", "attribute_definitions", "enum_values", "attribute_values", "attribute_history"]
    var before: seq[seq[ResultRow]]
    for table in tables:
      before.add db.all("SELECT * FROM " & table & " ORDER BY rowid")
    let response = runFilemeta("status", root)
    checkpoint response.output
    require response.exitCode == 0
    check db.all("PRAGMA user_version")[0][0].fromDb(int) == 2
    for index, table in tables:
      check db.all("SELECT * FROM " & table & " ORDER BY rowid") == before[index]
    check db.all("PRAGMA foreign_key_check").len == 0
    check db.all("SELECT name FROM sqlite_master WHERE name = 'custom_size'").len == 1
    check db.all("PRAGMA foreign_key_list(attribute_values)")[1][2].fromDb(string) == "files"
    db.exec("UPDATE files SET state = 'MISSING' WHERE id = 7")
    db.exec("INSERT INTO files(path, device, inode, size, mtime_ns, first_seen, last_seen) VALUES('a.file', 11, 99, 1, 1, 1, 1)")
    expect SqliteError:
      db.exec("INSERT INTO files(path, device, inode, size, mtime_ns, first_seen, last_seen) VALUES('a.file', 11, 100, 1, 1, 1, 1)")
    expect SqliteError:
      db.exec("INSERT INTO files(path, device, inode, size, mtime_ns, first_seen, last_seen) VALUES('other', 11, 99, 1, 1, 1, 1)")

  test "failed migration rolls back schema and data, future versions are rejected":
    let root = createTempDir("filemeta-migration-fail-", "")
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
    check db.all("PRAGMA user_version")[0][0].fromDb(int) == 2
    db.exec("PRAGMA user_version = 99")
    check runFilemeta("status", root).exitCode != 0
    check db.all("PRAGMA user_version")[0][0].fromDb(int) == 99
    check db.all("SELECT * FROM files ORDER BY id") == filesBefore

  test "replacement retains old identity and does not inherit metadata":
    let base = createTempDir("filemeta-replace-", "")
    defer: removeDir(base)
    let root = base / "repo"
    createDir(root)
    writeFile(root / "a.file", "old")
    writeFile(base / "replacement", "new identity")
    require runFilemeta("init", root).exitCode == 0
    require runFilemeta("taxonomy", "add", "note", "string", root).exitCode == 0
    require runFilemeta("set", "a.file", "note", "old metadata", root).exitCode == 0
    let db = openDatabase(root / ".filemeta" / "catalogue.db")
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
    check db.all("SELECT state FROM files WHERE id = ?", oldId)[0][0].fromDb(string) == "MISSING"
    check db.all("SELECT COUNT(*) FROM files WHERE path = 'a.file'")[0][0].fromDb(int) == 2
    check db.all("SELECT * FROM attribute_history ORDER BY id") == oldHistory
    check parseJson(runFilemeta("get", "a.file", "--json", root).output)["attributes"].len == 0
    check runFilemeta("history", "a.file", root).output == ""
    require runFilemeta("set", "a.file", "note", "new metadata", root).exitCode == 0
    moveFile(root / "a.file", base / "new")
    require runFilemeta("scan", root).exitCode == 0
    check "new metadata" in runFilemeta("get", "a.file", root).output
    check "old metadata" notin runFilemeta("history", "a.file", root).output
    db.exec("UPDATE files SET last_seen = 1 WHERE path = 'a.file'")
    check "new metadata" in runFilemeta("get", "a.file", root).output
    check summaryCount(runFilemeta("scan", root).output, "Missing") == 0
    check db.all("PRAGMA foreign_key_check").len == 0

  test "hard links share one stable canonical identity":
    let root = createTempDir("filemeta-links-", "")
    defer: removeDir(root)
    writeFile(root / "b.file", "same identity")
    createHardlink(root / "b.file", root / "a.file")
    let first = runFilemeta("scan", root)
    checkpoint first.output
    require first.exitCode == 0
    check summaryCount(first.output, "Added") == 1
    check summaryCount(first.output, "Scanned") == 1
    let db = openDatabase(root / ".filemeta" / "catalogue.db")
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
    let root = createTempDir("filemeta-atomic-", "")
    defer: removeDir(root)
    writeFile(root / "a.file", "hello")
    writeFile(root / "new.file", "new")
    require runFilemeta("init", root).exitCode == 0
    require runFilemeta("taxonomy", "add", "note", "string", root).exitCode == 0
    require runFilemeta("set", "a.file", "note", "original", root).exitCode == 0
    let db = openDatabase(root / ".filemeta" / "catalogue.db")
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
    let root = createTempDir("filemeta-audit-", "")
    defer: removeDir(root)
    writeFile(root / "a.file", "hello")
    require runFilemeta("init", root).exitCode == 0
    require runFilemeta("taxonomy", "add", "note", "string", root).exitCode == 0
    require runFilemeta("taxonomy", "add", "count", "integer", root).exitCode == 0
    require runFilemeta("taxonomy", "add", "rating", "enum", "RED", "BLUE", root).exitCode == 0
    let db = openDatabase(root / ".filemeta" / "catalogue.db")
    defer: db.close()
    for (attribute, first, canonical, second) in [("note", "", "", "next"), ("count", "03", "3", "4"), ("rating", "RED", "RED", "BLUE")]:
      require runFilemeta("set", "a.file", attribute, first, root).exitCode == 0
      require runFilemeta("set", "a.file", attribute, canonical, root).exitCode == 0
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
    let base = createTempDir("filemeta-paths-", "")
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
    let db = openDatabase(root / ".filemeta" / "catalogue.db")
    defer: db.close()
    for path in [base / "outside", "../outside", base / "repo-sibling" / "outside", "link", "linked-dir/outside", "inside-link"]:
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
    check parseJson(runFilemeta("get", "back\\slash", "--json", root).output)["path"].getStr == "back\\slash"

  test "opening commands do not create a catalogue":
    let root = createTempDir("filemeta-no-catalogue-", "")
    defer: removeDir(root)
    writeFile(root / "a.file", "hello")
    for command in ["get", "history"]:
      check runFilemeta(command, "a.file", root).exitCode != 0
      check not dirExists(root / ".filemeta")
    for command in ["status", "list"]:
      check runFilemeta(command, root).exitCode != 0
      check not dirExists(root / ".filemeta")
    check runFilemeta("find", "note == x", root).exitCode != 0
    check runFilemeta("taxonomy", "list", root).exitCode != 0
    check runFilemeta("set", "a.file", "note", "x", root).exitCode != 0
    check runFilemeta("unset", "a.file", "note", root).exitCode != 0
    check not dirExists(root / ".filemeta")

  test "query truth tables, precedence, literals and malformed input":
    let root = createTempDir("filemeta-logic-", "")
    defer: removeDir(root)
    require runFilemeta("init", root).exitCode == 0
    for attribute in ["left", "right", "third", "note", "weight"]:
      require runFilemeta("taxonomy", "add", attribute, "string", root).exitCode == 0
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
    for expression in ["weight>=3", "weight<=3", "weight>2", "weight<4", "weight!=4", "weight==3"]:
      expectQuery(expression, @["tt"])
    for expression in ["", "note", "note ==", "note = x", "note === x", "note <> x", "note == x and", "note == x xor note == y", "note == x note == y", "note == \"unterminated", "note == \"bad\\q\"", "note == and", "note == \"x\"junk", "== x y", "note == x or or note == y"]:
      let response = runFilemeta("find", expression, root)
      check response.exitCode != 0
      check "Error:" in response.output

  test "JSON strings round trip without changing field types":
    let root = createTempDir("filemeta-json-", "")
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
    let root = createTempDir("filemeta-bounds-", "")
    defer: removeDir(root)
    writeFile(root / "a.file", "hello")
    require runFilemeta("init", root).exitCode == 0
    let db = openDatabase(root / ".filemeta" / "catalogue.db")
    defer: db.close()
    for kind in ["integer", "real"]:
      require runFilemeta("taxonomy", "add", kind, kind, root).exitCode == 0
      let bounds = db.all("SELECT min_value, max_value FROM attribute_definitions WHERE name = ?", kind)[0]
      check bounds[0].kind == sqliteNull
      check bounds[1].kind == sqliteNull
      for value in ["-3", "3"]:
        check runFilemeta("set", "a.file", kind, value, root).exitCode == 0
    require runFilemeta("taxonomy", "add", "minimum", "real", "--min", "0", root).exitCode == 0
    require runFilemeta("taxonomy", "add", "maximum", "integer", "--max", "0", root).exitCode == 0
    require runFilemeta("taxonomy", "add", "zero", "integer", "--min", "0", "--max", "0", root).exitCode == 0
    check db.all("SELECT min_value, max_value FROM attribute_definitions WHERE name = 'minimum'")[0][1].kind == sqliteNull
    check db.all("SELECT min_value, max_value FROM attribute_definitions WHERE name = 'maximum'")[0][0].kind == sqliteNull
    check runFilemeta("set", "a.file", "minimum", "3.5", root).exitCode == 0
    check runFilemeta("set", "a.file", "minimum", "-1", root).exitCode != 0
    check runFilemeta("set", "a.file", "maximum", "-3", root).exitCode == 0
    check runFilemeta("set", "a.file", "maximum", "1", root).exitCode != 0
    check runFilemeta("set", "a.file", "zero", "0", root).exitCode == 0
    check runFilemeta("set", "a.file", "zero", "1", root).exitCode != 0
    check runFilemeta("set", "a.file", "zero", "-1", root).exitCode != 0

  test "repository initialisation and scan":
    let base = createTempDir("filemeta-init-", "")
    defer: removeDir(base)
    let root = base / "repo"
    createDir(root)
    writeFile(root / "a.file", "hello")

    let initRes = runFilemeta("init", root)
    check initRes.exitCode == 0
    check dirExists(root / ".filemeta")

    let scanRes = runFilemeta("scan", root)
    check scanRes.exitCode == 0
    check "Scanned:" in scanRes.output

  test "taxonomy validation and metadata assignment":
    let base = createTempDir("filemeta-tax-", "")
    defer: removeDir(base)
    let root = base / "repo"
    createDir(root)
    writeFile(root / "a.file", "hello")

    discard runFilemeta("init", root)
    discard runFilemeta("taxonomy", "add", "rating", "enum", "RED", "GREEN", "BLUE", root)
    discard runFilemeta("taxonomy", "add", "weight", "integer", "--min", "0", "--max", "5", root)

    let setOk = runFilemeta("set", root / "a.file", "rating", "BLUE", root)
    check setOk.exitCode == 0

    let badEnum = runFilemeta("set", root / "a.file", "rating", "PURPLE", root)
    check badEnum.exitCode != 0

    let setWeight = runFilemeta("set", root / "a.file", "weight", "3", root)
    check setWeight.exitCode == 0

    let badWeight = runFilemeta("set", root / "a.file", "weight", "99", root)
    check badWeight.exitCode != 0

  test "history and query filter":
    let base = createTempDir("filemeta-query-", "")
    defer: removeDir(base)
    let root = base / "repo"
    createDir(root)
    writeFile(root / "a.file", "hello")

    discard runFilemeta("init", root)
    discard runFilemeta("taxonomy", "add", "rating", "enum", "RED", "GREEN", "BLUE", root)
    discard runFilemeta("taxonomy", "add", "weight", "integer", "--min", "0", "--max", "5", root)
    discard runFilemeta("set", root / "a.file", "rating", "BLUE", root)
    discard runFilemeta("set", root / "a.file", "weight", "3", root)

    let historyRes = runFilemeta("history", root / "a.file", root)
    check historyRes.exitCode == 0
    check "rating" in historyRes.output or "weight" in historyRes.output

    let findRes = runFilemeta("find", "rating == \"BLUE\" and weight >= 3", root)
    check findRes.exitCode == 0
    check "a.file" in findRes.output
