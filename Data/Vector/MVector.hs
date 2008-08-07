{-# LANGUAGE MultiParamTypeClasses #-}
-- |
-- Module      : Data.Vector.MVector
-- Copyright   : (c) Roman Leshchinskiy 2008
-- License     : BSD-style
--
-- Maintainer  : rl@cse.unsw.edu.au
-- Stability   : experimental
-- Portability : non-portable
-- 
-- Generic interface to mutable vectors
--

#include "phases.h"

module Data.Vector.MVector (
  MVectorPure(..), MVector(..),

  slice, new, newWith, read, write, copy, grow,
  unstream, mstream, munstream,
  update, reverse, map
) where

import qualified Data.Vector.Stream      as Stream
import           Data.Vector.Stream      ( Stream )
import           Data.Vector.Stream.Size

import Control.Monad.ST ( ST )
import Control.Exception ( assert )

import GHC.Float (
    double2Int, int2Double
  )

import Prelude hiding ( length, reverse, map, read )

gROWTH_FACTOR :: Double
gROWTH_FACTOR = 1.5

-- | Basic pure functions on mutable vectors
class MVectorPure v a where
  -- | Length of the mutable vector
  length           :: v a -> Int

  -- | Yield a part of the mutable vector without copying it. No range checks!
  unsafeSlice      :: v a -> Int  -- ^ starting index
                          -> Int  -- ^ length of the slice
                          -> v a

  -- Check whether two vectors overlap.
  overlaps         :: v a -> v a -> Bool

-- | Class of mutable vectors. The type @m@ is the monad in which the mutable
-- vector can be transformed and @a@ is the type of elements.
--
class (Monad m, MVectorPure v a) => MVector v m a where
  -- | Create a mutable vector of the given length. Length is not checked!
  unsafeNew        :: Int -> m (v a)

  -- | Create a mutable vector of the given length and fill it with an
  -- initial value. Length is not checked!
  unsafeNewWith    :: Int -> a -> m (v a)

  -- | Yield the element at the given position. Index is not checked!
  unsafeRead       :: v a -> Int -> m a

  -- | Replace the element at the given position. Index is not checked!
  unsafeWrite      :: v a -> Int -> a -> m ()

  -- | Clear all references to external objects
  clear            :: v a -> m ()

  -- | Write the value at each position.
  set              :: v a -> a -> m ()

  -- | Copy a vector. The two vectors may not overlap. This is not checked!
  unsafeCopy       :: v a   -- ^ target
                   -> v a   -- ^ source
                   -> m ()

  -- | Grow a vector by the given number of elements. The length is not
  -- checked!
  unsafeGrow       :: v a -> Int -> m (v a)

  {-# INLINE unsafeNewWith #-}
  unsafeNewWith n x = do
                        v <- unsafeNew n
                        set v x
                        return v

  {-# INLINE set #-}
  set v x = do_set 0
    where
      n = length v

      do_set i | i < n = do
                            unsafeWrite v i x
                            do_set (i+1)
                | otherwise = return ()

  {-# INLINE unsafeCopy #-}
  unsafeCopy dst src = do_copy 0
    where
      n = length src

      do_copy i | i < n = do
                            x <- unsafeRead src i
                            unsafeWrite dst i x
                            do_copy (i+1)
                | otherwise = return ()

  {-# INLINE unsafeGrow #-}
  unsafeGrow v by = do
                      v' <- unsafeNew (n+by)
                      unsafeCopy (unsafeSlice v' 0 n) v
                      return v'
    where
      n = length v

-- | Test whether the index is valid for the vector
inBounds :: MVectorPure v a => v a -> Int -> Bool
{-# INLINE inBounds #-}
inBounds v i = i >= 0 && i < length v

-- | Yield a part of the mutable vector without copying it. Safer version of
-- 'unsafeSlice'.
slice :: MVectorPure v a => v a -> Int -> Int -> v a
{-# INLINE slice #-}
slice v i n = assert (i >=0 && n >= 0 && i+n <= length v)
            $ unsafeSlice v i n

-- | Create a mutable vector of the given length. Safer version of
-- 'unsafeNew'.
new :: MVector v m a => Int -> m (v a)
{-# INLINE new #-}
new n = assert (n >= 0) $ unsafeNew n

-- | Create a mutable vector of the given length and fill it with an
-- initial value. Safer version of 'unsafeNewWith'.
newWith :: MVector v m a => Int -> a -> m (v a)
{-# INLINE newWith #-}
newWith n x = assert (n >= 0) $ unsafeNewWith n x

-- | Yield the element at the given position. Safer version of 'unsafeRead'.
read :: MVector v m a => v a -> Int -> m a
{-# INLINE read #-}
read v i = assert (inBounds v i) $ unsafeRead v i

-- | Replace the element at the given position. Safer version of
-- 'unsafeWrite'.
write :: MVector v m a => v a -> Int -> a -> m ()
{-# INLINE write #-}
write v i x = assert (inBounds v i) $ unsafeWrite v i x

-- | Copy a vector. The two vectors may not overlap. Safer version of
-- 'unsafeCopy'.
copy :: MVector v m a => v a -> v a -> m ()
{-# INLINE copy #-}
copy dst src = assert (not (dst `overlaps` src) && length dst == length src)
             $ unsafeCopy dst src

-- | Grow a vector by the given number of elements. Safer version of
-- 'unsafeGrow'.
grow :: MVector v m a => v a -> Int -> m (v a)
{-# INLINE grow #-}
grow v by = assert (by >= 0)
          $ unsafeGrow v by

mstream :: MVector v m a => v a -> Stream (m a)
{-# INLINE mstream #-}
mstream v = v `seq` (Stream.unfold get 0 `Stream.sized` Exact n)
  where
    n = length v

    {-# INLINE get #-}
    get i | i < n     = Just (unsafeRead v i, i+1)
          | otherwise = Nothing

munstream :: MVector v m a => v a -> Stream (m a) -> m (v a)
{-# INLINE munstream #-}
munstream v s = v `seq` do
                          n' <- Stream.foldM put 0 s
                          return $ slice v 0 n'
  where
    put i m = do { write v i =<< m; return (i+1) }

-- | Create a new mutable vector and fill it with elements from the 'Stream'.
-- The vector will grow logarithmically if the 'Size' hint of the 'Stream' is
-- inexact.
unstream :: MVector v m a => Stream a -> m (v a)
{-# INLINE_STREAM unstream #-}
unstream s = case upperBound (Stream.size s) of
               Just n  -> unstreamMax     s n
               Nothing -> unstreamUnknown s

unstreamMax :: MVector v m a => Stream a -> Int -> m (v a)
{-# INLINE unstreamMax #-}
unstreamMax s n
  = do
      v  <- new n
      let put i x = do { write v i x; return (i+1) }
      n' <- Stream.foldM put 0 s
      return $ slice v 0 n'

unstreamUnknown :: MVector v m a => Stream a -> m (v a)
{-# INLINE unstreamUnknown #-}
unstreamUnknown s
  = do
      v <- new 0
      (v', n) <- Stream.foldM put (v, 0) s
      return $ slice v' 0 n
  where
    {-# INLINE put #-}
    put (v, i) x = do
                     v' <- enlarge v i
                     unsafeWrite v' i x
                     return (v', i+1)

    {-# INLINE enlarge #-}
    enlarge v i | i < length v = return v
                | otherwise    = unsafeGrow v
                                 . max 1
                                 . double2Int
                                 $ int2Double (length v) * gROWTH_FACTOR

update :: MVector v m a => v a -> Stream (Int, a) -> m ()
{-# INLINE update #-}
update v s = Stream.mapM_ put s
  where
    {-# INLINE put #-}
    put (i, x) = write v i x

reverse :: MVector v m a => v a -> m ()
{-# INLINE reverse #-}
reverse v = reverse_loop 0 (length v - 1)
  where
    reverse_loop i j | i < j = do
                                 x <- unsafeRead v i
                                 y <- unsafeRead v j
                                 unsafeWrite v i y
                                 unsafeWrite v j x
    reverse_loop _ _ = return ()


map :: MVector v m a => (a -> a) -> v a -> m ()
{-# INLINE map #-}
map f v = map_loop 0
  where
    n = length v

    map_loop i | i <= n    = do
                               x <- read v i
                               write v i (f x)
               | otherwise = return ()
