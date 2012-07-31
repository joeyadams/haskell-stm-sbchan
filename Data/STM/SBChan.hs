-- |
-- Module:      Data.STM.SBChan
-- Copyright:   (c) Joseph Adams 2012
-- License:     BSD3
-- Maintainer:  joeyadams3.14159@gmail.com
-- Portability: Requires STM
--
-- FIFO queue for STM, bounded by the total \"size\" of the items.
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE RecordWildCards #-}
module Data.STM.SBChan (
    -- * SBChan
    SBChan,
    newSBChan,
    newSBChanIO,

    -- * Item sizes
    ItemSize(..),
    SBCItem(..),

    -- * Reading and writing
    readSBChan,
    writeSBChan,
    peekSBChan,
    unGetSBChan,
    isEmptySBChan,

    -- ** Non-blocking variants
    tryReadSBChan,
    tryWriteSBChan,
    tryPeekSBChan,

    -- ** Alternative overflow strategies
    cramSBChan,
    rollSBChan,

    -- * Managing the limit
    getLimitSBChan,
    setLimitSBChan,
    satisfyLimitSBChan,

    -- * Miscellaneous
    clearSBChan,
) where

import Control.Concurrent.STM.TVar
import Control.Monad.STM
import Data.Typeable                (Typeable)

import Data.STM.TList (TList)
import qualified Data.STM.TList as TList

data SBChan a = SBC
    { readEnd   :: !(TVar (ReadEnd a))
    , writeEnd  :: !(TVar (WriteEnd a))
    }
    -- ^ Invariants:
    --
    --  * 'readSize' >= 0 and 'writeSize' >= 0, provided that:
    --
    --      1) For all x, 'itemSize' x >= 0.
    --
    --      2) Int does not overflow.
    --
    --  * 'writeSize' - 'readSize' = total size of items in the channel
    --
    --  * 'writeSize' >= 'readSize', assuming 'itemSize' always returns >= 0.
    deriving Typeable

instance Eq (SBChan a) where
    a == b = readEnd a == readEnd b

data ReadEnd a = ReadEnd
    { readPtr   :: !(TList a)
    , readSize  :: !Int
        -- ^ Total size of items read since we last synced with the write end
    }

-- | Invariants:
--
--  * 'writePtr' points to a 'TNil'.
--
--  * 'writeSize' <= 'chanLimit', except in the following cases:
--
--      1) There is a single item in the channel, and its size is larger than
--         'chanLimit'.
--
--      2) 'setLimitSBChan' was used, causing 'chanLimit' to fall below
--         'writeSize'.
--
--      3) 'cramSBChan' was used.
--
data WriteEnd a = WriteEnd
    { writePtr  :: !(TList a)
    , writeSize :: !Int
        -- ^ Total size of items in the channel, *plus* total size of items
        -- read that the write end doesn't know about.  When 'writeSize'
        -- exceeds 'chanLimit', we sync with the read end to take into account
        -- capacity gained due to reads.
    , chanLimit :: !Int
        -- ^ Size limit of the channel, as returned by 'getLimitSBChan'.  It is
        -- stored in the write end so it can be accessed easily by writers.
    }

class ItemSize a where
    -- | Return the \"size\" of an individual item.  This is usually an
    -- estimate of how many bytes the item takes up in memory, including
    -- channel overhead.
    --
    -- 'itemSize' must return a number >= 0.  'itemSize' should be fast, in
    -- case it is re-evaluated often due to transaction retries and
    -- invalidations.
    itemSize :: a -> Int

------------------------------------------------------------------------

-- | Create a new, empty 'SBChan', with the given size limit.
--
-- To change the size limit later, use 'setLimitSBChan'.
newSBChan :: Int -> STM (SBChan a)
newSBChan limit = do
    hole <- TList.empty
    rv <- newTVar $ ReadEnd hole 0
    wv <- newTVar $ WriteEnd hole 0 limit
    return (SBC rv wv)

{- |
@IO@ variant of 'newSBChan'.  This is useful for creating top-level
'SBChan's using 'System.IO.Unsafe.unsafePerformIO', because performing
'atomically' inside a pure computation is extremely dangerous (can lead to
'Control.Exception.NestedAtomically' errors and even segfaults,
see GHC ticket #5866).

Example:

@
logChannel :: 'SBChan' LogEntry
logChannel = 'System.IO.Unsafe.unsafePerformIO' ('newSBChanIO' 500000)
\{\-\# NOINLINE logChannel \#\-\}
@
-}
newSBChanIO :: Int -> IO (SBChan a)
newSBChanIO limit = do
    hole <- TList.emptyIO
    rv <- newTVarIO $ ReadEnd hole 0
    wv <- newTVarIO $ WriteEnd hole 0 limit
    return (SBC rv wv)

-- | Remove all items from the 'SBChan'.
clearSBChan :: SBChan a -> STM ()
clearSBChan SBC{..} = do
    hole <- TList.empty
    oldWriteEnd <- readTVar writeEnd
    writeTVar readEnd  $ ReadEnd hole 0
    writeTVar writeEnd $ WriteEnd hole 0 (chanLimit oldWriteEnd)

-- | Read the next item from the channel.  'retry' if the channel is empty.
readSBChan :: ItemSize a => SBChan a -> STM a
readSBChan = undefined

-- | Write an item to the channel.  'retry' if the item does not fit.
--
-- As an exception, if the channel is currently empty, but the item's size
-- exceeds the channel limit all by itself, it will be written to the channel
-- anyway.  This is to prevent a large item from causing the application to
-- deadlock.
writeSBChan :: ItemSize a => SBChan a -> a -> STM ()
writeSBChan = undefined

-- | Get the next item from the channel without removing it.  'retry' if the
-- channel is empty.
peekSBChan :: SBChan a -> STM a
peekSBChan = undefined

-- | Put an item back on the channel, where it will be the next item read.
--
-- This will always succeed, even if it causes the channel's size limit to be
-- exceeded.  The rationale is that the size limit can be exceeded in some
-- cases (e.g. by writing an oversized item to an empty channel).  If we allow
-- 'writeSBChan' to exceed the limit, but don't allow 'unGetSBChan' to exceed
-- the limit, then we can't always read an item and put it back.
--
-- Note that 'Control.Concurrent.STM.TBQueue.unGetTBQueue' in
-- "Control.Concurrent.STM.TBQueue" is different: it will 'retry' if the queue
-- is full.
unGetSBChan :: ItemSize a => SBChan a -> a -> STM ()
unGetSBChan SBC{..} a = do
    ReadEnd{..} <- readTVar readEnd
    readPtr' <- TList.cons a readPtr
    writeTVar readEnd $! ReadEnd
        { readPtr  = readPtr'
        , readSize = readSize - itemSize a
        }

-- | Return 'True' if the channel is empty.
isEmptySBChan :: SBChan a -> STM Bool
isEmptySBChan SBC{..} = do
    ReadEnd{..} <- readTVar readEnd
    TList.null readPtr

-- | Variant of 'readSBChan' which does not 'retry'.  Instead, it returns
-- 'Nothing' if the channel is empty.
tryReadSBChan :: ItemSize a => SBChan a -> STM (Maybe a)
tryReadSBChan SBC{..} = do
    ReadEnd{..} <- readTVar readEnd
    let pop x xs = do
            writeTVar readEnd $! ReadEnd
                { readPtr  = xs
                , readSize = readSize + itemSize x
                }
            return (Just x)
    TList.uncons (return Nothing) pop readPtr

-- | Variant of 'writeSBChan' which does not 'retry'.  Instead, it returns
-- 'False' if the item does not fit.
tryWriteSBChan :: ItemSize a => SBChan a -> a -> STM Bool
tryWriteSBChan SBC{..} x = do
    we@WriteEnd{..} <- readTVar writeEnd
    let writeSize' = writeSize + itemSize x
    if writeSize' <= chanLimit
        then do
            appendWriteEnd writeEnd we x writeSize'
            return True
        else do
            ReadEnd{..} <- readTVar readEnd
            let writeSize'' = writeSize' - readSize
            let syncAndAppend = do
                    writeTVar readEnd $! ReadEnd
                        { readPtr  = readPtr
                        , readSize = 0
                        }
                    appendWriteEnd writeEnd we x writeSize''
                    return True
            -- If the item does not fit, but the channel is empty, we want to
            -- insert it anyway.  readPtr == writePtr is an optimized way to
            -- test if the channel is empty when we've already read both
            -- 'readEnd' and 'writeEnd'.
            if writeSize'' <= chanLimit || readPtr == writePtr
                then syncAndAppend
                else return False

appendWriteEnd :: TVar (WriteEnd a) -> WriteEnd a -> a -> Int -> STM ()
appendWriteEnd var WriteEnd{..} x writeSize' = do
    writePtr' <- TList.append writePtr x
    writeTVar var $! WriteEnd
        { writePtr  = writePtr'
        , writeSize = writeSize'
        , chanLimit = chanLimit
        }

-- | Variant of 'peekSBChan' which does not 'retry'.  Instead, it returns
-- 'Nothing' if the channel is empty.
tryPeekSBChan :: SBChan a -> STM (Maybe a)
tryPeekSBChan SBC{..} = do
    ReadEnd{..} <- readTVar readEnd
    TList.uncons (return Nothing) (\x _xs -> return (Just x)) readPtr

-- | Like 'writeSBChan', but ignore the channel size limit.  This will always
-- succeed, and will not 'retry'.
cramSBChan :: ItemSize a => SBChan a -> a -> STM ()
cramSBChan SBC{..} x = do
    we@WriteEnd{..} <- readTVar writeEnd
    let writeSize' = writeSize + itemSize x
    if writeSize' <= chanLimit
        then appendWriteEnd writeEnd we x writeSize'
        else do
            -- Sync with the read end to avoid integer overflow.
            ReadEnd{..} <- readTVar readEnd
            -- Avoid modifying 'readEnd' if we can.
            if readSize == 0
                then appendWriteEnd writeEnd we x writeSize'
                else do
                    writeTVar readEnd $! ReadEnd
                        { readPtr  = readPtr
                        , readSize = 0
                        }
                    appendWriteEnd writeEnd we x (writeSize' - readSize)

-- | Like 'writeSBChan', but if the channel is full, drop items from the
-- beginning of the channel until there is enough room for the new item (or
-- until the channel is empty).  This will always succeed, and will not
-- 'retry'.
--
-- Return the number of items dropped.
rollSBChan :: ItemSize a => SBChan a -> a -> STM Int
rollSBChan = undefined

-- | Get the current limit on total size of items in the channel.
getLimitSBChan :: SBChan a -> STM Int
getLimitSBChan = undefined

-- | Set the total size limit.  If the channel exceeds the new limit, too bad.
setLimitSBChan :: SBChan a -> Int -> STM ()
setLimitSBChan = undefined

-- | Drop items from the beginning of the channel until the channel's size
-- limit is satisfied, or until there is only one item left in the channel.
satisfyLimitSBChan :: ItemSize a => SBChan a -> STM ()
satisfyLimitSBChan = undefined

------------------------------------------------------------------------
-- Convenience

-- | Wrapper for items where @'itemSize' item = 1@.  This helps you use
-- 'SBChan' as a channel with a maximum /number/ of items.
newtype SBCItem a = SBCItem { unSBCItem :: a }
    deriving Typeable

instance ItemSize (SBCItem a) where
    itemSize _ = 1
