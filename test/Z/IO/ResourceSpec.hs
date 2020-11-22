{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Z.IO.ResourceSpec where

import           Control.Concurrent
import           Control.Exception
import           Control.Monad
import           Z.Data.PrimRef.PrimIORef
import           Data.Typeable
import           Z.IO.Resource          as R
import           Test.Hspec
import           Test.HUnit

data WorkerException = WorkerException deriving (Typeable, Show)

instance Exception WorkerException

spec :: Spec
spec = describe "resource tests" $ do
    it "resource pool" $ do
        resCounter <- newCounter 0
        workerCounter <- newCounter 0
        let res = initResource (atomicAddCounter_ resCounter 1)
                               (\ _ -> atomicSubCounter_ resCounter 1)
            resPool = initPool res 100 5
        R.withResource resPool $ \ pool -> do
            let res = initInPool pool
            forM_ [1..1000] $ \ k -> forkIO. R.withResource res $ \ i -> do
                atomicAddCounter_ workerCounter 1
                r <- readPrimIORef resCounter
                threadDelay 1000000
                assertEqual "pool should limit max usage" True (r <= 100)

            threadDelay 13000000
            -- first 100 worker quickly get resources
            -- then hold for 1s, rest 100 worker have to wait, and so on
            -- so here we wait for 5s to make sure every worker got a resource
            -- we used to use replicateConcurrently_ from async, but it's
            -- not really neccessary

            w <- readPrimIORef workerCounter
            assertEqual "worker should be able to get resource" 1000 w

            r <- readPrimIORef resCounter
            assertEqual "pool should keep returned resources alive" 100 r

            s <- poolStat pool
            assertEqual "pool should be scanning returned resources" PoolScanning s

            threadDelay 5000000  -- after 5s, 1000 thread should release all resources

            r <- readPrimIORef resCounter
            assertEqual "pool should reap unused resources" 0 r

            threadDelay 5000000  -- another 5s

            s <- poolStat pool
            assertEqual "pool should stop scanning returned resources" PoolEmpty s

            -- Let's test again

            writePrimIORef workerCounter 0

            forM_ [1..1000] $ \ k -> forkIO. R.withResource res $ \ i -> do
                atomicAddCounter_ workerCounter 1
                r <- readPrimIORef resCounter
                threadDelay 1000000
                assertEqual "pool should limit max usage" True (r <= 100)


            threadDelay 12000000

            w <- readPrimIORef workerCounter
            assertEqual "worker should be able to get resource" 1000 w

            r <- readPrimIORef resCounter
            assertEqual "pool should keep returned resources alive" 100 r

            s <- poolStat pool
            assertEqual "pool should be scanning returned resources" PoolScanning s

            threadDelay 5000000  -- after 5s, 1000 thread should release all resources

            r <- readPrimIORef resCounter
            assertEqual "pool should reap unused resources" 0 r

            threadDelay 500000  -- another 5s

            s <- poolStat pool
            assertEqual "pool should stop scanning returned resources" PoolEmpty s

    it "resource pool under exceptions" $ do
        resCounter <- newCounter 0
        let res = initResource (atomicAddCounter' resCounter 1)
                               (\ _ -> atomicSubCounter_ resCounter 1)
            resPool = initPool res 100 5
        R.withResource resPool $ \ pool -> do
            let res = initInPool pool

            forM_ [1..1000] $ \ k -> forkIO. R.withResource res $ \ i -> do
                r <- readPrimIORef resCounter
                threadDelay 1000000
                when (even i) (throwIO WorkerException)
                assertEqual "pool should limit max usage" True (r <= 100)

            threadDelay 12000000

            r <- readPrimIORef resCounter
            assertEqual "pool should keep returned resources alive" 100 r

            s <- poolStat pool
            assertEqual "pool should be scanning returned resources" PoolScanning s

            threadDelay 5000000  -- after 5s, 1000 thread should release all resources

            r <- readPrimIORef resCounter
            assertEqual "pool should reap unused resources" 0 r

            threadDelay 5000000  -- after 5s, scanning thread should stoped

            s <- poolStat pool
            assertEqual "pool should stop scanning returned resources" PoolEmpty s
