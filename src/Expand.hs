-- SPDX-License-Identifier: Apache-2.0

module Expand (
  expandPath
  )
where

import System.Directory (canonicalizePath)
import System.FilePath ((</>))
import System.Posix.Env (getEnvDefault)

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
