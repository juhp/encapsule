-- SPDX-License-Identifier: Apache-2.0

module Enter (
  enterContainer,
  passwdEntryForUidSh,
  passwdEntryForNameSh,
  usablePasswdHome,
  )
where

import Control.Monad (unless, when)
import Data.Maybe (isNothing)
import SimpleCmd (cmd_, cmdFull)
import System.Directory (canonicalizePath, getHomeDirectory)
import System.Exit (exitWith)
import System.FilePath (isAbsolute)
import System.Process (rawSystem)
import System.Posix.User (getEffectiveUserID, getEffectiveUserName)

import ShellQuote

enterContainer :: Bool -> Bool -> Bool -> String -> [String] -> IO ()
enterContainer dryrun debug running container command = do
  hostHome <- getHomeDirectory >>= canonicalizePath
  unless running $ do
    putStr "start "
    cmd_ "podman" ["start", container]
  (username, mPasswdHome) <- lookupContainerUser container
  -- FIXME fails if no runuser!
  let userCmd = if null command then ["bash"] else command
      homeEnv =
        if isNothing mPasswdHome then ["env", "HOME=" ++ hostHome] else []
      execArgs = ["exec", "-it", container,
                  "runuser", "-u", username, "--"]
                 ++ homeEnv ++ userCmd
  when (dryrun || debug) $
    putStrLn $ unwords ("podman" : map shellQuote execArgs)
  unless dryrun $ do
    ret <- rawSystem "podman" execArgs
    exitWith ret

-- POSIX lookup: print passwd name and home (two lines) for a numeric UID.
passwdEntryForUidSh :: String -> String
passwdEntryForUidSh uid =
  passwdEntrySh $ "[ \"$id\" = " ++ shellQuote uid ++ " ]"

-- POSIX lookup: print passwd name and home (two lines) for a user name.
passwdEntryForNameSh :: String -> String
passwdEntryForNameSh user =
  passwdEntrySh $ "[ \"$name\" = " ++ shellQuote user ++ " ]"

passwdEntrySh :: String -> String
passwdEntrySh match =
  "while IFS=: read name _ id _ _ home _; do " ++ match ++
  " && echo \"$name\" && echo \"$home\" && break; done < /etc/passwd"

-- Empty, "/", or non-absolute passwd homes are dummy (e.g. keep-id).
usablePasswdHome :: String -> Maybe FilePath
usablePasswdHome h
  | null h || h == "/" = Nothing
  | isAbsolute h = Just h
  | otherwise = Nothing

lookupContainerUser :: String -> IO (String, Maybe FilePath)
lookupContainerUser container = do
  hostName <- getEffectiveUserName
  uid <- getEffectiveUserID
  let uidStr = show (fromIntegral uid :: Integer)
      sh = passwdEntryForUidSh uidStr
  (_, out, _) <- cmdFull "podman" ["exec", container, "/bin/sh", "-c", sh] ""
  case lines out of
    (n:h:_) | not (null n) -> return (n, usablePasswdHome h)
    (n:_) | not (null n) -> return (n, Nothing)
    _ -> return (hostName, Nothing)
