{-# LANGUAGE Strict #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE QuantifiedConstraints #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Database.Redis.Schema.Lock
  ( LockParams(..), ShareableLockParams(..)
  , defaultMetaParams
  , ExclusiveLock, withExclusiveLock
  , ShareableLock, withShareableLock, LockSharing(..)
  )
  where

import GHC.Generics
import Data.Functor     ( void )
import Data.Maybe       ( fromMaybe )
import Data.Time        ( NominalDiffTime, addUTCTime, getCurrentTime )
import Data.Set         ( Set )
import Data.ByteString  ( ByteString )
import qualified Data.Set as Set
import qualified Data.ByteString.Char8 as BS

import System.Random    ( randomIO )

import Control.Concurrent  ( threadDelay, myThreadId )
import Control.Monad.Fix   ( fix )
import Control.Monad.Catch ( MonadThrow(..), MonadCatch(..), MonadMask(..), throwM, finally )
import Control.Monad.IO.Class ( liftIO, MonadIO )

import qualified Database.Redis.Schema as Redis

data LockParams = LockParams
  { lpMeanRetryInterval :: NominalDiffTime
  , lpAcquireTimeout    :: NominalDiffTime
  , lpLockTTL           :: Redis.TTL
  }

-- | ID of the process that owns the Redis lock.
newtype LockOwnerId = LockOwnerId { _unLockOwnerId :: ByteString }
  deriving newtype (Eq, Ord, Redis.Serializable)
instance Redis.Value inst LockOwnerId
instance Redis.SimpleValue inst LockOwnerId

--------------------
-- Exclusive lock --
--------------------

-- | Redis value representing the exclusive lock.
newtype ExclusiveLock = ExclusiveLock
  { _elOwnerId :: LockOwnerId
  }
  deriving newtype (Eq, Redis.Serializable)
instance Redis.Value inst ExclusiveLock
instance Redis.SimpleValue inst ExclusiveLock

-- | Execute the given action in an exclusively locked context.
--
-- This is useful mainly for operations that need to be atomic
-- while manipulating *both* Redis and database (such as various commit scripts).
--
-- For Redis-only transactions, use 'Redis.atomically'.
-- For database-only transactions, use database transactions.
-- For shareable locks, use 'withShareableLock'.
-- For exclusive locks, 'withExclusiveLock' is more efficient.
withExclusiveLock ::
  ( MonadCatch m, MonadThrow m, MonadMask m, MonadIO m
  , Redis.Ref ref, Redis.ValueType ref ~ ExclusiveLock
  )
  => Redis.Pool (Redis.RefInstance ref)
  -> LockParams  -- ^ Params of the lock, such as timeouts or TTL.
  -> ref         -- ^ Lock ref
  -> m a         -- ^ The action to perform under lock
  -> m a
withExclusiveLock redis lp ref action = do
  exclusiveLockAcquire redis lp ref >>= \case
    Nothing -> throwM Redis.LockAcquireTimeout
    Just ourId -> action `finally` exclusiveLockRelease redis ref ourId

-- | Acquire a distributed exclusive lock.
-- Returns Nothing on timeout. Otherwise it returns the unique client ID used for the lock.
exclusiveLockAcquire ::
  ( MonadCatch m, MonadThrow m, MonadMask m, MonadIO m
  , Redis.Ref ref, Redis.ValueType ref ~ ExclusiveLock
  )
  => Redis.Pool (Redis.RefInstance ref) -> LockParams -> ref -> m (Maybe LockOwnerId)
exclusiveLockAcquire redis lp ref = do
  -- this is unique only if we have only one instance of HConductor running
  ourId <- LockOwnerId . BS.pack . show <$> liftIO myThreadId  -- unique client id
  tsDeadline <- addUTCTime (lpAcquireTimeout lp) <$> liftIO getCurrentTime
  fix $ \ ~retry -> do  -- ~ makes the lambda lazy
    tsNow <- liftIO getCurrentTime
    if tsNow >= tsDeadline
      then return Nothing  -- didn't manage to acquire the lock before timeout
      else do
        -- set the lock if it does not exist
        didNotExist <- Redis.run redis $
          Redis.setIfNotExistsTTL ref (ExclusiveLock ourId) (lpLockTTL lp)
        if didNotExist
          then return (Just ourId)  -- everything went well
          else do
            -- someone got there first; wait a bit and try again
            fuzzySleep (lpMeanRetryInterval lp)
            retry

exclusiveLockRelease ::
  ( MonadCatch m, MonadThrow m, MonadMask m, MonadIO m
  , Redis.Ref ref, Redis.ValueType ref ~ ExclusiveLock
  )
  => Redis.Pool (Redis.RefInstance ref) -> ref -> LockOwnerId -> m ()
exclusiveLockRelease redis ref ourId =
  -- While we were locked, the lock could have expired
  -- and someone else could have acquired the lock in the meantime.
  --
  -- To avoid deleting someone else's lock, we need to check if it's ours.
  void
    $ Redis.run redis
      $ Redis.deleteIfEqual ref (ExclusiveLock ourId)


--------------------
-- Shareable lock --
--------------------

data LockSharing
  = Shared
  | Exclusive
  deriving (Eq, Ord, Show, Read, Generic)
instance Redis.Value inst LockSharing
instance Redis.Serializable LockSharing where
  toBS Shared = "shared"
  toBS Exclusive = "exclusive"
  fromBS "shared" = Just Shared
  fromBS "exclusive" = Just Exclusive
  fromBS _ = Nothing
instance Redis.SimpleValue inst LockSharing

data LockFieldName :: * -> * where
  LockFieldSharing :: LockFieldName LockSharing
  LockFieldOwners  :: LockFieldName (Set LockOwnerId)

-- Ref that points to the components of a shareable lock.
data LockField :: * -> * -> * where
  LockField :: ByteString -> LockFieldName ty -> LockField inst ty

instance Redis.Value inst ty => Redis.Ref (LockField inst ty) where
  type ValueType (LockField inst ty) = ty
  type RefInstance (LockField inst ty) = inst
  toIdentifier (LockField lockSlugBS LockFieldSharing) = Redis.SviTopLevel
    $ Redis.colonSep [ "lock", lockSlugBS, "sharing"]
  toIdentifier (LockField lockSlugBS LockFieldOwners) =
    Redis.colonSep [ "lock", lockSlugBS, "owners"]

-- Ref that points to the meta lock of the shareable lock.
-- A meta lock is always an exclusive lock
-- and it synchronises the access to the components of the shareable lock.
newtype MetaLock ref = MetaLock ref

instance (Redis.Ref ref, Redis.ValueType ref ~ ShareableLock)
  => Redis.Ref (MetaLock ref) where

  type ValueType (MetaLock ref) = ExclusiveLock
  type RefInstance (MetaLock ref) = Redis.RefInstance ref

  toIdentifier (MetaLock ref) = Redis.SviTopLevel $ Redis.colonSep
    [ "lock"
    , Redis.toIdentifier ref
    , "meta"
    ]

data ShareableLock = ShareableLock
  { lockSharing :: LockSharing
  , lockOwners  :: Set LockOwnerId
  }

instance Redis.Value inst ShareableLock where
  type Identifier ShareableLock = ByteString

  txValGet slugBS = do
    mbSharing <- Redis.txGet (LockField slugBS LockFieldSharing)
    mbOwners  <- Redis.txGet (LockField slugBS LockFieldOwners)
    pure $ case mbSharing of
      Nothing -> Nothing  -- lock does not exist
      Just lockSharing -> Just
        $ ShareableLock lockSharing (fromMaybe Set.empty mbOwners)

  txValSet slugBS lock =
    Redis.txSet (LockField slugBS LockFieldSharing) (lockSharing lock)
    *> Redis.txSet (LockField slugBS LockFieldOwners) (lockOwners lock)

  txValDelete slugBS =
    Redis.txDelete_ (LockField slugBS LockFieldSharing)
    *> Redis.txDelete_ (LockField slugBS LockFieldOwners)

  txValSetTTLIfExists slugBS ttl = (||)
    <$> Redis.txSetTTLIfExists (LockField slugBS LockFieldSharing) ttl
    <*> Redis.txSetTTLIfExists (LockField slugBS LockFieldOwners) ttl

  valGet slugBS = Redis.atomically $ Redis.txValGet slugBS
  valSet slugBS val = Redis.atomically $ Redis.txValSet slugBS val
  valDelete slugBS = Redis.atomically $ Redis.txValDelete @inst @ShareableLock slugBS
  valSetTTLIfExists slugBS ttl = Redis.atomically
    $ Redis.txValSetTTLIfExists @inst @ShareableLock slugBS ttl

data ShareableLockParams = ShareableLockParams
  { slpParams :: LockParams
  , slpMetaParams :: LockParams
  }

defaultMetaParams :: LockParams
defaultMetaParams = LockParams
  { lpMeanRetryInterval =  50e-3
  , lpAcquireTimeout    = 500e-3
  , lpLockTTL           = 2 * Redis.second
  }

-- | Execute the given action in a locked, possibly shared context.
--
-- This is useful mainly for operations that need to be atomic
-- while manipulating *both* Redis and database (such as various commit scripts).
--
-- For Redis-only transactions, use 'atomically'.
-- For database-only transactions, use database transactions.
-- For exclusive locks, withExclusiveLock is more efficient.
--
-- NOTE: the shareable lock seems to have quite a lot of performance overhead.
-- Always benchmark first whether the exclusive lock would perform better in your scenario,
-- even when a shareable lock would be sufficient in theory.
withShareableLock
  :: ( MonadCatch m, MonadThrow m, MonadMask m, MonadIO m
     , Redis.Ref ref, Redis.ValueType ref ~ ShareableLock
     , Redis.SimpleValue (Redis.RefInstance ref) (MetaLock ref)
     )
  => Redis.Pool (Redis.RefInstance ref)
  -> ShareableLockParams  -- ^ Params of the lock, such as timeouts or TTL.
  -> LockSharing -- ^ Shared / Exclusive
  -> ref         -- ^ Lock ref
  -> m a         -- ^ The action to perform under lock
  -> m a
withShareableLock redis slp lockSharing ref action =
  shareableLockAcquire redis slp lockSharing ref >>= \case
    Nothing -> throwM Redis.LockAcquireTimeout
    Just ourId -> action
      `finally` shareableLockRelease redis slp ref lockSharing ourId

shareableLockAcquire ::
  forall m ref.
  ( MonadCatch m, MonadThrow m, MonadMask m, MonadIO m
  , Redis.Ref ref, Redis.ValueType ref ~ ShareableLock
  , Redis.SimpleValue (Redis.RefInstance ref) (MetaLock ref)
  ) => Redis.Pool (Redis.RefInstance ref) -> ShareableLockParams -> LockSharing -> ref -> m (Maybe LockOwnerId)
shareableLockAcquire redis slp lockSharing ref = do
  -- this is unique only if we have only one instance of HConductor running
  ourId <- LockOwnerId . BS.pack . show <$> liftIO myThreadId  -- unique client id
  tsDeadline <- addUTCTime (lpAcquireTimeout $ slpParams slp) <$> liftIO getCurrentTime
  fix $ \ ~retry -> do  -- ~ makes the lambda lazy
    tsNow <- liftIO getCurrentTime
    if tsNow >= tsDeadline
      then return Nothing  -- didn't manage to acquire the lock before timeout
      else do
        -- acquire the lock if possible, using the meta lock to synchronise access
        success <- withExclusiveLock redis (slpMetaParams slp) (MetaLock ref) $
          Redis.run redis $ do
            -- get just the sharing flag
            -- avoid getting the list of all owners
            Redis.get (lockField LockFieldSharing) >>= \case
              -- no lock, just acquire it
              Nothing -> do
                Redis.set ref $ ShareableLock lockSharing (Set.singleton ourId)
                return True

              -- lock is shareably acquired
              -- we want to share
              -- so we can acquire
              Just Shared | lockSharing == Shared -> do
                Redis.sInsert (lockField LockFieldOwners) [ourId]
                return True

              -- can't acquire lock otherwise
              _ -> return False

        if success
          then do
            -- everything went well, set ttl and return
            Redis.run redis $ Redis.setTTL ref (lpLockTTL $ slpParams slp)
            return (Just ourId)
          else do
            -- someone got there first; wait a bit and try again
            fuzzySleep $ lpMeanRetryInterval (slpParams slp)
            retry
  where
    lockField :: LockFieldName ty -> LockField (Redis.RefInstance ref) ty
    lockField = LockField (Redis.toIdentifier ref)

shareableLockRelease ::
  forall m ref.
  ( MonadCatch m, MonadThrow m, MonadMask m, MonadIO m
  , Redis.Ref ref, Redis.ValueType ref ~ ShareableLock
  , Redis.SimpleValue (Redis.RefInstance ref) (MetaLock ref)
  ) => Redis.Pool (Redis.RefInstance ref) -> ShareableLockParams -> ref -> LockSharing -> LockOwnerId -> m ()
shareableLockRelease redis slp ref lockSharing ourId =
  withExclusiveLock redis (slpMetaParams slp) (MetaLock ref) $ Redis.run redis $ do
    -- While we were locked, the lock could have expired
    -- and someone else could have acquired the lock in the meantime.
    --
    -- To avoid deleting someone else's lock, we need to check if it's ours.
    Redis.sContains (lockField LockFieldOwners) ourId >>= \case
      False -> pure ()  -- lock is not ours, nothing to do here
      True -> case lockSharing of
        -- we can delete the lock without further exchange with Redis
        Exclusive -> Redis.delete_ ref

        -- we need to check if we're the last owner
        Shared -> do
          -- (the set item could expire here so size could be zero)
          size <- Redis.sSize (lockField LockFieldOwners)
          if size <= 1
            -- delete the whole lock
            then Redis.delete_ ref
            -- just remove ourselves from the list of owners
            else Redis.sDelete (lockField LockFieldOwners) [ourId]
  where
    lockField :: LockFieldName ty -> LockField (Redis.RefInstance ref) ty
    lockField = LockField (Redis.toIdentifier ref)

-- | Sleep between 0.75 and 1.25 times the given time, uniformly randomly.
fuzzySleep :: MonadIO m => NominalDiffTime -> m ()
fuzzySleep interval = liftIO $ do
    -- randomise wait time slightly
    r <- randomIO :: IO Double  -- r is between 0.0 and 1.0
    let q = 1 + (r - 0.5) / 2   -- q is between 0.75 and 1.25
    -- NominalDiffTime behaves like seconds; threadDelay takes microseconds
    threadDelay (round $ 1e6 * realToFrac q * interval)
