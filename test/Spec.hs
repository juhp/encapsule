-- SPDX-License-Identifier: Apache-2.0

module Main (main) where

import Control.Exception (finally)
import Control.Monad (unless)
import Data.List (isInfixOf)
import Data.Maybe (fromMaybe)
import System.Directory (canonicalizePath, createDirectoryIfMissing,
                         removeDirectoryRecursive)
import System.Exit (ExitCode(..))
import System.FilePath ((</>))
import System.Posix.Process (getProcessID)
import System.Posix.Temp (mkdtemp)
import System.Process (readProcessWithExitCode)
import Test.Hspec

import EncapsuleTest

main :: IO ()
main = hspec spec

spec :: Spec
spec = do
  describe "dryrun" $ do
    it "prints podman run with keep-id" $
      withGenericImage $ \img -> do
        out <- dryrun [img]
        out `shouldContain` "podman run"
        out `shouldContain` "--userns=keep-id"

    it "applies --name" $
      withGenericImage $ \img -> do
        pid <- getProcessID
        let n = "testhost" ++ show pid
        out <- dryrun ["--name", n, img]
        out `shouldContain` ("--name encapsule-" ++ n)

    it "applies --name ^ without encapsule- prefix" $
      withGenericImage $ \img -> do
        out <- dryrun ["--name", "^bare-encap-test", img]
        out `shouldContain` "--name bare-encap-test"

    it "sets --project workdir and container name" $
      withGenericImage $ \img ->
        withTestDir $ \tmp -> do
          let proj = tmp </> "proj"
          createDirectoryIfMissing True proj
          out <- dryrun ["--project", proj, img]
          out `shouldContain` "--workdir"
          out `shouldContain` "--name encapsule-"
          out `shouldContain` "-proj"

    it "uses runuser or sudo to switch with --user root" $
      withGenericImage $ \img -> do
        out <- dryrun [img]
        case debugField out "switch" of
          Just "none" -> pendingWith $ img ++ " has no runuser or sudo"
          _ -> do
            out' <- dryrun ["--user", "root", img]
            assertUserSwitch out' "root"

  describe "ubuntu" $ do
    it "uses ubuntu user and passwd home for UID 1000" $ do
      img <- ubuntuImg
      requireImage img
      uid <- hostUid
      unless (uid == "1000") $
        pendingWith $ "host uid is " ++ uid ++ ", not 1000"
      user <- hostUser
      out <- dryrun [img]
      case debugField out "image user" of
        Just "ubuntu" -> do
          assertUserSwitch out "ubuntu"
          out `shouldNotContain` ("runuser -u " ++ user)
          out `shouldContain` "--workdir /home/ubuntu"
          case debugField out "HOME" of
            Just hosthome ->
              out `shouldNotContain` ("-e=HOME=" ++ hosthome)
            Nothing -> expectationFailure "ubuntu debug HOME line"
          debugField out "container home" `shouldBe` Just "/home/ubuntu"
        other ->
          pendingWith $ "image user is " ++ fromMaybe "unknown" other ++ ", not ubuntu"

    it "mounts --home on /home/ubuntu" $ do
      img <- ubuntuImg
      requireImage img
      uid <- hostUid
      unless (uid == "1000") $
        pendingWith $ "host uid is " ++ uid ++ ", not 1000"
      out0 <- dryrun [img]
      unless (debugField out0 "image user" == Just "ubuntu") $
        pendingWith "image user is not ubuntu"
      withTestDir $ \tmp -> do
        let homeTmp = tmp </> "home"
        createDirectoryIfMissing True homeTmp
        homeAbs <- canonicalizePath homeTmp
        let mHost = debugField out0 "HOME"
        out <- dryrun ["--home", homeTmp, img]
        out `shouldContain` (homeAbs ++ ":/home/ubuntu")
        out `shouldContain` "label=level:s0"
        case mHost of
          Just h -> out `shouldNotContain` (homeAbs ++ ":" ++ h)
          Nothing -> return ()

  describe "fedora" $ do
    it "falls back to host user and HOME when passwd has no UID" $ do
      img <- fedoraImg
      requireImage img
      user <- hostUser
      out <- dryrun [img]
      case debugField out "image user" of
        Just "(none)" -> do
          debugField out "user" `shouldBe` Just user
          debugField out "passwd home" `shouldBe` Just "(none)"
          case (debugField out "switch", debugField out "HOME") of
            (Just "none", _) ->
              pendingWith "fedora image has no runuser or sudo"
            (_, Just hosthome) -> do
              assertUserSwitch out user
              out `shouldContain` ("-e=HOME=" ++ hosthome)
              out `shouldNotContain` ("--workdir " ++ hosthome)
              out `shouldContain` "--passwd-entry"
              out `shouldContain` (":" ++ hosthome ++ ":/bin/sh")
            (_, Nothing) ->
              expectationFailure "fedora debug HOME line"
        other ->
          pendingWith $ "image has uid user " ++ fromMaybe "unknown" other

  describe "sudo" $ do
    it "writes sudoers when sudo is present, skips when not" $
      withGenericImage $ \img -> do
        out <- dryrun [img]
        case debugField out "sudo" of
          Just "True" -> do
            out `shouldContain` "NOPASSWD:ALL"
            outNo <- dryrun ["--no-sudo", img]
            outNo `shouldNotContain` "NOPASSWD:ALL"
          Just "False" -> do
            out `shouldNotContain` "NOPASSWD:ALL"
            outNo <- dryrun ["--no-sudo", img]
            outNo `shouldNotContain` "NOPASSWD:ALL"
          other ->
            expectationFailure $
              "debug sudo line for " ++ img ++ " (got: " ++
              show other ++ ")"

  describe "commit" $ do
    it "offers --name" $ do
      out <- encapsule ["commit", "--help"]
      out `shouldContain` "-n,--name NAME"

    it "names the image encapsule-CONTAINER by default" $
      withScratchContainer $ \cname -> do
        out <- encapsule ["commit", "--dryrun", cname]
        out `shouldContain` "buildah commit"
        out `shouldContain` ("encapsule-" ++ cname)

    it "applies --name to the encapsule image" $
      withScratchContainer $ \cname -> do
        pid <- getProcessID
        let n = "commitname" ++ show pid
        out <- encapsule ["commit", "--dryrun", "--name", n, cname]
        out `shouldContain` ("encapsule-" ++ n)

    it "applies --name ^ without encapsule- prefix" $
      withScratchContainer $ \cname -> do
        out <- encapsule ["commit", "--dryrun", "--name", "^bare-encap-img", cname]
        out `shouldContain` "bare-encap-img"
        out `shouldNotContain` "encapsule-bare-encap-img"

  describe "live" $ do
    it "runs id -un in the container" $
      withGenericImage $ \img -> do
        tty <- hasTTY
        forced <- liveEnabled
        unless (tty || forced) $
          pendingWith "not a TTY (set ENCAPSULE_LIVE=1 to force)"
        pid <- getProcessID
        let name = "^encap-live-" ++ show pid
        out <- encapsule
          ["run", "--no-skel", "--name", name, img, "--", "id", "-un"]
        let names = commandOutputLines out
            ttyWarn = "not a TTY" `isInfixOf` out
        uid <- hostUid
        uimg <- ubuntuImg
        let mUser
              | img == uimg && uid == "1000" = Just "ubuntu"
              | otherwise = Nothing
        case (names, mUser) of
          ([], _)
            | ttyWarn -> pendingWith "not a TTY"
            | otherwise -> expectationFailure "live run produced no command output"
          (ns, Just u) -> ns `shouldContain` [u]
          (ns, Nothing) -> last ns `shouldSatisfy` (not . null)

withTestDir :: (FilePath -> IO a) -> IO a
withTestDir act = do
  d <- mkdtemp "/tmp/encapsule-test-XXXXXX"
  act d `finally` removeDirectoryRecursive d

withScratchContainer :: (String -> IO ()) -> IO ()
withScratchContainer act =
  withGenericImage $ \img -> do
    (code, out, err) <- readProcessWithExitCode "podman"
      ["create", img, "true"] ""
    unless (code == ExitSuccess) $
      pendingWith $ "podman create failed: " ++ err
    case lines out of
      cid:_ | not (null cid) ->
        act cid `finally` do
          _ <- readProcessWithExitCode "podman" ["rm", "-f", cid] ""
          return ()
      _ -> pendingWith "podman create produced no id"

assertUserSwitch :: String -> String -> Expectation
assertUserSwitch out user =
  case debugField out "switch" of
    Just "runuser" -> do
      out `shouldContain` ("runuser -u " ++ user)
      out `shouldContain` "--user=root"
    Just "sudo" -> do
      out `shouldContain` ("sudo -n --preserve-env -u " ++ user)
      out `shouldContain` "--user=root"
    Just "none" -> pendingWith "image has no runuser or sudo"
    other ->
      expectationFailure $ "debug switch line (got: " ++ show other ++ ")"
