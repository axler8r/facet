## Gitignore-style pattern matching for `facet scan --no-ignore`/`--ignore-file`.
import std/[options, os, strutils]

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

proc matchSegment(pattern: string, name: string): bool =
  ## fnmatch-style single path-segment matcher supporting *, ?, and [..] classes.
  proc rec(pi, ni: int): bool =
    if pi == pattern.len:
      return ni == name.len
    case pattern[pi]
    of '*':
      var p2 = pi
      while p2 < pattern.len and pattern[p2] == '*': inc p2
      if p2 == pattern.len: return true
      var n2 = ni
      while n2 <= name.len:
        if rec(p2, n2): return true
        inc n2
      return false
    of '?':
      if ni >= name.len: return false
      return rec(pi + 1, ni + 1)
    of '[':
      if ni >= name.len: return false
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
        if j + 2 < pattern.len and pattern[j + 1] == '-' and pattern[j + 2] != ']':
          if name[ni] >= pattern[j] and name[ni] <= pattern[j + 2]:
            matched = true
          j += 3
        else:
          if name[ni] == pattern[j]:
            matched = true
          inc j
      if j >= pattern.len or classStart == j:
        # unterminated or empty class: treat '[' literally
        if name[ni] != '[': return false
        return rec(pi + 1, ni + 1)
      inc j # skip ']'
      if matched == negate: return false
      return rec(j, ni + 1)
    of '\\':
      if pi + 1 < pattern.len:
        if ni >= name.len or name[ni] != pattern[pi + 1]: return false
        return rec(pi + 2, ni + 1)
      else:
        if ni >= name.len or name[ni] != '\\': return false
        return rec(pi + 1, ni + 1)
    else:
      if ni >= name.len or name[ni] != pattern[pi]: return false
      return rec(pi + 1, ni + 1)
  rec(0, 0)

proc matchPattern(patternSegs: seq[string], pathSegs: seq[string]): bool =
  ## Matches a `**`-aware sequence of pattern segments against path segments.
  proc rec(pi, si: int): bool =
    if pi == patternSegs.len:
      return si == pathSegs.len
    if patternSegs[pi] == "**":
      if rec(pi + 1, si): return true
      if si < pathSegs.len and rec(pi, si + 1): return true
      return false
    if si == pathSegs.len:
      return false
    if not matchSegment(patternSegs[pi], pathSegs[si]): return false
    return rec(pi + 1, si + 1)
  rec(0, 0)

proc parseIgnoreLine(line: string): Option[IgnoreRule] =
  var text = line.strip(chars = {'\r'})
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

proc isPathIgnored*(sources: seq[IgnoreSource], globalRules: seq[IgnoreRule],
    relPath: string, isDir: bool): Option[IgnoreRule] =
  ## `sources` are ancestor-to-current directory-scoped rules (root first);
  ## `globalRules` are explicit `--ignore-file` rules applied last, repo-wide.
  ## Returns the last matching rule (git precedence), or none if not ignored.
  var winner = none(IgnoreRule)
  for src in sources:
    let sub = if src.baseDir.len == 0: relPath else: relPath[src.baseDir.len + 1 .. ^1]
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
