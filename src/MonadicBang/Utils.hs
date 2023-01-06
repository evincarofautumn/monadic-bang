{-# LANGUAGE MonoLocalBinds #-}

module MonadicBang.Utils where

import Control.Monad.Trans.Maybe
import Data.Foldable
import Data.Monoid

type DList a = Endo [a]

type Handler m a = a -> m a

{-# INLINE fromDList #-}
fromDList :: DList a -> [a]
fromDList = appEndo ?? []

{-# INLINE (??) #-}
(??) :: Functor f => f (a -> b) -> a -> f b
fs ?? x = ($ x) <$> fs

-- This is included in transformers 0.6, but that can't be used together with ghc 9.4
{-# INLINE hoistMaybe #-}
hoistMaybe :: Applicative m => Maybe a -> MaybeT m a
hoistMaybe = MaybeT . pure

{-# INLINE dup #-}
dup :: a -> (a, a)
dup a = (a, a)

{-# INLINE foldMapA #-}
foldMapA :: (Traversable t, Applicative f, Monoid m) => (a -> f m) -> t a -> f m
foldMapA f xs = fold <$> traverse f xs

panic :: String -> a
panic message = error $ unlines ["MonadicBang panic:", message, "", submitReport]
  where
    submitReport = "This is likely a bug. Please submit a bug report at https://github.com/JakobBruenker/monadic-bang/issues"
