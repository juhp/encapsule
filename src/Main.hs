-- SPDX-License-Identifier: Apache-2.0

{-# LANGUAGE RecordWildCards #-}

module Main (main) where

import Control.Monad (unless, void, when, (>=>))
import Data.List.Extra (intercalate, isPrefixOf, splitOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isNothing, mapMaybe)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import Safe (headMay, lastMay, readMay)
import System.Directory (canonicalizePath, createDirectoryIfMissing,
                         doesDirectoryExist, doesFileExist, doesPathExist,
                         getHomeDirectory, getModificationTime)
import System.Environment.XDG.BaseDir (getUserConfigFile)
import System.Exit (exitWith, exitFailure)
import System.FilePath ((</>), makeRelative, takeDirectory, takeFileName)
import System.IO (BufferMode(NoBuffering), hSetBuffering, stdout)
import System.Posix.Process (getProcessID)
import System.Posix.Env (getEnvDefault)
import System.Posix.Files (fileOwner, getFileStatus, isSocket)
import System.Posix.User (getEffectiveUserID, getEffectiveUserName)
import System.Process (rawSystem)
import Data.Time.Clock (UTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime, parseTimeM)
import SimpleCmd (cmd, cmd_, cmdBool, cmdFull, cmdLines, warning, (+-+))
import SimpleCmdArgs
import SimplePrompt (yesNo)
import TOML (Value(..), Table, renderTOMLError, decodeFile)

import Paths_encapsule (version)
import Script

progname :: String
progname = "encapsule"

data ProjectName = Project FilePath | Name String

main :: IO ()
main = do
  hSetBuffering stdout NoBuffering
  simpleCmdArgs (Just version)
    progname
    ("Run a toolbox image in an isolated podman container" +-+
     "https://github.com/juhp/encapsule#readme") $
    subcommands
    -- FIXME add/separate: create/enter/run
    [ Subcommand "list" "List encapsule images and containers" $
      pure listCmd
    , Subcommand "list-caps" "List available capabilities" $
      pure listCapsCmd
    , Subcommand "rm" "Remove an encapsule container" $
      removeCmd
      <$> toolboxArg
      <*> optional projectNameOpt
    , Subcommand "rmi" "Remove an encapsule image" $
      removeImageCmd
      <$> dryrunOpt
      <*> toolboxArg
    , Subcommand "stop" "Stop an encapsule container" $
      stopCmd
      <$> toolboxArg
      <*> optional projectNameOpt
    , Subcommand "backup" "Create a tarball backup of a directory" $
      backupCmd
      <$> dryrunOpt
      <*> switchWith 'y' "yes" "Don't prompt for large directories"
      <*> optional (strOptionWith 'o' "output" "FILE" "Output tarball (default: DIR-<timestamp>.tar.gz)")
      <*> argumentWith str "DIR"
    , Subcommand "create" "Create an encapsule container" $
      runCmd <$> runOpts True False False
    , Subcommand "enter" "Connect to a encapsule container" $
      enterCmd
      <$> dryrunOpt
      <*> pure True
      <*> optional toolboxArg
      <*> optional projectNameOpt
    , Subcommand "refresh" "Update an encapsule image from a (toolbox) container" $
      refreshCmd
      <$> dryrunOpt
      <*> switchLongWith "force" "Re-commit even if the image looks up to date"
      <*> toolboxArg
    , Subcommand "run" "Run a temporary encapsule container" $
      runCmd <$> runOpts False True True
    ]
  where
    dryrunOpt = switchLongWith "dryrun" "Print the podman command instead of running it"

    projectOpt = strOptionWith 'p' "project" "DIR[:opts]"

    nameOpt = strOptionWith 'n' "name" "NAME" "Optional container name (prefix with '^' prefix to skip 'encapsule-' prefix)"

    projectNameOpt = Project <$> projectOpt "Project name or path" <|>
                     Name <$> nameOpt

    toolboxArg = argumentWith str "TOOLBOX"

    runOpts keep unique refresh' =
      RunOpts
      <$> toolboxArg
      <*> many (strOptionWith 'v' "volume" "HOST:CONTAINER[:opts]" "Bind mounts (default to selinux :z)")
      <*> many (strOptionWith 'e' "env" "KEY[=VALUE]" "Set or pass through an environment variable")
      <*> many (strOptionLongWith "path" "DIR" "Prepend a directory to PATH inside the container")
      <*> many (strOptionWith 'i' "init" "CMD" "A bash snippet run when creating the encapsule container")
      <*> many (strOptionLongWith "cap" "NAME" "Enable a capability from the config file")
      <*> switchLongWith "pull" "Pull newer container image"
      <*> optional (strOptionWith 'H' "home" "DIR[:opts]" "Mount a directory as a writable home (created if missing; e.g. DIR:O for overlay)")
      <*> optional (projectOpt "Mount a (project) directory as workdir (e.g. DIR:O for overlay)")
      <*> optional nameOpt
      <*> pure keep
      <*> switchLongWith "readonly" "Make the encapsule container filesystem read-only"
      <*> switchLongWith "no-network" "Disable network access"
      <*> switchLongWith "no-sudo" "Skip passwordless sudo setup"
      <*> switchLongWith "no-skel" "Don't copy /etc/skel into an empty home"
      <*> pure unique
      <*> many (strOptionLongWith "podman-opt" "OPTION" "Pass an option directly to podman")
      <*> switchLongWith "debug" "Show debug output"
      <*> dryrunOpt
      <*> (if refresh'
           then switchLongWith "refresh" "Force re-commit of the toolbox image"
           else pure False)
      <*> many (argumentWith str "CMD")


listCmd :: IO ()
listCmd = do
  cmd_ "podman" ["images",
                 "--filter", "reference=" ++ progname ++ "-*",
                 "--format", "{{.Repository}}:{{.Tag}}  {{.Size}}  {{.Created}}"]
  putChar '\n'
  cmd_ "podman" ["ps", "-a",
                 "--filter", "name=^" ++ progname +=+ "",
                 "--format", "{{.Names}}  {{.Status}}"]

listCapsCmd :: IO ()
listCapsCmd = do
  config <- loadConfig
  let capabilities = getCapabilities config
  if Map.null capabilities
    then putStrLn "No capabilities defined"
    else do
      putStrLn "Available capabilities:"
      mapM_ (putStrLn . ("  " ++) . T.unpack) $ Map.keys capabilities

removeCmd :: String -> Maybe ProjectName -> IO ()
removeCmd toolbox mprojectname = do
  containerName <- mkContainerName toolbox mprojectname
  exists <- cmdBool "podman" ["container", "exists", containerName]
  if exists
    then do
      (_, out, _) <- cmdFull "podman"
        ["container", "inspect", "-f", "{{.State.Running}}", containerName] ""
      when (take 4 out == "true") $ do
        putStr "stopping "
        cmd_ "podman" ["stop", containerName]
      putStr "rm "
      cmd_ "podman" ["rm", containerName]
    else warning $ "container" +-+ containerName +-+ "not found"

removeImageCmd :: Bool -> String -> IO ()
removeImageCmd dryrun name =
  when dryrun $
  removeImage (progname +=+ name)

-- FIXME dryrun
stopCmd :: String -> Maybe ProjectName -> IO ()
stopCmd name mprojectname = do
  containerName <- mkContainerName name mprojectname
  exists <- cmdBool "podman" ["container", "exists", containerName]
  if exists
    then do
      putStr "stop "
      cmd_ "podman" ["stop", containerName]
    else warning $ "container" +-+ containerName +-+ "not found"

enterCmd :: Bool -> Bool -> Maybe String -> Maybe ProjectName -> IO ()
enterCmd dryrun running mbase mprojectname = do
  regexp <-
    case mprojectname of
      Nothing -> return $ progname +=+ fromMaybe "" mbase
      Just (Name n) -> return $ progname ++ '-' : n
      Just (Project p) -> do
        projectDir <- resolveProject p
        return $ progname ++ '-' : fromMaybe ".*" mbase ++ '-' : workProjectName projectDir
  ps <- cmdLines "podman" $ "ps" :
        ["-a" | not running] ++
        ["--filter", "name=" ++ '^' : regexp,
         "--format", "{{.Names}}"]
  case ps of
    [] ->
      if running
      then do
        enterCmd dryrun False mbase mprojectname
      else error' "encapsule container not found"
    [c] -> do
      unless running $
        warning "no running encapsule container found"
      enterContainer dryrun True c []
    _ -> error' $ "multiple" +-+ (if running then  "running" else "") +-+ "containers match:\n" ++ unlines ps

enterContainer :: Bool -> Bool -> String -> [String] -> IO ()
enterContainer dryrun running container command = do
  homedir <- getHomeDirectory >>= canonicalizePath
  username <- getEffectiveUserName
  unless running $ do
    putStr "start "
    cmd_ "podman" ["start", container]
  let userCmd = if null command then ["bash"] else command
      execCmd = ["podman", "exec", "-it", container,
                 "runuser", "-u", username, "--",
                 "env", "HOME=" ++ homedir] ++ userCmd
  if dryrun
    then putStrLn $ unwords (map shellQuote execCmd)
    else do
      ret <- rawSystem "podman" (drop 1 execCmd)
      exitWith ret

data RunOpts = RunOpts
  { toolbox :: String
  , vols :: [String]
  , envs :: [String]
  , paths :: [String]
  , inits :: [String]
  , caps :: [String]
  , pull :: Bool
  , mhome :: Maybe FilePath
  , mproject :: Maybe FilePath
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
  , refresh :: Bool
  , command :: [String]
  }

runCmd :: RunOpts -> IO ()
runCmd (RunOpts {..}) = do
  let (mhomeDir, homeMountOpts) = splitDirOptsMaybe mhome
      (mprojectPath, projectMountOpts) = splitDirOptsMaybe mproject
  mprojectDir <- traverse resolveProject mprojectPath
  containerName <-
    mkContainerName toolbox $
      maybe (Project <$> mprojectPath) (Just . Name) mname
  debug $ containerName
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
  homedir <- getHomeDirectory >>= canonicalizePath
  debug $ "HOME:" +-+ homedir
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
            , not keep
            , not readonly
            , not nonetwork
            , not nosudo
            , not noskel
            , null podmanopts
            , not refresh
            ]
      unless noopts $
        error' "cannot give options for an existing container!"
      warning "Entering existing container"
      enterContainer dryrun True container command
    else createContainer homedir mhomeDir homeMountOpts mprojectDir
                          projectMountOpts container
  where
    createContainer homedir mhomeDir homeMountOpts mprojectDir
                    projectMountOpts container = do
      mtemphome <- traverse (expandPath homedir >=> canonicalizePath) mhomeDir
      case (mtemphome, mprojectDir) of
        (Just h, Just p) | h == p ->
          error' "--home and --project must be different directories"
        _ -> return ()
      let isImage = ':' `elem` toolbox
      debug $ if isImage
              then "image:" +-+ toolbox
                   -- FIXME handling of unique is kind of broken: not container
              else "toolbox:" +-+ toolbox
      image <-
        if isImage
        then do
          when pull $
            cmd_ "podman" ["pull", toolbox]
          return toolbox
        else commitToolbox dryrun toolbox refresh
      config <- loadConfig
      let capabilities = getCapabilities config

      (extraVols, extraEnvs, extraPaths, extraInits, extraSecurityOpts) <-
        resolveCapabilities capabilities caps

      homeVol <-
        case mtemphome of
          Just temphome -> do
            createDirectoryIfMissing True temphome
            -- Mount targets under $HOME land inside the temp home volume;
            -- create them as the user so podman does not leave root-owned paths.
            case mprojectDir of
              Just p -> ensureTempHomeMountPoint homedir temphome p p
              Nothing -> return ()
            mapM_ (ensureTempHomeVol homedir temphome) (vols ++ extraVols)
            return [temphome ++ ":" ++ homedir ++ maybeOpts homeMountOpts]
          Nothing -> return []

      username <- getEffectiveUserName

      projectVol <-
        case mprojectDir of
          Just d -> do
            exists <- doesDirectoryExist d
            if exists
              then return [d ++ ':' : d ++ maybeOpts projectMountOpts]
              else error' $ "project dir not found:" +-+ d
          Nothing -> return []
      -- mounting real $HOME needs label=disable (no :z) on Fedora/SELinux
      let mountsRealHome =
            Just homedir == mtemphome || Just homedir == mprojectDir
          securityOpts =
            extraSecurityOpts ++
            ["label=disable" | mountsRealHome,
             "label=disable" `notElem` extraSecurityOpts]
          volumes = homeVol ++ vols ++ extraVols ++ projectVol
          envVars = envs ++ extraEnvs
          allpaths = paths ++ extraPaths
          allinits = inits ++ extraInits

          runuserCmd =
            let envParts = ("HOME=" ++ homedir) : pathEnvPart allpaths
                userCmdParts = mkUserCmd command allinits
            in "env" +-+ unwords (envParts ++ map shellQuote userCmdParts)

          sudoers = "/etc/sudoers.d" </> progname
          installSetup =
            [TL.unpack $ installScript debugging (not nosudo) | isImage]
          sudoSetup =
            if nosudo
            then ["rm -f /usr/bin/sudo"]
            else ["echo" +-+ shellQuote (username +-+ "ALL=(ALL) NOPASSWD:ALL")
                  +-+ ">" +-+ sudoers,
                  "chmod 440" +-+ sudoers]
          homeSetup =
            if isNothing mhome
            then ["mkdir -p" +-+ homedir,
                  "chown" +-+ username +-+ homedir]
            else []
          skelSetup =
            [ "if [ ! -e " ++ shellQuote (homedir </> ".bashrc") ++
              " ] && [ -d /etc/skel ]; then " ++
              "runuser -u" +-+ username +-+ "-- cp -an /etc/skel/." +-+
              shellQuote (homedir ++ "/") ++ "; fi"
            | not noskel ]
          -- podman --workdir requires the path to exist at start; for no
          -- --workdir/--project, mkdir home first then cd (see workdirPart)
          cdHome = ["cd" +-+ shellQuote homedir | isNothing mprojectDir]
          fallback =
            if isImage
            then " || exec" +-+ runuserCmd
            else ""
          trace = ["set -x" | debugging]
          setup = intercalate " && "
                  (trace ++ installSetup ++ sudoSetup ++ homeSetup ++ skelSetup ++
                   cdHome ++
                  [mkInitSetup allinits | not (null allinits)] ++
                  ["exec runuser -u" +-+ username +-+ "--" +-+ runuserCmd])
                  ++ fallback

      when ("label=disable" `elem` securityOpts) $
        warning "SELinux labeling disabled for this container (label=disable)"
      unless dryrun $ debug $ "setup:" +-+ setup
      mounts <- mapM (addSelinuxLabel homedir) volumes

      let workdirPart =
            case mprojectDir of
              Just d -> ["--workdir", d]
              Nothing -> []
          args = "run" :
                 [ "--rm" | not keep] ++
                 [ "-it",
                   "--userns=keep-id",
                   "--name", container,
                   "--hostname", hostnameFromName container,
                   "--user", "root",
                   "-e", "HOME=" ++ homedir,
                   "-e", "TERM",
                   "-e", "COLORTERM"]
                ++ workdirPart
                ++ (if readonly
                    then ["--read-only", "--tmpfs", "/tmp", "--tmpfs", "/run"]
                         ++ case mtemphome of
                              Nothing -> ["--tmpfs", homedir]
                              Just _ -> []
                    else [])
                ++ (if nonetwork then ["--net", "none"] else [])
                ++ concatMap (\s -> ["--security-opt", s]) securityOpts
                ++ concatMap (\m -> ["-v", m]) mounts
                ++ concatMap (\e -> ["-e", e]) envVars
                ++ podmanopts
                ++ [image, "sh", "-c", setup]

      if dryrun
        then putStrLn $ unwords $ "podman" : map shellQuote args
        else do
          ret <- rawSystem "podman" args
          exitWith ret

    debug msg = when debugging $ warning $ "debug:" +-+ msg

-- image management

refreshCmd :: Bool -> Bool -> String -> IO ()
refreshCmd dryrun force toolbox = do
  containerExists <- cmdBool "podman" ["container", "exists", toolbox]
  unless containerExists $
    error' $ "container '" ++ toolbox ++ "' not found"
  let image = progname +=+ toolbox
  imageExists <- cmdBool "podman" ["image", "exists", image]
  unless imageExists $
    error' $ "image" +-+ image +-+ "not found (create or run first)"
  needsCommit <-
    if force
    then return True
    else do
      imageTime <- inspectUTCTime image "{{.Created}}"
      toolboxTime <- toolboxFreshness toolbox
      case (imageTime, toolboxTime) of
        (Just img, Just tb) -> return (img < tb)
        -- if we cannot compare, recommit to be safe
        _ -> return True
  if needsCommit
    then void $ commitToolbox dryrun toolbox True
    else putStrLn $ image +-+ "is up to date"

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

-- Prefer overlay UpperDir mtime (system changes, not bind mounts);
-- fall back to StartedAt, then Created.
toolboxFreshness :: String -> IO (Maybe UTCTime)
toolboxFreshness toolbox = do
  upper <- inspectFormat toolbox "{{.GraphDriver.Data.UpperDir}}"
  mUpper <-
    if null upper || upper == "<no value>"
    then return Nothing
    else do
      exists <- doesDirectoryExist upper
      if exists
        then Just <$> getModificationTime upper
        else return Nothing
  case mUpper of
    Just t -> return (Just t)
    Nothing -> do
      started <- inspectFormat toolbox "{{.State.StartedAt}}"
      -- podman uses year 0001 when the container has never started
      if null started || "0001-01-01" `isPrefixOf` started
        then inspectUTCTime toolbox "{{.Created}}"
        else return (parsePodmanTime started)

inspectUTCTime :: String -> String -> IO (Maybe UTCTime)
inspectUTCTime name format =
  parsePodmanTime <$> inspectFormat name format

-- podman -f '{{.Created}}' prints Go's time.String
-- (e.g. "2026-06-29 16:18:14.981069671 +0800 +08"), not ISO8601.
parsePodmanTime :: String -> Maybe UTCTime
parsePodmanTime raw =
  case words raw of
    (day : clock : off : _) ->
      parseTimeM True defaultTimeLocale "%Y-%m-%d %H:%M:%S%Q %z"
      (unwords [day, clock, off])
    _ -> Nothing

inspectFormat :: String -> String -> IO String
inspectFormat name format = do
  (_, out, _) <- cmdFull "podman" ["inspect", "-f", format, name] ""
  return $ filter (/= '\n') out

commitToolbox :: Bool -> String -> Bool -> IO String
commitToolbox dryrun toolbox refresh = do
  let image = progname +=+ toolbox
  imageExists <- cmdBool "podman" ["image", "exists", image]
  if imageExists && not refresh
    then return image
    else do
      containerExists <- cmdBool "podman" ["container", "exists", toolbox]
      if containerExists
        then do
        ok <-
          if dryrun then return True
          else do
            putStr "writing image "
            cmdBool "buildah"
              ["commit", "--disable-compression", toolbox, image]
        if ok
          then return image
          else error' $ "could not commit image of container" +-+ toolbox
        else error' $ "container '" ++ toolbox ++ "' not found"

removeImage :: String -> IO ()
removeImage image = do
  putStr "rmi "
  cmd_ "podman" ["rmi", image]

-- config

configPath :: IO FilePath
configPath = getUserConfigFile progname "config.toml"

loadConfig :: IO (Maybe Table)
loadConfig = do
  path <- configPath
  exists <- doesFileExist path
  if not exists
    then return Nothing
    else do
      result <- decodeFile path
      case result of
        Left e -> error' $ "config parse error:" +-+ T.unpack (renderTOMLError e)
        Right table -> return (Just table)

getCapabilities :: Maybe Table -> Table
getCapabilities Nothing = Map.empty
getCapabilities (Just table) =
  case Map.lookup (T.pack "capabilities") table of
    Just (Table t) -> t
    _ -> Map.empty

resolveCapabilities :: Table -> [String] -> IO ([String], [String], [String], [String], [String])
resolveCapabilities caps capNames = do
  results <- mapM (resolveCap caps) capNames
  let (vs, es, ps, is, ss) = unzip5 results
  return (concat vs, concat es, concat ps, concat is, concat ss)
  where
    unzip5 = foldr (\(a,b,c,d,e) (as,bs,cs,ds,es) -> (a:as,b:bs,c:cs,d:ds,e:es))
                   ([],[],[],[],[])

resolveCap :: Table -> String -> IO ([String], [String], [String], [String], [String])
resolveCap caps name =
  case Map.lookup (T.pack name) caps of
    Just (Table cap) ->
      return ( getStringList "volumes" cap
             , getStringList "env" cap
             , getStringList "path" cap
             , case getStringVal "init" cap of
                 Just s -> [s]
                 Nothing -> []
             , getStringList "security_opts" cap
             )
    _ -> do
      let available = if Map.null caps
                      then "(none defined)"
                      else intercalate ", " $ map T.unpack $ Map.keys caps
      error' $ "unknown capability '" ++ name ++ "'. Available:" +-+ available

getStringList :: String -> Table -> [String]
getStringList key table =
  case Map.lookup (T.pack key) table of
    Just (Array arr) -> mapMaybe valueToString arr
    _ -> []

getStringVal :: String -> Table -> Maybe String
getStringVal key table =
  case Map.lookup (T.pack key) table of
    Just (String t) -> Just (T.unpack t)
    _ -> Nothing

valueToString :: Value -> Maybe String
valueToString (String t) = Just (T.unpack t)
valueToString _ = Nothing

-- SELinux labeling

-- FIXME rather return Mount type or triple?
addSelinuxLabel :: FilePath -> String -> IO String
addSelinuxLabel homedir spec =
  case break (== ':') spec of
    (hostPart, []) -> do
      hostExp <- expandPath homedir hostPart
      requireVolumeHost hostExp
      skipLabel <- shouldSkipLabel hostExp
      return $ hostExp ++ ":" ++ hostExp ++ if skipLabel then "" else ":z"
    (hostPart, _:rest') -> do
      hostExp <- expandPath homedir hostPart
      requireVolumeHost hostExp
      let (containerPart, optsPart)
            | isVolumePathStart rest' =
                case break (== ':') rest' of
                  (c, [])  -> (c, Nothing)
                  (c, _:o) -> (c, Just o)
            | otherwise = (hostExp, if null rest' then Nothing else Just rest')
      containerExp <- expandPath homedir containerPart
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
    -- cannot relabel (rootless lsetxattr fails on files owned by another user).
    shouldSkipLabel hostExp = do
      sockFile <- isSocketFile hostExp
      selfOwned <- ownedBySelf hostExp
      return $ sockFile || hostExp == homedir || not selfOwned

requireVolumeHost :: FilePath -> IO ()
requireVolumeHost path = do
  exists <- doesPathExist path
  unless exists $
    error' $ "volume host path not found:" +-+ path

isSocketFile :: FilePath -> IO Bool
isSocketFile path = isSocket <$> getFileStatus path

-- Rootless podman cannot lsetxattr on files owned by another uid (e.g. /etc/*).
ownedBySelf :: FilePath -> IO Bool
ownedBySelf path = do
  uid <- getEffectiveUserID
  st <- getFileStatus path
  return $ fileOwner st == uid

-- DIR[:opts] for --home/--project (opts must not look like a path).
splitDirOpts :: String -> (FilePath, Maybe String)
splitDirOpts spec =
  case break (== ':') spec of
    (dir, []) -> (dir, Nothing)
    (dir, _:rest)
      | isVolumePathStart rest -> (spec, Nothing)
      | otherwise -> (dir, Just rest)

splitDirOptsMaybe :: Maybe String -> (Maybe FilePath, Maybe String)
splitDirOptsMaybe Nothing = (Nothing, Nothing)
splitDirOptsMaybe (Just s) =
  let (dir, opts) = splitDirOpts s
  in (Just dir, opts)

maybeOpts :: Maybe String -> String
maybeOpts Nothing = ""
maybeOpts (Just o) = ':' : o

isVolumePathStart :: String -> Bool
isVolumePathStart ('/':_) = True
isVolumePathStart ('~':_) = True
isVolumePathStart ('$':_) = True
isVolumePathStart _       = False

-- path and env expansion

expandPath :: FilePath -> String -> IO FilePath
expandPath homedir ('~':'/':rest) = do
  rest' <- expandEnvVars rest
  canonicalizePath $ homedir </> rest'
expandPath homedir "~" = return homedir
expandPath _ s = expandEnvVars s

expandEnvVars :: String -> IO String
expandEnvVars [] = return []
expandEnvVars ('$':'{':rest) =
  case break (== '}') rest of
    (var, '}':after) -> do
      val <- getEnvDefault var ""
      rest' <- expandEnvVars after
      return (val ++ rest')
    _ -> do
      rest' <- expandEnvVars rest
      return ("${" ++ rest')
expandEnvVars ('$':rest) =
  let (var, after) = span isVarChar rest
  in if null var
     then do
       rest' <- expandEnvVars rest
       return ('$' : rest')
     else do
       val <- getEnvDefault var ""
       rest' <- expandEnvVars after
       return (val ++ rest')
  where
    isVarChar c = c `elem` (['A'..'Z'] ++ ['a'..'z'] ++ ['0'..'9'] ++ "_")
expandEnvVars (c:rest) = do
  rest' <- expandEnvVars rest
  return (c : rest')

resolveProject :: FilePath -> IO FilePath
resolveProject dir = do
  homedir <- getHomeDirectory >>= canonicalizePath
  finaldir <- expandPath homedir dir >>= canonicalizePath
  when (finaldir == homedir) $
    warning "mounting $HOME as project (consider a subdirectory)"
  return finaldir

-- True if path is base or a subdirectory of base (avoids /home/foo vs /home/foobar).
isUnderDir :: FilePath -> FilePath -> Bool
isUnderDir base path =
  path == base || (base ++ "/") `isPrefixOf` path

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
        createDirectoryIfMissing True (takeDirectory dest)
        destExists <- doesPathExist dest
        unless destExists $ writeFile dest ""
      else createDirectoryIfMissing True dest

ensureTempHomeVol :: FilePath -> FilePath -> String -> IO ()
ensureTempHomeVol homedir temphome spec = do
  (hostPath, containerPath) <- volumePaths homedir spec
  ensureTempHomeMountPoint homedir temphome hostPath containerPath

-- Resolve host and container paths from a volume spec (before SELinux opts).
volumePaths :: FilePath -> String -> IO (FilePath, FilePath)
volumePaths homedir spec =
  case break (== ':') spec of
    (hostPart, []) -> do
      p <- expandPath homedir hostPart
      return (p, p)
    (hostPart, _:rest') -> do
      hostExp <- expandPath homedir hostPart
      if isVolumePathStart rest'
        then do
          let containerPart = takeWhile (/= ':') rest'
          containerExp <- expandPath homedir containerPart
          return (hostExp, containerExp)
        else return (hostExp, hostExp)

-- container naming

sanitizeName :: String -> String
sanitizeName = map (\c -> if c `elem` nameChars then c else '-')
  where
    nameChars = ['A'..'Z'] ++ ['a'..'z'] ++ ['0'..'9'] ++ "_.-"

-- Dots separate DNS labels in hostnames, so replace them for --hostname.
hostnameFromName :: String -> String
hostnameFromName = map (\c -> if c == '.' then '-' else c)

workProjectName :: FilePath -> String
workProjectName = sanitizeName . takeFileName

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

-- utilities

shellQuote :: String -> String
shellQuote s
  | all isSafe s = s
  | otherwise = "'" ++ concatMap escSQ s ++ "'"
  where
    isSafe c = c `elem` (['A'..'Z'] ++ ['a'..'z'] ++ ['0'..'9'] ++ "-_./=:@,+")
    escSQ '\'' = "'\\''"
    escSQ c = [c]

-- | Combine two strings with a single space
infixr 4 +=+
(+=+) :: String -> String -> String
s +=+ t | lastMay s == Just '-' = s ++ t
        | headMay t == Just '-' = s ++ t
s +=+ t = s ++ '-' : t

error':: String -> IO a
error' err = do
  putStrLn err
  exitFailure
