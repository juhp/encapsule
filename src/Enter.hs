-- SPDX-License-Identifier: Apache-2.0

module Enter (
  enterContainer,
  passwdNameForUidSh,
  )
where

import Control.Monad (unless, when)
import SimpleCmd (cmd_, cmdFull)
import System.Directory (canonicalizePath, getHomeDirectory)
import System.Exit (exitWith)
import System.Process (rawSystem)
import System.Posix.User (getEffectiveUserID, getEffectiveUserName)

import ShellQuote

enterContainer :: Bool -> Bool -> Bool -> String -> [String] -> IO ()
enterContainer dryrun debug running container command = do
  homedir <- getHomeDirectory >>= canonicalizePath
  unless running $ do
    putStr "start "
    cmd_ "podman" ["start", container]
  username <- lookupContainerUser container
  -- FIXME fails if no runuser!
  let userCmd = if null command then ["bash"] else command
      execArgs = ["exec", "-it", container,
                  "runuser", "-u", username, "--",
                  "env", "HOME=" ++ homedir] ++ userCmd
  when (dryrun || debug) $
    putStrLn $ unwords ("podman" : map shellQuote execArgs)
  unless dryrun $ do
    ret <- rawSystem "podman" execArgs
    exitWith ret

-- POSIX lookup of the passwd name for a numeric UID.
passwdNameForUidSh :: String -> String
passwdNameForUidSh uid =
  "while IFS=: read name _ id _; do [ \"$id\" = " ++ shellQuote uid ++
  " ] && echo \"$name\" && break; done < /etc/passwd"

lookupContainerUser :: String -> IO String
lookupContainerUser container = do
  hostName <- getEffectiveUserName
  uid <- getEffectiveUserID
  let uidStr = show (fromIntegral uid :: Integer)
      sh = passwdNameForUidSh uidStr
  (_, out, _) <- cmdFull "podman" ["exec", container, "/bin/sh", "-c", sh] ""
  case filter (not . null) (lines out) of
    (n:_) -> return n
    [] -> return hostName
