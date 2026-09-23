## Gitignore-style pattern matching for `facet scan --no-ignore`/`--ignore-file`.
import std/[options, os, strutils, tables]

type
  IgnoreRule* = object
    negated*: bool
    dirOnly*: bool
    segs*: seq[string]
    raw*: string
    source*: string

  IgnoreSource* = object
    baseDir*: string ## path relative to scan root; "" for the root itself
    rules*: seq[IgnoreRule]

const posixClasses = {
  "alnum": {'a' .. 'z', 'A' .. 'Z', '0' .. '9'},
  "alpha": {'a' .. 'z', 'A' .. 'Z'},
  "blank": {' ', '\t'},
  "cntrl": {'\x00' .. '\x1F', '\x7F'},
  "digit": {'0' .. '9'},
  "graph": {'\x21' .. '\x7E'},
  "lower": {'a' .. 'z'},
  "print": {'\x20' .. '\x7E'},
  "punct": {'\x21' .. '\x2F', '\x3A' .. '\x40', '\x5B' .. '\x60', '\x7B' .. '\x7E'},
  "space": {' ', '\t', '\n', '\v', '\f', '\r'},
  "upper": {'A' .. 'Z'},
  "xdigit": {'0' .. '9', 'a' .. 'f', 'A' .. 'F'},
}.toTable

proc matchSegment(pattern: string, name: string): bool =
  ## fnmatch-style single path-segment matcher supporting *, ?, and [..] classes.
  var cache = initTable[(int, int), bool]()
  proc rec(pi, ni: int): bool =
    let key = (pi, ni)
    if key in cache:
      return cache[key]
    result =
      if pi == pattern.len:
        ni == name.len
      else:
        case pattern[pi]
        of '*':
          var p2 = pi
          while p2 < pattern.len and pattern[p2] == '*': inc p2
          if p2 == pattern.len: true
          else:
            var matched = false
            var n2 = ni
            while n2 <= name.len:
              if rec(p2, n2):
                matched = true
                break
              inc n2
            matched
        of '?':
          if ni >= name.len: false
          else: rec(pi + 1, ni + 1)
        of '[':
          if ni >= name.len: false
          else:
            var j = pi + 1
            var negate = false
            if j < pattern.len and pattern[j] in {'!', '^'}:
              negate = true
              inc j
            let classStart = j
            var matched = false
            var first = true
            while j < pattern.len and (pattern[j] != ']' or first):
              first = false
              if pattern[j] == '[' and j + 1 < pattern.len and pattern[j + 1] == ':':
                let closeIdx = pattern.find(":]", j + 2)
                if closeIdx >= 0:
                  let className = pattern[j + 2 ..< closeIdx]
                  if className in posixClasses:
                    if name[ni] in posixClasses[className]:
                      matched = true
                    j = closeIdx + 2
                    continue
              if j + 2 < pattern.len and pattern[j + 1] == '-' and pattern[j +
                  2] != ']':
                if name[ni] >= pattern[j] and name[ni] <= pattern[j + 2]:
                  matched = true
                j += 3
              else:
                if name[ni] == pattern[j]:
                  matched = true
                inc j
            if j >= pattern.len or classStart == j:
              # unterminated or empty class: treat '[' literally
              if name[ni] != '[': false
              else: rec(pi + 1, ni + 1)
            else:
              inc j # skip ']'
              if matched == negate: false
              else: rec(j, ni + 1)
        of '\\':
          if pi + 1 < pattern.len:
            if ni >= name.len or name[ni] != pattern[pi + 1]: false
            else: rec(pi + 2, ni + 1)
          else:
            if ni >= name.len or name[ni] != '\\': false
            else: rec(pi + 1, ni + 1)
        else:
          if ni >= name.len or name[ni] != pattern[pi]: false
          else: rec(pi + 1, ni + 1)
    cache[key] = result
  rec(0, 0)

proc matchPattern(patternSegs: seq[string], pathSegs: seq[string]): bool =
  ## Matches a `**`-aware sequence of pattern segments against path segments.
  ## A trailing `**` (with at least one preceding segment) requires at least
  ## one descendant path segment, matching git's "match everything inside"
  ## semantics for e.g. `foo/**` (which does not match `foo` itself).
  var cache = initTable[(int, int), bool]()
  proc rec(pi, si: int): bool =
    let key = (pi, si)
    if key in cache:
      return cache[key]
    result =
      if pi == patternSegs.len:
        si == pathSegs.len
      elif patternSegs[pi] == "**":
        if pi == patternSegs.high and pi > 0:
          si < pathSegs.len
        elif rec(pi + 1, si):
          true
        elif si < pathSegs.len:
          rec(pi, si + 1)
        else:
          false
      elif si == pathSegs.len:
        false
      elif not matchSegment(patternSegs[pi], pathSegs[si]):
        false
      else:
        rec(pi + 1, si + 1)
    cache[key] = result
  rec(0, 0)

proc trimTrailingUnescapedSpaces(text: string): string =
  ## Trims trailing spaces unless escaped with a backslash (git semantics),
  ## counting consecutive backslashes so an even count still escapes a space.
  result = text
  while result.len > 0 and result[^1] == ' ':
    var slashCount = 0
    var cursor = result.len - 2
    while cursor >= 0 and result[cursor] == '\\':
      inc slashCount
      dec cursor
    if slashCount mod 2 == 1:
      break
    result.setLen(result.len - 1)

proc parseIgnoreLine(line: string): Option[IgnoreRule] =
  var text = trimTrailingUnescapedSpaces(line.strip(chars = {'\r'}))
  if text.len == 0 or text[0] == '#':
    return none(IgnoreRule)
  var negated = false
  if text[0] == '!':
    negated = true
    text = text[1 .. ^1]
  elif text.startsWith("\\!") or text.startsWith("\\#"):
    text = text[1 .. ^1]
  var dirOnly = false
  if text.len > 0 and text[^1] == '/':
    dirOnly = true
    text = text[0 ..< ^1]
  if text.len == 0:
    return none(IgnoreRule)
  var anchored = false
  if text[0] == '/':
    anchored = true
    text = text[1 .. ^1]
  elif '/' in text:
    anchored = true
  if text.len == 0:
    return none(IgnoreRule)
  var segs = text.split('/')
  if not anchored:
    segs = @["**"] & segs
  some(IgnoreRule(negated: negated, dirOnly: dirOnly, segs: segs, raw: line))

proc parseIgnoreRules*(content: string, source: string): seq[IgnoreRule] =
  for line in content.splitLines():
    let ruleOpt = parseIgnoreLine(line)
    if ruleOpt.isSome:
      var rule = ruleOpt.get
      rule.source = source
      result.add rule

proc loadIgnoreFile*(path: string): seq[IgnoreRule] =
  if not fileExists(path):
    raise newException(ValueError, "ignore file not found: " & path)
  parseIgnoreRules(readFile(path), path)

proc discoverIgnoreRules*(absDir: string): seq[IgnoreRule] =
  for name in [".gitignore", ".facetignore"]:
    let candidate = absDir / name
    if fileExists(candidate):
      result.add parseIgnoreRules(readFile(candidate), candidate)

proc isPathIgnored*(sources: openArray[IgnoreSource], globalRules: openArray[
    IgnoreRule], relPath: string, isDir: bool): Option[IgnoreRule] =
  ## `sources` are ancestor-to-current directory-scoped rules (root first);
  ## `globalRules` are explicit `--ignore-file` rules applied last, repo-wide.
  ## Returns the last matching rule (git precedence), or none if not ignored.
  var winner = none(IgnoreRule)
  for src in sources:
    let sub = if src.baseDir.len == 0: relPath else: relPath[src.baseDir.len +
        1 .. ^1]
    let segs = sub.split('/')
    for rule in src.rules:
      if rule.dirOnly and not isDir: continue
      if matchPattern(rule.segs, segs):
        winner = if rule.negated: none(IgnoreRule) else: some(rule)
  let segsRoot = relPath.split('/')
  for rule in globalRules:
    if rule.dirOnly and not isDir: continue
    if matchPattern(rule.segs, segsRoot):
      winner = if rule.negated: none(IgnoreRule) else: some(rule)
  winner
