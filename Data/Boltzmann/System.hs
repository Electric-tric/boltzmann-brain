{-|
 Module      : Data.Boltzmann.System
 Description : System utilities for combinatorial specifications.
 Copyright   : (c) Maciej Bendkowski, 2017

 License     : BSD3
 Maintainer  : maciej.bendkowski@tcs.uj.edu.pl
 Stability   : experimental
 -}
module Data.Boltzmann.System
    ( System(..)
    , size
    , constructors
    , Cons(..)
    , Arg(..)
    , types

    , PSystem(..)
    , typeList
    , paramTypes
    , paramTypesW
    , typeWeight
    , seqTypes

    , SystemType(..)
    , systemType
    , hasAtoms
    , isAtomic

    , evalT
    , evalC
    , evalA
    , getIdx
    , value
    , eval
    ) where

import Data.Set (Set)
import qualified Data.Set as S

import Data.Map (Map)
import qualified Data.Map.Strict as M

import Numeric.LinearAlgebra hiding (size)

import Data.Maybe (mapMaybe)

import Data.List (nub)
import Data.Graph

-- | System of combinatorial structures.
data System a = System { defs        :: Map String [Cons a]   -- ^ Type definitions.
                       , annotations :: Map String String     -- ^ System annotations.
                       } deriving (Show)

size :: System a -> Int
size = M.size . defs

constructors :: System a -> Int
constructors = length . concat . M.elems . defs

-- | Type constructor.
data Cons a = Cons { func      :: String        -- ^ Constructor name.
                   , args      :: [Arg]         -- ^ Argument list.
                   , weight    :: a             -- ^ Constructor weight.
                   , frequency :: Maybe Double  -- ^ Marking parameter.
                   } deriving (Eq,Show)

-- | Type constructor arguments.
data Arg = Type String                       -- ^ Regular type reference.
         | List String                       -- ^ Type list reference.
           deriving (Eq,Show)

argName :: Arg -> String
argName (Type s) = s
argName (List s) = s

-- | Type set of the given system.
types :: System a -> Set String
types = M.keysSet . defs

-- | Parametrised system of combinatorial structures.
data PSystem a = PSystem { system  :: System a      -- ^ System with probability weights.
                         , values  :: Vector a      -- ^ Numerical values of corresponding types.
                         , param   :: a             -- ^ Evaluation parameter.
                         , weights :: System Int    -- ^ System with input weights.
                         } deriving (Show)

-- | Type list of the given parametrised system.
typeList :: PSystem a -> [String]
typeList = S.toList . M.keysSet . defs . system

-- | List of types with corresponding constructors.
paramTypes :: PSystem a -> [(String, [Cons a])]
paramTypes = M.toList . defs . system

-- | List of types with corresponding constructors and input weights.
paramTypesW :: PSystem a -> [(String, [(Cons a, Int)])]
paramTypesW sys = map (addW $ weights sys) xs
    where xs = paramTypes sys

addW :: System Int -> (String, [a]) -> (String, [(a, Int)])
addW sys (s, cons) = (s, zip cons ws)
    where ws = typeW sys s

typeW :: System Int -> String -> [Int]
typeW sys s = case s `M.lookup` defs sys of
    Just cons -> map weight cons
    Nothing -> []

-- | Type weight of the given parametrised system.
typeWeight :: PSystem Double -> String -> Double
typeWeight sys t = vec ! idx
    where m   = defs $ system sys
          vec = values sys
          idx = M.findIndex t m

-- | List of sequence types.
seqTypes :: System a -> [String]
seqTypes = S.elems . S.fromList . concatMap seqTypesCons
            . concat . M.elems . defs

seqTypesCons :: Cons a -> [String]
seqTypesCons = mapMaybe listN . args
    where listN (List s) = Just s
          listN _        = Nothing

isListArg :: Arg -> Bool
isListArg (List _) = True
isListArg  _       = False

data SystemType = Rational
                | Algebraic
                | Unsupported String   -- ^ error message

instance Show SystemType where
    show Rational        = "rational"
    show Algebraic       = "algebraic"
    show (Unsupported _) = "unsupported"

-- | Determines the system type.
systemType :: System a -> SystemType
systemType sys
  | not (isLinear sys)        = Algebraic
  | not (isInterruptible sys) = Unsupported "Given rational system is not interruptible."
  | otherwise =
    let depGraph = dependencyGraph sys
     in case scc depGraph of
          [_] -> Rational
          xs  -> Unsupported $ "Given rational system has "
                    ++ show (length xs) ++ " strongly connected components."

-- | Constructs a dependency graph for the given system.
dependencyGraph :: System a -> Graph
dependencyGraph sys = buildG (0,n+d-1) (edgs ++ edgs')
    where idx s      = M.findIndex s (defs sys)
          idxSeq s   = n + S.findIndex s seqsSet
          edgs       = concatMap (edges' atomicT idx idxSeq) $ M.toList (defs sys)
          edgs'      = concatMap (\t -> [(idxSeq t, idxSeq t),
                                    (idxSeq t, idx t)]) seqs
          atomicT    = atomicTypes sys
          seqsSet    = S.fromAscList seqs
          seqs       = seqTypes sys
          d          = S.size seqsSet
          n          = size sys

edges' :: Set String -> (String -> Int) -> (String -> Int) -> (String, [Cons b]) -> [(Vertex, Vertex)]
edges' atomicT idx idxSeq (t,cons) = concatMap edge' $ neighbours cons
    where tidx           = idx t
          neighbours     = nub . concatMap args
          edge' (List s) = [(tidx, idxSeq s)]
          edge' (Type s)
            | s `S.member` atomicT = [(tidx, idx s), (idx s, tidx)] -- double edge
            | otherwise = [(tidx, idx s)]

-- | Checks whether the system is linear, i.e.
--   each constructor references at most one type.
isLinear :: System a -> Bool
isLinear sys = all (all linear) (M.elems $ defs sys)
    where atomicT     = atomicTypes sys
          linear cons =  not (any isListArg $ args cons)
            && length (compoundArgs atomicT $ args cons) <= 1

-- | Determines whether each constructor n the system has at most one atom.
--   Note: the system is assumed to contain some atoms (see hasAtoms).
isInterruptible :: System a -> Bool
isInterruptible sys = all interruptible' $ M.elems (defs sys)
    where interruptible' cons = length (filter isAtomic cons) <= 1

compoundArgs :: Set String -> [Arg] -> [Arg]
compoundArgs atomicT = filter (\x -> argName x `S.notMember` atomicT)

-- | Determines the set of "atomic" types.
atomicTypes :: System a -> Set String
atomicTypes sys = S.fromList $ map fst ts
    where ts = filter isAtomic' $ M.toList (defs sys)
          isAtomic' (_,cons) = all isAtomic cons

isAtomic :: Cons a -> Bool
isAtomic = null . args

-- | Determines whether the system has atoms.
hasAtoms :: System a -> Bool
hasAtoms sys = any (any isAtomic) $ M.elems (defs sys)

-- | Evaluates the type in the given coordinates.
evalT :: System Int -> Double -> Vector Double -> [Cons Int] -> Double
evalT sys z ys cons = sum $ map (evalC sys z ys) cons

-- | Evaluates the constructor in the given coordinates.
evalC :: System Int -> Double -> Vector Double -> Cons Int -> Double
evalC sys z ys con = foldl (*) start $ map (evalA sys ys) (args con)
    where w = weight con
          start = if w > 0 then z ^^ w
                           else 1

-- | Evaluates the argument in the given coordinates.
evalA :: System Int -> Vector Double -> Arg -> Double
evalA sys ys (Type t) = ys ! getIdx sys t
evalA sys ys (List t) = recip $ 1 - ys ! getIdx sys t

getIdx :: System Int -> String -> Int
getIdx sys x = x `M.findIndex` defs sys

value :: String -> System b -> Vector Double -> Double
value t sys vec = vec ! M.findIndex t (defs sys)

-- | Evaluates the system in the given coordinates.
eval :: System Int -> Vector Double -> Double -> Vector Double
eval sys ys z = n |> map update [0..n]
    where n = size sys
          f k = snd $ M.elemAt k (defs sys)
          update idx = evalT sys z ys $ f idx
