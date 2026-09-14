-- SPDX-License-Identifier: Apache-2.0

module EncapsuleTest (
  encapsule,
  dryrun,
  debugField,
  commandOutputLines,
  hasTTY,
  liveEnabled,
  ubuntuImg,
  fedoraImg,
  hostUid,
  hostUser,
  requireImage,
  withGenericImage,
  ) where

import Control.Exception (IOException, try)
import Control.Monad (unless)
import Data.List (isInfixOf, isPrefixOf)
import Data.Maybe (fromMaybe, listToMaybe)
import System.Environment (lookupEnv)
import System.Exit (ExitCode(..))
import System.Posix.IO (stdInput)
import System.Posix.Terminal (queryTerminal)
import System.Posix.User (getEffectiveUserID, getEffectiveUserName)
import System.Process (readProcessWithExitCode)
import Test.Hspec (pendingWith)

-- | Run encapsule with args; combined stdout and stderr.
encapsule :: [String] -> IO String
encapsule args = do
  exe <- fromMaybe "encapsule" <$> lookupEnv "ENCAPSULE"
  (_, out, err) <- readProcessWithExitCode exe args ""
  return $ out ++ err

dryrun :: [String] -> IO String
dryrun args = encapsule $ ["run", "--dryrun", "--debug", "--no-skel"] ++ args

-- | Non-empty output lines that are not podman/log noise (e.g. "not a TTY").
commandOutputLines :: String -> [String]
commandOutputLines out =
  [ l
  | l <- map (filter (/= '\r')) (lines out)
  , not (null l)
  , not (isNoise l)
  ]
  where
    isNoise l =
      "level=warning" `isInfixOf` l
        || "not a TTY" `isInfixOf` l
        || "msg=" `isInfixOf` l

debugField :: String -> String -> Maybe String
debugField out key =
  let prefix = "debug: " ++ key ++ ": "
  in listToMaybe
       [ filter (/= '\r') rest
       | l <- lines out
       , Just rest <- [afterInfix prefix l]
       ]

afterInfix :: String -> String -> Maybe String
afterInfix p s
  | p `isPrefixOf` s = Just $ drop (length p) s
  | p `isInfixOf` s =
      let n = length p
          go i
            | i + n > length s = Nothing
            | take n (drop i s) == p = Just (drop (i + n) s)
            | otherwise = go (i + 1)
      in go 0
  | otherwise = Nothing

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

hasTTY :: IO Bool
hasTTY = queryTerminal stdInput

liveEnabled :: IO Bool
liveEnabled = do
  env <- lookupEnv "ENCAPSULE_LIVE"
  return $ env == Just "1"

ubuntuImg :: IO String
ubuntuImg = fromMaybe "ubuntu:latest" <$> lookupEnv "ENCAPSULE_TEST_UBUNTU"

fedoraImg :: IO String
fedoraImg = fromMaybe "fedora:latest" <$> lookupEnv "ENCAPSULE_TEST_FEDORA"

hostUid :: IO String
hostUid = show . toInteger <$> getEffectiveUserID

hostUser :: IO String
hostUser = getEffectiveUserName

requirePodman :: IO ()
requirePodman = do
  ok <- hasPodman
  unless ok $ pendingWith "podman not found"

requireImage :: String -> IO ()
requireImage img = do
  requirePodman
  ok <- imageExists img
  unless ok $ pendingWith $ "no " ++ img ++ " image"

withGenericImage :: (String -> IO ()) -> IO ()
withGenericImage act = do
  requirePodman
  u <- ubuntuImg
  f <- fedoraImg
  mu <- imageExists u
  mf <- imageExists f
  case (mu, mf) of
    (True, _) -> act u
    (_, True) -> act f
    _ -> pendingWith $ "no " ++ u ++ " or " ++ f ++ " image"
