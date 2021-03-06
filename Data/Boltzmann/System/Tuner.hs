{-|
 Module      : Data.Boltzmann.System.Tuner
 Description : Interface utilities with the Paganini tuner.
 Copyright   : (c) Maciej Bendkowski, 2017

 License     : BSD3
 Maintainer  : maciej.bendkowski@tcs.uj.edu.pl
 Stability   : experimental
 -}
module Data.Boltzmann.System.Tuner
    ( PSolver(..)
    , PArg(..)
    , defaultArgs
    , writeSpecification
    , readPaganini
    , runPaganini
    ) where

import Control.Monad

import System.IO
import System.Process hiding (system)

import Text.Megaparsec
import Text.Megaparsec.String

import Numeric.LinearAlgebra hiding (size,double)

import Data.Map (Map)
import qualified Data.Map.Strict as M

import Data.MultiSet (MultiSet)
import qualified Data.MultiSet as B
import qualified Data.Set as S

import Data.Maybe

import Data.Boltzmann.System
import Data.Boltzmann.Internal.Parser

-- | Paganini convex program solvers
data PSolver = SCS
             | ECOS
             | CVXOPT

instance Show PSolver where
    show SCS    = "SCS"
    show ECOS   = "ECOS"
    show CVXOPT = "CVXOPT"

-- | Paganini arguments
data PArg = PArg { solver    :: PSolver
                 , precision :: Double
                 , maxiters  :: Int
                 , sysType   :: SystemType
                 } deriving (Show)

toArgs :: PArg -> [String]
toArgs arg = ["-s", show (solver arg)
             ,"-p", show (precision arg)
             ,"-m", show (maxiters arg)
             ,"-t", show (sysType arg)]

rationalArgs :: PArg
rationalArgs = PArg { solver    = SCS
                    , precision = 1.0e-20
                    , maxiters  = 2500
                    , sysType   = Rational
                    }

algebraicArgs :: PArg
algebraicArgs = PArg { solver    = ECOS
                     , precision = 1.0e-20
                     , maxiters  = 20
                     , sysType   = Algebraic
                     }

-- | Determines default Paganini arguments
defaultArgs :: System a -> PArg
defaultArgs sys =
    case systemType sys of
      Rational  -> rationalArgs
      Algebraic -> algebraicArgs
      _         -> error "Unsupported"

logger :: String -> IO ()
logger s = hPutStrLn stderr ("[LOG] " ++ s)

writeListLn :: Show a => Handle -> [a] -> IO ()
writeListLn h xs = hPutStrLn h (showsList xs)

printer :: Show a => (a -> String -> String) -> [a] -> String
printer _ [] = ""
printer f xs = foldl1 (\a b -> (a . (" " ++) . b))
                        (map f xs) ""

showsList :: Show a => [a]
          -> String

showsList = printer shows

writeSpecification :: System Int -> Handle -> IO ()
writeSpecification sys hout = do
    logger "Writing specification"
    let freqs   = frequencies sys
    let seqs    = seqTypes sys
    let spec    = toPSpec sys

    -- # of equations and frequencies
    writeListLn hout [numTypes spec + numSeqTypes spec
                     ,length freqs]

    -- vector of frequencies
    writeListLn hout freqs

    -- type specifications
    let find' x = x `S.findIndex` M.keysSet (defs sys)
    foldM_ (typeSpecification hout find' spec) 0 (M.elems $ defs sys)

    -- sequence specifications
    mapM_ (seqSpecification hout find' spec) seqs

    logger "Finished writing specification"

getArgs :: System Int -> Maybe PArg -> PArg
getArgs sys = fromMaybe (defaultArgs sys)

runPaganini :: System Int -> Maybe PArg
            -> IO (Either (ParseError Char Dec)
                    (PSystem Double))

runPaganini sys arg = do

    logger "Running paganini"
    let arg' = getArgs sys arg
    logger (printer (++) $ "Arguments: " : toArgs arg')

    (Just hin, Just hout, _, _) <-
        createProcess (proc "paganini" (toArgs arg')){ std_out = CreatePipe
                                                     , std_in  = CreatePipe }

    -- write to paganini's stdout
    writeSpecification sys hin

    -- read output parameters
    s <- hGetContents hout
    let spec = toPSpec sys
    let pag  = parse (paganiniStmt spec) "" s

    case pag of
      Left err -> return $ Left err
      Right (rho, us, ts) -> do
          logger "Parsed paganini output"
          let ts'  = fromList ts
          let sys' = parametrise sys rho ts' us
          logger "Finished"
          return $ Right sys'

readPaganini :: System Int -> String
             -> IO (Either (ParseError Char Dec)
                   (PSystem Double))

readPaganini sys f = do
    let spec = toPSpec sys
    pag <- parsePaganini spec f
    case pag of
        Left err -> return $ Left err
        Right (rho, us, ts) -> do
            let ts'  = fromList ts
            return (Right $ parametrise sys rho ts' us)

frequencies :: System Int -> [Double]
frequencies sys = concatMap (mapMaybe frequency)
    ((M.elems . defs) sys)

-- | Paganini helper specification.
data PSpec = PSpec { numFreqs    :: Int
                   , numTypes    :: Int
                   , numSeqTypes :: Int
                   }

toPSpec :: System Int -> PSpec
toPSpec sys = PSpec { numFreqs    = d
                    , numTypes    = ts
                    , numSeqTypes = ss
                    }

   where ts = size sys
         d  = length $ frequencies sys
         ss = length $ seqTypes sys

typeSpecification :: Handle -> (String -> Int) -> PSpec
                  -> Int -> [Cons Int] -> IO Int

typeSpecification hout find' spec idx cons = do
    let n = length cons
    hPrint hout n -- # of constructors
    foldM (consSpecification hout find' spec) idx cons

consSpecification :: Handle -> (String -> Int) -> PSpec
                  -> Int -> Cons Int -> IO Int

consSpecification hout find' spec idx cons = do
    let (vec, idx') = consVec find' spec idx cons
    writeListLn hout vec -- constructor specification
    return idx'

indicator :: Int -> Int -> [Int]
indicator n k = indicator' n k 1

indicator' :: Int -> Int -> Int -> [Int]
indicator' 0 _ _ = []
indicator' n 0 x = x : replicate (n-1) 0
indicator' n k x = 0 : indicator' (n-1) (k-1) x

occurrences :: Cons a -> (MultiSet String, MultiSet String)
occurrences cons = occurrences' (B.empty,B.empty) $ args cons

occurrences' :: (MultiSet String, MultiSet String)
             -> [Arg] -> (MultiSet String, MultiSet String)

occurrences' (ts,sts) [] = (ts,sts)
occurrences' (ts,sts) (Type s : xs) = occurrences' (s `B.insert` ts,sts) xs
occurrences' (ts,sts) (List s : xs) = occurrences' (ts, s `B.insert` sts) xs

consVec :: (String -> Int) -> PSpec -> Int -> Cons Int -> ([Int], Int)
consVec find' spec idx cons =
      let (tocc, socc) = occurrences cons
          w            = fromIntegral $ weight cons
          dv           = indicator' (numFreqs spec) idx (weight cons)
          tv           = typeVec find' (numTypes spec) tocc
          sv           = typeVec find' (numSeqTypes spec) socc

      in case frequency cons of
           Just _  -> (w : dv ++ tv ++ sv, idx + 1)
           Nothing -> (w : replicate (numFreqs spec) 0 ++ tv ++ sv, idx)

typeVec :: (String -> Int) -> Int -> MultiSet String -> [Int]
typeVec find' size' m = typeVec' find' vec ls
    where vec = M.fromList [(n,0) | n <- [0..size'-1]]
          ls  = B.toOccurList m

typeVec' :: (String -> Int) -> Map Int Int -> [(String,Int)] -> [Int]
typeVec' _ vec [] = M.elems vec
typeVec' find' vec ((t,n) : xs) = typeVec' find' vec' xs
    where vec' = M.insert (find' t) n vec

seqSpecification :: Handle -> (String -> Int) -> PSpec
                 -> String -> IO ()

seqSpecification hout find' spec st = do
    let n = 1 + numTypes spec + numFreqs spec + numSeqTypes spec
    let f = replicate (numFreqs spec) 0
    let t = indicator (numTypes spec) (find' st)
    let s = indicator (numSeqTypes spec) (find' st)
    hPrint hout (2 :: Int) -- # of constructors
    writeListLn hout $ replicate n (0 :: Int)
    writeListLn hout $ 0 : f ++ t ++ s

paganiniStmt :: PSpec -> Parser (Double, [Double], [Double])
paganiniStmt spec = do
    rho <- double
    us  <- parseN double $ numFreqs spec
    ts  <- parseN double $ numTypes spec
    return (rho, us, ts)

-- | Parses the given Paganini specification.
parsePaganini :: PSpec -> String
              -> IO (Either (ParseError Char Dec)
                    (Double, [Double], [Double]))

parsePaganini spec = parseFromFile (paganiniStmt spec)

-- | Compute the numerical Boltzmann probabilities for the given system.
parametrise :: System Int -> Double -> Vector Double -> [Double] -> PSystem Double
parametrise sys rho ts us = PSystem { system  = computeProb sys rho ts us
                                    , values  = ts
                                    , param   = rho
                                    , weights = sys
                                    }

evalExp :: System Int -> Double -> Vector Double
        -> [Double] -> Cons Int -> (Double, [Double])

evalExp sys rho ts us exp' =
    let w     = weight exp'
        xs    = args exp'
        exp'' = (rho ^^ w) * product (map (evalA sys ts) xs)
     in case frequency exp' of
          Nothing -> (exp'', us)
          Just _  -> (head us ^^ w * exp'', tail us)

computeExp :: System Int -> Double -> Vector Double
           -> [Double] -> Double -> Double -> [Cons Int]
           -> ([Cons Double], [Double])

computeExp _ _ _ us _ _ [] = ([], us)
computeExp sys rho ts us tw w (e:es) = (e { weight = x / tw } : es', us'')
    where (es', us'') = computeExp sys rho ts us' tw x es
          (w', us') = evalExp sys rho ts us e
          x = w + w'

computeProb' :: System Int -> Double -> Vector Double
             -> [Double] -> [(String, [Cons Int])]
             -> [(String, [Cons Double])]

computeProb' _ _ _ _ [] = []
computeProb' sys rho ts us ((t,cons):tys) = (t,cons') : tys'
    where (cons', us') = computeExp sys rho ts us (value t sys ts) 0.0 cons
          tys' = computeProb' sys rho ts us' tys

computeProb :: System Int -> Double -> Vector Double -> [Double] -> System Double
computeProb sys rho ts us = sys { defs = M.fromList tys }
    where tys = computeProb' sys rho ts us (M.toList $ defs sys)
