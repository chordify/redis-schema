# redis-schema

A strongly typed, schema-based Redis library.
The focus is at composability: providing combinators,
on top of which you can correctly build your application or another library.

Examples of libraries (TODO):
- Lock
- Remote Job

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

### Parameterised references

If you want a separate counter for every day,
you define a slightly more interesting reference type.

```haskell
-- Note that the type constructor is still nullary (no parameters)
-- but the data constructor takes the 'Date' in question.
data DailyVisitors = DailyVisitors Date

instance Redis.Ref DailyVisitors where
  -- Again, the reference points to an 'Int'.
  -- We're talking about the type of the reference so no date is present here.
  type ValueType DailyVisitors = Int

  -- The location does depend on the value of the reference,
  -- so it can depend on the date. We include the date in the Redis path.
  toIdentifier (DailyVisitors date) =
    Redis.colonSep ["visitors", "daily", ByteString.pack (show date)]

f :: Redis.Pool -> Date -> IO ()
f pool today = Redis.run pool $ do
  -- atomically bump the number of visitors
  incrementBy (DailyVisitors today) 1

  -- (other threads may modify the value here)

  -- read and print the reference
  n <- get (DailyVisitors today)
  liftIO $ print n
```

### Lists, Sets, Hashes, etc.

What we've read/written so far were `SimpleValue`s: data items that can be
encoded as `ByteString`s and used without restrictions.
However, Redis also provides richer data structures, including lists, sets,
and maps/hashes.

The advantage is that Redis provides operations to manipulate these data
structures directly. You can insert elements, delete elements, etc., without
reading a `ByteString`-encoded structure and writing its modified version back.

The disadvantage is that Redis does not support nesting them.

That does not mean there's absolutely no way to put sets in sets --
if you encode the inner sets into ByteString, you can nest them however you want.
However, you will not be able to use functions like `sInsert` or `sDelete`
to modify the inner sets,
and you'll have to read/write the entire inner value every time.

This is reflected in `redis-schema` by the fact that
the `SimpleValue` instance is not defined for `Set a`, `Map k v` and `[a]`,
which prevents nesting them directly.

On the other hand, `redis-schema` defines additional functions
specific to these data structures, such as the above mentioned
`sInsert`, which is used to insert elements into a Redis set.

```haskell
-- The set of visitor IDs for the given date.
data DailyVisitorSet = DailyVisitorSet Date

instance Redis.Ref DailyVisitorSet where
  -- This reference points to a set of visitor IDs.
  type ValueType DailyVisitorSet = Set VisitorId

  -- The Redis location of the value.
  toIdentifier (DailyVisitorSet date) =
    Redis.colonSep ["visitor_set", "daily", ByteString.pack (show date)]

f :: Redis.Pool -> Date -> VisitorId -> IO ()
f pool today vid = Redis.run pool $ do
  -- insert the visitor ID
  sInsert (DailyVisitorSet today) vid

  -- get the size of the updated set
  -- (and print it)
  liftIO . print =<< sSize (DailyVisitorSet today)

  -- atomically get and clear the visitor set
  -- (and print it)
  liftIO . print =<< take (DailyVisitorSet today)
```

There is a number of functions available for these structures,
refer to the reference documentation / source code for a complete list.

Also, we add functions when we need them, so it's quite possible that the function
that you require has not been added yet. Pull requests are welcome.

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
