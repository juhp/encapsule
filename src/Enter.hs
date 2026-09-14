-- SPDX-License-Identifier: Apache-2.0

module Enter (
  enterContainer,
  passwdEntryForUidSh,
  passwdEntryForNameSh,
  usablePasswdHome,
  langEnvArgs,
  )
where

import Control.Monad (unless, when)
import Data.Maybe (fromMaybe, isNothing)
import SimpleCmd (cmd, cmd_, cmdFull)
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
  wd <- containerWorkdir container
  let userCmd = if null command then ["bash"] else command
      homeDir = fromMaybe hostHome mPasswdHome
      -- If inspect reports "/" then --workdir was omitted at create
      -- (host $HOME was not in the image), then fallback to $HOME
      workdir =
        case wd of
          "" -> homeDir
          "/" -> homeDir
          d -> d
      homeEnv =
        if isNothing mPasswdHome then ["env", "HOME=" ++ homeDir] else []
      execArgs = ["exec", "-it", "--user", username,
                  "--workdir", workdir, container]
                 ++ langEnvArgs ++ homeEnv ++ userCmd
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

-- Empty, "/", or non-absolute passwd homes are dummy
-- (keep-id copies --workdir, which defaults to "/").
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

containerWorkdir :: String -> IO String
containerWorkdir container =
  cmd "podman"
  ["container", "inspect", "-f", "{{.Config.WorkingDir}}", container]

-- Base images typically only ship C.UTF-8 (plus C/POSIX). Override with
-- -e LANG=C or -e LANG=en_US.UTF-8 if the image has that locale.
langEnvArgs :: [String]
langEnvArgs = ["-e", "LANG=C.UTF-8"]
