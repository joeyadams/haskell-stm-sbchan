{-# LANGUAGE BangPatterns #-}
import Prelude hiding (catch)

import Control.Concurrent.STM
import Control.Exception
import Control.Monad            (forM_, replicateM_)
import Data.STM.SBChan

test1 :: IO ()
test1 = do
    chan <- newSBChanIO 10
    atomically $ do
        SBCItem _ <- readSBChan chan
        return ()

test2 :: IO ()
test2 = do
    chan <- newSBChanIO 10
    atomically $ writeSBChan chan undefined
    atomically $ do
        SBCItem _ <- readSBChan chan
        return ()

test3 :: IO ()
test3 = do
    chan <- newSBChanIO 10
    replicateM_ 3 $ do
        replicateM_ 10 $ atomically $ writeSBChan chan $ SBCItem ()
        False <- atomically $ tryWriteSBChan chan $ SBCItem ()
        replicateM_ 10 $ atomically $ readSBChan chan
        True <- atomically $ isEmptySBChan chan
        return ()

test4 :: IO ()
test4 = do
    testWith cramSBChan
    testWith rollSBChan
  where
    testWith write = do
        chan <- newSBChanIO 10
        forM_ [1..100] $ atomically . write chan . SBCItem
        dumpSBChanInts chan
        True <- atomically $ isEmptySBChan chan
        return ()

test5 :: IO ()
test5 = do
    chan <- atomically $ newSBChan 10
    forM_ [1..100] $ atomically . cramSBChan chan . SBCItem
    dropped <- atomically $ satisfyLimitSBChan chan
    putStrLn $ "Dropped " ++ show dropped ++ " items."
    False <- atomically $ tryWriteSBChan chan undefined
    SBCItem 91 <- atomically $ readSBChan chan
    True  <- atomically $ tryWriteSBChan chan $ SBCItem 101
    False <- atomically $ tryWriteSBChan chan $ SBCItem 102
    dumpSBChanInts chan

test6 :: IO ()
test6 = do
    chan <- atomically $ newSBChan 10
    forM_ [1..100] $ atomically . cramSBChan chan . SBCItem
    atomically $ unGetSBChan chan $ SBCItem 0
    False <- atomically $ tryWriteSBChan chan undefined
    dropped <- atomically $ rollSBChan chan $ SBCItem 101
    putStrLn $ "Dropped " ++ show dropped ++ " items."
    dumpSBChanInts chan

test7 :: IO ()
test7 = do
    chan <- atomically $ newSBChan 10
    forM_ [1..100] $ atomically . cramSBChan chan . SBCItem
    atomically $ unGetSBChan chan $ SBCItem 0
    dumpSBChanInts chan

newtype V = V Int

instance ItemSize V where
    itemSize (V n) = n

test8 :: IO ()
test8 = do
    chan <- newSBChanIO 10

    -- Yes, we *are* allowed to write this item, since it is the only item
    -- right now.
    True <- atomically $ tryWriteSBChan chan $ V 100

    -- However, we can't write anything else now.
    False <- atomically $ tryWriteSBChan chan $ V 0

    atomically $ cramSBChan chan $ V 0
    1 <- atomically $ satisfyLimitSBChan chan

    True  <- atomically $ tryWriteSBChan chan $ V 1
    True  <- atomically $ tryWriteSBChan chan $ V 2
    True  <- atomically $ tryWriteSBChan chan $ V 3
    4     <- atomically $ rollSBChan chan $ V 100
    V 100 <- atomically $ peekSBChan chan
    return ()

test9 :: IO ()
test9 = do
    chan <- newSBChanIO 10
    True  <- atomically $ tryWriteSBChan chan $ V 1
    True  <- atomically $ tryWriteSBChan chan $ V 2
    True  <- atomically $ tryWriteSBChan chan $ V 3
    atomically $ cramSBChan chan $ V 100
    False <- atomically $ tryWriteSBChan chan $ V 0
    False <- atomically $ tryWriteSBChan chan $ V 0

    3     <- atomically $ satisfyLimitSBChan chan
    False <- atomically $ tryWriteSBChan chan $ V 0

    V 100 <- atomically $ readSBChan chan
    True  <- atomically $ tryWriteSBChan chan $ V 0

    return ()

main :: IO ()
main = mapM_ runTest
    [ "test1" # test1
    , "test2" # test2
    , "test3" # test3
    , "test4" # test4
    , "test5" # test5
    , "test6" # test6
    , "test7" # test7
    , "test8" # test8
    , "test9" # test9
    ]
  where
    (#) = (,)

dumpSBChan :: ItemSize a => SBChan a -> STM [a]
dumpSBChan chan =
    loop id
  where
    loop !dl = do
        m <- tryReadSBChan chan
        case m of
            Nothing -> return $ dl []
            Just x  -> loop $ dl . (x:)

dumpSBChanInts :: SBChan (SBCItem Int) -> IO ()
dumpSBChanInts chan =
    atomically (dumpSBChan chan) >>= print . map unSBCItem

runTest :: (String, IO ()) -> IO ()
runTest (name, io) = do
    putStrLn $ "*** Running " ++ name
    io `catch` \(SomeException e) -> print e
