-- SPDX-License-Identifier: Apache-2.0

module Main (main) where

import Control.Monad.Extra (unless, when)
import Data.Maybe (fromMaybe)
import SimpleCmd (cmd_, cmdBool, cmdFull, cmdLines, cmdN, warning, (+-+))
import SimpleCmdArgs
import System.IO (BufferMode(NoBuffering), hSetBuffering, stdout)

import Backup
import Config
import Error
import Paths_encapsule (version)
import qualified Run
import Run hiding (RunOpts(..))

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
      <$> strArg "TOOLBOX"
      <*> optional projectNameOpt
    , Subcommand "rmi" "Remove an encapsule image" $
      removeImageCmd
      <$> dryrunOpt
      <*> strArg "TOOLBOX"
    , Subcommand "stop" "Stop an encapsule container" $
      stopCmd
      <$> strArg "TOOLBOX"
      <*> optional projectNameOpt
    , Subcommand "backup" "Create a tarball backup of a directory" $
      backupCmd
      <$> dryrunOpt
      <*> switchWith 'y' "yes" "Don't prompt for large directories"
      <*> optional (strOptionWith 'o' "output" "FILE" "Output tarball (default: DIR-<timestamp>.tar.gz)")
      <*> strArg "DIR"
    , Subcommand "commit" "Commit an encapsule image from a container" $
      commitCmd
      <$> dryrunOpt
      <*> optional (strOptionWith 'n' "name" "NAME" "Optional image name (prefix with '^' to skip 'encapsule-' prefix)")
      <*> strArg "TOOLBOX"
    , Subcommand "create" "Create an encapsule container" $
      runCmd <$> runOpts True False
    , Subcommand "enter" "Connect to an encapsule container" $
      enterCmd
      <$> dryrunOpt
      <*> debugOpt
      <*> pure True
      <*> optional (strArg "TOOLBOX")
      <*> optional projectNameOpt
      <*> many (strArg "[--] CMD")
    , Subcommand "run" "Run a temporary encapsule container" $
      runCmd <$> runOpts False True
    ]
  where
    dryrunOpt = switchLongWith "dryrun" "Print the podman command instead of running it"

    projectOpt = strOptionWith 'p' "project" "DIR[:opts]"

    nameOpt = strOptionWith 'n' "name" "NAME" "Optional container name (prefix with '^' prefix to skip 'encapsule-' prefix)"

    projectNameOpt = Project <$> projectOpt "Project name or path" <|>
                     Name <$> nameOpt

    backupDirOpt s l m h =
      let pair fs sn = (fs,sn) in
        pair
        <$> strOptionWith s l m h
        <*> switchLongWith ("backup-" ++ l) ("Tarball" +-+ l +-+ "directory before starting")

    debugOpt = switchLongWith "debug" "Show debug output"

    runOpts keep unique =
      Run.RunOpts
      <$> strArg "IMAGE"
      <*> many (strOptionWith 'v' "volume" "HOST:CONTAINER[:opts]" "Bind mount (user's files default to selinux :z)")
      <*> many (strOptionWith 'e' "env" "KEY[=VALUE]" "Set or pass through an environment variable")
      <*> many (strOptionLongWith "path" "DIR" "Prepend a directory to PATH inside the container")
      <*> many (strOptionWith 'i' "init" "CMD" "A bash snippet run when creating the encapsule container")
      <*> many (strOptionLongWith "cap" "NAME" "Enable a capability from the config file")
      <*> switchLongWith "pull" "Pull newer container image"
      <*> optional (strOptionLongWith "user" "USER" "Override container user [default: host/image user with host UID]")
      <*> optional (backupDirOpt 'H' "home" "DIR[:opts]" "Mount a directory as a writable home (created if missing; use DIR:O to overlay)")
      <*> optional (backupDirOpt 'p' "project" "DIR[:opts]" "Mount a (project) directory as workdir (use DIR:O to overlay)")
      <*> optional nameOpt
      <*> pure keep
      <*> switchLongWith "readonly" "Make the encapsule container filesystem read-only"
      <*> switchLongWith "no-network" "Disable network access"
      <*> switchLongWith "no-sudo" "Skip passwordless sudo setup"
      <*> switchLongWith "no-skel" "Don't copy /etc/skel into an empty home"
      <*> pure unique
      <*> many (strOptionLongWith "podman-opt" "OPTION" "Pass an option directly to podman")
      <*> debugOpt
      <*> dryrunOpt
      <*> many (strArg "[--] CMD")

listCmd :: IO ()
listCmd = do
  needPodman
  cmd_ "podman" ["images",
                 "--filter", "reference=" ++ progname ++ "-*",
                 "--format", "{{.Repository}}:{{.Tag}}  {{.Size}}  {{.Created}}"]
  putChar '\n'
  cmd_ "podman" ["ps", "-a",
                 "--filter", "name=^" ++ progname +=+ "",
                 "--format", "{{.Names}}  {{.Status}}"]

removeCmd :: String -> Maybe ProjectName -> IO ()
removeCmd toolbox mprojectname = do
  containerName <- mkContainerName toolbox mprojectname
  needPodman
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

-- FIXME check image exists?
removeImageCmd :: Bool -> String -> IO ()
removeImageCmd dryrun name =
  let image = progname +=+ name in
    if dryrun
    then putStrLn $ "would rmi" +-+ image
    else do
      needPodman
      putStr "rmi "
      cmd_ "podman" ["rmi", image]

-- FIXME dryrun
stopCmd :: String -> Maybe ProjectName -> IO ()
stopCmd name mprojectname = do
  containerName <- mkContainerName name mprojectname
  needPodman
  exists <- cmdBool "podman" ["container", "exists", containerName]
  if exists
    then do
      putStr "stop "
      cmd_ "podman" ["stop", containerName]
    else warning $ "container" +-+ containerName +-+ "not found"

enterCmd :: Bool -> Bool -> Bool -> Maybe String -> Maybe ProjectName
         -> [String] -> IO ()
enterCmd dryrun debug running mbase mprojectname command = do
  regexp <-
    case mprojectname of
      Nothing -> return $ progname +=+ fromMaybe "" mbase
      Just (Name n) -> return $ progname ++ '-' : n
      Just (Project p) -> do
        projectDir <- resolveProject p
        return $ progname ++ '-' : fromMaybe ".*" mbase ++ '-' : workProjectName projectDir
  needPodman
  ps <- cmdLines "podman" $ "ps" :
        ["-a" | not running] ++
        ["--filter", "name=" ++ '^' : regexp,
         "--format", "{{.Names}}"]
  case ps of
    [] ->
      if running
      then do
        enterCmd dryrun debug False mbase mprojectname command
      else error' "encapsule container not found"
    [c] -> do
      unless running $
        warning "no running encapsule container found"
      enterContainer dryrun debug True c command
    _ -> error' $ "multiple" +-+ (if running then  "running" else "") +-+ "containers match:\n" ++ unlines ps

-- image management

commitCmd :: Bool -> Maybe String -> String -> IO ()
commitCmd dryrun mname toolbox = do
  needPodman
  containerExists <- cmdBool "podman" ["container", "exists", toolbox]
  unless containerExists $
    error' $ "container '" ++ toolbox ++ "' not found"
  let image = maybe (progname +=+ toolbox) encapsuleName mname
      encapsuleName ('^':n) = n
      encapsuleName n = progname +=+ n
  imageExists <- cmdBool "podman" ["image", "exists", image]
  unless imageExists $
    putStrLn $ "creating new image:" +-+ image
  let buildah_args = ["commit", "--disable-compression", toolbox, image]
  if dryrun
    then cmdN "buildah" buildah_args
    else do
      putStr "writing image "
      cmd_ "buildah" buildah_args
