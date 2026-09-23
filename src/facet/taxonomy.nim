import std/[math, options, sets, strutils]
import nim_sqlite
import ./database

func isFiniteNumber*(value: float64): bool =
  classify(value) notin {fcNan, fcInf, fcNegInf}

type
  AttributeKind* = enum
    akString, akInteger, akReal, akBoolean, akEnum

  AttributeValue* = object
    case kind*: AttributeKind
    of akString, akEnum:
      text*: string
    of akInteger:
      integer*: int64
    of akReal:
      real*: float64
    of akBoolean:
      boolean*: bool

const kindNames = [
  akString: "string",
  akInteger: "integer",
  akReal: "real",
  akBoolean: "boolean",
  akEnum: "enum",
]

func kindText*(kind: AttributeKind): string =
  ## Storage vocabulary for `attribute_definitions.type`; explicit mapping so
  ## a future enum reordering cannot silently change persisted strings.
  kindNames[kind]

func parseAttributeKind*(text: string): AttributeKind =
  for kind, name in kindNames:
    if name == text:
      return kind
  raise newException(ValueError, "unsupported taxonomy type: " & text)

func canonicalText*(value: AttributeValue): string =
  case value.kind
  of akString, akEnum: value.text
  of akInteger: $value.integer
  of akReal: $value.real
  of akBoolean: (if value.boolean: "true" else: "false")

func compareIntegerToReal*(actual: int64, expected: float64): int =
  ## Compares an exact int64 against a float64 bound/operand without
  ## rounding `actual` to float first, so large integers keep full precision.
  if not isFiniteNumber(expected):
    raise newException(ValueError, "non-finite numeric operand")
  if expected >= 9223372036854775808.0:
    return -1
  if expected < -9223372036854775808.0:
    return 1
  let truncated = int64(expected)
  if actual != truncated:
    return (if actual < truncated: -1 else: 1)
  let truncatedFloat = float64(truncated)
  if truncatedFloat == expected: 0
  elif truncatedFloat < expected: -1
  else: 1

type AttributeDef* = object
  id*: int
  name*: string
  kind*: AttributeKind
  required*: bool
  description*: string
  minValue*: Option[float]
  maxValue*: Option[float]
  integerMin*: Option[int64]
  integerMax*: Option[int64]
  allowed*: seq[string]

proc fetchAttributeDef*(db: DbConn, name: string): Option[AttributeDef] =
  let rows = db.all("SELECT id, name, type, required, description, min_value, max_value, min_integer, max_integer FROM attribute_definitions WHERE name = ?", name)
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
  let intMin = if row[7].kind == sqliteNull: none(int64) else: some(row[
      7].fromDb(int64))
  let intMax = if row[8].kind == sqliteNull: none(int64) else: some(row[
      8].fromDb(int64))
  result = some(AttributeDef(
    id: row[0].fromDb(int),
    name: row[1].fromDb(string),
    kind: parseAttributeKind(row[2].fromDb(string)),
    required: row[3].fromDb(int) == 1,
    description: row[4].fromDb(string),
    minValue: minv, maxValue: maxv,
    integerMin: intMin, integerMax: intMax,
    allowed: allowed))

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
    float] = none(float), integerMin: Option[int64] = none(int64),
    integerMax: Option[int64] = none(int64)) =
  let norm = name.strip()
  if norm.len == 0:
    raise newException(ValueError, "taxonomy name cannot be empty")
  let parsedKind =
    try:
      parseAttributeKind(kind)
    except ValueError:
      raise newException(ValueError, "unsupported taxonomy type: " & kind)
  if parsedKind == akEnum and values.len == 0:
    raise newException(ValueError, "enum attributes require values")
  if parsedKind == akEnum:
    var uniqueValues = initHashSet[string]()
    for value in values:
      if value in uniqueValues:
        raise newException(ValueError, "duplicate enum value: " & value)
      uniqueValues.incl value
  if minValue.isSome and not isFiniteNumber(minValue.get):
    raise newException(ValueError, "minimum must be finite")
  if maxValue.isSome and not isFiniteNumber(maxValue.get):
    raise newException(ValueError, "maximum must be finite")
  if minValue.isSome and maxValue.isSome and minValue.get > maxValue.get:
    raise newException(ValueError, "minimum cannot exceed maximum")
  if minValue.isSome and integerMin.isSome:
    raise newException(ValueError, "cannot specify both integer and real minimum bounds")
  if maxValue.isSome and integerMax.isSome:
    raise newException(ValueError, "cannot specify both integer and real maximum bounds")
  if integerMin.isSome and integerMax.isSome and integerMin.get >
      integerMax.get:
    raise newException(ValueError, "minimum cannot exceed maximum")

  db.transaction:
    if db.value("SELECT 1 FROM attribute_definitions WHERE name = ?", norm).isSome:
      raise newException(ValueError, "taxonomy attribute already exists: " & norm)

    db.exec("INSERT INTO attribute_definitions(name, type, required, description, min_value, max_value, min_integer, max_integer) VALUES(?, ?, 0, '', ?, ?, ?, ?)",
        norm, kindText(parsedKind), minValue, maxValue, integerMin, integerMax)
    let id = db.value("SELECT id FROM attribute_definitions WHERE name = ?",
        norm).get.fromDb(int)
    if parsedKind == akEnum:
      for value in values:
        db.exec("INSERT INTO enum_values(attribute_id, value) VALUES(?, ?)", id, value)

proc removeTaxonomyAttribute*(db: DbConn, name: string) =
  if db.value("SELECT 1 FROM attribute_definitions WHERE name = ?", name).isNone:
    raise newException(ValueError, "attribute definition not found: " & name)
  db.exec("DELETE FROM attribute_definitions WHERE name = ?", name)

proc parseAttributeValue*(def: AttributeDef, raw: string): AttributeValue =
  case def.kind
  of akString:
    AttributeValue(kind: akString, text: raw)
  of akInteger:
    let v =
      try:
        parseBiggestInt(raw)
      except ValueError:
        raise newException(ValueError, "expected integer for " & def.name)
    if def.integerMin.isSome:
      if v < def.integerMin.get:
        raise newException(ValueError, "integer below minimum")
    elif def.minValue.isSome and compareIntegerToReal(v, def.minValue.get) < 0:
      raise newException(ValueError, "integer below minimum")
    if def.integerMax.isSome:
      if v > def.integerMax.get:
        raise newException(ValueError, "integer above maximum")
    elif def.maxValue.isSome and compareIntegerToReal(v, def.maxValue.get) > 0:
      raise newException(ValueError, "integer above maximum")
    AttributeValue(kind: akInteger, integer: int64(v))
  of akReal:
    let v =
      try:
        parseFloat(raw)
      except ValueError:
        raise newException(ValueError, "expected real for " & def.name)
    if not isFiniteNumber(v):
      raise newException(ValueError, "expected finite real for " & def.name)
    if def.minValue.isSome and v < def.minValue.get: raise newException(
        ValueError, "real below minimum")
    if def.maxValue.isSome and v > def.maxValue.get: raise newException(
        ValueError, "real above maximum")
    AttributeValue(kind: akReal, real: v)
  of akBoolean:
    let lower = raw.toLowerAscii()
    if lower in ["true", "1", "yes", "on"]:
      AttributeValue(kind: akBoolean, boolean: true)
    elif lower in ["false", "0", "no", "off"]:
      AttributeValue(kind: akBoolean, boolean: false)
    else:
      raise newException(ValueError, "expected boolean for " & def.name)
  of akEnum:
    if raw notin def.allowed:
      raise newException(ValueError, "invalid value for " & def.name & ": " & raw)
    AttributeValue(kind: akEnum, text: raw)

proc validateAttributeValue*(def: AttributeDef, raw: string): string =
  ## Legacy string-in/string-out wrapper retained for callers that only need
  ## the canonical text representation.
  canonicalText(parseAttributeValue(def, raw))
