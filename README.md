# redis-schema

A strongly typed, schema-based Redis library.

BEWARE: The documentation is being written.

## Examples

### Simple variables

```haskell
-- This module is generally intended to be imported qualified.
import qualified Database.Redis.Schema as Redis

-- The type of references to the number of visitors.
-- Since we want only one number of visitors, this type is a singleton.
-- Later on, we'll see more interesting types of references.
data NumberOfVisitors = NumberOfVisitors

-- We define that NumberOfVisitors is indeed a Redis reference.
instance Redis.Ref NumberOfVisitors where
  -- The type of the value that NumberOfVisitors refers to is Int.
  type ValueType NumberOfVisitors = Int

  -- The location of the value that NumberOfVisitors refers to is "visitors:number".
  toIdentifier NumberOfVisitors = "visitors:number"

f :: Redis.Pool -> IO ()
f pool = Redis.run pool $ do
  -- write to the reference
  set NumberOfVisitors 42
  setTTL NumberOfVisitors (24 * Redis.hour)

  -- atomically read and clear (zero) the reference
  -- useful for transactional moves of data
  n2 <- take NumberOfVisitors
  liftIO $ print n2

  -- read the value of the reference
  n <- get NumberOfVisitors
  liftIO $ print n  -- this prints zero, assuming no writes from other threads
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

### Custom data types

```haskell
import Database.Redis.Schema

-- | Define a custom redis instance.
-- This is optional, but useful in case
-- you are using multiple Redis servers.
data MyRedisInstance

-- | Define the type that you want to use
-- to store your data under.
data MyKey = MyKey

-- | Define the data type that you wish to
-- store.
newtype MyData = MyData { unMyData :: Int }
  deriving newtype (Serializable)

-- | Write an instance of the 'Value' class
-- for your data. This allows a 'Ref' instance
-- to refer to your data type.
instance SimpleValue MyRedisInstance MyData
instance Value MyRedisInstance MyData

-- | Define the 'Ref' instance for your key
-- type.
instance Ref MyKey where
  type ValueType MyKey = MyData
  type RefInstance MyKey = MyRedisInstance
  toIdentifier MyKey = SviTopLevel "my:key"

-- | Store a number in Redis with key "my:key"
setMyData :: Int -> RedisM MyRedisInstance ()
setMyData nr = set MyKey (MyData nr)

-- | Get a number from Redis with key "my:key"
getMyData :: RedisM MyRedisInstance (Maybe Int)
getMyData = fmap unMyData <$> get MyKey
```

## License

BSD 3-clause.

<!--
vim: ts=2 sts=2 sw=2 et
-->
