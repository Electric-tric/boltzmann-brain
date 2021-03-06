-- | Compiler: Boltzmann brain v1.1
-- | Singularity: 0.33333301544189453
module Sampler (genRandomM, sampleM, sampleMIO) where
import Control.Monad (guard)
import Control.Monad.Trans (lift)
import Control.Monad.Trans.Maybe (MaybeT(..), runMaybeT)
import Control.Monad.Random
       (RandomGen(..), Rand, getRandomR, evalRandIO)

data M = Leaf
       | Unary M
       | Binary M M
       deriving Show

randomP :: RandomGen g => MaybeT (Rand g) Double
randomP = lift (getRandomR (0, 1))

genRandomM :: RandomGen g => Int -> MaybeT (Rand g) (M, Int)
genRandomM ub
  = do guard (ub > 0)
       p <- randomP
       if p < 0.3341408333975344 then return (Leaf, 1) else
         if p < 0.667473848839429 then
           do (x0, w0) <- genRandomM (ub - 1)
              return (Unary x0, 1 + w0)
           else
           do (x0, w0) <- genRandomM (ub - 1)
              (x1, w1) <- genRandomM (ub - 1 - w0)
              return (Binary x0 x1, 1 + w1 + w0)

sampleM :: RandomGen g => Int -> Int -> Rand g M
sampleM lb ub
  = do sample <- runMaybeT (genRandomM ub)
       case sample of
           Nothing -> sampleM lb ub
           Just (x, s) -> if lb <= s then return x else sampleM lb ub

sampleMIO :: Int -> Int -> IO M
sampleMIO lb ub = evalRandIO (sampleM lb ub)
