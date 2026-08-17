-- SPDX-License-Identifier: Apache-2.0

module Main (main) where

import Control.Exception (IOException, evaluate, try)
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Maybe (fromMaybe)
import System.Environment (lookupEnv)
import System.Exit (ExitCode(..), exitSuccess)
import System.Process (readProcessWithExitCode)
import Test.Tasty (localOption)
import Test.Tasty.Bench

main :: IO ()
main = do
  mimg <- pickImage
  case mimg of
    Nothing -> do
      putStrLn "skipping benches: no podman or usable image"
      exitSuccess
    Just img -> do
      nref <- newIORef (0 :: Int)
      -- Wall-clock: CPU time ignores time spent in encapsule/podman.
      defaultMain
        [ localOption WallTime $
            bgroup "encapsule"
              [ bench "dryrun" $
                  nfIO $ runEnc ["run", "--dryrun", "--no-skel", img]
              , bench "run true" $ nfIO $ do
                  n <- atomicModifyIORef' nref (\i -> (i + 1, i))
                  let name = "^encap-bench-" ++ show n
                  runEnc ["run", "--no-skel", "--name", name, img, "--", "true"]
              ]
        ]

runEnc :: [String] -> IO ()
runEnc args = do
  exe <- fromMaybe "encapsule" <$> lookupEnv "ENCAPSULE"
  (code, out, err) <- readProcessWithExitCode exe args ""
  case code of
    ExitSuccess -> evaluate ()
    ExitFailure n ->
      fail $ "encapsule failed (" ++ show n ++ "): " ++ out ++ err

pickImage :: IO (Maybe String)
pickImage = do
  ok <- hasPodman
  if not ok
    then return Nothing
    else do
      u <- fromMaybe "ubuntu:latest" <$> lookupEnv "ENCAPSULE_TEST_UBUNTU"
      f <- fromMaybe "fedora:latest" <$> lookupEnv "ENCAPSULE_TEST_FEDORA"
      mu <- imageExists u
      mf <- imageExists f
      return $
        case (mu, mf) of
          (True, _) -> Just u
          (_, True) -> Just f
          _ -> Nothing

hasPodman :: IO Bool
hasPodman = do
  r <- try (readProcessWithExitCode "podman" ["--version"] "")
         :: IO (Either IOException (ExitCode, String, String))
  case r of
    Left _ -> return False
    Right (code, _, _) -> return $ code == ExitSuccess

imageExists :: String -> IO Bool
imageExists img = do
  (code, _, _) <- readProcessWithExitCode "podman" ["image", "exists", img] ""
  return $ code == ExitSuccess
