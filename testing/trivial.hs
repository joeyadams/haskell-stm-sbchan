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

main :: IO ()
main = mapM_ runTest
    [ "test1" # test1
    , "test2" # test2
    , "test3" # test3
    , "test4" # test4
    , "test5" # test5
    , "test6" # test6
    , "test7" # test7
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
