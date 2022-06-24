# redis-schema

A strongly typed, schema-based Redis library.
The focus is at composability: providing combinators,
on top of which you can correctly build your application or another library.

Examples of libraries (TODO):
- Lock
- Remote Job

BEWARE: The documentation is being written.

## Examples

Imagine you want to use Redis to count the number of the visitors
on your website. This is how you would do it with `redis-schema`.

### Simple variables

(For demonstration purposes, the following example also includes some
basic operations you might not do while counting visitors, too. :) )

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

  -- atomically increment the number of visitors
  incrementBy (DailyVisitors today) 1

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

With composite keys, it's sometimes useful to use `Redis.colonSep`,
which builds a single colon-separated `ByteString` from the provided components.

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

### Hashes

There is a special operator `(:/)` to access the items of a hash,
as if they were individual Redis `Ref`s.
Here's our running example with website visitors,
except that now instead of just the count of visits, or just the set of visitors,
we will store exactly how many times each visitor has visited us.

```haskell
data Visitors = Visitors Date

instance Redis.Ref Visitors where
  -- Each daily visitor structure is a map from visitor ID to the number of visits.
  type ValueType Visitors = Map VisitorId Int

  toIdentifier (Visitors date) =
    Redis.colonSep ["visitors", ByteString.pack (show date)]

f :: Redis.Pool -> Date -> VisitorId -> IO ()
f pool today visitorId = do
  -- increment one specific counter inside the hash
  incrementBy (Visitors today :/ visitorId) 1

  -- print all visitors
  allVisitors <- get (Visitors today)
  print allVisitors
```

Using operator `(:/)`, we could write `Visitors today :/ visitorId`
to reference a single field of a hash. However, we can also
retrieve and print the whole hash if we choose to.

#### Aside: Hashes vs. composite keys

In the previous example, the reference `Visitors date`
points to a `Map VisitorId Int`. This is one realisation of a mapping
`(Date, VisitorId) -> Int` but not the only one.
Another way would be including the `VisitorId` in the key like this:

```haskell
data VisitCount = VisitCount Date VisitorId

instance Redis.Ref VisitCount where
  type ValueType VisitCount = Int

  toIdentifier (VisitCount date visitorId) =
    Redis.colonSep
      [ "visitors"
      , ByteString.pack (show date)
      , ByteString.pack (show visitorId)
      ]
```

This way, every date-visitor combination gets its own full key-value entry
in Redis. There are advantages and disadvantages to either representation.

* With hashes, you also get a list of visitor IDs for each day.
  With composite keys, you have to use the `SCAN` or `KEYS` Redis command.

* It's easy to `get`, `set` or `take` whole hashes (atomically).
  With separate keys, you have to use an explicit transaction,
  and code up these operations manually.

* Hashes take less space than the same number of values in separate keys.

* You cannot set the TTL of items in a hash separately: only the whole hash has a TTL.
  With separate keys, you can set TTL individually.

Hence the encoding depends on your use case. If you're caching
a set of related things for a certain visitor, which you want to read as a whole
and expire as a whole, it makes sense to put them in a hash.

If your items are rather separate and you want to expire them separately,
you have to put them in separate keys.
Fields like `date` should probably go in the (possibly composite) key
because they will likely affect the required expiration time.

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
