{-# LANGUAGE AllowAmbiguousTypes #-}  -- for remoteJobWorker
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
module Database.Redis.Schema.RemoteJob (
  -- * Types
  WorkerId (..),
  WorkerHandle,
  RemoteJobError (..),
  JobQueue (..),

  -- * Main functionality
  runRemoteJob,
  runRemoteJobAsync,
  remoteJobWorker,
  withRemoteJobWorker,
  gracefulShutdown,

  -- * Inspection
  queueLength,
  countRunningJobs,
) where

import Data.Binary ( decode, encode, Binary(..) )
import Data.Bifunctor as BF ( second )
import Data.Kind ( Type )
import Data.Maybe ( isJust )
import Data.Proxy ( Proxy(..) )
import Data.String ( IsString )
import Data.Text ( Text )
import Data.Time ( UTCTime, getCurrentTime, addUTCTime )
import Data.Time.Clock.POSIX ( utcTimeToPOSIXSeconds )
import Data.UUID ( UUID )
import Data.UUID.V4 ( nextRandom )
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Set as Set

import Database.Redis ( ConnectionLostException )
import Database.Redis.Schema as Redis

import Control.Concurrent.MonadIO
import Control.Monad ( when, forever )
import Control.Monad.Catch
import Control.Exception ( SomeAsyncException )

import GHC.Generics ( Generic )


-- | Errors that can occur in the remote job running.
data RemoteJobError
  = RemoteJobException String
  | NoActiveWorkers
  | Timeout
  deriving ( Show, Generic )
instance Binary RemoteJobError

instance Serializable RemoteJobError where
  fromBS = readBinary
  toBS = showBinary

-- | Identifier for the worker process, is only used for inspecting the queue
newtype WorkerId = WorkerId { unWorkerId :: Text }
  deriving newtype ( Show, Eq, Ord, IsString, Serializable, Binary )

-- | Handle of the worker process, which can be used in the graceful shutdown procedure
data WorkerHandle = WorkerHandle (MVar ()) ThreadId

class JobQueue jq where
  -- | The remote job protocol, a list of 'i -> o' entries indicating
  --   this queue can contains jobs taking type 'i' as input and
  --   returning type 'o'. Both 'i' and 'o' must have a binary instance.
  type RPC jq :: [Type]

  -- | Prefix for the Redis keys
  keyPrefix :: BS.ByteString

  -- | Which Redis instance the queue lives in.
  type RedisInstance jq :: Instance
  type RedisInstance jq = DefaultInstance

-- | This queue contains many requests.
-- There is only one request queue and it's read by all workers.
data RequestQueue jq = RequestQueue
instance JobQueue jq => Ref (RequestQueue jq) where
  type RefInstance (RequestQueue jq) = RedisInstance jq
  type ValueType (RequestQueue jq) = [(Priority, (UUID, Int, BSL.ByteString))]
  toIdentifier RequestQueue =
    colonSep [keyPrefix @jq, "requests"]

-- | This set contains the requests that are currently being processed.
data RunningJobs jq = RunningJobs
instance JobQueue jq => Ref (RunningJobs jq) where
  type RefInstance (RunningJobs jq) = RedisInstance jq
  type ValueType (RunningJobs jq) = Set.Set (WorkerId, (UUID, Int, BSL.ByteString))
  toIdentifier RunningJobs =
    colonSep [keyPrefix @jq, "running"]

-- | A box that contains only one response.
-- For every response, a unique box is created (tagged with job ID).
newtype ResultBox jq = ResultBox UUID
instance JobQueue jq => Ref (ResultBox jq) where
  type RefInstance (ResultBox jq) = RedisInstance jq
  type ValueType (ResultBox jq) = [Either RemoteJobError BSL.ByteString]
  toIdentifier (ResultBox uuid) =
    colonSep [keyPrefix @jq, "result", toBS uuid]

-- | A registry of all active workers
data Workers jq = Workers
instance JobQueue jq => Ref (Workers jq) where
  type RefInstance (Workers jq) = RedisInstance jq
  type ValueType (Workers jq) = [(Priority, WorkerId)]
  toIdentifier Workers =
    Redis.colonSep [keyPrefix @jq, "workers"]

-- | Type class to check where in the 'RPC' list a i->o job occurs, which
--   is then used together with 'CanHandle' to use the right handler.
class FindHandler (i :: Type) (o :: Type) (xs :: [Type]) where
  handlerIdx :: Proxy (i -> o) -> Proxy xs -> Int

instance (FindHandler' i o xs (IsHead (i -> o) xs)) => FindHandler i o xs where
  handlerIdx = handlerIdx' (Proxy @(IsHead (i -> o) xs))

class FindHandler' (i :: Type) (o :: Type) (xs :: [Type]) (isHead :: Bool) where
  handlerIdx' :: Proxy isHead -> Proxy (i -> o) -> Proxy xs -> Int

instance FindHandler' i o ((i -> o) ': xs) 'True where
  handlerIdx' _ _ _ = 0

instance FindHandler i o xs => FindHandler' i o (x ': xs) 'False where
  handlerIdx' _ _ _ = 1 + handlerIdx (Proxy @(i -> o)) (Proxy @xs)

type family IsHead (x :: Type) (xs :: [Type]) :: Bool where
  IsHead x (x ': _) = True
  IsHead x _        = 'False


-- | An instance 'CanHandle m xs' means that the list xs of i->o jobs
--   can be handled in monad m, e.g. there exists Binary instances for all
--   i and o, and the instances take care of encoding and decoding as the
--   right type.
class CanHandle (m :: Type -> Type) (xs :: [Type]) where
  type HandleTy m xs r :: Type
  doHandle :: Proxy m -> Proxy xs -> ((Int -> BSL.ByteString -> m BSL.ByteString) -> m r) -> HandleTy m xs r

instance CanHandle m '[] where
  type HandleTy m '[] r = m r
  doHandle Proxy Proxy cont = cont $ \_ _ -> error "remoteJobWorker: protocol broken"

instance (Monad m, Binary i, Binary o, CanHandle m xs) => CanHandle m ((i -> o) ': xs) where
  type HandleTy m ((i -> o) ': xs) r = (i -> m o) -> HandleTy m xs r
  doHandle Proxy Proxy cont f = doHandle (Proxy @m) (Proxy @xs) (cont . g) where
    g handler i bsi
      | i == 0    = encode <$> f (decode bsi)
      | otherwise = handler (i - 1) bsi

-- | Run a job on a remote worker. This will block until a 'remoteJobWorker' process picks up the
--   task. The 'Double' argument is the priority, jobs with a lower priority are picked up earlier.
runRemoteJob ::
  forall q i o m.
  (MonadCatch m, MonadIO m, JobQueue q, FindHandler i o (RPC q), Binary i, Binary o) =>
  Bool -> Pool (RedisInstance q) -> Priority -> i -> m (Either RemoteJobError o)
runRemoteJob waitForWorkers pool prio a = do
  -- Check that there are active workers
  abort <-
    if waitForWorkers
    then return False
    else (==0) <$> run pool (countWorkers @q)

  if abort then return $ Left NoActiveWorkers
  else do
    -- Add the job
    jobId <- liftIO nextRandom
    let job = (jobId, handlerIdx (Proxy @(i -> o)) (Proxy @(RPC q)), encode a)

    -- Add to the queue and wait for the result. If any exception occurs at this point
    -- (which is then likely an async exception), we remove the element from the queue,
    -- because we will not listen to the result anymore anyway.
    popResult <- run pool
      ( do zInsert (RequestQueue @q) [(prio,job)]
           lPopRightBlocking 0 (ResultBox @q jobId)
      ) `onException`
      run pool (zDelete (RequestQueue @q) job)

    -- Now look at the result and decode it.
    return $ case popResult of
      Just r  -> BF.second decode r
      Nothing -> Left Timeout

-- | Run a job on a remote worker but do not wait for any results. This assumes the remote
--   job has some side-effect, which is executed by a 'remoteJobWorker' process that picks
--   up this task.
runRemoteJobAsync ::
  forall q i m.
  (MonadCatch m, MonadIO m, JobQueue q, FindHandler i () (RPC q), Binary i) =>
  Pool (RedisInstance q) -> Priority -> i -> m ()
runRemoteJobAsync pool prio a = do
  -- Add to the queue and forget about it.
  jobId <- liftIO nextRandom
  let job = (jobId, handlerIdx (Proxy @(i -> ())) (Proxy @(RPC q)), encode a)
  run pool $ zInsert (RequestQueue @q) [(prio,job)]

-- | The actual worker loop, this generalizes over 'remoteJobWorker' and 'forkRemoteJobWorker'
remoteJobWorker' :: forall q m r. (MonadIO m, MonadCatch m, MonadMask m, JobQueue q, CanHandle m (RPC q)) =>
  (MVar () -> m () -> m r) -> WorkerId -> Pool (RedisInstance q) -> (SomeException -> m ()) -> HandleTy m (RPC q) r
remoteJobWorker' cont wid pool logger = doHandle (Proxy @m) (Proxy @(RPC q)) $ \handler -> do
  -- MVar that is used for the graceful shutdown procedure. When it is full, the worker
  -- thread is not doing anything and can be killed. As soon as the worker starts working
  -- it takes the value and puts it back when the work is done.
  workerFree <- liftIO $ newMVar ()
  let
    -- Main loop, pop elements from the queue and handle them
    loop :: m ()
    loop = run pool (bzPopMin (RequestQueue @q) 0) >>= \case
      Just (_, it@(jobId, idx, bsa)) -> do
        -- Update the RunningJobs queue at the start and end of this block,
        -- and keep the workerFree var up to date
        bracket_
          (run pool (sInsert (RunningJobs @q) [(wid,it)]) >> liftIO (takeMVar workerFree))
          (run pool (sDelete (RunningJobs @q) [(wid,it)]) >> liftIO (putMVar workerFree ())) $ do
            -- Call the actual handler
            resp <- fmap Right (handler idx bsa)
                    `catchAll`
                    (return . Left)

            -- Send back the result
            let bso = case resp of
                  Left e  -> Left $ RemoteJobException $ show e
                  Right b -> Right b
            run pool $ do
              let box = ResultBox @q jobId
              lPushLeft box [bso]
              -- set ttl to ensure the data is not left behind in case of crashes,
              -- the caller should be awaiting this already, so it's either read
              -- directly or it is never read.
              setTTLIfExists_ box (5 * Redis.second)

            -- Check for exceptions
            case resp of
              Right _ -> return ()
              Left e -> do
                -- Call the parent logger
                logger e

                -- And in case of an async exception, rethrow
                let mbAsync :: Maybe SomeAsyncException
                    mbAsync = fromException e
                when (isJust mbAsync) $ throwM e

        -- Sleep for a tiny bit, to allow the graceful shutdown procedure to interrupt when needed
        liftIO $ threadDelay 1000 -- 1ms
        loop

      -- With BRPOP and no timeout there should always be a result
      _ ->  error "remoteJobWorker: Got no result with BRPOP and timeout 0"

    -- Fork a keep-alive loop that updates our latest-seen time every
    -- 5 seconds. We use the current UTC timestamp as priority, so
    -- that we can efficiently count the servers that checked in recently.
    signup = liftIO $ forkIO $ forever $ do
      t <- liftIO getCurrentTime
      run pool $ zInsert (Workers @q) [(utcTimeToPriority t, wid)]
      threadDelay 5_000_000 -- 5s

    -- Kill the keep-alive loop and remove ourselves from the list.
    signout tid = do
      liftIO $ killThread tid
      run pool $ zDelete (Workers @q) wid

  -- Signup and signout in an exception-safe way.
  -- When the connection is lost (which will also throw exceptions
  -- in signup/signout), we sleep for a while and try again
  let outerLoop = bracket signup signout (const loop)
        `catch`
        \(e :: ConnectionLostException) -> do
          -- Make sure to log the exception
          logger (toException e)

          -- Sleep for 10s
          liftIO $ threadDelay 10_000_000

          -- And run the loop again
          outerLoop

  -- Pass the continuation the function to start up the outer loop
  cont workerFree outerLoop


-- | Worker for handling jobs from the queue. The first function that matches the given input/output types
--   will be executed. Multiple workers can be run in parallel.
--   When exceptions appear in the handling function, this exception will be sent to the caller
--   as a String and this exception is thrown from the worker process.
remoteJobWorker :: forall q m. (MonadIO m, MonadCatch m, MonadMask m, JobQueue q, CanHandle m (RPC q)) =>
  WorkerId -> Pool (RedisInstance q) -> (SomeException -> m ()) -> HandleTy m (RPC q) ()
remoteJobWorker = remoteJobWorker' @q cont where
  cont :: MVar () -> m () -> m ()
  cont _ runLoop = runLoop

-- | Forking version of 'remoteJobWorker', which forks a thread to do the work and returns a 'WorkerHandle'
--   that can be passed to 'gracefulShutdown' to end the worker thread in a graceful way.
--   This function ensures that on exceptions, the worker is cleaned up properly.
withRemoteJobWorker :: forall q m a. (HasFork m, MonadIO m, MonadCatch m, MonadMask m, JobQueue q, CanHandle m (RPC q)) =>
  WorkerId -> Pool (RedisInstance q) -> (SomeException -> m ()) -> (WorkerHandle -> m a) -> HandleTy m (RPC q) a
withRemoteJobWorker wid pool logger outerCont = remoteJobWorker' @q cont wid pool logger where
  cont :: MVar () -> m () -> m a
  cont workerFree runLoop = do
    tid <- fork runLoop
    let hd = WorkerHandle workerFree tid
    outerCont hd
      `finally` -- on exceptions or when the outer thread finishes, make sure to clean up
      hardShutdown hd

-- | Gracefully shut down the worker, which means waiting for the current job to complete
--   There is a tiny race condition, so there is a small chance the worker just took
--   a new job when it is killed.
gracefulShutdown :: MonadIO m => WorkerHandle -> m ()
gracefulShutdown (WorkerHandle workerFree tid) = liftIO $ do
  takeMVar workerFree
  killThread tid

-- | Send an async exception to the worker thread to kill it and clean up. The remote job
--   caller will receive a 'RemoteJobException' if a job is running.
hardShutdown :: MonadIO m => WorkerHandle -> m ()
hardShutdown (WorkerHandle _ tid) = liftIO $ killThread tid

-- | Returns the number of workers that are currently connected to the job queue.
countWorkers :: forall jq. JobQueue jq => RedisM (RedisInstance jq) Integer
countWorkers = do
  -- Count workers that checked in at most 10s ago. Workers are supposed to
  -- do this every 5 seconds, so we allow missing one beat.
  t <- liftIO getCurrentTime
  zCount (Workers @jq) (utcTimeToPriority $ addUTCTime (-10) t) maxBound

-- | Helper for worker list, which converts the current timestamp to a priority
utcTimeToPriority :: UTCTime -> Priority
utcTimeToPriority = Priority . realToFrac . utcTimeToPOSIXSeconds

-- | Returns the number of jobs that are currently queued
queueLength :: forall jq. JobQueue jq => RedisM (RedisInstance jq) Integer
queueLength = zSize (RequestQueue @jq)

-- | Returns the number of jobs that are currently being processed
countRunningJobs :: forall jq. JobQueue jq => RedisM (RedisInstance jq) Integer
countRunningJobs = sSize (RunningJobs @jq)
