import std/[json, options, os, posix, strutils]
import nim_sqlite
import ./database
import ./taxonomy

proc decodeDbValue*(def: AttributeDef, value: DbValue): string =
  case def.kind
  of "string":
    if value.kind == sqliteNull: "" else: value.fromDb(string)
  of "integer":
    if value.kind == sqliteNull: "" else: $value.fromDb(int64)
  of "real":
    if value.kind == sqliteNull: "" else: $value.fromDb(float64)
  of "boolean":
    if value.kind == sqliteNull:
      ""
    else:
      if value.fromDb(int64) == 1: "true" else: "false"
  else:
    if value.kind == sqliteNull: "" else: value.fromDb(string)

proc decodeAttributeRow*(def: AttributeDef, row: ResultRow): string =
  case def.kind
  of "string":
    if row[0].kind == sqliteNull: "" else: row[0].fromDb(string)
  of "integer":
    if row[1].kind == sqliteNull: "" else: $row[1].fromDb(int64)
  of "real":
    if row[2].kind == sqliteNull: "" else: $row[2].fromDb(float64)
  of "boolean":
    if row[3].kind == sqliteNull:
      ""
    else:
      if row[3].fromDb(int64) == 1: "true" else: "false"
  else:
    if row[0].kind == sqliteNull: "" else: row[0].fromDb(string)

proc resolveFileId*(db: DbConn, root: string, filePath: string,
    register: bool = false): int =
  let rel = normalizeRelativePath(root, filePath)
  let record = queryFileByPath(db, rel)
  if not register and record.isSome:
    return record.get.id
  let full = root / rel
  var info: Stat
  if lstat(full.cstring, info) == 0:
    if not S_ISREG(info.st_mode):
      raise newException(ValueError, "not a regular file: " & rel)
    let device = cast[uint64](info.st_dev)
    let inode = cast[uint64](info.st_ino)
    let identity = queryFileBySignature(db, device, inode)
    if not register:
      if identity.isSome:
        return identity.get.id
    else:
      if record.isSome and (record.get.device != device or record.get.inode != inode):
        markMissing(db, record.get.id)
      let now = utcNowNs()
      let mtimeNs = int64(info.st_mtim.tv_sec) * 1_000_000_000'i64 + int64(
          info.st_mtim.tv_nsec)
      if identity.isSome:
        let previous = identity.get
        var canonicalInfo: Stat
        var canonical = rel
        let canonicalFull = root / previous.path
        if lstat(canonicalFull.cstring, canonicalInfo) == 0 and S_ISREG(
          canonicalInfo.st_mode) and cast[uint64](canonicalInfo.st_dev) ==
                device and cast[uint64](canonicalInfo.st_ino) == inode:
          canonical = previous.path
        updateFileRecord(db, previous.id, canonical, info.st_size, mtimeNs, now)
        return previous.id
      return insertFileRecord(db, rel, device, inode, info.st_size, mtimeNs,
          now, now)
  elif register and osLastError().int notin [ENOENT.int, ENOTDIR.int]:
    raiseOSError(osLastError(), full)
  if record.isSome:
    return record.get.id
  raise newException(ValueError, "file not found in catalogue: " & rel)

proc setAttribute*(db: DbConn, root: string, filePath: string,
    attributeName: string, rawValue: string) =
  db.transaction:
    let defOpt = fetchAttributeDef(db, attributeName)
    if defOpt.isNone:
      raise newException(ValueError, "attribute not found: " & attributeName)
    let def = defOpt.get
    let valid = validateAttributeValue(def, rawValue)
    let fileId = resolveFileId(db, root, filePath, register = true)
    let currentRows = db.all("SELECT value_text, value_integer, value_real, value_boolean FROM attribute_values WHERE file_id = ? AND attribute_id = ?",
        fileId, def.id)
    let oldValue = if currentRows.len > 0: some(decodeAttributeRow(def,
        currentRows[0])) else: none(string)
    if oldValue == some(valid):
      return

    db.exec("INSERT INTO attribute_values(file_id, attribute_id, value_text, value_integer, value_real, value_boolean) VALUES(?, ?, ?, ?, ?, ?) ON CONFLICT(file_id, attribute_id) DO UPDATE SET value_text = excluded.value_text, value_integer = excluded.value_integer, value_real = excluded.value_real, value_boolean = excluded.value_boolean",
        fileId, def.id, if def.kind == "string" or def.kind ==
        "enum": valid else: "", if def.kind == "integer": parseInt(
        valid) else: 0, if def.kind == "real": parseFloat(valid) else: 0.0,
        if def.kind == "boolean": (if valid == "true": 1 else: 0) else: 0)
    db.exec("INSERT INTO attribute_history(file_id, attribute_id, old_value, new_value, changed_at) VALUES(?, ?, ?, ?, ?)",
        fileId, def.id, oldValue, valid, utcNowNs())

proc unsetAttribute*(db: DbConn, root: string, filePath: string,
    attributeName: string) =
  db.transaction:
    let defOpt = fetchAttributeDef(db, attributeName)
    if defOpt.isNone:
      raise newException(ValueError, "attribute not found: " & attributeName)
    let def = defOpt.get
    let fileId = resolveFileId(db, root, filePath)
    let currentRows = db.all("SELECT value_text, value_integer, value_real, value_boolean FROM attribute_values WHERE file_id = ? AND attribute_id = ?",
        fileId, def.id)
    if currentRows.len == 0:
      raise newException(ValueError, "attribute not set: " & attributeName)
    let oldValue = decodeAttributeRow(def, currentRows[0])
    db.exec("DELETE FROM attribute_values WHERE file_id = ? AND attribute_id = ?",
        fileId, def.id)
    db.exec("INSERT INTO attribute_history(file_id, attribute_id, old_value, new_value, changed_at) VALUES(?, ?, ?, ?, ?)",
        fileId, def.id, oldValue, none(string), utcNowNs())

proc fileAttributes*(db: DbConn, fileId: int): seq[tuple[name: string,
    value: string]] =
  let rows = db.all("SELECT ad.name, ad.type, av.value_text, av.value_integer, av.value_real, av.value_boolean FROM attribute_values av JOIN attribute_definitions ad ON ad.id = av.attribute_id WHERE av.file_id = ? ORDER BY ad.name", fileId)
  for row in rows:
    let def = (row[0].fromDb(string), row[1].fromDb(string))
    var value = ""
    case def[1]
    of "string":
      if row[2].kind == sqliteNull: value = "" else: value = row[2].fromDb(string)
    of "integer":
      if row[3].kind == sqliteNull: value = "" else: value = $row[3].fromDb(int64)
    of "real":
      if row[4].kind == sqliteNull: value = "" else: value = $row[4].fromDb(float64)
    of "boolean":
      if row[5].kind == sqliteNull:
        value = ""
      else:
        value = if row[5].fromDb(int64) == 1: "true" else: "false"
    else:
      if row[2].kind == sqliteNull: value = "" else: value = row[2].fromDb(string)
    result.add((def[0], value))

proc printFileDetails*(db: DbConn, root: string, filePath: string,
    jsonMode: bool = false): string =
  let fileId = resolveFileId(db, root, filePath)
  let fileRows = db.all("SELECT path, size, mtime_ns, state FROM files WHERE id = ?", fileId)
  if fileRows.len == 0:
    raise newException(ValueError, "file not found: " & filePath)
  let row = fileRows[0]
  let attrs = fileAttributes(db, fileId)
  let path = row[0].fromDb(string)
  let state = row[3].fromDb(string)
  let size = row[1].fromDb(int64)
  let modTime = row[2].fromDb(int64)
  if jsonMode:
    var attributes = newJObject()
    for kv in attrs:
      attributes[kv.name] = %kv.value
    result = $(%*{"path": path, "state": state, "size": size,
      "modified": modTime, "attributes": attributes})
  else:
    result = "Path:      " & path & "\n" &
      "State:     " & state & "\n" &
      "Size:      " & $size & "\n" &
      "Modified:  " & $modTime & "\n\n" &
      "Attributes:\n"
    if attrs.len == 0:
      result &= "  (none)\n"
    else:
      for kv in attrs:
        result &= "  " & kv.name & ": " & kv.value & "\n"

proc getHistory*(db: DbConn, filePath: string, attributeName: string = "",
    root: string = ""): seq[tuple[attribute: string, oldValue: string,
    newValue: string, changedAt: int64]] =
  var fileId: int
  if root.len > 0:
    fileId = resolveFileId(db, root, filePath)
  else:
    let record = queryFileByPath(db, filePath)
    if record.isNone:
      raise newException(ValueError, "file not found in catalogue: " & filePath)
    fileId = record.get.id
  var sql = "SELECT ad.name, ah.old_value, ah.new_value, ah.changed_at FROM attribute_history ah JOIN attribute_definitions ad ON ad.id = ah.attribute_id WHERE ah.file_id = ?"
  var params: seq[DbValue] = @[toDb(fileId)]
  if attributeName.len > 0:
    sql &= " AND ad.name = ?"
    params.add DbValue(kind: sqliteText, strVal: attributeName)
  sql &= " ORDER BY ah.changed_at DESC, ah.id DESC"
  for row in db.all(sql, params):
    let oldv = if row[1].kind == sqliteNull: "" else: row[1].fromDb(string)
    let newv = if row[2].kind == sqliteNull: "" else: row[2].fromDb(string)
    result.add((row[0].fromDb(string), oldv, newv, row[3].fromDb(int64)))
