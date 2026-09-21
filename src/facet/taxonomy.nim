import std/[options, strutils]
import nim_sqlite
import ./database

type AttributeDef* = tuple[
  id: int,
  name: string,
  kind: string,
  required: bool,
  description: string,
  minValue: Option[float],
  maxValue: Option[float],
  allowed: seq[string]
]

proc fetchAttributeDef*(db: DbConn, name: string): Option[AttributeDef] =
  let rows = db.all("SELECT id, name, type, required, description, min_value, max_value FROM attribute_definitions WHERE name = ?", name)
  if rows.len == 0:
    return none(AttributeDef)
  let row = rows[0]
  var allowed: seq[string] = @[]
  let enumRows = db.all("SELECT value FROM enum_values WHERE attribute_id = ? ORDER BY value",
      row[0].fromDb(int))
  for r in enumRows:
    allowed.add r[0].fromDb(string)

  let minv = if row[5].kind == sqliteNull: none(float) else: some(row[5].fromDb(float))
  let maxv = if row[6].kind == sqliteNull: none(float) else: some(row[6].fromDb(float))
  result = some((row[0].fromDb(int), row[1].fromDb(string), row[2].fromDb(
      string), row[3].fromDb(int) == 1, row[4].fromDb(string), minv, maxv, allowed))

proc listTaxonomy*(db: DbConn): seq[tuple[name: string, kind: string,
    values: seq[string]]] =
  let rows = db.all("SELECT id, name, type FROM attribute_definitions ORDER BY name")
  for row in rows:
    let id = row[0].fromDb(int)
    var allowed: seq[string] = @[]
    for enumRow in db.all("SELECT value FROM enum_values WHERE attribute_id = ? ORDER BY value", id):
      allowed.add enumRow[0].fromDb(string)
    result.add((row[1].fromDb(string), row[2].fromDb(string), allowed))

proc addTaxonomyAttribute*(db: DbConn, name: string, kind: string, values: seq[
    string] = @[], minValue: Option[float] = none(float), maxValue: Option[
    float] = none(float)) =
  let norm = name.strip()
  if norm.len == 0:
    raise newException(ValueError, "taxonomy name cannot be empty")
  if kind notin ["string", "integer", "real", "boolean", "enum"]:
    raise newException(ValueError, "unsupported taxonomy type: " & kind)
  if kind == "enum" and values.len == 0:
    raise newException(ValueError, "enum attributes require values")
  if minValue.isSome and maxValue.isSome and minValue.get > maxValue.get:
    raise newException(ValueError, "minimum cannot exceed maximum")

  if db.value("SELECT 1 FROM attribute_definitions WHERE name = ?", norm).isSome:
    raise newException(ValueError, "taxonomy attribute already exists: " & norm)

  db.exec("INSERT INTO attribute_definitions(name, type, required, description, min_value, max_value) VALUES(?, ?, 0, '', ?, ?)",
      norm, kind, minValue, maxValue)
  let id = db.value("SELECT id FROM attribute_definitions WHERE name = ?",
      norm).get.fromDb(int)
  if kind == "enum":
    for value in values:
      db.exec("INSERT INTO enum_values(attribute_id, value) VALUES(?, ?)", id, value)

proc removeTaxonomyAttribute*(db: DbConn, name: string) =
  if db.value("SELECT 1 FROM attribute_definitions WHERE name = ?", name).isNone:
    raise newException(ValueError, "attribute definition not found: " & name)
  db.exec("DELETE FROM attribute_definitions WHERE name = ?", name)

proc validateAttributeValue*(def: AttributeDef, raw: string): string =
  case def.kind
  of "string":
    result = raw
  of "integer":
    try:
      let v = parseInt(raw)
      if def.minValue.isSome and float(v) <
          def.minValue.get: raise newException(ValueError, "integer below minimum")
      if def.maxValue.isSome and float(v) >
          def.maxValue.get: raise newException(ValueError, "integer above maximum")
      result = $v
    except ValueError:
      raise newException(ValueError, "expected integer for " & def.name)
  of "real":
    try:
      let v = parseFloat(raw)
      if def.minValue.isSome and v < def.minValue.get: raise newException(
          ValueError, "real below minimum")
      if def.maxValue.isSome and v > def.maxValue.get: raise newException(
          ValueError, "real above maximum")
      result = $v
    except ValueError:
      raise newException(ValueError, "expected real for " & def.name)
  of "boolean":
    let lower = raw.toLowerAscii()
    if lower in ["true", "1", "yes", "on"]: result = "true"
    elif lower in ["false", "0", "no", "off"]: result = "false"
    else: raise newException(ValueError, "expected boolean for " & def.name)
  of "enum":
    if raw notin def.allowed:
      raise newException(ValueError, "invalid value for " & def.name & ": " & raw)
    result = raw
  else:
    result = raw
