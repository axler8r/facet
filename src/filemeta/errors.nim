type
  FilemetaError* = object of CatchableError
  ValidationError* = object of FilemetaError
  NotFoundError* = object of FilemetaError
  UsageError* = object of FilemetaError

proc raiseValidation*(msg: string) =
  raise newException(ValidationError, msg)

proc raiseNotFound*(msg: string) =
  raise newException(NotFoundError, msg)

proc raiseUsage*(msg: string) =
  raise newException(UsageError, msg)
