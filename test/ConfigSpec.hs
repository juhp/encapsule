-- SPDX-License-Identifier: Apache-2.0

module ConfigSpec (spec) where

import Control.Exception (bracket)
import qualified Data.Map.Strict as Map
import System.Directory (createDirectoryIfMissing, removeDirectoryRecursive)
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>), takeDirectory)
import System.Posix.Temp (mkdtemp)
import Test.Hspec

import Config (getCapabilities, loadConfig, resolveCapabilities)
import EncapsuleTest (encapsule)

spec :: Spec
spec = describe "config" $ do
  it "returns Nothing when no config files exist, including bundled defaults" $
    withConfigDirs $ \_ _ _ ->
      loadConfig `shouldReturn` Nothing

  it "loads bundled defaults when no user or system config exists" $
    withConfigDirs $ \user _ _ -> do
      writeBundledConfig user "[capabilities.bundled]\nenv = ['BUNDLED']\n"
      resolve ["bundled"] `shouldReturn` ([], ["BUNDLED"], [], [], [])
      out <- encapsule ["list-caps"]
      out `shouldBe` "Available capabilities:\n  bundled\n"

  it "merges user overrides over bundled defaults without a system config" $
    withConfigDirs $ \user _ _ -> do
      writeBundledConfig user $ unlines
        [ "[capabilities.shared]"
        , "env = ['BUNDLED']"
        , "path = ['/bundled/bin']"
        , "[capabilities.bundled]"
        , "volumes = ['bundled-volume']"
        ]
      writeConfig user "[capabilities.shared]\nenv = ['USER']\n"
      resolve ["shared", "bundled"] `shouldReturn`
        (["bundled-volume"], ["USER"], ["/bundled/bin"], [], [])

  it "ignores bundled defaults when a system config exists" $
    withConfigDirs $ \user _ system -> do
      writeBundledConfig user "[capabilities.bundled]\nenv = ['BUNDLED']\n"
      writeConfig system "[capabilities.system]\nenv = ['SYSTEM']\n"
      out <- encapsule ["list-caps"]
      out `shouldBe` "Available capabilities:\n  system\n"

  it "lets an empty system config suppress bundled defaults" $
    withConfigDirs $ \user system _ -> do
      writeBundledConfig user "[capabilities.bundled]\nenv = ['BUNDLED']\n"
      writeConfig system ""
      (getCapabilities <$> loadConfig) `shouldReturn` Map.empty

  it "reports malformed bundled defaults when no system config exists" $
    withConfigDirs $ \user _ _ -> do
      writeBundledConfig user "[broken\n"
      out <- encapsule ["list-caps"]
      out `shouldContain` "config parse error in"
      out `shouldContain` (takeDirectory user </> "bundled" </> "data" </> "config.toml")

  it "ignores malformed bundled defaults when a system config exists" $
    withConfigDirs $ \user system _ -> do
      writeBundledConfig user "[broken\n"
      writeConfig system "[capabilities.system]\nenv = ['SYSTEM']\n"
      resolve ["system"] `shouldReturn` ([], ["SYSTEM"], [], [], [])

  it "loads a user config without a system config" $
    withConfigDirs $ \user _ _ -> do
      writeConfig user "[capabilities.user]\nenv = ['USER_ONLY']\n"
      resolve ["user"] `shouldReturn` ([], ["USER_ONLY"], [], [], [])

  it "loads a system config without a user config" $
    withConfigDirs $ \_ system _ -> do
      writeConfig system "[capabilities.system]\nenv = ['SYSTEM_ONLY']\n"
      resolve ["system"] `shouldReturn` ([], ["SYSTEM_ONLY"], [], [], [])

  it "merges capability fields and replaces arrays and scalar values" $
    withConfigDirs $ \user system _ -> do
      writeConfig system $ unlines
        [ "[capabilities.shared]"
        , "volumes = ['system-volume']"
        , "env = ['SYSTEM_ENV']"
        , "path = ['/system/bin']"
        , "init = 'system-init'"
        , "security_opts = ['label=disable']"
        , "[capabilities.system]"
        , "env = ['SYSTEM_ONLY']"
        ]
      writeConfig user $ unlines
        [ "[capabilities.shared]"
        , "volumes = []"
        , "env = ['USER_ENV']"
        , "init = 'user-init'"
        , "[capabilities.user]"
        , "env = ['USER_ONLY']"
        ]
      resolve ["shared"] `shouldReturn`
        ([], ["USER_ENV"], ["/system/bin"], ["user-init"], ["label=disable"])
      resolve ["system", "user"] `shouldReturn`
        ([], ["SYSTEM_ONLY", "USER_ONLY"], [], [], [])

  it "respects system directory order and user precedence" $
    withConfigDirs $ \user first second -> do
      writeConfig second "[capabilities.shared]\nenv = ['SECOND']\npath = ['/second/bin']\n"
      writeConfig first "[capabilities.shared]\nenv = ['FIRST']\n"
      resolve ["shared"] `shouldReturn` ([], ["FIRST"], ["/second/bin"], [], [])
      writeConfig user "[capabilities.shared]\nenv = ['USER']\n"
      resolve ["shared"] `shouldReturn` ([], ["USER"], ["/second/bin"], [], [])

  it "lets a user value replace a system table" $
    withConfigDirs $ \user system _ -> do
      writeConfig system "[capabilities.shared]\nenv = ['SYSTEM']\n"
      writeConfig user "capabilities = []\n"
      (getCapabilities <$> loadConfig) `shouldReturn` Map.empty

  it "reports the path of a malformed system config even with a user config" $
    withConfigDirs $ \user system _ -> do
      writeConfig user "[capabilities.user]\nenv = ['USER']\n"
      writeConfig system "[broken\n"
      out <- encapsule ["list-caps"]
      out `shouldContain` "config parse error in"
      out `shouldContain` (system </> "encapsule" </> "config.toml")

resolve :: [String] -> IO ([String], [String], [String], [String], [String])
resolve names = do
  caps <- getCapabilities <$> loadConfig
  resolveCapabilities caps names

writeConfig :: FilePath -> String -> IO ()
writeConfig dir contents = do
  let appDir = dir </> "encapsule"
  createDirectoryIfMissing True appDir
  writeFile (appDir </> "config.toml") contents

writeBundledConfig :: FilePath -> String -> IO ()
writeBundledConfig user contents = do
  let dataDir = takeDirectory user </> "bundled" </> "data"
  createDirectoryIfMissing True dataDir
  writeFile (dataDir </> "config.toml") contents

withConfigDirs :: (FilePath -> FilePath -> FilePath -> IO a) -> IO a
withConfigDirs action =
  bracket (mkdtemp "/tmp/encapsule-config-test-XXXXXX") removeDirectoryRecursive $ \tmp -> do
    let user = tmp </> "user"
        first = tmp </> "system-first"
        second = tmp </> "system-second"
    withEnv "XDG_CONFIG_HOME" user $
      withEnv "XDG_CONFIG_DIRS" (first ++ ":" ++ second) $
        withEnv "encapsule_datadir" (tmp </> "bundled") $
          action user first second

withEnv :: String -> String -> IO a -> IO a
withEnv key value action =
  bracket (lookupEnv key) restore $ \_ -> do
    setEnv key value
    action
  where
    restore Nothing = unsetEnv key
    restore (Just old) = setEnv key old
