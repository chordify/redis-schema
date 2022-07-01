# redis-schema

A strongly typed, schema-based Redis library.
The focus is at composability: providing combinators
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
basic operations you might *not* do while counting visitors, too. :) )

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
  liftIO $ print n  -- this prints "Just 0", assuming no writes from other threads
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
`(Date, VisitorId) -> Int` but not the only possible one.
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

* With hashes, you also implicitly get a list of visitor IDs for each day.
  With composite keys, you have to use the `SCAN` or `KEYS` Redis command.

* It's easy to `get`, `set` or `take` whole hashes (atomically).
  With separate keys, you have to use an explicit transaction,
  and code up these operations manually.

* Hashes take less space than the same number of values in separate keys.

* You cannot set the TTL of items in a hash separately: only the whole hash has a TTL.
  With separate keys, you can set TTL individually.

* You cannot have complex data types (Redis sets, Redis hashes, etc.)
  nested inside hashes without encoding them as `ByteString`s first.
  (See [Lists, sets, hashes, etc.](#lists-sets-hashes-etc))
  There are no such restrictions for separate keys.

Hence the encoding depends on your use case. If you're caching
a set of related things for a certain visitor, which you want to read as a whole
and expire as a whole, it makes sense to put them in a hash.

If your items are rather separate, you want to expire them separately,
or you want to store structures like hashes inside,
you have to put them in separate keys.
Fields like `date` should probably generally go in the (possibly composite) key
because they will likely affect the required expiration time.

### Records

We have just seen how to use Redis hashes to store values of type `Map k v`.
The number of items in the map is unlimited
but all keys and values must have the same type.

There's another (major) use case for Redis hashes: records.
Records are structures which contain a fixed number of named values,
where each value can have a different type.
It is therefore a natural way of clustering related data together.

Here's an example showing how records are modelled in `redis-schema`.

```haskell
-- First, we use GADTs to describe the available fields and their types.
-- Here, 'Email' has type 'Text', 'DateOfBirth' has type 'Date',
-- and 'Visits' and 'Clicks' have type 'Int'.
data VisitorField :: * -> * where
  Email :: VisitorField Text
  DateOfBirth :: VisitorField Date
  Visits :: VisitorField Int
  Clicks :: VisitorField Int

-- We define how to translate record keys to strings
-- that will be used to key the Redis hash.
instance Redis.RecordField VisitorField where
  rfToBS Email = "email"
  rfToBS DateOfBirth = "date-of-birth"
  rfToBS Visits = "visits"
  rfToBS Clicks = "clicks"

-- Then we define the type of references pointing to the visitor statistics
-- for any given visitor ID.
data VisitorStats = VisitorStats VisitorId

-- Finally, we declare that the type of references is indeed a Redis reference.
instance Redis.Ref VisitorStats where
  -- The type pointed to is 'Redis.Record VisitorField', which means
  -- a record with the fields defined by 'VisitorField'.
  type ValueType VisitorStats = Redis.Record VisitorField

  -- As usual, this defines what key in Redis this reference points to.
  toIdentifier (VisitorStats visitorId) =
    Redis.colonSep ["visitors", "statistics", Redis.toBS visitorId]
```

This example is a bit silly because if you know `DateOfBirth` about your unregistered visitors,
there's something very wrong. However, for demonstrational purposes, it'll suffice.

Now we can get references to the individual fields with the specialised operator `:.`.

```haskell
handleClick :: VisitorId -> Redis ()
handleClick visitorId = do
  -- for demonstration purposes, log the email
  email <- Redis.get (VisitorStats visitorId :. Email)
  liftIO $ print email

  -- atomically increase the counter of clicks
  Redis.incrementBy (VisitorStats visitorId :. Clicks) 1
```

In the current implementation, records cannot be read or written as a whole.
(However, they *can* be deleted and their TTL can be set.)
There is no special reason for that, except that it would be too much type-level code
that we currently do not need, so we keep it simple.

However, see [Meta-records](#meta-records) for the next best solution.

#### Aside: non-fixed record fields

The number of fields in a record is not *really* fixed.
Consider the following declaration.

```haskell
data VisitorField :: * -> * where
  Visits :: Date -> VisitorField Int

instance Redis.RecordField VisitorField where
  rfToBS (Visits date) = Redis.colonSep ["visits", Redis.toBS date]
```

This creates a record with a separate field for every date, named `visits:${DATE}`.

### Transactions

Redis does support transactions and `redis-schema` supports them,
but they are not like SQL transactions, which you may be accustomed to.
A more suggestive name for Redis transactions might be "atomic operation batches".

The main difference between SQL-like transactions and batched Redis transactions
is that in SQL, you can start a transaction, run a query, receive its output,
and then run another query in the same transaction. Sending queries and receiving their outputs
can be interleaved in the same transaction, and later queries can depend on the output
of previous queries.

With Redis-style batched transactions, on the other hand, you can batch up multiple operations
but the atomicity of a transaction ends at the moment you receive the output of those operations.
Hence later operations in a batch cannot depend on the output of the previous operations,
as that output is not available yet.

While the structure of SQL-like transactions is captured by the `Monad` typeclass,
Redis-style fixed-effects transactions are described by `Applicative` functors --
and this is exactly the interface that `redis-schema` provides for Redis transactions.

#### The `Tx` functor

`redis-schema` defines the `Tx` functor for transactional computations.

```haskell
newtype Tx inst a
instance Functor (Tx inst)
instance Applicative (Tx inst)
instance Alternative (Tx inst)

atomically :: Tx inst a -> RedisM inst a
txThrow :: RedisException -> Tx inst a
```

The type parameter `inst` is explained in section [Redis instances](#redis-instances),
but can be ignored for now.

Redis transactions are run using the combinator called `atomically`,
and they also support throwing exceptions using `txThrow`. Throwing
an exception in a transaction will not prevent any side effects from taking place;
only the exception will be re-thrown in the `RedisM` monad
instead of returning the output of the transaction. The `Alternative` instance
of `Tx` can be used to "catch" these exceptions.

#### Working with transactions

Most functions, like `get`, `set` or `take`,
have a sibling that can be used in a transaction, usually prefixed with `tx`:

```haskell
get   :: Ref ref => ref -> RedisM (RefInstance ref) (Maybe (ValueType ref))
txGet :: Ref ref => ref -> Tx     (RefInstance ref) (Maybe (ValueType ref))
```

With `ApplicativeDo`, these transactional functions can be used as conveniently
as their non-transactional counterparts. For example, the function `take`,
which atomically reads and deletes a Redis value, could be (re-)implemented as follows:

```haskell
{-# LANGUAGE ApplicativeDo #-}

take :: Ref ref => ref -> RedisM (RefInstance ref) (Maybe (ValueType ref))
take ref = atomically $ do
  value <- txGet ref
  txDelete_ ref
  pure value
```

#### What Redis transactions cannot do

One might try to attempt an alternative implementation of `txIncrementBy`:

```haskell
import Data.Maybe (fromMaybe)

txIncrementBy' :: (SimpleRef ref, Num (ValueType ref))
  => ref -> Integer -> Tx (RefInstance ref) (ValueType ref)
txIncrementBy' ref incr = do
  oldValue <- fromMaybe 0 <$> txGet ref        -- COMPILER ERROR
  let newValue = oldValue + fromInteger incr
  txSet ref newValue
  pure newValue
```

The compiler complains
```
• Could not deduce (Monad (Tx (RefInstance ref)))
    arising from a do statement
```
because `oldValue` is used non-trivially in the `do` block,
but `Tx` implements only `Applicative` and not `Monad`.

This error is exactly a goal of the design: it indicates at compile time
that Redis does not support this usage pattern.

#### Errors in transactions

Beware that Redis won't roll back failed transactions, which means they
are not atomic in that sense. A Redis transaction that fails halfway through
will retain all effects up to the point of failure.
See [the Redis documentation](https://redis.io/docs/manual/transactions/#errors-inside-a-transaction)
for details and rationale.

#### Monads vs applicative functors

The underlying library of `redis-schema`, Hedis, provides a monad `RedisTx`
to describe Redis transactions. Since monads would be too powerful, Hedis uses
an opaque wrapper for `Queued` results to prevent the users from accessing
values that are not available yet. We believe that using an applicative functor
instead is a perfect match for this use case: it allows exactly the right
operations, and all wrapping/unwrapping can be done entirely transparently.

Another improvement of `Tx` is that `Tx` allows throwing
`RedisException`s transparently.

### Exceptions

TODO `RedisException`

### Custom data types

#### Redis instances

TODO

TODO: probably need to talk about instances? separate section?

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

### Meta-records

In Haskell, records can be nested arbitrarily. You can have a record
that contains some fields alongside another couple of records,
which themselves contain arbitrarily nested maps and lists of further records.

Redis does not support such arbitrary nesting. However,
we can often work around this limitation by distributing the datastructure
over a number of separate Redis keys.
For example, consider a case where each visitor should be associated with
the number of visits, the number of clicks, and the set of their favourite songs.
Here we can keep the visits+clicks in one record reference per visitor, and the set of favourites
in another reference, again per visitor.
However, we still need to read the visits+clicks separately from the favourites.
This is not just a question of convenience: two separate reads may lead to a race condition,
unless we run them in a transaction.

Since `redis-schema` encourages compositionality, it is possible to make data structures
that gather (or scatter) all their data across Redis automatically, without having
to manipulate every component separately every time. Here's an example.

```haskell
-- VisitorFields are visits and clicks.
data VisitorField :: * -> * where
  Visits :: VisitorField Int
  Clicks :: VisitorField Int

-- VisitorStats is a record with VisitorFields
data VisitorStats = VisitorStats VisitorId
instance RedisRef VisitorStats where
  type ValueType VisitorStats = Redis.Record VisitorField
  toIdentifier = {- ...omitted... -}

-- A separate reference to the favourite songs.
data FavouriteSongs = FavouriteSongs VisitorId
instance Redis.Ref FavouriteSongs where
  type ValueType FavouriteSongs = Set SongId
  toIdentifier = {- ...omitted... -}

-- Finally, here's our composite record that we want to read/write atomically.
data VisitorInfo = VisitorInfo
  { viVisits :: Int
  , viClicks :: Int
  , viFavouriteSongs :: Set SongId
  }

instance Redis.Value Redis.DefaultInstance VisitorInfo where
  type Identifier VisitorInfo = VisitorId

  txValGet visitorId = do
    visits <- fromMaybe 0 <$> Redis.txGet (VisitorStats visitorId :. Visits)
    clicks <- fromMaybe 0 <$> Redis.txGet (VisitorStats visitorId :. Clicks)
    favourites <- fromMaybe Set.empty <$> Redis.txGet (FavouriteSongs visitorId)
    return $ Just VisitorInfo
      { viVisits = visits
      , viClicks = clicks
      , viFavourites = favourites
      }

  txValSet visitorId vi = do
    Redis.txSet (VisitorStats visitorId :. Visits) (viVisits vi)
    Redis.txSet (VisitorStats visitorId :. Clicks) (viClicks vi)
    Redis.txSet (FavouriteSongs visitorId) (viFavourites vi)

  txValDelete visitorId = do
    Redis.txDelete (VisitorStats visitorId)
    Redis.txDelete (FavouriteSongs visitorId)

  {- etc. -}
```

It's a bit of a boilerplate, but now all the scatter/gather code is packed
in the `Value` instance, it's safe and it composes. Moreover, with small
let-bound functions, the repetition can be greatly minimised.

TODO: you must specify an instance, i think that all sub-elements must be in the same instance

## Libraries

### Locks

* Exclusive
* Shared

### Remote jobs

TODO

## Future work

* Rework Maybe (e.g. numeric types never return `Nothing`)
* `SimpleValue` etc., something can be read/written but not setttled etc.
* whole records

## License

BSD 3-clause.

<!--
vim: ts=2 sts=2 sw=2 et
-->
