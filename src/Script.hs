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
  , createhome :: Bool
  , homedir :: T.Text
  , mprojectDir :: Maybe FilePath
  }

setupScript :: Bool -> Bool -> Bool -> Setup -> String
setupScript dbg haveRunuser haveSudo (Setup {..}) =
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
        when haveRunuser $
        whenCmd
        (test (TDirExists homedir)
         -&&-
         test (TDirExists (T.pack "/etc/skel"))) $
        let cpArgs = ["-a", "--update=none", "/etc/skel/.", homedir <> "/"]
        in if haveRunuser
           then runHide "runuser" $ ["-u", username, "--"] ++ "cp" : cpArgs
           else runHide "cp" cpArgs
      when (isNothing mprojectDir) $
        runHide "cd" [homedir | not createhome]
