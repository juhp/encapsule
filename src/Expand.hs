-- SPDX-License-Identifier: Apache-2.0

module Expand (
  expandPath,
  expandContainerPath,
  )
where

import System.Directory (canonicalizePath)
import System.FilePath ((</>))
import System.Posix.Env (getEnvDefault)

-- | Expand ~ and $VARS; canonicalize (host paths).
expandPath :: FilePath -- homedir
           -> String -- path string
           -> IO FilePath
expandPath = expandHome canonicalizePath

-- | Expand ~ and $VARS without canonicalize (container paths need not exist on the host).
expandContainerPath :: FilePath -- homedir
                    -> String -- path string
                    -> IO FilePath
expandContainerPath = expandHome return

expandHome :: (FilePath -> IO FilePath) -> FilePath -> String -> IO FilePath
expandHome finish homedir ('~':'/':rest) = do
  rest' <- expandEnvVars rest
  finish $ homedir </> rest'
expandHome finish homedir "~" = finish homedir
expandHome _ _ s = expandEnvVars s

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
