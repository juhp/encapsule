-- SPDX-License-Identifier: Apache-2.0

module Main (main) where

import Control.Exception (finally)
import Control.Monad (unless)
import Data.List (isInfixOf)
import Data.Maybe (fromMaybe)
import System.Directory (canonicalizePath, createDirectoryIfMissing,
                         removeDirectoryRecursive)
import System.FilePath ((</>))
import System.Posix.Process (getProcessID)
import System.Posix.Temp (mkdtemp)
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

    it "uses runuser -u root with --user root" $
      withGenericImage $ \img -> do
        out <- dryrun [img]
        case debugField out "runuser" of
          Just "True" -> do
            out' <- dryrun ["--user", "root", img]
            out' `shouldContain` "runuser -u root"
          _ -> pendingWith $ img ++ " has no runuser"

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
          out `shouldContain` "runuser -u ubuntu"
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
          case (debugField out "runuser", debugField out "HOME") of
            (Just "True", Just hosthome) -> do
              out `shouldContain` ("runuser -u " ++ user)
              out `shouldContain` ("-e=HOME=" ++ hosthome)
            (Just "True", Nothing) ->
              expectationFailure "fedora debug HOME line"
            _ -> pendingWith "fedora image has no runuser"
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
            outNo `shouldContain` "rm -f /usr/bin/sudo"
            outNo `shouldNotContain` "NOPASSWD:ALL"
          Just "False" -> do
            out `shouldNotContain` "NOPASSWD:ALL"
            outNo <- dryrun ["--no-sudo", img]
            outNo `shouldNotContain` "rm -f /usr/bin/sudo"
          other ->
            expectationFailure $
              "debug sudo line for " ++ img ++ " (got: " ++
              show other ++ ")"

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
