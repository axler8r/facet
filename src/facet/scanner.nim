import std/[algorithm, options, os, posix, sets, strutils, tables]
import ./database
import ./ignore

type
  ScanOptions* = object
    noIgnore*: bool
    ignoreFilePaths*: seq[string]
    verboseIgnore*: bool

proc defaultScanOptions*(): ScanOptions =
  ScanOptions(noIgnore: false, ignoreFilePaths: @[], verboseIgnore: false)

proc loadGlobalIgnoreRules(options: ScanOptions): seq[IgnoreRule] =
  for path in options.ignoreFilePaths:
    result.add loadIgnoreFile(path)

proc iterTrackedFiles*(root: string, options: ScanOptions = defaultScanOptions()): seq[string] =
  let globalRules = loadGlobalIgnoreRules(options)
  var pending = @[(dir: root, sources: newSeq[IgnoreSource]())]
  while pending.len > 0:
    let (directory, parentSources) = pending.pop()
    if symlinkExists(directory):
      raise newException(ValueError, "directory became a symlink during scan: " & directory)
    var sources = parentSources
    if not options.noIgnore:
      let discovered = discoverIgnoreRules(directory)
      if discovered.len > 0:
        let baseDir = if directory == root: "" else: normalizeRelativePath(root, directory)
        sources.add IgnoreSource(baseDir: baseDir, rules: discovered)
    for kind, path in walkDir(directory, checkDir = true):
      if path == root / ".facet" or path == root / ".git":
        continue
      case kind
      of pcLinkToFile, pcLinkToDir: discard
      of pcDir, pcFile:
        let isDir = kind == pcDir
        let relative = relativePath(path, root)
        let matchOpt = isPathIgnored(sources, globalRules, relative, isDir)
        if matchOpt.isSome:
          if options.verboseIgnore:
            echo "Ignored: " & relative & " (matched " & matchOpt.get.raw &
                " from " & matchOpt.get.source & ")"
          continue
        if isDir:
          pending.add (dir: path, sources: sources)
        else:
          result.add normalizeRelativePath(root, path)
  result.sort()

proc scanRepository*(root: string, options: ScanOptions = defaultScanOptions()): Summary =
  let target = normalizedPath(absolutePath(root))
  var snapshot = initOrderedTable[string, seq[FileRecord]]()
  for relative in iterTrackedFiles(target, options):
    let full = target / relative
    var info: Stat
    if lstat(full.cstring, info) != 0:
      raiseOSError(osLastError(), full)
    if not S_ISREG(info.st_mode):
      raise newException(ValueError, "file changed type during scan: " & relative)
    let device = cast[uint64](info.st_dev)
    let inode = cast[uint64](info.st_ino)
    let signature = $device & ":" & $inode
    snapshot.mgetOrPut(signature, @[]).add FileRecord(
      path: relative, device: device, inode: inode, size: info.st_size,
      mtimeNs: int64(info.st_mtim.tv_sec) * 1_000_000_000'i64 + int64(
          info.st_mtim.tv_nsec))

  let db = initDatabase(target)
  defer: db.close()
  db.transaction:
    let existing = listFiles(db)
    var lookup = initTable[string, FileRecord]()
    for record in existing:
      lookup[$record.device & ":" & $record.inode] = record
    var seen = initHashSet[int]()
    let now = utcNowNs()
    db.exec("UPDATE files SET state = 'MISSING' WHERE state = 'PRESENT'")
    for signature, links in snapshot:
      var observed = links[0]
      if lookup.hasKey(signature):
        let previous = lookup[signature]
        for link in links:
          if link.path == previous.path:
            observed = link
            break
        seen.incl previous.id
        if previous.path != observed.path:
          inc result.moved
        elif previous.size == observed.size and previous.mtimeNs ==
            observed.mtimeNs and previous.state == PresentState:
          inc result.unchanged
        else:
          inc result.updated
        updateFileRecord(db, previous.id, observed.path, observed.size,
            observed.mtimeNs, now)
      else:
        discard insertFileRecord(db, observed.path, observed.device,
            observed.inode, observed.size, observed.mtimeNs, now, now)
        inc result.added
      inc result.scanned
    for previous in existing:
      if previous.id notin seen and previous.state == PresentState:
        inc result.missing

proc scanSummaryText*(sum: Summary): string =
  "Scanned:   " & alignLeft($sum.scanned, 8) & "\n" &
    "Added:     " & alignLeft($sum.added, 8) & "\n" &
    "Updated:   " & alignLeft($sum.updated, 8) & "\n" &
    "Moved:     " & alignLeft($sum.moved, 8) & "\n" &
    "Missing:   " & alignLeft($sum.missing, 8) & "\n" &
    "Unchanged: " & alignLeft($sum.unchanged, 8) & "\n"
