{-# LANGUAGE RecordWildCards #-}

-- SPDX-License-Identifier: Apache-2.0

module Run (
  ProjectName(..),
  RunOpts(..),
  runCmd,
  (+=+),
  enterContainer,
  mkContainerName,
  resolveProject,
  workProjectName,
  )
where

import Control.Monad.Extra (unless, unlessM, when, whenJust, (>=>))
import Data.List.Extra (intercalate, isPrefixOf, splitOn)
import Data.Maybe (fromMaybe, isJust, isNothing)
import qualified Data.Text.Lazy as TL
import Safe (headMay, lastMay)
import SimpleCmd
import SimplePrompt (promptEnter)
import System.Console.Pretty (Color(..), color, supportsPretty)
import System.Directory (canonicalizePath, createDirectoryIfMissing,
                         doesDirectoryExist, doesFileExist, doesPathExist,
                         getHomeDirectory)
import System.Environment (lookupEnv)
import System.Exit (exitWith)
import System.FilePath ((</>), makeRelative, takeDirectory, takeFileName)
import System.Posix.Files (fileOwner, getFileStatus, isSocket)
import System.Posix.Process (getProcessID)
import System.Posix.Types (UserID)
import System.Posix.User (getEffectiveGroupID, getEffectiveUserID,
                          getEffectiveUserName)
import System.Process (rawSystem)


import Backup
import Config (getCapabilities, loadConfig, progname, resolveCapabilities)
import Enter
import Expand
import Script
import ShellQuote

data ProjectName = Project FilePath | Name String

data RunOpts = RunOpts
  { toolbox :: String
  , vols :: [String]
  , envs :: [String]
  , paths :: [String]
  , inits :: [String]
  , caps :: [String]
  , pull :: Bool
  , muser :: Maybe String
  , mhome :: Maybe (FilePath, Bool)
  , mproject :: Maybe (FilePath, Bool)
  , mname :: Maybe String
  , keep :: Bool
  , readonly :: Bool
  , nonetwork :: Bool
  , nosudo :: Bool
  , noskel :: Bool
  , unique :: Bool
  , podmanopts :: [String]
  , debugging :: Bool
  , dryrun :: Bool
  , command :: [String]
  }

runCmd :: RunOpts -> IO ()
runCmd (RunOpts {..}) = do
  let (mhomeDir, homeMountOpts, backupHome) = splitDirOptsMaybe mhome
      (mprojectPath, projectMountOpts, backupProject) = splitDirOptsMaybe mproject
  mprojectDir <- traverse resolveProject mprojectPath
  containerName <-
    mkContainerName toolbox $
      maybe (Project <$> mprojectPath) (Just . Name) mname
  debug containerName
  exists <- cmdBool "podman" ["container", "exists", containerName]
  when (keep && not unique && exists) $
    error' $ "container" +-+ containerName +-+ "already exists"
  container <-
    -- FIXME Coderabbit pointed out this could lead to race with 2 invocations
    if unique && exists
    then do
      pid <- getProcessID
      return $ containerName +=+ show pid
    else return containerName
  debug $ "container:" +-+ container
  running <-
    if unique
    then return False
    else
      if exists
        then do
          (_, out, _) <- cmdFull "podman"
            ["container", "inspect", "-f", "{{.State.Running}}", container] ""
          if take 4 out == "true"
            then return True
            else do
            putStr "start "
            cmd_ "podman" ["start", container]
            return True
        else return False
  debug $ "running:" +-+ show running
  hostHome <- getHomeDirectory >>= canonicalizePath
  debug $ "HOME:" +-+ hostHome
  if running
    then do
      let noopts = and
            [ null vols
            , null envs
            , null paths
            , null inits
            , null caps
            , isNothing mproject || isNothing mname
            , isNothing mhome
            , isNothing muser
            , not keep
            , not readonly
            , not nonetwork
            , not nosudo
            , not noskel
            , null podmanopts
            ]
      unless noopts $
        error' "cannot give options for an existing container!"
      warning "Entering existing container"
      enterContainer dryrun debugging True container command
    else do
      when backupHome $
        whenJust mhomeDir $ backupCmd dryrun False Nothing
      when backupProject $
        whenJust mprojectDir $ backupCmd dryrun False Nothing
      -- * createContainer
      mtemphome <- traverse (expandPath hostHome >=> canonicalizePath) mhomeDir
      case (mtemphome, mprojectDir) of
        (Just h, Just p) | h == p ->
          error' "--home and --project must be different directories"
        _ -> return ()
      when pull $
        cmd_ "podman" ["pull", toolbox]
      image <- do
        let eimg = progname +=+ toolbox
        exists' <- cmdBool "podman" ["image", "exists", eimg]
        if exists'
          then return eimg
          else do
          debug $ "no" +-+ eimg +-+ "image"
          exists'' <- cmdBool "podman" ["image", "exists", toolbox]
          if exists''
            then do
            debug $ "using" +-+ toolbox +-+ "image"
            return toolbox
            else error' $
                 show toolbox +-+ "image not found\n" ++
                 "Create an image from a container with 'commit', or build/pull one"
      debug $ "image:" +-+ image
      config <- loadConfig
      let capabilities = getCapabilities config

      (extraVols, extraEnvs, extraPaths, extraInits, extraSecurityOpts) <-
        resolveCapabilities capabilities caps

      -- FIXME perhaps add --no-runuser?
      uid <- getEffectiveUserID
      gid <- getEffectiveGroupID
      let uidStr = show (fromIntegral uid :: Integer)
          gidStr = show (fromIntegral gid :: Integer)
      (haveRunuser, haveSudo, mImageUser, mPasswdHome) <-
        probeImage debugging image uid muser
      debug $ "runuser:" +-+ show haveRunuser
      debug $ "sudo:" +-+ show haveSudo
      debug $ "image user:" +-+ fromMaybe "(none)" mImageUser
      debug $ "passwd home:" +-+ fromMaybe "(none)" mPasswdHome

      username <-
        case muser of
          Just user -> return user
          Nothing -> maybe getEffectiveUserName return mImageUser
      debug $ "user:" +-+ username

      let switch = chooseSwitchUser haveRunuser haveSudo
          startAsRoot =
            canSwitchUser switch
            || isNothing mhome && isNothing muser && isNothing mImageUser
          stayAsRoot = startAsRoot && not (canSwitchUser switch)
          (containerHome, overrideHome) =
            if stayAsRoot
            then ("/root", False)
            else (fromMaybe hostHome mPasswdHome, isNothing mPasswdHome)
      debug $ "switch:" +-+ switchLabel switch
      debug $ "container home:" +-+ containerHome

      homeVol <-
        case mtemphome of
          Just temphome -> do
            unlessM (doesDirectoryExist temphome) $ do
              warning $ temphome +-+ "does not exist"
              promptEnter "Press Enter to create it and continue"
              createDirectoryIfMissing True temphome
            -- Mount targets under container $HOME land inside the temp home
            -- volume; create them as the user so podman does not leave
            -- root-owned paths.
            case mprojectDir of
              Just p -> ensureTempHomeMountPoint containerHome temphome p p
              Nothing -> return ()
            mapM_ (ensureTempHomeVol hostHome containerHome temphome)
              (vols ++ extraVols)
            return [temphome ++ ":" ++ containerHome ++ maybeOpts homeMountOpts]
          Nothing -> return []

      projectVol <-
        case mprojectDir of
          Just d -> do
            exists' <- doesDirectoryExist d
            if exists'
              then return [d ++ ':' : d ++ maybeOpts projectMountOpts]
              else error' $ "project dir not found:" +-+ d
          Nothing -> return []
      -- mounting real $HOME needs label=disable (no :z) on Fedora/SELinux.
      -- --home DIR still uses :z (shared type); pin MCS to s0 so podman does
      -- not stamp the container's private categories on the host tree.
      let mountsRealHome =
            Just hostHome == mtemphome || Just hostHome == mprojectDir
          securityOpts =
            extraSecurityOpts ++
            ["label=disable" | mountsRealHome,
             "label=disable" `notElem` extraSecurityOpts] ++
            ["label=level:s0" | isJust mtemphome && not mountsRealHome,
             "label=level:s0" `notElem` extraSecurityOpts,
             "label=disable" `notElem` extraSecurityOpts]
          volumes = homeVol ++ vols ++ extraVols ++ projectVol
          envVars = envs ++ extraEnvs
          allinits = inits ++ extraInits
      allpaths <- mapM (expandContainerPath containerHome) (paths ++ extraPaths)
      let userCmd =
            let envParts =
                  (if overrideHome then (("HOME=" ++ containerHome) :) else id) $
                  pathEnvPart allpaths
                userCmdParts = mkUserCmd command allinits
            in
              (if null envParts then id else (("env" +-+ unwords envParts) +-+)) $
              unwords $ map shellQuote userCmdParts

          -- mkdir+chown when not bind-mounting --home. A passwd home may
          -- already exist but not be writable (committed toolbox image).
          setupArgs =
            Setup nosudo noskel (TL.pack username) progname (isNothing mhome) (TL.pack containerHome) mprojectDir

          setupParts =
            let setup = setupScript debugging switch haveSudo setupArgs
            in [setup | not (null setup)] ++
               [mkInitSetup allinits | not (null allinits)]
          finalCmd =
            case switchUserArgs switch username of
              []   -> "exec" +-+ userCmd
              args -> "exec" +-+ unwords args +-+ userCmd
          execScript =
            (if debugging then ("set -x &&" +-+) else id) $
            if null setupParts
            then finalCmd
            else intercalate " && " $ setupParts ++ [finalCmd]

      when ("label=disable" `elem` securityOpts) $
        warning "SELinux labeling disabled for this container (label=disable)"
      unless dryrun $ debug $ "setup:" +-+ execScript
      mounts <- mapM (addSelinuxLabel hostHome containerHome) volumes
      tzMounts <- hostTimezoneMount
      debug $ "timezone:" +-+ show tzMounts

      -- Only pass --workdir when that path already exists at start:
      -- crun will not create it, and podman then fails.
      -- Existing: --project/--home mounts, /root, the image passwd home,
      -- or a --read-only tmpfs on $HOME. Host $HOME is mkdir'd later.
      let workdirTarget = fromMaybe containerHome mprojectDir
          workdirReady =
            isJust mprojectDir
            || isJust mhome
            || stayAsRoot
            || isJust mPasswdHome
            || (readonly && isNothing mtemphome)
          workdirPart =
            if workdirReady
            then ["--workdir", workdirTarget]
            else []
          args = "run" :
                 [ "--rm" | not keep] ++
                 [ "-it",
                   "--userns=keep-id",
                   "--name", container,
                   "--hostname", hostnameFromName container,
                   "-e", "TERM",
                   "-e", "COLORTERM"]
                ++ ["-e=HOME=" ++ containerHome | overrideHome]
                -- keep-id copies --workdir into the passwd home, defaulting
                -- to "/" ; set the real home when the image has no passwd dir
                ++ (if overrideHome
                    then ["--passwd-entry",
                          intercalate ":"
                            [username, "*", uidStr, gidStr, "",
                             containerHome, "/bin/sh"]]
                    else [])
                ++ (if startAsRoot
                    then ["--user=root"]
                    else ["--user=" ++ username])
                ++ workdirPart
                ++ (if readonly
                    then ["--read-only", "--tmpfs", "/tmp", "--tmpfs", "/run"]
                         ++ case mtemphome of
                              Nothing -> ["--tmpfs", containerHome]
                              Just _ -> []
                    else [])
                ++ (if nonetwork then ["--net", "none"] else [])
                ++ concatMap (\s -> ["--security-opt", s]) securityOpts
                ++ concatMap (\m -> ["-v", m]) (tzMounts ++ mounts)
                ++ concatMap (\e -> ["-e", e]) envVars
                ++ podmanopts
                ++ [image, "sh", "-c", execScript]

      when (dryrun || debugging) $ do
        useColor <- do
          pretty <- supportsPretty
          noColor <- lookupEnv "NO_COLOR"
          return $ pretty && maybe True null noColor
        cmdN "podman" $ map (colorizeOpt useColor) args
      unless dryrun $ do
        ret <- rawSystem "podman" args
        exitWith ret
  where
    debug msg = when debugging $ warning $ "debug:" +-+ msg

colorizeOpt :: Bool -> String -> String
colorizeOpt useColor arg
  | "-" `isPrefixOf` arg =
      case break (== '=') arg of
        (flag, '=':val) -> tint flag ++ '=' : shellQuote val
        (flag, _) -> tint flag
  | otherwise = shellQuote arg
  where
    tint s = if useColor then color Cyan s else s

resolveProject :: FilePath -> IO FilePath
resolveProject dir = do
  homedir <- getHomeDirectory >>= canonicalizePath
  finaldir <- expandPath homedir dir >>= canonicalizePath
  when (finaldir == homedir) $
    warning "mounting $HOME as project (consider a subdirectory)"
  return finaldir

mkContainerName :: String -> Maybe ProjectName -> IO String
mkContainerName base mprojectname = do
  case mprojectname of
    Nothing -> return $ progname +=+ sanebase
    Just mp ->
      case mp of
        Name ('^':n) -> return n
        Name n -> return $ progname +=+ n
        Project p -> do
          projectDir <- resolveProject p
          return $ progname ++ '-' : sanebase +=+ workProjectName projectDir
  where
    sanebase = sanitizeName base

-- DIR[:opts] for --home/--project (opts must not look like a path).
splitDirOpts :: String -> (FilePath, Maybe String)
splitDirOpts spec =
  case break (== ':') spec of
    (dir, []) -> (dir, Nothing)
    (dir, _:rest)
      | isVolumePathStart rest -> (spec, Nothing)
      | otherwise -> (dir, Just rest)

splitDirOptsMaybe :: Maybe (String,Bool)
                  -> (Maybe FilePath, Maybe String, Bool)
splitDirOptsMaybe Nothing = (Nothing, Nothing, False)
splitDirOptsMaybe (Just (s,backup)) =
  let (dir, opts) = splitDirOpts s
  in (Just dir, opts, backup)

maybeOpts :: Maybe String -> String
maybeOpts Nothing = ""
maybeOpts (Just o) = ':' : o

isVolumePathStart :: String -> Bool
isVolumePathStart ('/':_) = True
isVolumePathStart ('~':_) = True
isVolumePathStart ('$':_) = True
isVolumePathStart _       = False

-- | Combine two strings with a dash
infixr 4 +=+
(+=+) :: String -> String -> String
s +=+ t | lastMay s == Just '-' = s ++ t
        | headMay t == Just '-' = s ++ t
s +=+ t = s ++ '-' : t

-- Probe image without keep-id so /etc/passwd is the image's, not host-injected.
probeImage :: Bool -> String -> UserID -> Maybe String
           -> IO (Bool, Bool, Maybe String, Maybe FilePath)
probeImage dbg image uid muser = do
  let uidStr = show (fromIntegral uid :: Integer)
      lookupSh = maybe (passwdEntryForUidSh uidStr) passwdEntryForNameSh muser
  when dbg $ warning $ "checking for runuser, sudo and" +-+
    maybe ("uid" +-+ uidStr) ("user" +-+) muser
  let sh = unlines
        [ cmdPresentSh "runuser"
        , cmdPresentSh "sudo"
        , lookupSh
        ]
      args = ["run", "--rm", "--pull=never", "--entrypoint", "/bin/sh", image, "-c", sh]
  when dbg $ putStrLn $ unwords ("podman" : map shellQuote args)
  (_, out, _) <- cmdFull "podman" args ""
  return $
    case lines out of
      (r:s:n:h:_) -> (r == "1", s == "1", nonEmpty n, usablePasswdHome h)
      (r:s:n:_) -> (r == "1", s == "1", nonEmpty n, Nothing)
      (r:s:_) -> (r == "1", s == "1", Nothing, Nothing)
      (r:_) -> (r == "1", False, Nothing, Nothing)
      [] -> (False, False, Nothing, Nothing)
  where
    nonEmpty s = if null s then Nothing else Just s

cmdPresentSh :: String -> String
cmdPresentSh c =
  "command -v " ++ shellQuote c ++ " >/dev/null 2>&1 && echo 1 || echo 0"

-- Pre-create a bind mount point under temp home when the container path is
-- inside $HOME (directories, or empty files for file/socket mounts).
ensureTempHomeMountPoint :: FilePath -> FilePath -> FilePath -> FilePath -> IO ()
ensureTempHomeMountPoint homedir temphome hostPath containerPath =
  when (isUnderDir homedir containerPath) $ do
    let dest = temphome </> makeRelative homedir containerPath
    hostIsFile <- doesFileExist hostPath
    hostIsSock <- isSocketFile hostPath
    if hostIsFile || hostIsSock
      then do
      -- FIXME maybe confirm?
      createDirectoryIfMissing True (takeDirectory dest)
      destExists <- doesPathExist dest
      unless destExists $ writeFile dest ""
      else
      -- FIXME confirm?
      createDirectoryIfMissing True dest

ensureTempHomeVol :: FilePath -> FilePath -> FilePath -> String -> IO ()
ensureTempHomeVol hostHome containerHome temphome spec = do
  (hostPath, containerPath) <- volumePaths hostHome containerHome spec
  ensureTempHomeMountPoint containerHome temphome hostPath containerPath

-- Resolve host and container paths from a volume spec (before SELinux opts).
volumePaths :: FilePath -> FilePath -> String -> IO (FilePath, FilePath)
volumePaths hostHome containerHome spec =
  case break (== ':') spec of
    (hostPart, []) -> do
      hostExp <- expandPath hostHome hostPart
      containerExp <- expandContainerPath containerHome hostPart
      return (hostExp, containerExp)
    (hostPart, _:rest') -> do
      hostExp <- expandPath hostHome hostPart
      if isVolumePathStart rest'
        then do
          let containerPart = takeWhile (/= ':') rest'
          containerExp <- expandContainerPath containerHome containerPart
          return (hostExp, containerExp)
        else do
          containerExp <- expandContainerPath containerHome hostPart
          return (hostExp, containerExp)

-- shell command construction

pathEnvPart :: [String] -> [String]
pathEnvPart [] = []
pathEnvPart ps =
  let prefix = intercalate ":" ps
  in ["PATH=\"" ++ prefix ++ ":$PATH\""]

mkInitSetup :: [String] -> String
mkInitSetup [] = ""
mkInitSetup snippets =
  let content = intercalate "\\n" snippets
  in "printf" +-+ shellQuote content +-+ "> /tmp" </> progname ++ "-init.sh"

mkUserCmd :: [String] -> [String] -> [String]
mkUserCmd [] inits = mkUserCmd ["bash"] inits
mkUserCmd ["bash"] (_:_) =
  ["bash", "--rcfile", "/tmp" </> progname ++ "-init.sh"]
mkUserCmd com inits@(_:_) =
  let initChain = intercalate " && " inits
      cmdStr = initChain +-+ "&& exec" +-+ unwords (map shellQuote com)
  in ["sh", "-c", cmdStr]
mkUserCmd com [] = com

-- SELinux labeling

-- Rootless podman cannot lsetxattr on files owned by another uid (e.g. /etc/*)
-- FIXME rather return Mount type or triple?
addSelinuxLabel :: FilePath -> FilePath -> String -> IO String
addSelinuxLabel hostHome containerHome spec =
  case break (== ':') spec of
    (hostPart, []) -> do
      hostExp <- expandPath hostHome hostPart
      containerExp <- expandContainerPath containerHome hostPart
      requireVolumeHost hostExp
      skipLabel <- shouldSkipLabel hostExp
      return $ hostExp ++ ":" ++ containerExp ++ if skipLabel then "" else ":z"
    (hostPart, _:rest') -> do
      hostExp <- expandPath hostHome hostPart
      requireVolumeHost hostExp
      let (containerPart, optsPart)
            | isVolumePathStart rest' =
                case break (== ':') rest' of
                  (c, [])  -> (c, Nothing)
                  (c, _:o) -> (c, Just o)
            | otherwise = (hostPart, if null rest' then Nothing else Just rest')
      containerExp <- expandContainerPath containerHome containerPart
      skipLabel <- shouldSkipLabel hostExp
      let labeled = case optsPart of
            Nothing ->
              if skipLabel
              then hostExp ++ ":" ++ containerExp
              else hostExp ++ ":" ++ containerExp ++ ":z"
            Just o ->
              let flags = splitOn "," o
              in if skipLabel || "z" `elem` flags || "Z" `elem` flags
                    || "O" `elem` flags
                 then hostExp ++ ":" ++ containerExp ++ ":" ++ o
                 else hostExp ++ ":" ++ containerExp ++ ":" ++ o ++ ",z"
      return labeled
  where
    -- Skip auto :z for sockets, real $HOME (uses label=disable), and paths we
    -- cannot relabel (rootless lsetxattr fails on files owned by another user)
    shouldSkipLabel hostExp = do
      sockFile <- isSocketFile hostExp
      selfOwned <- ownedBySelf hostExp
      return $ sockFile || hostExp == hostHome || not selfOwned

-- later possibly also support /etc/timezone
hostTimezoneMount :: IO [String]
hostTimezoneMount = do
  let localtime = "/etc/localtime"
  found <- doesFileExist localtime
  return $
    [localtime ++ ':' : localtime ++ ":ro" | found]

-- # Naming

-- Dots separate DNS labels in hostnames, so replace them for --hostname.
hostnameFromName :: String -> String
hostnameFromName = map (\c -> if c == '.' then '-' else c)

workProjectName :: FilePath -> String
workProjectName = sanitizeName . takeFileName

sanitizeName :: String -> String
sanitizeName = map (\c -> if c `elem` nameChars then c else '-')
  where
    nameChars = ['A'..'Z'] ++ ['a'..'z'] ++ ['0'..'9'] ++ "_.-"

-- True if path is base or a subdirectory of base (avoids /home/foo vs /home/foobar).
isUnderDir :: FilePath -> FilePath -> Bool
isUnderDir base path =
  path == base || (base ++ "/") `isPrefixOf` path

requireVolumeHost :: FilePath -> IO ()
requireVolumeHost path = do
  exists <- doesPathExist path
  unless exists $
    error' $ "volume host path not found:" +-+ path

isSocketFile :: FilePath -> IO Bool
isSocketFile path = isSocket <$> getFileStatus path

ownedBySelf :: FilePath -> IO Bool
ownedBySelf path = do
  uid <- getEffectiveUserID
  st <- getFileStatus path
  return $ fileOwner st == uid
