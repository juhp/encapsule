-- SPDX-License-Identifier: Apache-2.0

module Enter (
  enterContainer
  )
where

import Control.Monad (unless)
import SimpleCmd (cmd_)
import System.Directory (canonicalizePath, getHomeDirectory)
import System.Exit (exitWith)
import System.Process (rawSystem)
import System.Posix.User (getEffectiveUserName)

import ShellQuote

enterContainer :: Bool -> Bool -> String -> [String] -> IO ()
enterContainer dryrun running container command = do
  homedir <- getHomeDirectory >>= canonicalizePath
  username <- getEffectiveUserName
  unless running $ do
    putStr "start "
    cmd_ "podman" ["start", container]
  -- FIXME fails if no runuser!
  let userCmd = if null command then ["bash"] else command
      execCmd = ["podman", "exec", "-it", container,
                 "runuser", "-u", username, "--",
                 "env", "HOME=" ++ homedir] ++ userCmd
  if dryrun
    then putStrLn $ unwords (map shellQuote execCmd)
    else do
      ret <- rawSystem "podman" (drop 1 execCmd)
      exitWith ret
