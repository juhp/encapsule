-- SPDX-License-Identifier: Apache-2.0

module Backup (backupCmd)

where

import Control.Monad (unless, when)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)

import Safe (readMay)
import SimpleCmd ((+-+), cmd, cmd_, warning)
import SimplePrompt (yesNo)
import System.Directory (canonicalizePath,
                         doesDirectoryExist, doesFileExist,
                         getHomeDirectory)
import System.FilePath (takeDirectory, takeFileName)

import Error
import Expand
import ShellQuote

-- Prompt when backing up more than this many bytes.
largeBackupBytes :: Integer
largeBackupBytes = 100 * 1024 * 1024

backupCmd :: Bool -> Bool -> Maybe FilePath -> FilePath -> IO ()
backupCmd dryrun yes moutput dir = do
  homedir <- getHomeDirectory >>= canonicalizePath
  src <- expandPath homedir dir >>= canonicalizePath
  exists <- doesDirectoryExist src
  unless exists $
    error' $ "directory not found:" +-+ src
  size <- dirSizeBytes src
  let sizeStr = humanSize size
  putStrLn $ src +-+ "(" ++ sizeStr ++ ")"
  when (not yes && size >= largeBackupBytes || size == 0) $ do
    ok <- yesNo $ "Directory is" +-+ sizeStr ++ ", continue?"
    unless ok $
      error' "aborted"
  out <-
    case moutput of
      Just o -> expandPath homedir o
      Nothing -> do
        now <- getCurrentTime
        let stamp = formatTime defaultTimeLocale "%Y-%m-%d_%H:%M:%SZ" now
        return $ src ++ "-" ++ stamp ++ ".tar.gz"
  outExists <- doesFileExist out
  when outExists $
    if yes
    then warning $ "overwriting" +-+ out
    else error' $ "output already exists:" +-+ out +-+ "(use -y to overwrite)"
  let parent = takeDirectory src
      base = takeFileName src
      args = ["czf", out, "-C", parent, base]
  if dryrun
    then putStrLn $ unwords $ "tar" : map shellQuote args
    else do
      putStrLn $ "Writing" +-+ out
      cmd_ "tar" args

dirSizeBytes :: FilePath -> IO Integer
dirSizeBytes path = do
  out <- cmd "du" ["-sb", path]
  case words out of
    (n:_) | Just i <- readMay n -> return i
    _ -> error' $ "could not determine size of" +-+ path

humanSize :: Integer -> String
humanSize n
  | n >= g = show (n `div` g) ++ "G"
  | n >= m = show (n `div` m) ++ "M"
  | n >= k = show (n `div` k) ++ "K"
  | otherwise = show n ++ "B"
  where
    k = 1024
    m = k * 1024
    g = m * 1024
