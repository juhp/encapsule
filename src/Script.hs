{-# LANGUAGE ExtendedDefaultRules #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- SPDX-License-Identifier: Apache-2.0


module Script (
  SwitchUser(..),
  chooseSwitchUser,
  canSwitchUser,
  switchUserArgs,
  switchLabel,
  setupScript,
  Setup(..)
  )
where

import Control.Monad (unless, when)
import Control.Monad.Shell
import Data.Maybe (isNothing)
import qualified Data.Text.Lazy as T
import System.FilePath ((</>))
import System.Posix.IO

default (T.Text)

data SwitchUser = Runuser | Sudo | None

chooseSwitchUser :: Bool -> Bool -> SwitchUser
chooseSwitchUser True _     = Runuser
chooseSwitchUser False True = Sudo
chooseSwitchUser _ _        = None

canSwitchUser :: SwitchUser -> Bool
canSwitchUser None = False
canSwitchUser _    = True

-- argv prefix; empty for None
switchUserArgs :: SwitchUser -> String -> [String]
switchUserArgs Runuser u = ["runuser", "-u", u, "--"]
switchUserArgs Sudo    u = ["sudo", "-n", "--preserve-env", "-u", u, "--"]
switchUserArgs None    _ = []

switchLabel :: SwitchUser -> String
switchLabel Runuser = "runuser"
switchLabel Sudo    = "sudo"
switchLabel None    = "none"

data Setup = Setup
  { nosudo :: Bool
  , noskel :: Bool
  , username :: T.Text
  , program :: String
  , createhome :: Bool
  , homedir :: T.Text
  , mprojectDir :: Maybe FilePath
  }

setupScript :: Bool -> SwitchUser -> Bool -> Setup -> String
setupScript dbg switch haveSudo (Setup {..}) =
  T.unpack . T.replace "\t" " " . linearScript $
  sudoSetup >> homeSetup
  where
    redir s dest =
        if dbg then s else s |> (dest :: String) &stdError>&stdOutput
    runHide c args = run c args `redir` "/dev/null"
    -- haveCmd c = runHide "command" ["-v",c]

    sudoSetup =
      when haveSudo $
      unless nosudo $
      let sudoers = "/etc/sudoers.d" in
          whenCmd (test $ TDirExists sudoers) $ do
          runHide "echo" [username, "ALL=(ALL) NOPASSWD:ALL"] `redir` (sudoers </> program)
          runHide "chmod" ["440", T.pack sudoers]

    homeSetup = do
      when createhome $ do
        runHide "mkdir" ["-p", homedir]
        runHide "chown" [username, homedir]
      unless noskel $
        when (canSwitchUser switch) $
        whenCmd
        (test (TDirExists homedir)
         -&&-
         test (TDirExists (T.pack "/etc/skel"))) $
        let cpArgs = ["-a", "--update=none", "/etc/skel/.", homedir <> "/"]
        in case map T.pack $ switchUserArgs switch (T.unpack username) of
             prog:args -> runHide prog $ args ++ "cp" : cpArgs
             [] -> return ()
      when (isNothing mprojectDir && createhome) $
       runHide "cd" [homedir]
