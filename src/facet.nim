import std/[options, os, strutils]
import ./facet/database
import ./facet/ignore
import ./facet/scanner
import ./facet/taxonomy
import ./facet/metadata
import ./facet/query

type HelpStyle = object
  enabled: bool

proc isTruthyEnv(value: string): bool =
  value.toLowerAscii() notin ["", "0", "false", "no", "off"]

proc detectColorEnabled(): bool =
  if existsEnv("NO_COLOR"):
    return false
  if existsEnv("FACET_COLOR"):
    return isTruthyEnv(getEnv("FACET_COLOR"))
  true

proc style(enabled: bool, code: string, text: string): string =
  if enabled:
    "\e[" & code & "m" & text & "\e[0m"
  else:
    text

proc bold(s: HelpStyle, text: string): string =
  style(s.enabled, "1", text)

proc accent(s: HelpStyle, text: string): string =
  style(s.enabled, "36", text)

proc muted(s: HelpStyle, text: string): string =
  style(s.enabled, "2", text)

proc wrapWords(text: string, width: int): seq[string] =
  if width <= 0:
    return @[text]
  var current = ""
  for word in text.splitWhitespace():
    if current.len == 0:
      current = word
    elif current.len + 1 + word.len <= width:
      current.add " "
      current.add word
    else:
      result.add current
      current = word
  if current.len > 0:
    result.add current
  if result.len == 0:
    result = @[""]

proc printCommandRow(s: HelpStyle, signature: string, description: string,
    commandWidth: int = 54, descriptionWidth: int = 56) =
  let indent = "  "
  let left = s.accent(signature)
  if signature.len <= commandWidth:
    let pad = repeat(' ', commandWidth - signature.len + 2)
    echo indent & left & pad & description
  else:
    echo indent & left
    let wrapped = wrapWords(description, descriptionWidth)
    let descIndent = indent & repeat(' ', commandWidth + 2)
    for line in wrapped:
      echo descIndent & line

proc usage() =
  let s = HelpStyle(enabled: detectColorEnabled())
  echo s.bold("facet") & " - " & s.muted("structured file metadata catalogue")
  echo ""
  echo s.bold("Usage")
  echo "  " & s.accent("facet") & " <command> [arguments]"
  echo "  " & s.accent("facet") & " --help"
  echo ""
  echo s.bold("Commands")
  printCommandRow(s, "init [ROOT]", "Initialise catalogue under ROOT")
  printCommandRow(s,
      "scan [--no-ignore] [--ignore-file PATH]... [--verbose-ignore] [ROOT]",
      "Scan filesystem and reconcile catalogue")
  printCommandRow(s, "status [ROOT]", "Show root and tracked file count")
  printCommandRow(s, "list [ROOT]", "List tracked paths")
  printCommandRow(s, "get PATH [--json] [ROOT]", "Show file details and attributes")
  printCommandRow(s, "set PATH ATTRIBUTE VALUE [ROOT]", "Set attribute value")
  printCommandRow(s, "unset PATH ATTRIBUTE [ROOT]", "Remove attribute value")
  printCommandRow(s, "ignore PATH [ROOT]", "Untrack PATH and exclude it from future scans")
  printCommandRow(s, "history PATH [ATTRIBUTE] [ROOT]", "Show attribute change history")
  printCommandRow(s, "find 'EXPRESSION' [ROOT]", "Filter files by query expression")
  printCommandRow(s,
      "taxonomy add NAME TYPE [VALUES...] [--min N --max N] [ROOT]",
      "Create taxonomy attribute")
  printCommandRow(s, "taxonomy list [ROOT]", "List taxonomy attributes")
  printCommandRow(s, "taxonomy show NAME [ROOT]", "Show taxonomy attribute definition")
  printCommandRow(s, "taxonomy remove NAME [ROOT]", "Delete taxonomy attribute")
  echo ""
  echo s.bold("Examples")
  echo "  " & s.accent("facet init /data")
  echo "  " & s.accent("facet scan /data")
  echo "  " & s.accent("facet taxonomy add note string /data")
  echo "  " & s.accent("facet set docs/a.txt note 'hello world' /data")
  echo "  " & s.accent("facet get docs/a.txt --json /data")
  echo "  " & s.accent("facet find \"note == \\\"hello world\\\"\" /data")
  echo "  " & s.accent("facet ignore docs/scratch.txt /data")
  echo ""
  echo s.muted("Set FACET_COLOR=0 or NO_COLOR=1 to disable color output.")

proc commandPath(path: string, explicitRoot: bool): string =
  if explicitRoot: path else: absolutePath(path)

proc initRepo(root: string) =
  let target = if root.len > 0: absolutePath(root) else: getCurrentDir()
  let db = initDatabase(target)
  db.close()
  echo "Initialised: " & target

proc scanRepo(args: seq[string]) =
  var options = defaultScanOptions()
  var root = ""
  var i = 0
  while i < args.len:
    let token = args[i]
    case token
    of "--no-ignore":
      options.noIgnore = true
    of "--ignore-file":
      if i + 1 >= args.len:
        raise newException(ValueError, "--ignore-file requires a PATH argument")
      inc i
      options.ignoreFilePaths.add absolutePath(args[i])
    of "--verbose-ignore":
      options.verboseIgnore = true
    else:
      if root.len > 0:
        raise newException(ValueError, "unexpected argument: " & token)
      root = token
    inc i
  let target = if root.len > 0: absolutePath(root) else: detectRoot()
  let summary = scanRepository(target, options)
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

proc doIgnore(args: seq[string]) =
  if args.len == 0:
    raise newException(ValueError, "ignore requires a path")
  var root = detectRoot()
  let path = commandPath(args[0], args.len >= 2)
  if args.len >= 2:
    root = absolutePath(args[1])
  let db = openCatalogue(root)
  defer: db.close()
  let rel = normalizeRelativePath(root, path)
  let record = queryFileByPath(db, rel)
  if record.isNone:
    raise newException(ValueError, "file not tracked: " & rel)
  appendIgnoreRule(root, rel)
  deleteFileRecord(db, record.get.id)
  echo "Ignored: " & rel

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
    var minText = none(string)
    var maxText = none(string)
    var i = 2
    while i < rest.len:
      let token = rest[i]
      if token == "--min":
        if i + 1 >= rest.len:
          raise newException(ValueError, "--min requires a value")
        minText = some(rest[i + 1]); inc i
      elif token == "--max":
        if i + 1 >= rest.len:
          raise newException(ValueError, "--max requires a value")
        maxText = some(rest[i + 1]); inc i
      else:
        values.add token
      inc i
    var minValue: Option[float] = none(float)
    var maxValue: Option[float] = none(float)
    var integerMin: Option[int64] = none(int64)
    var integerMax: Option[int64] = none(int64)
    if kind == "integer":
      if minText.isSome: integerMin = some(parseBiggestInt(minText.get))
      if maxText.isSome: integerMax = some(parseBiggestInt(maxText.get))
    else:
      if minText.isSome: minValue = some(parseFloat(minText.get))
      if maxText.isSome: maxValue = some(parseFloat(maxText.get))
    addTaxonomyAttribute(db, name, kind, values, minValue, maxValue,
        integerMin, integerMax)
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
    echo "Type: " & kindText(def.kind)
    if def.allowed.len > 0:
      echo "Values: " & def.allowed.join(", ")
    if def.integerMin.isSome: echo "Min: " & $def.integerMin.get
    elif def.minValue.isSome: echo "Min: " & $def.minValue.get
    if def.integerMax.isSome: echo "Max: " & $def.integerMax.get
    elif def.maxValue.isSome: echo "Max: " & $def.maxValue.get
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
  if args.len == 0 or args[0] in ["-h", "--help", "help"]:
    usage(); return
  let cmd = args[0]
  try:
    case cmd
    of "init":
      let root = if args.len > 1: args[1] else: getCurrentDir()
      initRepo(root)
    of "scan":
      scanRepo(args[1 .. ^1])
    of "status":
      let root = if args.len > 1: args[1] else: detectRoot()
      showStatus(root)
    of "get":
      doGet(args[1 .. ^1])
    of "set":
      doSet(args[1 .. ^1])
    of "unset":
      doUnset(args[1 .. ^1])
    of "ignore":
      doIgnore(args[1 .. ^1])
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
