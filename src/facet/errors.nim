type
  FacetError* = object of CatchableError
  ValidationError* = object of FacetError
  NotFoundError* = object of FacetError
  UsageError* = object of FacetError

proc raiseValidation*(msg: string) =
  raise newException(ValidationError, msg)

proc raiseNotFound*(msg: string) =
  raise newException(NotFoundError, msg)

proc raiseUsage*(msg: string) =
  raise newException(UsageError, msg)
