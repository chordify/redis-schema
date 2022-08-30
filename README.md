# redis-schema

A strongly typed, schema-based, composable Redis library.
It strives to provide a solid layer on top of which you can
correctly build your application or another library.

## Why `redis-schema`

### Statically typed schema

#### Hedis

The most common Redis library seems to be
[Hedis](https://hackage.haskell.org/package/hedis), and `redis-schema` builds
on top of it. However, consider the type of `get` in Hedis:

```haskell
get
    :: (RedisCtx m f)
    => ByteString -- ^ key
    -> m (f (Maybe ByteString))
```

For most use cases, it would be nice if:
* the value could be decoded from a `ByteString` automatically
  * provides convenience but also type safety
* the key could imply the type of the value
  * provides type safety
  * guides programmer, documents structures, etc. -- everything we love about static types
  * it's also immediately clear which instance to use for decoding

#### `redis-schema`

In `redis-schema`, the type of `get` is:
```haskell
get :: Ref ref => ref -> RedisM (RefInstance ref) (Maybe (ValueType ref))
```
and it makes use of user-supplied declarations:
```haskell
data NumberOfVisitors = NumberOfVisitors Date

instance Ref NumberOfVisitors where
  type ValueType NumberOfVisitors = Integer
  toIdentifier (NumberOfVisitors date) =
    SviTopLevel $ Redis.colonSep ["number-of-visitors", BS.pack (show date)]
```

The differences are:
* Instead of `ByteStrings`, `redis-schema` uses references that are usually
  bespoke ADTs, such as `NumberOfVisitors`.
* Bespoke reference types eliminate string operations scattered across the code:
  you write `get (NumberOfVisitors today)` instead of
  `get ("number-of-visitors:" <> BS.pack (show today))`.
  `ByteString` concatenation of course needs to be done somewhere
  but it's implemented only once: in the `toIdentifier` method.
* The `Ref` instance of that data type determines that
  the reference stores `Integer`s. This can be seen
  in the associated type family `ValueType`.

More complex data structures, like records, work similarly.

### Composability

A major goal of `redis-schema` is to provide typed primitives,
on top of which one can safely and conveniently build further typed libraries,
such as [`Database.Redis.Lock`](#locks)
or [`Database.Redis.RemoteJob`](#remote-jobs).
[Meta-records](#meta-records) are another example of how low-level
primitives compose into higher-level "primitives" of the same kind.

The focus at composability is reflected in the design decisions of various typeclasses,
and in the design and use of Redis transactions to ensure that
composability is not broken by race conditions.

## Tutorial by example

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

In the current implementation, `Record`s cannot be read or written as a whole.
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

This creates a record with a separate field for every date:

```haskell
handleVisit :: VisitorId -> Date -> Redis ()
handleVisit visitorId today = do
  Redis.incrementBy (VisitorStats visitorId :. Visits today) 1
```

### Transactions

Redis does support transactions and `redis-schema` supports them,
but they are not like SQL transactions, which you may be accustomed to.
A more suggestive name for Redis transactions might be
"[mostly](#errors-in-transactions) atomic operation batches".

The main difference between SQL-like transactions and batched Redis transactions
is that in SQL, you can start a transaction, run a query, receive its output,
and then run another query in the same transaction. Sending queries and receiving their outputs
can be interleaved in the same transaction, and later queries can depend on the output
of previous queries, while the database takes care of the ACIDity of the transaction.

With Redis-style batched transactions, on the other hand, you can batch up
multiple operations but the atomicity of a transaction ends at the moment you
receive the output of those operations. Anything you do with the output is not
enclosed in that transaction anymore, and other clients could have modified the
data in the meantime. In other words, later operations in a batched transaction
cannot depend on the output of the previous operations, as that output is not
available yet.

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

Redis transactions are run using the combinator called `atomically`.
A failing operation (or using `txThrow`)
in a transaction [will not prevent any other side effects from taking place](#errors-in-transactions);
only the exception will be re-thrown in the `RedisM` monad
instead of returning the output of the transaction. The `Alternative` instance
of `Tx` can be used to address exceptions.

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
are not atomic in that sense, and may be carried out incompletely.
A Redis transaction that fails in the middle
will keep going and retain all effects except for any failed operations.
See [the Redis documentation](https://redis.io/docs/manual/transactions/#errors-inside-a-transaction)
for details and rationale.

#### Monads vs applicative functors

The underlying library of `redis-schema`, Hedis, provides a monad `RedisTx`
to describe Redis transactions. Since monads would be too powerful, Hedis uses
an opaque wrapper for `Queued` results to prevent the users from accessing
values that are not available yet. We believe that using an applicative functor
instead is a perfect match for this use case: it allows exactly the right
operations, and all wrapping/unwrapping can be done entirely transparently.
`Tx` also propagates exceptions from transactions transparently.

### Exceptions

The type of exceptions in `redis-schema` is `RedisException`,
and they are thrown using `throwIO` under the hood.
These arise mostly from internal error conditions, such as
connection errors, decoding errors, etc.,
but library users can nevertheless still throw them manually
using `throw :: RedisException -> RedisM inst a`.

Unlike `hedis`, `redis-schema` does support throwing exceptions
in transactions. Exceptions do *not* abort transactions
-- all effects of a transaction will persist even if an exception has been thrown --
but `RedisException`s thrown using `txThrow` are transparently propagated out of the transaction
and thrown at the `RedisM` level instead of returning the result of the transaction.

### Custom data types

Every type that can be stored in Redis using `redis-schema`
comes with a `Value` instance that describes how to read, write, and perform
other operations on values of that type in Redis.

There are two kinds of Redis `Value`s: simple values and non-simple values.
Simple values are those that encode/decode to/from a `ByteString`, and thus
have no restrictions on how they can be used in Redis.
They can be stored in top-level keys, as well as in Redis lists,
Redis sets, Redis hashes, etc. Simple values include
integers, floats, text, bytestrings, etc.

Non-simple values are all values that are more complicated than a bytestring,
and thus will come with restrictions. For example, Redis lists are not simple values.

Let's start by discussing simple values.

#### Simple values

The easiest case of declaring Redis instances for custom data types
are newtypes of types that already have Redis instances. For example,
if your user IDs are textual but you would still like to keep them apart
from other `Text` data, you could use the following declarations.

```haskell
{-# LANGUAGE DerivingStrategies #-}

newtype UserId = UserId Text
  deriving newtype (Redis.Serializable)

instance Redis.Value inst UserId
instance Redis.SimpleValue inst UserId
```

Thanks to `deriving newtype`, we did not have to write
any wrapping/unwrapping boilerplate, and thanks to
the default implementations of `Value` methods,
we did not have to write those, either.

The class `SimpleValue` does not have any methods, and it mostly
only stands for the list of constraints in its declaration
(primarily, for the `Serializable` constraint).
`SimpleValue` is a typeclass rather than a constraint alias
because you may want to have a `Serializable` instance for
a non-simple `Value`. Thus a `SimpleValue` instance also represents
the intentional declaration that the type in question should be regarded
as a simple value.

For other types, we need to supply a `Serializable` instance,
which is, however, often not too hard.

```haskell
data Color = Red | Green | Blue

instance Redis.Serializable Color where
  fromBS = Redis.readBS
  toBS   = Redis.showBS

-- Convenience functions available:
-- Redis.readBS :: Read val => ByteString -> Maybe val
-- Redis.showBS :: Show val => val -> ByteString

instance Redis.Value inst Color
instance Redis.SimpleValue inst Color
```

The typeclass `Serializable` is separate from `Show`, `Read`, and `Binary` because:
* `Show` and `Read` quote strings, and we need the ability to avoid doing it
* `Binary` does not produce human-readable output and would thus affect the usability of tools like `redis-cli`

Since `redis-schema` is intended to be imported qualified as `Redis`,
`Redis.Serializable` is an accurate name for the typeclass.

#### Non-simple values

Non-simple values have instances only for `Value`.
The default implementations of methods of `Value` require a `SimpleValue` instance,
thus relieving us from defining them whenever a `SimpleValue` instance exists.
For non-simple values, we have to implement the methods of `Value` manually.

Not all methods of `Value` may make sense for all data types,
or not all methods may be practically implementable.
In such cases, it's acceptable to fill the definition with an `error` message.

For example, the `Record` type defined by `redis-schema` does not support
reading/writing whole records because that would require more type-level
machinery than we needed at the time.

Another example is the fact that `setTTL` does not make (a lot of)
sense for values represented by `SviHash`,
i.e. for values that exist inside a Redis hash, as TTL can be set only for the whole hash.
Pragmatically, `redis-schema` resorts to silently changing the TTL for the whole hash.

Yet another example are the `PubSub` channels,
where the operations of `get` and `set` do not make sense.

In all these cases, the "correct" solution would be splitting the `Value`
typeclass into smaller classes per supported feature so that the availability
of the individual operations is declared at the type level. We decided to keep
things simple (if perhaps a bit crude) and use a single `Value` typeclass. This
may be revisited in the future.

#### Redis instances

In section [Simple Variables](#simple-variables), we have seen that
a `Redis.Ref` determines a "path to a variable" in Redis.
But what if you run more Redis servers? You might want that to use different
key eviction policies and different memory limits for different purposes.

The definition of `Redis.Ref` includes an extra associated type family
called `RefInstance`, which identifies the server, representing the hitherto
missing part of the "path to the variable". This type family has a default
value `DefaultInstance`, which is why we have not needed to deal with it so far.
Here's what it looks like:

```haskell
-- | The kind of Redis instances. Ideally, this would be a user-defined DataKind,
--   but since Haskell does not have implicit arguments,
--   that would require that we index everything with it explicitly,
--   which would create a lot of syntactic noise.
--
--   (Ab)using the * kind for instances is a compromise.
type Instance = *

-- | We also define a default instance.
--   This is convenient for code bases using only one Redis instance,
--   since 'RefInstance' defaults to this. (See the 'Ref' typeclass below.)
data DefaultInstance

-- | The Redis monad related to the default instance.
type Redis = RedisM DefaultInstance

class Value (RefInstance ref) (ValueType ref) => Ref ref where
  -- | Type of the value that this ref points to.
  type ValueType ref :: *

  -- | RedisM instance this ref points into, with a default.
  type RefInstance ref :: Instance
  type RefInstance ref = DefaultInstance

  -- | How to convert the ref to an identifier that its value accepts.
  toIdentifier :: ref -> Identifier (ValueType ref)
```

A Redis instance can be added by declaring an empty tag type,
for example as follows:

```haskell
-- For data that should not get lost
type InstReliable = Redis.DefaultInstance

-- For throwaway data to speed things up
data InstCacheLRU
```

Then a `Redis.Ref` can be placed in the appropriate Redis instance:
```haskell
-- This Ref needs to be reliable
data VisitorCount = VisitorCount

instance Redis.Ref VisitorCount where
  type ValueType VisitorCount = Integer
  type RefInstance VisitorCount = InstReliable
  toIdentifier VisitorCount = "visitor_count"


-- This Ref can be evicted as necessary
data CachedFile = CachedFile FilePath

instance Redis.Ref CachedFile where
  type ValueType CachedFile = ByteString
  type RefInstance CachedFile = InstCacheLRU
  toIdentifier (CachedFile path) = Redis.colonSep ["cached_files", BS.pack path]
```

Finally, all connections and the Redis monad are tagged
by the Redis instance, best illustrated by this type signature:

```haskell
run :: MonadIO m => Pool inst -> RedisM inst a -> m a
```

There are two consequences.
First, all operations in a `RedisM` computation must work with the same instance.
Second, it is practical to have a wrapper function around `run` that automatically
selects the right connection `Pool` from the environment, based on the Redis instance
specified in the type of the `RedisM` computation.

### Meta-records

In Haskell, records can be nested arbitrarily. You can have a record
that contains some fields alongside another couple of records,
which themselves contain arbitrarily nested maps and lists of further records.

Redis does not support such arbitrary nesting and being able to
access and manipulate the inner structures like you would a top-level one
(e.g. increment a counter deep in the structure).
However, we can often work around this limitation
by distributing the datastructure over a number of separate Redis keys.
For example, consider a case where each visitor should be associated with
the number of visits, the number of clicks, and the set of their favourite songs.
Here we can keep the visits+clicks in one record reference per visitor, and the set of favourites
in another reference, again per visitor.
However, we still need to read the visits+clicks separately from the favourites.
This is not just an impediment to convenience: two separate reads may lead to a race condition,
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
instance Redis.Ref VisitorStats where
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
in the `Value` instance, it's safe and it composes. Moreover, using `let`-bound
shorthand functions for common expressions, the repetition can be greatly minimised.

#### Aside: instances

Looking back at this instance head:
```haskell
instance Redis.Value Redis.DefaultInstance VisitorInfo where
```
we see that unlike in the usual case, this `Value` instance has been declared specifically
for `DefaultInstance`. The reason is that the definition of the `Value` instance
for `VisitorInfo` accesses Redis refs `VisitorStats` and `FavouriteSongs`,
and these refs are linked to `DefaultInstance`.

Since every Redis `Ref` must be linked to a specific Redis instance, and cannot be polymorphic
in the instance (its purpose is to give a path to the variable, as discussed),
all meta-records that access them under the hood must be declared for that particular instance.
Consequently, all `Ref`s that make up a meta-record must be linked to the same Redis instance.

## Libraries

### Locks

* Exclusive
* Shared

### Remote jobs

Sadly, this library has not been published yet.
We'd like to, though.

## Future work

* Numeric types in Redis never return `Nothing`; they'll return `Just 0` instead.
  Perhaps the return types could reflect that somehow.

* Different Redis `Value`s sometimes support different operations, as briefly discussed
  at [non-simple values](#non-simple-values). We may want to split `Value` into multiple
  type classes, depending on the supported operations.

* [Records](#records) cannot be read/written as a whole.
  The only reason is that we did not need it,
  and thus opted to avoid all the type-level machinery
  coming with extensible records.
  However, adopting an established library like `vinyl`
  as an optional dependency might be worth it.

## License

BSD 3-clause.

<!--
vim: ts=2 sts=2 sw=2 et
-->
