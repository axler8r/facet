import std/[json, strutils]
import nim_sqlite
import ./database

proc splitQuery*(expr: string): seq[string] =
  var position = 0
  while position < expr.len:
    if expr[position] in Whitespace:
      inc position
      continue
    let start = position
    if expr[position] == '"':
      inc position
      var closed = false
      while position < expr.len:
        if expr[position] == '\\':
          if position + 1 >= expr.len or expr[position + 1] notin {'"', '\\',
              '/', 'b', 'f', 'n', 'r', 't', 'u'}:
            raise newException(ValueError, "invalid query literal escape")
          position += 2
        elif expr[position] == '"':
          inc position
          closed = true
          break
        else:
          if expr[position] < ' ':
            raise newException(ValueError, "query control characters must be escaped")
          inc position
      if not closed:
        raise newException(ValueError, "unterminated query literal")
      if position < expr.len and expr[position] notin Whitespace:
        raise newException(ValueError, "expected whitespace after query literal")
    elif expr[position] in {'=', '!', '<', '>'}:
      while position < expr.len and expr[position] in {'=', '!', '<', '>'}:
        inc position
    else:
      while position < expr.len and expr[position] notin Whitespace + {'=', '!',
          '<', '>', '"'}:
        inc position
    result.add expr[start ..< position]

proc parseQuery*(expr: string): seq[tuple[attr: string, op: string,
    value: string, logic: string]] =
  let tokens = splitQuery(expr)
  if tokens.len == 0:
    raise newException(ValueError, "query expression cannot be empty")
  var position = 0
  while position < tokens.len:
    if position + 2 >= tokens.len:
      raise newException(ValueError, "invalid query expression: " & expr)
    let attr = tokens[position]
    if attr[0] notin Letters + {'_'} or attr.contains(AllChars - Letters -
        Digits - {'_', '.', '-'}):
      raise newException(ValueError, "invalid query attribute: " & attr)
    let op = tokens[position + 1]
    if op notin ["==", "!=", "<", "<=", ">", ">="]:
      raise newException(ValueError, "unsupported query operator: " & op)
    var value = tokens[position + 2]
    if value.startsWith('"'):
      value = parseJson(value).getStr()
    elif value.toLowerAscii() in ["and", "or"] or value.contains({'=', '!', '<', '>'}):
      raise newException(ValueError, "expected query operand")
    position += 3
    var logic = ""
    if position < tokens.len:
      logic = tokens[position].toLowerAscii()
      if logic notin ["and", "or"]:
        raise newException(ValueError, "expected AND or OR: " & tokens[position])
      inc position
      if position == tokens.len:
        raise newException(ValueError, "missing comparison after " & logic)
    result.add((attr, op, value, logic))

proc compareValues*(actual: string, op: string, expected: string): bool =
  try:
    case op
    of "==": actual == expected
    of "!=": actual != expected
    of "<": actual.parseFloat() < expected.parseFloat()
    of "<=": actual.parseFloat() <= expected.parseFloat()
    of ">": actual.parseFloat() > expected.parseFloat()
    of ">=": actual.parseFloat() >= expected.parseFloat()
    else: false
  except ValueError:
    case op
    of "==": actual == expected
    of "!=": actual != expected
    else: false

proc findFilesForExpression*(db: DbConn, expr: string): seq[string] =
  let clauses = parseQuery(expr)
  if clauses.len == 0:
    return @[]

  let rows = db.all("SELECT id, path FROM files ORDER BY path")
  for row in rows:
    let fileId = row[0].fromDb(int)
    let path = row[1].fromDb(string)
    var matches = false
    var groupMatches = true
    for clause in clauses:
      let attrRows = db.all("SELECT ad.name, ad.type, av.value_text, av.value_integer, av.value_real, av.value_boolean FROM attribute_values av JOIN attribute_definitions ad ON ad.id = av.attribute_id WHERE av.file_id = ? AND ad.name = ?",
          fileId, clause.attr)
      var actual = ""
      if attrRows.len > 0:
        let r = attrRows[0]
        let kind = r[1].fromDb(string)
        case kind
        of "string": actual = r[2].fromDb(string)
        of "integer": actual = $r[3].fromDb(int64)
        of "real": actual = $r[4].fromDb(float64)
        of "boolean": actual = if r[5].fromDb(int64) == 1: "true" else: "false"
        of "enum": actual = r[2].fromDb(string)
        else: actual = r[2].fromDb(string)
      let current = attrRows.len > 0 and compareValues(actual, clause.op, clause.value)
      groupMatches = groupMatches and current
      if clause.logic in ["or", ""]:
        matches = matches or groupMatches
        groupMatches = true
    if matches:
      result.add path
