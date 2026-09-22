{-# LANGUAGE ExtendedDefaultRules #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- SPDX-License-Identifier: Apache-2.0


module Script (
  SwitchUser(..),
  chooseSwitchUser,
  switchUserArgs,
  switchLabel,
  setupScript,
  Setup(..)
  )
where

import Control.Monad (unless, when)
import Control.Monad.Shell
import Data.Maybe (isJust, isNothing)
import qualified Data.Text.Lazy as T
import System.FilePath ((</>))
import System.Posix.IO

default (T.Text)

data SwitchUser = Runuser | Sudo

chooseSwitchUser :: Bool -> Bool -> Maybe SwitchUser
chooseSwitchUser True _     = Just Runuser
chooseSwitchUser False True = Just Sudo
chooseSwitchUser _ _        = Nothing

-- argv prefix; empty for None
switchUserArgs :: String -> SwitchUser -> [String]
switchUserArgs u Runuser = ["runuser", "-u", u, "--"]
switchUserArgs u Sudo = ["sudo", "-n", "--preserve-env", "-u", u, "--"]

switchLabel :: SwitchUser -> String
switchLabel Runuser = "runuser"
switchLabel Sudo    = "sudo"

data Setup = Setup
  { sudoEnable :: Bool
  , noskel :: Bool
  , username :: T.Text
  , program :: String
  , createhome :: Bool
  , homedir :: T.Text
  , mprojectDir :: Maybe FilePath
  }

setupScript :: Bool -> Maybe SwitchUser -> Bool -> Setup -> String
setupScript dbg mswitch haveSudo (Setup {..}) =
  T.unpack . T.replace "\t" " " . linearScript $
  sudoSetup >> homeSetup
  where
    redir s dest =
        if dbg then s else s |> (dest :: String) &stdError>&stdOutput
    runHide c args = run c args `redir` "/dev/null"
    -- haveCmd c = runHide "command" ["-v",c]

    sudoSetup =
      when haveSudo $
      when sudoEnable $
      let sudoers = "/etc/sudoers.d" in
          whenCmd (test $ TDirExists sudoers) $ do
          runHide "echo" [username, "ALL=(ALL) NOPASSWD:ALL"] `redir` (sudoers </> program)
          runHide "chmod" ["440", T.pack sudoers]

    homeSetup = do
      when createhome $ do
        runHide "mkdir" ["-p", homedir]
        runHide "chown" [username, homedir]
      unless noskel $
        when (isJust mswitch) $
        whenCmd
        (test (TDirExists homedir)
         -&&-
         test (TDirExists (T.pack "/etc/skel"))) $
        let cpArgs = ["-a", "--update=none", "/etc/skel/.", homedir <> "/"]
        in case map T.pack $ maybe [] (switchUserArgs (T.unpack username)) mswitch of
             prog:args -> runHide prog $ args ++ "cp" : cpArgs
             [] -> return ()
      when (isNothing mprojectDir && createhome) $
       runHide "cd" [homedir]
