{-# LANGUAGE Strict #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE QuantifiedConstraints #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE UndecidableInstances #-} -- for (RefInstance ref) in constraints in instance head
{-# OPTIONS_GHC -fno-warn-orphans #-} -- for Hedis.RedisResult (a,b,c)

-- | The schema-based Redis module.
--   This module is intended to be imported qualified.
--   That's why we don't have 'RedisRef' but rather 'Redis.Ref'.
module Database.Redis.Schema
  ( Pool(..), RedisM(..)
    -- Pool and RedisM export their internals so other libraries can provide combinators
    -- like runNonBlocking or others. These internals are not meant to be used ordinarily.
  , Redis, Instance, DefaultInstance
  , Tx, atomically, runTx
  , RedisException(..)
  , Ref(..), Value(..)
  , SimpleRef, SimpleValue, SimpleValueIdentifier(..), Serializable(..), Serializables(..)
  , TTL(..)
  , run
  , connect
  , incrementBy, incrementByFloat
  , txIncrementBy, txIncrementByFloat
  , get, set, getSet
  , txGet, txSet, txExpect
  , setWithTTL, setIfNotExists, setIfNotExists_
  , txSetWithTTL, txSetIfNotExists, txSetIfNotExists_
  , delete_, txDelete_
  , Database.Redis.Schema.take, txTake
  , setTTL, setTTLIfExists, setTTLIfExists_
  , txSetTTL, txSetTTLIfExists, txSetTTLIfExists_
  , readBS, showBS
  , showBinary, readBinary, colonSep
  , Tuple(..)
  , day, hour, minute, second
  , throw, throwMsg
  , sInsert, sDelete, sContains, sSize
  , Priority(..), zInsert, zSize, zCount, zDelete, zIncrBy, zPopMax, zPopMin, bzPopMin, zRangeByScoreLimit, zRange, zRevRange, zScanOpts, zUnionStoreWeights
  , txSInsert, txSDelete, txSContains, txSSize
  , MapItem(..)
  , RecordField(..), RecordItem(..), Record
  , lLength, lAppend, txLAppend, lPushLeft, lPopRight, lPopRightBlocking, lRem
  , watch, unwatch
  , unliftIO
  , deleteIfEqual, setIfNotExistsTTL
  , PubSub, pubSubListen, pubSubCountSubs
  ) where

import GHC.Word         ( Word32  )
import Data.Functor     ( void, (<&>) )
import Data.Function    ( (&) )
import Data.Time        ( UTCTime, LocalTime, Day )
import Text.Read        ( readMaybe )
import Data.ByteString  ( ByteString )
import Data.Binary      ( Binary, encode, decodeOrFail )
import Data.Text        ( Text )
import Data.Text.Encoding ( encodeUtf8, decodeUtf8 )
import Data.Kind        ( Type )
import Data.Map         ( Map )
import Data.Set         ( Set )
import Data.Int         ( Int64 )
import Data.UUID        ( UUID )
import qualified Data.UUID as UUID

import Control.Applicative
import qualified Control.Arrow as Arrow
import Control.Monad        ( (<=<) )
import Control.Exception    ( throwIO, Exception )
import Control.Monad.Reader ( runReaderT, ask )
import Control.Monad.IO.Class ( liftIO, MonadIO )

import qualified Numeric.Limits
import qualified Database.Redis as Hedis
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified System.IO.Error as IOE

-- | Each instance has a distinct connection pool type.
-- (Hedis names it Connection but it's a pool.)
newtype Pool inst = Pool{_unPool :: Hedis.Connection}

-- | Instance-indexed monad for Redis computations.
newtype RedisM inst a = Redis{unRedis :: Hedis.Redis a}
 deriving newtype (Functor, Applicative, Monad, MonadIO, Hedis.MonadRedis)

-- | The kind of Redis instances. Ideally, this would be a user-defined DataKind,
--   but since Haskell does not have implicit arguments,
--   that would require that we index everything with it explicitly,
--   which would create a lot of syntactic noise.
--
--   (Ab)using the Type kind for instances is a compromise.
type Instance = Type

-- | We also define a default instance.
--   This is convenient for code bases using only one Redis instance,
--   since 'RefInstance' defaults to this. (See the 'Ref' typeclass below.)
data DefaultInstance

-- | The Redis monad related to the default instance.
type Redis = RedisM DefaultInstance

instance Hedis.RedisCtx (RedisM inst) (Either Hedis.Reply) where
  returnDecode = Redis . Hedis.returnDecode

data RedisException
  = BadConnectionString String String
  | CouldNotPing String
  | UnexpectedResult String String
  | UserException String
  | TransactionAborted
  | TransactionError String
  | CouldNotDecodeValue (Maybe ByteString)
  | LockAcquireTimeout
  | UnexpectedStatus String Hedis.Status
  | EmptyAlternative  -- for 'instance Alternative Tx'
  deriving (Show, Exception)

-- | Time-To-Live for Redis values. The Num instance works in (integral) seconds.
newtype TTL = TTLSec { ttlToSeconds :: Integer }
  deriving newtype (Eq, Ord, Num)

run :: MonadIO m => Pool inst -> RedisM inst a -> m a
run (Pool pool) = liftIO . Hedis.runRedis pool . unRedis

throw :: RedisException -> RedisM inst a
throw = liftIO . throwIO

throwMsg :: String -> RedisM inst a
throwMsg = throw . UserException

-- | Expect Right, otherwise throw UnexpectedResult.
expectRight :: Show e => String -> Either e a -> RedisM inst a
expectRight _msg (Right x) = pure x
expectRight  msg (Left e) = throw $ UnexpectedResult ("Redis.expectRight: " ++ msg) (show $ left e)
  where
    -- hard to give this type to Left inline
    left :: e -> Either e ()
    left = Left

-- | Expect transaction success, otherwise throw.
expectTxSuccess :: Hedis.TxResult a -> RedisM inst a
expectTxSuccess (Hedis.TxSuccess x) = pure x
expectTxSuccess  Hedis.TxAborted    = throw TransactionAborted
expectTxSuccess (Hedis.TxError err) = throw $ TransactionError err

-- | Expect exact value, otherwise throw UnexpectedResult.
expect :: (Eq a, Show a) => String -> a -> a -> RedisM inst ()
expect msg expected actual
  | expected == actual = pure ()
  | otherwise = throw $ UnexpectedResult ("Redis.expect: " ++ msg) (show actual)

-- Useful in combination with the expect* functions.
ignore :: a -> RedisM inst ()
ignore _ = pure ()

-- | Open a connection pool to redis
connect :: String -> Int -> IO (Pool inst)
connect connectionString poolSize =
  case Hedis.parseConnectInfo connectionString of
    Left err -> throwIO $ BadConnectionString connectionString err
    Right connInfo -> do
      pool <- Hedis.connect connInfo
        { Hedis.connectMaxConnections = poolSize
        }
      customizeIOError connectionString (Hedis.runRedis pool Hedis.ping) >>= \case
        Right Hedis.Pong -> return (Pool pool)
        resp -> throwIO $ CouldNotPing (show resp)
  where
    -- Runs an IO action and prepends a custom error message to any occuring IOError
    customizeIOError :: String -> IO a -> IO a
    customizeIOError errorMessage action = IOE.modifyIOError customError action
      where
      customError :: IOError -> IOError
      customError err = IOE.ioeSetErrorString err (errorMessage <> "; " <> IOE.ioeGetErrorString err)

-- | Redis transactions.
--
-- In comparison with Hedis transactions:
--
-- * 'Tx' is newtyped as a separate functor for clearer types and better error messages.
--
-- * 'Tx' is not a monad, just an 'Applicative' functor.
--   Applicative exactly corresponds to the nature of Redis transactions,
--   and does not need 'Queued' hacks.
--
-- * 'Tx' supports throwing, and catching via 'Alternative'.
--   Beware that 'Tx' is 'Applicative' so all side effects will be carried out,
--   whether any actions throw or not. Throwing and catching is done at the level
--   where the _results_ of the individual applicative actions are composed.
--
-- You can still have do-notation with the @ApplicativeDo@ extension.
newtype Tx inst a = Tx
  { unTx :: Hedis.RedisTx (Hedis.Queued (Either RedisException a))
  }

instance Functor (Tx inst) where
  fmap f (Tx tx) = Tx $ fmap (fmap (fmap f)) tx

instance Applicative (Tx inst) where
  pure x = Tx $ pure (pure (pure x))
  Tx txF <*> Tx txX = Tx $ do
    queuedF <- txF
    queuedX <- txX
    pure $ do
      eitherF <- queuedF
      eitherX <- queuedX
      pure (eitherF <*> eitherX)

instance Alternative (Tx inst) where
  empty = txThrow EmptyAlternative
  Tx txX <|> Tx txY = Tx $ do
    queuedX <- txX
    queuedY <- txY
    pure $ do
      eitherX <- queuedX
      eitherY <- queuedY
      pure $ case eitherX of
        Right x -> Right x
        Left _err -> case eitherY of
          Right y -> Right y
          Left err -> Left err

-- | Run a Redis transaction and return its result.
--
-- Most code will probably want to use 'atomically' instead,
-- which automatically propagates errors.
runTx :: Tx inst a -> RedisM inst (Hedis.TxResult (Either RedisException a))
runTx = Redis . Hedis.multiExec . unTx

-- | Throw in a transaction.
txThrow :: RedisException -> Tx inst a
txThrow e = Tx $ pure (pure (Left e))

-- | Embed a raw Hedis action in a 'Tx' transaction.
txWrap :: Hedis.RedisTx (Hedis.Queued a) -> Tx inst a
txWrap action = Tx (fmap Right <$> action)

-- | Run a 'Tx' transaction, propagating any errors.
atomically :: Tx inst a -> RedisM inst a
atomically tx = runTx tx >>= expectTxSuccess >>= \case
  Right x -> pure x
  Left  e -> throw e

-- | Apply a possibly failing computation to the result of a transaction.
--
-- Useful for implementation of various checks.
txCheckMap :: (a -> Either RedisException b) -> Tx inst a -> Tx inst b
txCheckMap f (Tx tx) = Tx (fmap (fmap g) tx)
  where
    g (Left e) = Left e  -- we already had an error here
    g (Right x) = f x    -- possibly fail

-- | Expect an exact value.
txExpect :: (Eq a, Show a) => String -> a -> Tx inst a -> Tx inst ()
txExpect msg expected = void . txCheckMap f
  where
    f x | x == expected = Right x
        | otherwise = Left $ UnexpectedResult msg (show x)

-- | Reference to some abstract Redis value.
--
-- 'ByteString's are inappropriate for this purpose:
--
-- * 'Ref's are typed.
--
-- * bytestring concatenation and other faffing is ugly and error-prone.
--
-- * some values may be stored across several Redis keys,
--   (such as Tiers.Redis.Profile),
--   in which case bytestrings are not even sufficient.
--
-- All methods have defaults for easy implementation of 'SimpleValue's for new types.
-- For simple values, it's sufficient to implement (or newtype-derive) 'SimpleValue',
-- and declare an empty @instance Value <TheType>@.
class Value (RefInstance ref) (ValueType ref) => Ref ref where
  -- | Type of the value that this ref points to.
  type ValueType ref :: Type

  -- | RedisM instance this ref points into, with a default.
  type RefInstance ref :: Instance
  type RefInstance ref = DefaultInstance

  -- | How to convert the ref to an identifier that its value accepts.
  toIdentifier :: ref -> Identifier (ValueType ref)

-- | Type that can be read/written from Redis.
--
-- This can be a simple value, such as string or integer, or a composite value,
-- such as a complex record stored across multiple keys, hashes, sets and lists.
--
-- We parameterise the typeclass with the Redis instance.
-- Most Value instances will want to keep 'inst' open
-- but some may need to restrict it to a particular Redis instance;
-- especially those that access Refs under the hood, since Refs are instance-specific.
class Value inst val where
  -- | How the value is identified in Redis.
  --
  -- Types like hashes, sets or list are always top-level keys in Redis,
  -- so these are identified by bytestrings. Simple values can be top-level
  -- or hash fields, so they are identified by SimpleValueIdentifier.
  -- Complex values may be identified by something else; for example
  -- 'Tiers.Redis.Profile' is identified by a 'Tiers.Token',
  -- because it's a complex value spread across multiple Redis keys.
  type Identifier val :: Type
  type Identifier val = SimpleValueIdentifier  -- default


  -- | Read a value from Redis in a transaction.
  txValGet :: Identifier val -> Tx inst (Maybe val)

  default txValGet :: SimpleValue inst val => Identifier val -> Tx inst (Maybe val)
  txValGet (SviTopLevel keyBS) = fmap (fromBS =<<) . txWrap $ Hedis.get keyBS
  txValGet (SviHash keyBS hkeyBS) = fmap (fromBS =<<) . txWrap $ Hedis.hget keyBS hkeyBS

  -- | Write a value to Redis in a transaction.
  txValSet :: Identifier val -> val -> Tx inst ()

  default txValSet :: SimpleValue inst val => Identifier val -> val -> Tx inst ()
  txValSet (SviTopLevel keyBS) val =
    txExpect "txValSet/plain" Hedis.Ok
      $ txWrap (Hedis.set keyBS $ toBS val)
  txValSet (SviHash keyBS hkeyBS) val =
    void
      $ txWrap (Hedis.hset keyBS hkeyBS $ toBS val)

  -- | Delete a value from Redis in a transaction.
  txValDelete :: Identifier val -> Tx inst ()

  default txValDelete :: SimpleValue inst val => Identifier val -> Tx inst ()
  txValDelete (SviTopLevel keyBS) = void . txWrap $ Hedis.del [keyBS]
  txValDelete (SviHash keyBS hkeyBS) = void . txWrap $ Hedis.hdel keyBS [hkeyBS]

  -- | Set time-to-live for a value in a transaction. Return 'True' if the value exists.
  txValSetTTLIfExists :: Identifier val -> TTL -> Tx inst Bool

  default txValSetTTLIfExists :: SimpleValue inst val => Identifier val -> TTL -> Tx inst Bool
  txValSetTTLIfExists (SviTopLevel keyBS) (TTLSec ttlSec) =
    txWrap $ Hedis.expire keyBS ttlSec
  txValSetTTLIfExists (SviHash keyBS _hkeyBS) (TTLSec ttlSec) =
    txWrap $ Hedis.expire keyBS ttlSec


  -- | Read a value.
  valGet :: Identifier val -> RedisM inst (Maybe val)

  default valGet :: SimpleValue inst val => Identifier val -> RedisM inst (Maybe val)
  valGet (SviTopLevel keyBS) =
    fmap (fromBS =<<) . expectRight "valGet/plain" =<< Hedis.get keyBS
  valGet (SviHash keyBS hkeyBS) =
    fmap (fromBS =<<) . expectRight "valGet/hash" =<< Hedis.hget keyBS hkeyBS

  -- | Write a value.
  valSet :: Identifier val -> val -> RedisM inst ()

  default valSet :: SimpleValue inst val => Identifier val -> val -> RedisM inst ()
  valSet (SviTopLevel keyBS) val =
    expect "valSet/plain" (Right Hedis.Ok) =<< Hedis.set keyBS (toBS val)
  valSet (SviHash keyBS hkeyBS) val =
    ignore {- @Integer -} =<< expectRight "valSet/hash" =<< Hedis.hset keyBS hkeyBS (toBS val)
      --   ^- this is Bool in some versions of Hedis and Integer in others

  -- | Delete a value.
  valDelete :: Identifier val -> RedisM inst ()

  default valDelete :: SimpleValue inst val => Identifier val -> RedisM inst ()
  valDelete (SviTopLevel keyBS) =
    ignore @Integer =<< expectRight "valDelete/plain" =<< Hedis.del [keyBS]
  valDelete (SviHash keyBS hkeyBS) =
    ignore @Integer =<< expectRight "valDelete/hash" =<< Hedis.hdel keyBS [hkeyBS]

  -- | Set time-to-live for a value. Return 'True' if the value exists.
  valSetTTLIfExists :: Identifier val -> TTL -> RedisM inst Bool

  default valSetTTLIfExists :: SimpleValue inst val => Identifier val -> TTL -> RedisM inst Bool
  valSetTTLIfExists (SviTopLevel keyBS) (TTLSec ttlSec) =
    expectRight "valSetTTLIfExists/plain" =<< Hedis.expire keyBS ttlSec
  valSetTTLIfExists (SviHash keyBS _hkeyBS) (TTLSec ttlSec) =
    expectRight "valSetTTLIfExists/hash" =<< Hedis.expire keyBS ttlSec

data SimpleValueIdentifier
  = SviTopLevel ByteString         -- ^ Stored in a top-level key.
  | SviHash ByteString ByteString  -- ^ Stored in a hash field.

-- | Simple values, like strings, integers or enums,
-- that be represented as a single bytestring.
--
-- Of course, any value can be represented as a single bytestring,
-- but structures like lists, hashes and sets have special support in Redis.
-- This allows insertions, updates, etc. in Redis directly,
-- but they cannot be read or written as bytestrings, and thus are not 'SimpleValue's.
class (Value inst val, Identifier val ~ SimpleValueIdentifier, Serializable val) => SimpleValue inst val

class Serializable val where
  fromBS :: ByteString -> Maybe val
  toBS :: val -> ByteString

-- | 'Ref' pointing to a 'SimpleValue'.
type SimpleRef ref = (Ref ref, SimpleValue (RefInstance ref) (ValueType ref))

get :: Ref ref => ref -> RedisM (RefInstance ref) (Maybe (ValueType ref))
get = valGet . toIdentifier

txGet :: Ref ref => ref -> Tx (RefInstance ref) (Maybe (ValueType ref))
txGet = txValGet . toIdentifier

set :: Ref ref => ref -> ValueType ref -> RedisM (RefInstance ref) ()
set = valSet . toIdentifier

txSet :: Ref ref => ref -> ValueType ref -> Tx (RefInstance ref) ()
txSet = txValSet . toIdentifier

delete_ :: forall ref. Ref ref => ref -> RedisM (RefInstance ref) ()
delete_ = valDelete @_ @(ValueType ref) . toIdentifier

txDelete_ :: forall ref. Ref ref => ref -> Tx (RefInstance ref) ()
txDelete_ = txValDelete @_ @(ValueType ref) . toIdentifier

-- | Atomically read and delete.
take :: Ref ref => ref -> RedisM (RefInstance ref) (Maybe (ValueType ref))
take ref = atomically (txTake ref)

-- | Atomically read and delete in a transaction.
txTake :: Ref ref => ref -> Tx (RefInstance ref) (Maybe (ValueType ref))
txTake ref = txGet ref <* txDelete_ ref

-- | Atomically set a value and return its old value.
getSet :: forall ref. SimpleRef ref => ref -> ValueType ref -> RedisM (RefInstance ref) (Maybe (ValueType ref))
getSet ref val = case toIdentifier ref of
  SviTopLevel keyBS ->
    fmap (fromBS =<<) . expectRight "getSet/plain"
      =<< Hedis.getset keyBS (toBS val)

  -- no native Redis call for this
  SviHash _ _ -> atomically (txGet ref <* txSet ref val)

-- | Bump the TTL without changing the content.
setTTLIfExists :: forall ref. Ref ref => ref -> TTL -> RedisM (RefInstance ref) Bool
setTTLIfExists = valSetTTLIfExists @_ @(ValueType ref) . toIdentifier

setTTLIfExists_ :: Ref ref => ref -> TTL -> RedisM (RefInstance ref) ()
setTTLIfExists_ ref = void . setTTLIfExists ref

setTTL :: Ref ref => ref -> TTL -> RedisM (RefInstance ref) ()
setTTL ref ttl = setTTLIfExists ref ttl >>= expect "setTTL: ref should exist" True

txSetTTLIfExists :: forall ref. Ref ref => ref -> TTL -> Tx (RefInstance ref) Bool
txSetTTLIfExists = txValSetTTLIfExists @_ @(ValueType ref) . toIdentifier

txSetTTLIfExists_ :: forall ref. Ref ref => ref -> TTL -> Tx (RefInstance ref) ()
txSetTTLIfExists_ ref ttl = void $ txSetTTLIfExists ref ttl

txSetTTL :: Ref ref => ref -> TTL -> Tx (RefInstance ref) ()
txSetTTL ref ttl =
  txSetTTLIfExists ref ttl
    & txExpect "txSetTTL: ref should exist" True

txSetWithTTL :: SimpleRef ref => ref -> TTL -> ValueType ref -> Tx (RefInstance ref) ()
txSetWithTTL ref ttl val = txSet ref val *> txSetTTL ref ttl

-- | Set value and TTL atomically.
setWithTTL :: forall ref. SimpleRef ref => ref -> TTL -> ValueType ref  -> RedisM (RefInstance ref) ()
setWithTTL ref ttl@(TTLSec ttlSec) val = case toIdentifier ref of
  SviTopLevel keyBS -> Hedis.setex keyBS ttlSec (toBS val)
    >>= expectRight "setWithTTL/SETEX"
    >>= expect "setWithTTL/SETEX should return OK" Hedis.Ok
  SviHash _ _ -> atomically (txSet ref val <* txSetTTL ref ttl)

-- | Increment the value under the given ref.
incrementBy :: (SimpleRef ref, Num (ValueType ref)) => ref -> Integer -> RedisM (RefInstance ref) (ValueType ref)
incrementBy ref val = fmap fromInteger . expectRight "incrementBy" =<< case toIdentifier ref of
  SviTopLevel keyBS -> Hedis.incrby keyBS val
  SviHash keyBS hkeyBS -> Hedis.hincrby keyBS hkeyBS val

txIncrementBy :: (SimpleRef ref, Num (ValueType ref)) => ref -> Integer -> Tx (RefInstance ref) (ValueType ref)
txIncrementBy ref val = fmap fromInteger . txWrap $ case toIdentifier ref of
  SviTopLevel keyBS -> Hedis.incrby keyBS val
  SviHash keyBS hkeyBS -> Hedis.hincrby keyBS hkeyBS val

-- | Increment the value under the given ref.
incrementByFloat :: (SimpleRef ref, Floating (ValueType ref)) => ref -> Double -> RedisM (RefInstance ref) (ValueType ref)
incrementByFloat ref val = fmap realToFrac . expectRight "incrementByFloat" =<< case toIdentifier ref of
  SviTopLevel keyBS -> Hedis.incrbyfloat keyBS val
  SviHash keyBS hkeyBS -> Hedis.hincrbyfloat keyBS hkeyBS val

txIncrementByFloat :: (SimpleRef ref, Floating (ValueType ref)) => ref -> Double -> Tx (RefInstance ref) (ValueType ref)
txIncrementByFloat ref val = fmap realToFrac . txWrap $ case toIdentifier ref of
  SviTopLevel keyBS -> Hedis.incrbyfloat keyBS val
  SviHash keyBS hkeyBS -> Hedis.hincrbyfloat keyBS hkeyBS val

setIfNotExists :: forall ref. SimpleRef ref => ref -> ValueType ref -> RedisM (RefInstance ref) Bool
setIfNotExists ref val = expectRight "setIfNotExists" =<< case toIdentifier ref of
  SviTopLevel keyBS -> Hedis.setnx keyBS (toBS val)
  SviHash keyBS hkeyBS -> Hedis.hsetnx keyBS hkeyBS (toBS val)

setIfNotExists_ :: SimpleRef ref => ref -> ValueType ref -> RedisM (RefInstance ref) ()
setIfNotExists_ ref val = void $ setIfNotExists ref val

txSetIfNotExists :: forall ref. SimpleRef ref => ref -> ValueType ref -> Tx (RefInstance ref) Bool
txSetIfNotExists ref val = txWrap $ case toIdentifier ref of
  SviTopLevel keyBS -> Hedis.setnx keyBS (toBS val)
  SviHash keyBS hkeyBS -> Hedis.hsetnx keyBS hkeyBS (toBS val)

txSetIfNotExists_ :: SimpleRef ref => ref -> ValueType ref -> Tx (RefInstance ref) ()
txSetIfNotExists_ ref val = void $ txSetIfNotExists ref val

setIfNotExistsTTL :: forall ref. SimpleRef ref => ref -> ValueType ref -> TTL -> RedisM (RefInstance ref) Bool
setIfNotExistsTTL ref val (TTLSec ttlSec) =
  (== Right Hedis.Ok) <$> case toIdentifier ref of
    SviHash _keyBS _hkeyBS -> error "setIfNotExistsTTL: hash keys not supported"
    SviTopLevel keyBS -> Hedis.setOpts keyBS (toBS val) Hedis.SetOpts
      { Hedis.setSeconds      = Just ttlSec
      , Hedis.setMilliseconds = Nothing
      , Hedis.setCondition    = Just Hedis.Nx
      }

deleteIfEqual :: forall ref. SimpleRef ref => ref -> ValueType ref -> RedisM (RefInstance ref) Bool
deleteIfEqual ref val =
  fmap (/= (0 :: Integer)) . expectRight "deleteIfEqual" =<< case toIdentifier ref of
    SviHash _keyBS _hkeyBS -> error "deleteIfEqual: hash keys not supported"
    SviTopLevel keyBS -> Hedis.eval luaSource [keyBS] [toBS val]
  where
    luaSource :: ByteString
    luaSource = BS.unlines
      [ "if redis.call(\"get\",KEYS[1]) == ARGV[1] then"
      , "  return redis.call(\"del\",KEYS[1])"
      , "else"
      , "  return 0"
      , "end"
      ]

-- | Make any subsequent transaction fail if the watched ref is modified
-- between the call to 'watch' and the transaction.
watch :: SimpleRef ref => ref -> RedisM (RefInstance ref) ()
watch ref = case toIdentifier ref of
  SviTopLevel keyBS ->
    Redis (Hedis.watch [keyBS]) >>= expect "watch/plain: OK expected" (Right Hedis.Ok)
  SviHash keyBS _hkeyBS ->
    Redis (Hedis.watch [keyBS]) >>= expect "watch/hash: OK expected" (Right Hedis.Ok)

-- | Unwatch all watched keys.
-- I can't find it anywhere in the documentation
-- but I hope that this unwatches only the keys for the current connection,
-- and does not affect other connections. Nothing else would make much sense.
unwatch :: RedisM inst ()
unwatch = Redis Hedis.unwatch >>= expect "unwatch: OK expected" (Right Hedis.Ok)

-- | Decode a list of ByteStrings.
-- On failure, return the first ByteString that could not be decoded.
fromBSMany :: Serializable val => [ByteString] -> Either ByteString [val]
fromBSMany = traverse $ \valBS -> case fromBS valBS of
  Just val -> Right val    -- decoded correctly
  Nothing  -> Left  valBS  -- decoding failure, return the malformed bytestring

txFromBSMany :: Serializable val => Tx inst [ByteString] -> Tx inst [val]
txFromBSMany = txCheckMap (f . fromBSMany)
  where
    f (Left badBS) = Left $ CouldNotDecodeValue (Just badBS)
    f (Right vals) = Right vals

instance Value inst ()
instance Serializable () where
  fromBS = const $ Just ()
  toBS = const ""
instance SimpleValue inst ()

{- conflicts with the [a] instance
instance Value inst String
instance Serializable String where
  fromBS = fmap Text.unpack . fromBS
  toBS = toBS . Text.pack
-}

instance Value inst Text
instance Serializable Text where
  fromBS = Just . decodeUtf8
  toBS = encodeUtf8
instance SimpleValue inst Text

instance Value inst Int
instance Serializable Int where
  fromBS = readBS
  toBS   = showBS
instance SimpleValue inst Int

instance Value inst Word32
instance Serializable Word32 where
  fromBS = readBS
  toBS   = showBS
instance SimpleValue inst Word32

instance Value inst Int64
instance Serializable Int64 where
  fromBS = readBS
  toBS   = showBS
instance SimpleValue inst Int64

instance Value inst Integer
instance Serializable Integer where
  fromBS = readBS
  toBS   = showBS
instance SimpleValue inst Integer

instance Value inst Double
instance Serializable Double where
  fromBS = readBS
  toBS   = showBS
instance SimpleValue inst Double

instance Value inst Bool
instance Serializable Bool where
  fromBS "0" = Just False
  fromBS "1" = Just True
  fromBS _ = Nothing

  toBS True  = "1"
  toBS False = "0"
instance SimpleValue inst Bool

instance Value inst UTCTime
instance Serializable UTCTime where
  fromBS = readBS
  toBS = showBS
instance SimpleValue inst UTCTime

instance Value inst Day
instance Serializable Day where
  fromBS = readBS
  toBS = showBS
instance SimpleValue inst Day

instance Value inst LocalTime
instance Serializable LocalTime where
  fromBS = readBS
  toBS = showBS
instance SimpleValue inst LocalTime

instance Value inst ByteString
instance Serializable ByteString where
  toBS   = id
  fromBS = Just
instance SimpleValue inst ByteString

instance Value inst BSL.ByteString
instance Serializable BSL.ByteString where
  toBS   = BSL.toStrict
  fromBS = Just . BSL.fromStrict
instance SimpleValue inst BSL.ByteString

instance Serializable UUID where
  toBS = toBS . UUID.toText
  fromBS = UUID.fromText <=< fromBS

instance Serializable a => Serializable (Maybe a) where
  fromBS b = case BS.uncons b of
    Just ('N', "") -> Just Nothing -- parsing succeeded, found Nothing
    Just ('J', r)  -> Just <$> fromBS r
    _              -> Nothing -- Parsing failed
  toBS Nothing  = "N"
  toBS (Just a) = "J" <> toBS a

instance (Serializable a, Serializable b) => Serializable (Either a b) where
  fromBS b = case BS.uncons b of
    Just ('L', xBS) -> Left <$> fromBS xBS
    Just ('R', yBS) -> Right <$> fromBS yBS
    _ -> Nothing
  toBS (Left x) = BS.cons 'L' (toBS x)
  toBS (Right y) = BS.cons 'R' (toBS y)

instance (SimpleValue inst a, SimpleValue inst b) => Value inst (a, b)
instance (Serializable a, Serializable b) => Serializable (a, b) where
  toBS (x, y) = toBS @(Tuple '[a,b]) (x :*: y :*: Nil)
  fromBS bs =
    fromBS @(Tuple '[a,b]) bs <&>
      \(x :*: y :*: Nil) -> (x,y)
instance (SimpleValue inst a, SimpleValue inst b) => SimpleValue inst (a,b)

instance (SimpleValue inst a, SimpleValue inst b, SimpleValue inst c) => Value inst (a, b, c)
instance (Serializable a, Serializable b, Serializable c) => Serializable (a, b, c) where
  toBS (x, y, z) = toBS (x :*: y :*: z :*: Nil)
  fromBS bs =
    fromBS @(Tuple '[a,b,c]) bs <&>
      \(x :*: y :*: z :*: Nil) -> (x,y,z)
instance (SimpleValue inst a, SimpleValue inst b, SimpleValue inst c) => SimpleValue inst (a, b, c)

readBS :: Read val => ByteString -> Maybe val
readBS = readMaybe . BS.unpack

showBS :: Show val => val -> ByteString
showBS = BS.pack . show

showBinary :: Binary val => val -> ByteString
showBinary = BSL.toStrict . encode

readBinary :: Binary val => ByteString -> Maybe val
readBinary bytes = case decodeOrFail $ BSL.fromStrict bytes of
  Left _ -> Nothing
  Right (_, _, val) -> Just val

colonSep :: [BS.ByteString] -> BS.ByteString
colonSep = BS.intercalate ":"

infixr 3 :*:
data Tuple :: [Type] -> Type where
  Nil :: Tuple '[]
  (:*:) :: a -> Tuple as -> Tuple (a ': as)

instance Eq (Tuple '[]) where
  _ == _ = True

instance Ord (Tuple '[]) where
  compare _ _ = EQ

instance (Eq a, Eq (Tuple as)) => Eq (Tuple (a ': as)) where
  (x :*: xs) == (y :*: ys) = x == y && xs == ys

instance (Ord a, Ord (Tuple as)) => Ord (Tuple (a ': as)) where
  compare (x :*: xs) (y :*: ys) = compare x y <> compare xs ys

class Serializables (as :: [Type]) where
  encodeSerializables :: Tuple as -> [BS.ByteString]
  decodeSerializables :: [BS.ByteString] -> Maybe (Tuple as)

instance Serializables '[] where
  encodeSerializables Nil = []

  decodeSerializables [] = Just Nil
  decodeSerializables _  = Nothing

instance (Serializable a, Serializables as) => Serializables (a ': as) where
  encodeSerializables (x :*: xs) = toBS x : encodeSerializables xs

  decodeSerializables [] = Nothing
  decodeSerializables (bs : bss) = (:*:) <$> fromBS bs <*> decodeSerializables bss

instance Serializables as => Value inst (Tuple as)
instance Serializables as => Serializable (Tuple as) where
  toBS = encodeBSs . encodeSerializables
    where
      -- Encode a list of bytestrings into a single bytestring
      -- that's unambiguous (for machines) but human-readable (for humans).
      --
      -- This is useful for tuples and records
      -- that you need to put in a Redis list or a Redis set
      -- so they need to be Serializables.
      --
      -- The format:
      --   <length1>,<length2>,...,<lengthN>:<string1>:<string2>:...:<stringN>
      --
      -- Lengths are base10 numbers, strings are literal binary strings.
      encodeBSs :: [BS.ByteString] -> BS.ByteString
      encodeBSs bss = BS.intercalate ":" (lengths : bss)
        where
          lengths = BS.intercalate "," [BS.pack (show (BS.length bs)) | bs <- bss]

  fromBS = decodeSerializables <=< decodeBSs
    where
      decodeBSs :: BS.ByteString -> Maybe [BS.ByteString]
      decodeBSs bsWhole = do
          lengths <- traverse fromBS $ BS.split ',' bsLengths
          splitLengths lengths bsData
        where
          -- bsData starts with a colon
          (bsLengths, bsData) = BS.span (/= ':') bsWhole

          splitLengths [] "" = Just []
          splitLengths [] _trailingGarbage = Nothing
          splitLengths (l:ls) bs = case BS.uncons bs of
            Just (':', bsNoColon) ->
              let (item, rest) = BS.splitAt l bsNoColon
                in (item :) <$> splitLengths ls rest

            _ -> Nothing
instance Serializables as => SimpleValue inst (Tuple as)

day :: TTL
day = 24 * hour

hour :: TTL
hour = 60 * minute

minute :: TTL
minute = 60 * second

second :: TTL
second = TTLSec 1

-- | Redis lists.
instance Serializable a => Value inst [a] where
  type Identifier [a] = ByteString

  txValGet keyBS =
    txWrap (Hedis.lrange keyBS 0 (-1))
    & txFromBSMany
    & fmap Just
  txValSet keyBS vs = void $ txWrap (Hedis.del [keyBS] *> Hedis.rpush keyBS (map toBS vs))
  txValDelete keyBS = void $ txWrap (Hedis.del [keyBS])
  txValSetTTLIfExists keyBS (TTLSec ttlSec) = txWrap (Hedis.expire keyBS ttlSec)

  valGet keyBS =
    Redis (Hedis.lrange keyBS 0 (-1))
      >>= expectRight "valGet/[a]"
      >>= (fromBSMany <&> \case
        Left badBS -> throw $ CouldNotDecodeValue (Just badBS)
        Right vs -> pure (Just vs))

  valSet keyBS vs =
    Redis (Hedis.multiExec (Hedis.del [keyBS] *> Hedis.rpush keyBS (map toBS vs)))
      >>= expectTxSuccess
      >>= ignore @Integer
  valDelete keyBS =
    Redis (Hedis.del [keyBS])
      >>= expectRight "valDelete/[a]"
      >>= ignore @Integer
  valSetTTLIfExists keyBS (TTLSec ttlSec) =
    Redis (Hedis.expire keyBS ttlSec)
      >>= expectRight "valSetTTLIfExists/[a]"

-- | Append to a Redis list.
lAppend :: forall ref a. (Ref ref, ValueType ref ~ [a], Serializable a) => ref -> [a] -> RedisM (RefInstance ref) ()
lAppend (toIdentifier -> keyBS) vals =
  Redis (Hedis.rpush keyBS (map toBS vals))
    >>= expectRight "rpush"
    >>= ignore @Integer

-- | Append to a Redis list in a transaction.
txLAppend :: forall ref a. (Ref ref, ValueType ref ~ [a], Serializable a) => ref -> [a] -> Tx (RefInstance ref) ()
txLAppend (toIdentifier -> keyBS) vals =
  void . txWrap $ Hedis.rpush keyBS (map toBS vals)

-- | Length of a Redis list
lLength :: forall ref a. (Ref ref, ValueType ref ~ [a], Serializable a) => ref -> RedisM (RefInstance ref) Integer
lLength (toIdentifier -> keyBS) =
  Redis (Hedis.llen keyBS)
    >>= expectRight "llen"

-- | Prepend to a Redis list.
lPushLeft :: forall ref a. (Ref ref, ValueType ref ~ [a], Serializable a) => ref -> [a] -> RedisM (RefInstance ref) ()
lPushLeft (toIdentifier -> keyBS) vals =
  Redis (Hedis.lpush keyBS (map toBS vals))
    >>= expectRight "lpush"
    >>= ignore @Integer

-- | Pop from the right.
lPopRight :: forall ref a. (Ref ref, ValueType ref ~ [a], Serializable a) => ref -> RedisM (RefInstance ref) (Maybe a)
lPopRight (toIdentifier -> keyBS) =
  Redis (Hedis.rpop keyBS)
  >>= fmap (fromBS =<<) . expectRight "rpop"

-- | Pop from the right, blocking.
lPopRightBlocking :: forall ref a. (Ref ref, ValueType ref ~ [a], Serializable a) => TTL -> ref -> RedisM (RefInstance ref) (Maybe a)
lPopRightBlocking (TTLSec timeoutSec) (toIdentifier -> keyBS) =
  Redis (Hedis.brpop [keyBS] timeoutSec)
    >>= expectRight "brpop"
    >>= \case
      Nothing -> pure Nothing -- timeout
      Just (_listName, valBS) ->
        case fromBS valBS of
          Just val -> pure $ Just val
          Nothing -> throw $ CouldNotDecodeValue (Just valBS)

-- | Delete from a Redis list
lRem :: forall ref a. (Ref ref, ValueType ref ~ [a], Serializable a) => ref -> Integer -> a -> RedisM (RefInstance ref) ()
lRem (toIdentifier -> keyBS) num val =
  Redis (Hedis.lrem keyBS num (toBS val))
    >>= expectRight "lrem"
    >>= ignore @Integer


-- | Redis sets.
instance (Serializable a, Ord a) => Value inst (Set a) where
  type Identifier (Set a) = ByteString

  txValGet keyBS =
    txWrap (Hedis.smembers keyBS)
    & txFromBSMany
    & fmap (Just . Set.fromList)

  txValSet keyBS vs =
    void $ txWrap (
      Hedis.del [keyBS]
      *> Hedis.sadd keyBS (map toBS $ Set.toList vs)
    )

  txValDelete keyBS = void $ txWrap (Hedis.del [keyBS])
  txValSetTTLIfExists keyBS (TTLSec ttlSec) = txWrap (Hedis.expire keyBS ttlSec)

  valGet keyBS =
    Hedis.smembers keyBS
      >>= expectRight "valGet/Set a"
      >>= (fromBSMany <&> \case
        Left badBS -> throw $ CouldNotDecodeValue (Just badBS)
        Right vs -> pure (Just $ Set.fromList vs))

  valSet keyBS vs =
    Redis (Hedis.multiExec (
      Hedis.del [keyBS]
      *> Hedis.sadd keyBS (map toBS $ Set.toList vs)
    ))
      >>= expectTxSuccess
      >>= ignore @Integer

  valDelete keyBS = Redis (Hedis.del [keyBS])
    >>= expectRight "valDelete/Set a"
    >>= ignore @Integer

  valSetTTLIfExists keyBS (TTLSec ttlSec) =
    Redis (Hedis.expire keyBS ttlSec)
      >>= expectRight "valSetTTLIfExists/Set a"

-- | Insert into a Redis set.
sInsert :: forall ref a. (Ref ref, ValueType ref ~ Set a, Serializable a) => ref -> [a] -> RedisM (RefInstance ref) ()
sInsert ref vals =
  Redis (Hedis.sadd (toIdentifier ref) (map toBS vals))
    >>= expectRight "setInsert"
    >>= ignore @Integer

-- | Insert into a Redis set in a transaction.
txSInsert :: forall ref a. (Ref ref, ValueType ref ~ Set a, Serializable a) => ref -> [a] -> Tx (RefInstance ref) ()
txSInsert ref vals =
  void . txWrap
    $ Hedis.sadd (toIdentifier ref) (map toBS vals)

-- | Delete from a Redis set.
sDelete :: forall ref a. (Ref ref, ValueType ref ~ Set a, Serializable a) => ref -> [a] -> RedisM (RefInstance ref) ()
sDelete ref vals =
  Redis (Hedis.srem (toIdentifier ref) (map toBS vals))
    >>= expectRight "hashSetDelete"
    >>= ignore @Integer

-- | Delete from a Redis set in a transaction.
txSDelete :: forall ref a. (Ref ref, ValueType ref ~ Set a, Serializable a) => ref -> [a] -> Tx (RefInstance ref) ()
txSDelete ref vals =
  void . txWrap
    $ Hedis.srem (toIdentifier ref) (map toBS vals)

-- | Check membership in a Redis set.
sContains :: forall ref a. (Ref ref, ValueType ref ~ Set a, Serializable a) => ref -> a -> RedisM (RefInstance ref) Bool
sContains ref val =
  Redis (Hedis.sismember (toIdentifier ref) (toBS val))
    >>= expectRight "setContains"

-- | Check membership in a Redis set, in a transaction.
txSContains :: forall ref a. (Ref ref, ValueType ref ~ Set a, Serializable a) => ref -> a -> Tx (RefInstance ref) Bool
txSContains ref val =
  txWrap $ Hedis.sismember (toIdentifier ref) (toBS val)

-- | Get set size.
sSize :: (Ref ref, ValueType ref ~ Set a) => ref -> RedisM (RefInstance ref) Integer
sSize ref = Redis (Hedis.scard (toIdentifier ref)) >>= expectRight "setSize"

-- | Get set size, in a transaction.
txSSize :: (Ref ref, ValueType ref ~ Set a) => ref -> Tx (RefInstance ref) Integer
txSSize ref = txWrap $ Hedis.scard (toIdentifier ref)

-- | Priority for a sorted set
newtype Priority = Priority { unPriority :: Double }
  deriving newtype (Eq, Ord, Num, Real, Fractional, RealFrac)

instance Serializable Priority where
  fromBS = fmap Priority . fromBS
  toBS   = toBS . unPriority

instance Bounded Priority where
  minBound = Priority (-Numeric.Limits.maxValue)
  maxBound = Priority   Numeric.Limits.maxValue

-- | Add elements to a sorted set
zInsert :: forall ref a. (Ref ref, ValueType ref ~ [(Priority, a)], Serializable a) => ref -> [(Priority, a)] -> RedisM (RefInstance ref) ()
zInsert (toIdentifier -> keyBS) vals =
  Redis (Hedis.zadd keyBS (map (unPriority Arrow.*** toBS) vals))
    >>= expectRight "zadd"
    >>= ignore @Integer

-- | Delete from a Redis sorted set
zDelete :: forall ref a. (Ref ref, ValueType ref ~ [(Priority, a)], Serializable a) => ref -> a -> RedisM (RefInstance ref) ()
zDelete (toIdentifier -> keyBS) val =
  Redis (Hedis.zrem keyBS [toBS val])
    >>= expectRight "zrem"
    >>= ignore @Integer

-- | Get the cardinality (number of elements) of a sorted set
zSize :: forall ref a. (Ref ref, ValueType ref ~ [(Priority, a)], Serializable a) => ref -> RedisM (RefInstance ref) Integer
zSize (toIdentifier -> keyBS) =
  Redis (Hedis.zcard keyBS)
    >>= expectRight "zcard"

-- | Returns the number of elements in the sorted set that have a score between minScore and
-- maxScore inclusive.
zCount :: forall ref a. (Ref ref, ValueType ref ~ [(Priority, a)], Serializable a) => ref -> Priority -> Priority -> RedisM (RefInstance ref) Integer
zCount (toIdentifier -> keyBS) (unPriority -> minScore) (unPriority -> maxScore) =
  Redis (Hedis.zcount keyBS minScore maxScore)
    >>= expectRight "zcount"

-- | Increment the value in the sorted set by the given amount. Note that if the value is not present this will add the
-- the value to the sorted list with the given amount as its priority.
zIncrBy :: forall ref a. (Ref ref, ValueType ref ~ [(Priority, a)], Serializable a) => ref -> Integer -> a -> RedisM (RefInstance ref) Priority
zIncrBy (toIdentifier -> keyBS) incr (toBS -> val)=
  Hedis.zincrby keyBS incr val
    >>= expectRight "zincrby"
    <&> Priority

-- | Remove given number of largest elements from a sorted set.
--   Available since Redis 5.0.0
zPopMax :: forall ref a. (Ref ref, ValueType ref ~ [(Priority, a)], Serializable a) => ref -> Integer -> RedisM (RefInstance ref) [(Priority, a)]
zPopMax (toIdentifier -> keyBS) cnt =
  Redis (zpopmax keyBS cnt)
  >>= expectRight "zpopmax call"
  >>= expectRight "zpopmax decode" . fromBSMany'
  where fromBSMany' = traverse $ \(valBS,sc) -> maybe (Left valBS) (Right . (Priority sc,)) $ fromBS valBS

-- | ZPOPMAX as it should be in the Hedis library (but it isn't yet)
--   Available since Redis 5.0.0
zpopmax :: Hedis.RedisCtx m f => ByteString -> Integer -> m (f [(ByteString, Double)])
zpopmax k c = Hedis.sendRequest ["ZPOPMAX", k, toBS c]

-- | Remove given number of smallest elements from a sorted set.
--   Available since Redis 5.0.0
zPopMin :: forall ref a. (Ref ref, ValueType ref ~ [(Priority, a)], Serializable a) => ref -> Integer -> RedisM (RefInstance ref) [(Priority, a)]
zPopMin (toIdentifier -> keyBS) cnt =
  Redis (zpopmin keyBS cnt)
  >>= expectRight "zpopmin call"
  >>= expectRight "zpopmin decode" . fromBSMany'
  where fromBSMany' = traverse $ \(valBS,sc) -> maybe (Left valBS) (Right . (Priority sc,)) $ fromBS valBS

-- | ZPOPMIN as it should be in the Hedis library (but it isn't yet)
--   Available since Redis 5.0.0
zpopmin :: Hedis.RedisCtx m f => ByteString -> Integer -> m (f [(ByteString, Double)])
zpopmin k c = Hedis.sendRequest ["ZPOPMIN", k, toBS c]

-- | Remove the smallest element from a sorted set, and block for the given number of seconds when it is not there yet.
--   Available since Redis 5.0.0
bzPopMin :: forall ref a. (Ref ref, ValueType ref ~ [(Priority, a)], Serializable a)
         => ref -> Integer -> RedisM (RefInstance ref) (Maybe (Priority, a))
bzPopMin (toIdentifier -> keyBS) timeout =
  Redis (bzpopmin keyBS timeout)
  >>= expectRight "bzPopMin call"
  >>= expectRight "bzPopMin decode" . fromBS'
  where
    fromBS' = maybe (Right Nothing) (\(_,valBS,sc) -> maybe (Left valBS) (Right . Just . (Priority sc,)) $ fromBS valBS)

-- | BZPOPMIN as it should be in the Hedis library (but it isn't yet)
--   Available since Redis 5.0.0
bzpopmin :: Hedis.RedisCtx m f => ByteString -> Integer -> m (f (Maybe (ByteString, ByteString, Double)))
bzpopmin k timeout = Hedis.sendRequest ["BZPOPMIN", k, toBS timeout]

-- Orphan instance, Hedis only implements this for 2-tuples, but BZPOPMIN gets 3 results
instance (Hedis.RedisResult a, Hedis.RedisResult b, Hedis.RedisResult c) => Hedis.RedisResult (a,b,c) where
  decode (Hedis.MultiBulk (Just [x,y,z])) = (,,) <$> Hedis.decode x <*> Hedis.decode y <*> Hedis.decode z
  decode r                                = Left r

-- | Get elements from a sorted set, between the given min and max values, and with the given offset and limit.
zRangeByScoreLimit :: forall ref a. (Ref ref, ValueType ref ~ [(Priority, a)], Serializable a)
                   => ref -> Priority -> Priority -> Integer -> Integer -> RedisM (RefInstance ref) [a]
zRangeByScoreLimit (toIdentifier -> keyBS) (Priority minV) (Priority maxV) offset limit =
  Hedis.zrangebyscoreLimit keyBS minV maxV offset limit
  >>= expectRight "zrangebyscoreLimit call"
  >>= expectRight "zrangebyscoreLimit decode" . fromBSMany

zRange :: forall ref a. (Ref ref, ValueType ref ~ [(Priority, a)], Serializable a)
          => ref -> Integer -> Integer -> RedisM (RefInstance ref) [a]
zRange (toIdentifier -> keyBS) start end =
  Hedis.zrange keyBS start end
  >>= expectRight "zrange call"
  >>= expectRight "zrange decode" . fromBSMany

zRevRange :: forall ref a. (Ref ref, ValueType ref ~ [(Priority, a)], Serializable a)
          => ref -> Integer -> Integer -> RedisM (RefInstance ref) [a]
zRevRange (toIdentifier -> keyBS) start end =
  Hedis.zrevrange keyBS start end
  >>= expectRight "zrevrange call"
  >>= expectRight "zrevrange decode" . fromBSMany

-- | Scan the sorted set by reference using an optional match and count.
zScanOpts :: forall ref a. (Ref ref, ValueType ref ~ [(Priority, a)], Serializable a)
          => ref -> Maybe Text -> Maybe Integer -> RedisM (RefInstance ref) [a]
zScanOpts (toIdentifier -> keyBS) mMatch mCount =
  Hedis.zscanOpts keyBS Hedis.cursor0 Hedis.ScanOpts { Hedis.scanMatch = toBS <$> mMatch, Hedis.scanCount = mCount}
  >>= expectRight "zscanOpts call"
  >>= expectRight "zscanOpts decode" . fromBSMany . map fst . snd

zUnionStoreWeights :: forall ref a. (Ref ref, ValueType ref ~ [(Priority, a)], Serializable a) => ref -> [(ref, Double)] -> RedisM (RefInstance ref) ()
zUnionStoreWeights (toIdentifier -> keyBS) refWithWeights =
  Hedis.zunionstoreWeights keyBS [(toIdentifier k, d) | (k, d) <- refWithWeights] Hedis.Sum
  >>= expectRight "zUnionStoreWeights call"
  >>= ignore @Integer

parseMap :: (Ord k, Serializable k, Serializable v)
  => [(ByteString, ByteString)] -> Maybe (Map k v)
parseMap kvsBS = Map.fromList <$> sequence
  [ (,) <$> fromBS keyBS <*> fromBS valBS
  | (keyBS, valBS) <- kvsBS
  ]

-- | Redis hashes.
instance (Ord k, Serializable k, Serializable v) => Value inst (Map k v) where
  type Identifier (Map k v) = ByteString

  txValGet keyBS =
    txWrap (Hedis.hgetall keyBS)
      & txCheckMap (
          maybe
            (Left $ CouldNotDecodeValue Nothing)
            (Right . Just)
          . parseMap
        )

  txValSet keyBS m =
    void $ txWrap (
      Hedis.del [keyBS]
      *> Hedis.hmset keyBS
        [(toBS ref, toBS val) | (ref, val) <- Map.toList m]
    )

  txValDelete keyBS = void . txWrap $ Hedis.del [keyBS]
  txValSetTTLIfExists keyBS (TTLSec ttlSec) =
    txWrap $ Hedis.expire keyBS ttlSec

  valGet keyBS =
    Hedis.hgetall keyBS
      >>= expectRight "valGet/Map k v"
      >>= \kvsBS -> case parseMap kvsBS of
        Just m -> pure (Just m)
        Nothing -> throw $ CouldNotDecodeValue Nothing

  valSet keyBS m =
    Redis (Hedis.multiExec (
      Hedis.del [keyBS]
      *> Hedis.hmset keyBS
        [(toBS ref, toBS val) | (ref, val) <- Map.toList m]
    ))
      >>= expectTxSuccess
      >>= expect "valSet/Map k v" Hedis.Ok

  valDelete keyBS =
    Redis (Hedis.del [keyBS])
      >>= expectRight "valDelete/Map k v"
      >>= ignore @Integer

  valSetTTLIfExists keyBS (TTLSec ttlSec) =
    Redis (Hedis.expire keyBS ttlSec)
      >>= expectRight "setTTLIfExists/Map k v"

infix 3 :/
-- | Map field addressing operator.
-- If @ref@ is a 'Ref' pointing to a @Map k v@,
-- then @(ref :/ k)@ is a ref with type @v@,
-- pointing to the entry in the map identified by @k@.
data MapItem :: Type -> Type -> Type -> Type where
  (:/) :: (Ref ref, ValueType ref ~ Map k v) => ref -> k -> MapItem ref k v

  -- Previously, 'MapItem' was defined simply as
  -- > data MapItem ref k v = (:/) ref k
  -- However, this caused GHC to choke on this because it provided no way
  -- to infer the value of 'v' from @ref :/ k@ alone -- 'v' is a phantom type,
  -- not mentioned in the expression.
  --
  -- This would block the instance resolution for @Ref (MapItem ref k v)@
  -- for any expression of the form @ref :/ k@, and cause more trouble down the line.
  --
  -- Hence I made 'MapItem' a GADT so that the type inference machine
  -- has clear instructions how to infer the correct value of 'v'.

instance
  ( Ref ref
  , ValueType ref ~ Map k v
  , Serializable k
  , SimpleValue (RefInstance ref) v
  ) => Ref (MapItem ref k v) where

  type ValueType (MapItem ref k v) = v
  type RefInstance (MapItem ref k v) = RefInstance ref
  toIdentifier (mapRef :/ k) = SviHash (toIdentifier mapRef) (toBS k)

infix 3 :.
-- | Record item addressing operator.
-- If @ref@ is a ref pointing to a @Record fieldF@,
-- and @k :: fieldF v@ is a field of that record,
-- then @(ref :. k)@ is a ref with type @v@,
-- pointing to that field of that record.
data RecordItem ref fieldF val = (:.) ref (fieldF val)

-- | Class of record fields. See 'Record' for details.
class RecordField (fieldF :: Type -> Type) where
  rfToBS :: fieldF a -> ByteString

instance
  ( Ref ref
  , ValueType ref ~ Record fieldF
  , SimpleValue (RefInstance ref) val
  , RecordField fieldF
  ) => Ref (RecordItem ref fieldF val) where

  type ValueType (RecordItem ref fieldF val) = val
  type RefInstance (RecordItem ref fieldF val) = RefInstance ref
  toIdentifier (ref :. field) = SviHash (toIdentifier ref) (rfToBS field)

-- | The value type for refs that point to records.
-- Can be deleted and SetTTLed.
-- Can't be read or written as a whole (at the moment).
--
-- The parameter @fieldF@ gives the field functor for this record.
-- This is usually a GADT indexed by the type of the corresponding record field.
--
-- 'Record' and 'Map' are related but different:
--
-- * 'Map' is a homogeneous variable-size collection of associations @k -> v@,
--   where all refs have the same type and all values have the same type,
--   just like a Haskell 'Map'.
--
--   'Map's can be read/written to Redis as whole entities out-of-the-box.
--
-- * 'Record' is a heterogeneous fixed-size record of items with different types,
--   just like Haskell records.
--
--   'Record's cannot be read/written whole at the moment.
--   There's no special reason for that, except that it would probably be
--   too much type-level code that noone needs at the moment.
--
--  See also: '(:.)'.
data Record (fieldF :: Type -> Type)

-- This is a bit of a hack. Records can't be written at the moment.
-- Maybe we should split the Value typeclass into ReadWriteValue and Value
instance Value inst (Record fieldF) where
  type Identifier (Record fieldF) = ByteString
  txValGet _ = error "Record is not meant to be read"
  txValSet _ _ = error "Record is not meant to be written"
  txValDelete keyBS = void . txWrap $ Hedis.del [keyBS]
  txValSetTTLIfExists keyBS (TTLSec ttlSec) = txWrap $ Hedis.expire keyBS ttlSec
  valGet _ = error "Record is not meant to be read"
  valSet _ _ = error "Record is not meant to be written"
  valDelete keyBS = Hedis.del [keyBS]
    >>= expectRight "valDelete/Record" >>= ignore @Integer
  valSetTTLIfExists keyBS (TTLSec ttlSec) =
    Hedis.expire keyBS ttlSec >>= expectRight "setTTLIfExists/Record"

unliftIO :: ((forall a. RedisM inst a -> IO a) -> IO b) -> RedisM inst b
unliftIO action = Redis $ Hedis.reRedis $ do
  env <- ask
  liftIO $ action $
    \(Redis redisA) -> runReaderT (Hedis.unRedis redisA) env

-- | PubSub channels.
data PubSub msg

instance Value inst (PubSub msg) where
  type Identifier (PubSub msg) = ByteString
  txValGet _ = error "PubSub is not meant to be read"
  txValSet _ _ = error "PubSub is not meant to be written"
  txValDelete keyBS = void . txWrap $ Hedis.del [keyBS]
  txValSetTTLIfExists keyBS (TTLSec ttlSec) = txWrap $ Hedis.expire keyBS ttlSec
  valGet _ = error "PubSub is not meant to be read"
  valSet _ _ = error "PubSub is not meant to be written"
  valDelete keyBS = Hedis.del [keyBS]
    >>= expectRight "valDelete/PubSub" >>= ignore @Integer
  valSetTTLIfExists keyBS (TTLSec ttlSec) =
    Hedis.expire keyBS ttlSec >>= expectRight "setTTLIfExists/PubSub"

pubSubListen :: (Ref ref, ValueType ref ~ PubSub msg, Serializable msg)
  => ref -> (Either RedisException msg -> IO Bool) -> RedisM (RefInstance ref) ()
pubSubListen (toIdentifier -> keyBS) process =
  Redis $ Hedis.pubSub (Hedis.subscribe [keyBS]) $ \rawMsg ->
    let msg = case fromBS (Hedis.msgMessage rawMsg) of
          Nothing -> Left (CouldNotDecodeValue $ Just (Hedis.msgMessage rawMsg))
          Just msg' -> Right msg'
    in liftIO (process msg) >>= \case
      True -> return mempty
      False -> return (Hedis.unsubscribe [keyBS])

pubSubCountSubs :: (Ref ref, ValueType ref ~ PubSub msg)
  => ref -> RedisM (RefInstance ref) Integer
pubSubCountSubs (toIdentifier -> keyBS) =
  Hedis.sendRequest ["PUBSUB", "NUMSUB", keyBS]
    >>= expectRight "pubSubCountSubs" 
    >>= \case
      Hedis.MultiBulk (Just [_, Hedis.Integer cnt]) -> return cnt
      _ -> error "pubSubCountSubs: unexpected reply"
