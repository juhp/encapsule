-- SPDX-License-Identifier: Apache-2.0

module Backup (backupCmd)

where

import Control.Monad.Extra (unless, when, whenM)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)

import Safe (readMay)
import SimpleCmd ((+-+), cmd, cmd_, cmdLines, cmdN, warning)
import SimplePrompt (yesNo)
import System.Directory (canonicalizePath,
                         doesDirectoryExist, doesFileExist, doesPathExist,
                         getHomeDirectory)
import System.FilePath (dropTrailingPathSeparator, takeDirectory, takeFileName,
                        (</>))
import System.IO.Extra (withTempFile)

import Error
import Expand
import ShellQuote

backupCmd :: Bool -> Bool -> Maybe FilePath -> FilePath -> IO ()
backupCmd dryrun yes moutput dir = do
  homedir <- getHomeDirectory >>= canonicalizePath
  src <- expandPath homedir dir >>= canonicalizePath
  exists <- doesDirectoryExist src
  unless exists $
    error' $ "directory not found:" +-+ src
  tarball <-
    case moutput of
      Just o -> expandPath homedir o
      Nothing -> do
        now <- getCurrentTime
        let stamp = formatTime defaultTimeLocale "%Y-%m-%d_%H-%M-%SZ" now
        return $ src ++ "-" ++ stamp ++ ".tar.gz"
  whenM (doesFileExist tarball) $
    if yes
    then warning $ "overwriting" +-+ tarball
    else error' $ "output already exists:" +-+ tarball +-+ "(use -y to overwrite)"
  isgit <- doesPathExist $ src </> ".git"
  let parent = takeDirectory src
      base = takeFileName src
      args = ["czf", tarball, "-C", parent]
  if isgit
    then do
    withTempFile $ \ignorefile -> do
      out <- cmdLines "git" ["-C", src, "ls-files", "--cached", "--others", "--exclude-per-directory=.gitignore", "--directory", "--ignored"]
      writeFile ignorefile $ unlines $ map dropTrailingPathSeparator out
      checkSize yes (Just ignorefile) src
      (if dryrun then cmdN else cmd_) "tar" $
        map shellQuote $ args ++ ["--exclude-from=" ++ ignorefile, base]
    else do
    checkSize yes Nothing src
    (if dryrun then cmdN else cmd_) "tar" $ map shellQuote args ++ [base]
  putStrLn $ "Wrote" +-+ tarball

-- Prompt when backing up more than this many bytes.
largeBackupBytes :: Integer
largeBackupBytes = 100 * 1024 * 1024

checkSize :: Bool -> Maybe FilePath -> FilePath -> IO ()
checkSize yes mignorefile src = do
  size <- dirSizeBytes mignorefile src
  let sizeStr = humanSize size
  putStrLn $ src +-+ "(" ++ sizeStr ++ ")"
  when (not yes && size >= largeBackupBytes || size == 0) $ do
    ok <- yesNo $ "Directory is" +-+ sizeStr ++ ", continue?"
    unless ok $
      error' "aborted"

dirSizeBytes :: Maybe FilePath -> FilePath -> IO Integer
dirSizeBytes mignorefile path = do
  let ignore = maybe [] (\i -> ["--exclude-from=" ++ i]) mignorefile
  out <- cmd "du" $ "-sb" : ignore ++ [path]
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
