{-|
Module      : Z.IO.FileSystem.Watch
Description : cross-platform recursive fs watcher
Copyright   : (c) Dong Han, 2017~2019
License     : BSD
Maintainer  : winterland1989@gmail.com
Stability   : experimental
Portability : non-portable

This module provides fs watcher based on libuv's fs_event, we also maintain watch list if target OS doesn't
support recursive watch(Linux's inotify).

@
-- start watch threads, use returned close function to cleanup watching threads.
(close, srcf) <- watchDir "fold_to_be_watch"
-- dup a file event source
src <- srcf
-- print event to stdout
runBIO $ src >|> sinkToIO printLineStd
@
-}

module Z.IO.FileSystem.Watch (watchDir) where

import           Control.Concurrent
import           Control.Monad
import           Data.Bits
import           Data.IORef
import qualified Data.HashMap.Strict      as HM
import           Data.Word
import           Foreign.Ptr              (plusPtr)
import           Foreign.Storable         (peek)
import           GHC.Generics
import           Z.Data.Array
import           Z.Data.CBytes            (CBytes)
import qualified Z.Data.CBytes            as CBytes
import           Z.Data.JSON              (EncodeJSON, FromValue, ToValue)
import           Z.Data.Text.ShowT        (ShowT)
import           Z.Data.Vector            (defaultChunkSize)
import           Z.Foreign
import           Z.IO.BIO
import           Z.IO.BIO.Concurrent
import           Z.IO.Exception
import           Z.IO.FileSystem
import qualified Z.IO.FileSystem.FilePath as P
import           Z.IO.UV.FFI
import           Z.IO.UV.Manager
import           Z.IO.LowResTimer

-- | File event with path info.
data FileEvent = FileAdd CBytes | FileRemove CBytes | FileModify CBytes
  deriving (Show, Read, Ord, Eq, Generic)
  deriving anyclass (ShowT, FromValue, ToValue, EncodeJSON)

-- | Start watching a given file or directory recursively.
--
watchDir :: CBytes -> IO (IO (), IO (Source FileEvent))
watchDir dir = do
    b <- isDir dir
    unless b (throwUVIfMinus_ (return UV_ENOTDIR))
#if defined(linux_HOST_OS)
    -- inotify doesn't support recursive watch, so we manually maintain watch list
    watchDirs_ 0 =<< getAllDirs_ dir [dir]
#else
    watchDirs_ UV_FS_EVENT_RECURSIVE [dir]
#endif

-- | Add all sub dir to an accumulator.
getAllDirs_ :: CBytes -> [CBytes] -> IO [CBytes]
getAllDirs_ pdir acc = do
    foldM (\ acc' (d,t) -> if (t == DirEntDir)
            then do
                d' <- pdir `P.join` d
                (getAllDirs_ d' (d':acc'))
            else return acc'
        ) acc =<< scandir pdir

-- Internal function to start watching
watchDirs_ :: CUInt -> [CBytes] -> IO (IO (), IO (Source FileEvent))
watchDirs_ flag dirs = do
    -- HashMap to store all watchers
    mRef <- newMVar HM.empty
    -- there's only one place to pull the sink, that is cleanUpWatcher
    (sink, srcf) <- newBroadcastTChanNode 1
    -- lock UVManager first
    (forM_ dirs $ \ dir -> do
        dir' <- P.normalize dir
        tid <- forkIO $ watchThread mRef dir' sink
        modifyMVar_ mRef $ \ m ->
            return $! HM.insert dir' tid m) `onException` cleanUpWatcher mRef sink
    return (cleanUpWatcher mRef sink, srcf)
  where
    eventBufSiz = defaultChunkSize

    cleanUpWatcher mRef sink = do
        m <- takeMVar mRef
        forM_ m killThread
        void (pull sink)

    watchThread mRef dir sink = do
        uvm <- getUVManager
        -- IORef store temp event to de-duplicated
        eRef <- newIORef Nothing
        (bracket
            (do withUVManager uvm $ \ loop -> do
                    hdl <- hs_uv_handle_alloc loop
                    slot <- getUVSlot uvm (peekUVHandleData hdl)
                    -- init uv struct
                    throwUVIfMinus_ (uv_fs_event_init loop hdl)

                    buf <- newPrimArray eventBufSiz :: IO (MutablePrimArray RealWorld Word8)

                    check <- throwOOMIfNull $ hs_uv_check_alloc
                    throwUVIfMinus_ (hs_uv_check_init check hdl)

                    withMutablePrimArrayContents buf $ \ p -> do
                        pokeBufferTable uvm slot (castPtr p) eventBufSiz
                        -- init uv_check_t must come after poking buffer
                        throwUVIfMinus_ $ hs_uv_fs_event_check_start check

                    return (hdl, slot, buf, check))

            (\ (hdl,_,_,check) -> hs_uv_handle_close hdl >> hs_uv_check_close check)

            (\ (hdl, slot, buf, _) -> do
                m <- getBlockMVar uvm slot
                (forever $ do

                    withUVManager' uvm $ do
                        _ <- tryTakeMVar m
                        pokeBufferSizeTable uvm slot eventBufSiz
                        CBytes.withCBytesUnsafe dir $ \ p ->
                            throwUVIfMinus_ (hs_uv_fs_event_start hdl p flag)

                    r <- takeMVar m `onException` (do
                            _ <- withUVManager' uvm $ uv_fs_event_stop hdl
                            void (tryTakeMVar m))

                    events <- withMutablePrimArrayContents buf $ \ p -> do
                        loopReadFileEvent (p `plusPtr` r) (p `plusPtr` eventBufSiz) []

                    forkIO $ processEvent dir mRef eRef sink events))
            ) `catch`
                -- when a directory is removed, either watcher is killed
                -- or hs_uv_fs_event_start return ENOENT
                (\ (_ :: NoSuchThing) -> return ())

    loopReadFileEvent p pend acc
        | p >= pend = return acc
        | otherwise = do
            event   <- peek p
            path    <- CBytes.fromCString (p `plusPtr` 1)
            loopReadFileEvent (p `plusPtr` (CBytes.length path + 2)) pend ((event,path):acc)

    processEvent pdir mRef eRef sink = mapM_ $ \ (e, path) -> do
        f <- pdir `P.join` path
        if (e .&. UV_RENAME) /= 0
        then catch
            (do s <- lstat f
#if defined(linux_HOST_OS)
                when (stMode s .&. S_IFMT == S_IFDIR) $ do
                    modifyMVar_ mRef $ \ m -> do
                        case HM.lookup f m of
                            Just _ -> return m
                            _ -> getAllDirs_ f [f] >>=
                                foldM (\ m' d -> do
                                    tid <- forkIO $ watchThread mRef d sink
                                    return $! HM.insert d tid m') m
#endif
                pushDedup eRef sink (FileAdd f))
            (\ (_ :: NoSuchThing) -> do
                modifyMVar_ mRef $ \ m -> do
                    forM_ (HM.lookup f m) killThread
                    return (HM.delete f m)
                pushDedup eRef sink (FileRemove f))
        else pushDedup eRef sink (FileModify f)

    pushDedup eRef sink event = do
        registerLowResTimer_ 1 $ do
            me' <- atomicModifyIORef' eRef $ \ me ->
                case me of
                    Just e -> (Nothing, Just e)
                    _ -> (Nothing, Nothing)
            forM_ me' (push sink)

        me' <- atomicModifyIORef' eRef $ \ me ->
            case me of
                Just e -> if (e == event)
                    then (me, Nothing)
                    else (Just event, Just e)
                _ -> (Just event, Nothing)
        forM_ me' (push sink)