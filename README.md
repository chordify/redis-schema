# redis-schema

A strongly typed, schema-based Redis library.

BEWARE: The documentation is being written.

## Examples

### Simple variables

```haskell
data NumberOfVisitors = NumberOfVisitors

instance Redis.Ref NumberOfVisitors where
  type ValueType NumberOfVisitors = Int
  toIdentifier NumberOfVisitors = "visitors:number"

f pool = Redis.run pool $ do
  -- write
  set NumberOfVisitors 42
  setTTL NumberOfVisitors (24 * Redis.hour)

  -- atomically read and clear
  n2 <- take NumberOfVisitors
  liftIO $ print n2

  -- read
  n <- get NumberOfVisitors
  liftIO $ print n  -- this prints zero, assuming no other writes

```

### Parameterised variables

```haskell
data DailyVisitors = DailyVisitors Date

instance Redis.Ref DailyVisitors where
  type ValueType DailyVisitors = Int
  toIdentifier (DailyVisitors date) =
    Redis.colonSep ["visitors", "daily", show date]

f pool today = Redis.run pool $ do
  set (DailyVisitors today) 42
  liftIO . print =<< get (DailyVisitors today)
```

### Lists, Sets

```haskell
data DailyVisitorSet = DailyVisitorSet Date

instance Redis.Ref DailyVisitorSet where
  type ValueType DailyVisitorSet = Set VisitorId
  toIdentifier (DailyVisitorSet date) =
    Redis.colonSep ["visitor_set", "daily", show date]

f pool today vid = Redis.run pool $ do
  sInsert (DailyVisitorSet today) vid
  liftIO . print =<< sSize (DailyVisitorSet today)
  liftIO . print =<< take (DailyVisitorSet today)
```

### Maps

### Records

### Transactions

### Locks

* Exclusive
* Shared

## License

BSD 3-clause.
