{-# LANGUAGE ExtendedDefaultRules #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- SPDX-License-Identifier: Apache-2.0


module Script (
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

data Setup = Setup
  { nosudo :: Bool
  , noskel :: Bool
  , username :: T.Text
  , program :: String
  , mhome :: Maybe String
  , homedir :: T.Text
  , mprojectDir :: Maybe FilePath
  }

setupScript :: Bool -> Bool -> Setup -> String
setupScript dbg haveRunuser (Setup {..}) =
  T.unpack . T.replace "\t" " " . linearScript $
  sudoSetup >> homeSetup
  where
    redir s dest =
        if dbg then s else s |> (dest :: String) &stdError>&stdOutput
    runHide c args = run c args `redir` "/dev/null"
    -- haveCmd c = runHide "command" ["-v",c]

    sudoSetup =
      if nosudo
        then runHide "rm" ["-f", "/usr/bin/sudo"]
        else
        when haveRunuser $
        let sudoers = "/etc/sudoers.d" in
          whenCmd (test $ TDirExists sudoers) $ do
          runHide "echo" [username, "ALL=(ALL) NOPASSWD:ALL"] `redir` (sudoers </> program)
          runHide "chmod" ["440", T.pack sudoers]

    homeSetup = do
      when haveRunuser $
        when (isNothing mhome) $ do
        runHide "mkdir" ["-p", homedir]
        runHide "chown" [username, homedir]
        -- FIXME? might be more consist not to condition on .bashrc
        unless noskel $
        -- (shell-monad bug) TAnd / TOr emit raw && / ||
          whenCmd
          (test (TNot $ TFileExists (T.unpack homedir </> ".bashrc"))
           -&&-
           test (TDirExists (T.pack "/etc/skel"))) $
          runHide "runuser" ["-u", username, "--", "cp", "-an", "/etc/skel/.", homedir <> "/"]
      when (isNothing mprojectDir) $
        runHide "cd" []
