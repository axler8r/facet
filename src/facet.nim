import std/[options, os, strutils]
import ./facet/database
import ./facet/scanner
import ./facet/taxonomy
import ./facet/metadata
import ./facet/query

proc usage() =
  echo "Usage: facet <command> [args]"
  echo "Commands: init [ROOT], scan [ROOT], status [ROOT], get PATH [--json], set PATH ATTRIBUTE VALUE [ROOT], unset PATH ATTRIBUTE [ROOT], taxonomy add NAME TYPE [values] [--min N --max N], taxonomy list, taxonomy show NAME, taxonomy remove NAME, history PATH [ROOT], list [ROOT], find 'EXPRESSION' [ROOT]"

proc commandPath(path: string, explicitRoot: bool): string =
  if explicitRoot: path else: absolutePath(path)

proc initRepo(root: string) =
  let target = if root.len > 0: absolutePath(root) else: getCurrentDir()
  let db = initDatabase(target)
  db.close()
  echo "Initialised: " & target

proc scanRepo(argRoot: string) =
  let root = if argRoot.len > 0: absolutePath(argRoot) else: detectRoot()
  let summary = scanRepository(root)
  stdout.write(scanSummaryText(summary))

proc showStatus(root: string) =
  let target = if root.len > 0: absolutePath(root) else: detectRoot()
  let db = openCatalogue(target)
  defer: db.close()
  echo "Root: " & target
  echo "Files: " & $fileCount(db)

proc doGet(args: seq[string]) =
  if args.len == 0:
    raise newException(ValueError, "get requires a path")
  var jsonMode = false
  var positional: seq[string]
  var root = detectRoot()
  for argument in args:
    if argument == "--json": jsonMode = true
    else: positional.add argument
  if positional.len notin 1 .. 2:
    raise newException(ValueError, "get requires PATH [--json] [ROOT]")
  let explicitRoot = positional.len == 2
  if explicitRoot: root = absolutePath(positional[1])
  let path = commandPath(positional[0], explicitRoot)
  let db = openCatalogue(root)
  defer: db.close()
  echo printFileDetails(db, root, path, jsonMode)

proc doSet(args: seq[string]) =
  if args.len < 3:
    raise newException(ValueError, "set requires PATH ATTRIBUTE VALUE [ROOT]")
  var root = detectRoot()
  let path = commandPath(args[0], args.len >= 4)
  let attribute = args[1]
  let value = args[2]
  if args.len >= 4:
    root = absolutePath(args[3])
  let db = openCatalogue(root)
  defer: db.close()
  setAttribute(db, root, path, attribute, value)
  echo "Updated: " & path & " " & attribute

proc doUnset(args: seq[string]) =
  if args.len < 2:
    raise newException(ValueError, "unset requires PATH ATTRIBUTE [ROOT]")
  var root = detectRoot()
  let path = commandPath(args[0], args.len >= 3)
  let attribute = args[1]
  if args.len >= 3:
    root = absolutePath(args[2])
  let db = openCatalogue(root)
  defer: db.close()
  unsetAttribute(db, root, path, attribute)
  echo "Unset: " & path & " " & attribute

proc doTaxonomy(args: seq[string]) =
  if args.len == 0:
    raise newException(ValueError, "taxonomy requires a subcommand")
  let sub = args[0]
  var root = detectRoot()
  var rest = args[1 .. ^1]
  if rest.len > 0 and dirExists(rest[^1]):
    root = absolutePath(rest[^1])
    rest = rest[0 ..< ^1]
  let db = openCatalogue(root)
  defer: db.close()
  case sub
  of "add":
    if rest.len < 2:
      raise newException(ValueError, "taxonomy add NAME TYPE [VALUES...]")
    let name = rest[0]
    let kind = rest[1]
    var values: seq[string] = @[]
    var minValue: Option[float] = none(float)
    var maxValue: Option[float] = none(float)
    var i = 2
    while i < rest.len:
      let token = rest[i]
      if token == "--min":
        if i + 1 < rest.len: minValue = some(parseFloat(rest[i + 1])); inc i
      elif token == "--max":
        if i + 1 < rest.len: maxValue = some(parseFloat(rest[i + 1])); inc i
      else:
        values.add token
      inc i
    addTaxonomyAttribute(db, name, kind, values, minValue, maxValue)
    echo "Added taxonomy: " & name
  of "list":
    for item in listTaxonomy(db):
      echo item.name & " " & item.kind & " " & item.values.join(", ")
  of "show":
    if rest.len == 0:
      raise newException(ValueError, "taxonomy show NAME")
    let defOpt = fetchAttributeDef(db, rest[0])
    if defOpt.isNone:
      raise newException(ValueError, "attribute not found: " & rest[0])
    let def = defOpt.get
    echo "Name: " & def.name
    echo "Type: " & def.kind
    if def.allowed.len > 0:
      echo "Values: " & def.allowed.join(", ")
    if def.minValue.isSome: echo "Min: " & $def.minValue.get
    if def.maxValue.isSome: echo "Max: " & $def.maxValue.get
  of "remove":
    if rest.len == 0:
      raise newException(ValueError, "taxonomy remove NAME")
    removeTaxonomyAttribute(db, rest[0])
    echo "Removed taxonomy: " & rest[0]
  else:
    raise newException(ValueError, "unsupported taxonomy action: " & sub)

proc doHistory(args: seq[string]) =
  if args.len == 0:
    raise newException(ValueError, "history requires a file path")
  var root = detectRoot()
  let path = args[0]
  var explicitRoot = false
  var attribute = ""
  if args.len >= 2 and dirExists(args[1]):
    root = absolutePath(args[1])
    explicitRoot = true
  elif args.len >= 2:
    attribute = args[1]
  if args.len >= 3 and dirExists(args[2]):
    root = absolutePath(args[2])
    explicitRoot = true
  let db = openCatalogue(root)
  defer: db.close()
  for entry in getHistory(db, normalizeRelativePath(root, commandPath(path,
      explicitRoot)), attribute, root):
    echo entry.attribute & ": " & entry.oldValue & " -> " & entry.newValue &
        " @ " & $entry.changedAt

proc doList(args: seq[string]) =
  var root = detectRoot()
  if args.len > 0 and dirExists(args[0]):
    root = absolutePath(args[0])
  let db = openCatalogue(root)
  defer: db.close()
  for rec in listFiles(db):
    echo rec.path

proc doFind(args: seq[string]) =
  if args.len == 0:
    raise newException(ValueError, "find requires an expression")
  var root = detectRoot()
  var exprTokens = args
  if args.len >= 2 and dirExists(args[^1]):
    root = absolutePath(args[^1])
    exprTokens = args[0 ..< args.len - 1]
  let expr = exprTokens.join(" ")
  let db = openCatalogue(root)
  defer: db.close()
  for path in findFilesForExpression(db, expr):
    echo path

proc main() =
  let args = commandLineParams()
  if args.len == 0:
    usage(); return
  let cmd = args[0]
  try:
    case cmd
    of "init":
      let root = if args.len > 1: args[1] else: getCurrentDir()
      initRepo(root)
    of "scan":
      let root = if args.len > 1: args[1] else: detectRoot()
      scanRepo(root)
    of "status":
      let root = if args.len > 1: args[1] else: detectRoot()
      showStatus(root)
    of "get":
      doGet(args[1 .. ^1])
    of "set":
      doSet(args[1 .. ^1])
    of "unset":
      doUnset(args[1 .. ^1])
    of "taxonomy":
      doTaxonomy(args[1 .. ^1])
    of "history":
      doHistory(args[1 .. ^1])
    of "list":
      doList(args[1 .. ^1])
    of "find":
      doFind(args[1 .. ^1])
    else:
      usage(); quit(1)
  except CatchableError as e:
    stderr.writeLine("Error: " & e.msg)
    quit(1)

when isMainModule:
  main()
