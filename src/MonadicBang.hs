{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE NoFieldSelectors #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE PatternSynonyms #-}

module MonadicBang (plugin) where

import Control.Arrow
import Control.Monad.Trans.RWS.CPS
import Data.Data
import Data.Function
import Data.Functor
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as M
import GHC
import GHC.Data.Bag
import GHC.Parser.Errors.Types
import GHC.Plugins
import GHC.Types.Error

import Debug.Trace

plugin :: Plugin
plugin = defaultPlugin
  { parsedResultAction = replaceBangs
  , pluginRecompile = purePlugin
  }

-- We don't care about which file things are from, because the entire AST comes
-- from the same module
data Loc = MkLoc {line :: Int, col :: Int}
         deriving (Eq, Ord, Show)

-- | Increment column by one to get the location after a bang
dropBang :: Loc -> Loc
dropBang loc = loc{col = loc.col + 1}

-- | Used to extract the Loc of a located expression
pattern ExprLoc :: Loc -> HsExpr GhcPs -> LHsExpr GhcPs
pattern ExprLoc{loc, expr} <- L (locA -> RealSrcSpan (spanToLoc -> loc) _) expr

spanToLoc :: RealSrcSpan -> Loc
spanToLoc = uncurry MkLoc . (srcLocLine &&& srcLocCol) . realSrcSpanStart

replaceBangs :: [CommandLineOption] -> ModSummary -> ParsedResult -> Hsc ParsedResult
replaceBangs _ _ (ParsedResult (HsParsedModule lexp files) msgs) =
  pure $ ParsedResult (HsParsedModule (fillHoles fills lexp) files) msgs{psErrors}
  where
    -- Take out the errors we care about, throw the rest back in
    (mkMessages -> psErrors, M.fromList . bagToList -> fills) =
      flip partitionBagWith msgs.psErrors.getMessages \cases
        err
          | PsErrBangPatWithoutSpace ExprLoc{loc, expr} <- err.errMsgDiagnostic
          -> traceShow loc $ Right (loc, expr)
          | otherwise -> Left err

-- | Replace holes in an AST whenever an expression with the corresponding
-- source span can be found in the given list.
fillHoles :: forall a . Data a => Map Loc (HsExpr GhcPs) -> a -> a
fillHoles fillers ast = case runRWS (go ast) () fillers of
  -- TODO: throw error if remaining isn't empty
  (ast, remaining, stmts) -> ast
  where

-- TODO: embed the expression in existing or new do-notation
-- Approach: in tryFillHole, whenever we encounter let/where/do/etc.,
-- make a separate monadic traversal through the subtree with a writer monad,
-- adding the bindings we need to the monadic context so we can construct the
-- correct do block once the traversal is evaluated
-- TODO for large modules with lots of !s, this might be slightly faster if we
-- only consider bangs we haven't found yet, i.e. remove others from the list.
    go :: forall a . Data a => a -> Fill a
    go = gmapM \cases
      (e :: e) -> eqT @e @(LHsExpr GhcPs) & \cases
        (Just Refl)
          | lexp@(ExprLoc (dropBang -> loc) (HsUnboundVar _ _)) <- e
          , Just expr <- fillers M.!? loc
          -> go (lexp $> expr)
        _ -> go e

-- TODO add something to state that lets us generate new variable names (hmm how do we make sure they don't clash with anything? If they're long enough I guess that would be sufficient)
-- This might just be IO btw, need not be state - although random isn't a boot package... and I'd rather only rely on those
-- this would be easier if we were in TcM
-- anyway take a look at unsafeGetFreshLocalUnique - don't think we can use it though
-- we don't technically even *need* randomness - we could start with one randomly generated number that we then use for every module, and increment by one every time
type Fill = RWS () [(RdrName, HsExpr GhcPs)] (Map Loc (HsExpr GhcPs))
