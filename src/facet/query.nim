import std/[json, options, sets, strutils, tables]
import nim_sqlite
import ./database
import ./metadata
import ./taxonomy

type
  QueryOperator* = enum
    qoEqual, qoNotEqual, qoLess, qoLessEqual, qoGreater, qoGreaterEqual
  QueryLogic* = enum
    qlEnd, qlAnd, qlOr
  QueryClause* = object
    attribute*: string
    operator*: QueryOperator
    expected*: string
    nextLogic*: QueryLogic

const operatorTokens = [
  qoEqual: "==",
  qoNotEqual: "!=",
  qoLess: "<",
  qoLessEqual: "<=",
  qoGreater: ">",
  qoGreaterEqual: ">=",
]

func parseQueryOperator(token: string): QueryOperator =
  for op, text in operatorTokens:
    if text == token:
      return op
  raise newException(ValueError, "unsupported query operator: " & token)

func parseQueryLogic(token: string): QueryLogic =
  case token.toLowerAscii()
  of "and": qlAnd
  of "or": qlOr
  else: raise newException(ValueError, "expected AND or OR: " & token)

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

proc parseQueryClauses*(expr: string): seq[QueryClause] =
  ## Parses a `facet find` expression left-to-right into typed clauses.
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
    let operator = parseQueryOperator(tokens[position + 1])
    var value = tokens[position + 2]
    if value.startsWith('"'):
      value = parseJson(value).getStr()
    elif value.toLowerAscii() in ["and", "or"] or value.contains({'=', '!', '<', '>'}):
      raise newException(ValueError, "expected query operand")
    position += 3
    var logic = qlEnd
    if position < tokens.len:
      logic = parseQueryLogic(tokens[position])
      inc position
      if position == tokens.len:
        raise newException(ValueError, "missing comparison after " &
            tokens[position - 1])
    result.add QueryClause(attribute: attr, operator: operator,
        expected: value, nextLogic: logic)

proc parseQuery*(expr: string): seq[tuple[attr: string, op: string,
    value: string, logic: string]] =
  ## String-tuple adapter retained for compatibility.
  for clause in parseQueryClauses(expr):
    let logic = case clause.nextLogic
      of qlEnd: ""
      of qlAnd: "and"
      of qlOr: "or"
    result.add((clause.attribute, operatorTokens[clause.operator],
        clause.expected, logic))

proc compareValues*(actual: string, op: QueryOperator, expected: string): bool =
  case op
  of qoEqual:
    return actual == expected
  of qoNotEqual:
    return actual != expected
  else:
    discard

  var actualInt, expectedInt: BiggestInt
  var actualIsInt = true
  var expectedIsInt = true
  try:
    actualInt = parseBiggestInt(actual)
  except ValueError:
    actualIsInt = false
  try:
    expectedInt = parseBiggestInt(expected)
  except ValueError:
    expectedIsInt = false

  var comparison: int
  if actualIsInt and expectedIsInt:
    comparison = cmp(actualInt, expectedInt)
  elif actualIsInt:
    var expectedFloat: float64
    try:
      expectedFloat = parseFloat(expected)
    except ValueError:
      return false
    if not isFiniteNumber(expectedFloat):
      return false
    comparison = compareIntegerToReal(int64(actualInt), expectedFloat)
  elif expectedIsInt:
    var actualFloat: float64
    try:
      actualFloat = parseFloat(actual)
    except ValueError:
      return false
    if not isFiniteNumber(actualFloat):
      return false
    comparison = -compareIntegerToReal(int64(expectedInt), actualFloat)
  else:
    var actualFloat, expectedFloat: float64
    try:
      actualFloat = parseFloat(actual)
      expectedFloat = parseFloat(expected)
    except ValueError:
      return false
    if not isFiniteNumber(actualFloat) or not isFiniteNumber(expectedFloat):
      return false
    comparison = cmp(actualFloat, expectedFloat)

  case op
  of qoLess: comparison < 0
  of qoLessEqual: comparison <= 0
  of qoGreater: comparison > 0
  of qoGreaterEqual: comparison >= 0
  else: false

proc loadRequestedAttributes(db: DbConn,
    names: HashSet[string]): Table[int, Table[string, string]] =
  ## Loads every attribute value for every file in one query, retaining only
  ## the attributes named in `names`, keyed by `fileId -> attrName -> canonical
  ## text`. This is one SELECT regardless of file/clause count, at the cost of
  ## visiting every stored attribute_values row once; see design.md for the
  ## memory/read tradeoff.
  result = initTable[int, Table[string, string]]()
  for row in db.iterate("SELECT av.file_id, ad.name, ad.type, av.value_text, av.value_integer, av.value_real, av.value_boolean FROM attribute_values av JOIN attribute_definitions ad ON ad.id = av.attribute_id ORDER BY av.file_id, ad.name"):
    let name = row[1].fromDb(string)
    if name notin names:
      continue
    let fileId = row[0].fromDb(int)
    let kind = parseAttributeKind(row[2].fromDb(string))
    let columns: AttributeColumns = (row[3], row[4], row[5], row[6])
    let valueOpt = decodeAttributeValue(kind, columns)
    if valueOpt.isSome:
      result.mgetOrPut(fileId, initTable[string, string]())[name] =
        canonicalText(valueOpt.get)

proc findFilesForExpression*(db: DbConn, expr: string): seq[string] =
  let clauses = parseQueryClauses(expr)
  if clauses.len == 0:
    return @[]

  var names = initHashSet[string]()
  for clause in clauses:
    names.incl clause.attribute

  var files: seq[tuple[id: int, path: string]]
  var attributesByFile: Table[int, Table[string, string]]
  db.transaction:
    for row in db.iterate("SELECT id, path FROM files ORDER BY path"):
      files.add (id: row[0].fromDb(int), path: row[1].fromDb(string))
    attributesByFile = loadRequestedAttributes(db, names)

  for file in files:
    let attrs = attributesByFile.getOrDefault(file.id, initTable[string,
        string]())
    var matches = false
    var groupMatches = true
    for clause in clauses:
      let actualOpt = attrs.hasKey(clause.attribute)
      let current = actualOpt and compareValues(attrs[clause.attribute],
          clause.operator, clause.expected)
      groupMatches = groupMatches and current
      if clause.nextLogic in [qlOr, qlEnd]:
        matches = matches or groupMatches
        groupMatches = true
    if matches:
      result.add file.path
