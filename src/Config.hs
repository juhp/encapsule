-- SPDX-License-Identifier: Apache-2.0

module Config (
  listCapsCmd,
  loadConfig,
  getCapabilities,
  progname,
  resolveCapabilities
  )
where

import Data.List (intercalate)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import qualified Data.Text as T
import SimpleCmd (error', (+-+))
import System.Directory (doesFileExist)
import System.Environment.XDG.BaseDir (getUserConfigFile)
import TOML (Value(..), Table, renderTOMLError, decodeFile)

progname :: String
progname = "encapsule"

loadConfig :: IO (Maybe Table)
loadConfig = do
  path <- getUserConfigFile progname "config.toml"
  exists <- doesFileExist path
  if not exists
    then return Nothing
    else do
      result <- decodeFile path
      case result of
        Left e -> error' $ "config parse error:" +-+ T.unpack (renderTOMLError e)
        Right table -> return (Just table)

getCapabilities :: Maybe Table -> Table
getCapabilities Nothing = Map.empty
getCapabilities (Just table) =
  case Map.lookup (T.pack "capabilities") table of
    Just (Table t) -> t
    _ -> Map.empty

resolveCapabilities :: Table -> [String] -> IO ([String], [String], [String], [String], [String])
resolveCapabilities caps capNames = do
  results <- mapM (resolveCap caps) capNames
  let (vs, es, ps, is, ss) = unzip5 results
  return (concat vs, concat es, concat ps, concat is, concat ss)
  where
    unzip5 = foldr (\(a,b,c,d,e) (as,bs,cs,ds,es) -> (a:as,b:bs,c:cs,d:ds,e:es))
                   ([],[],[],[],[])

resolveCap :: Table -> String -> IO ([String], [String], [String], [String], [String])
resolveCap caps name =
  case Map.lookup (T.pack name) caps of
    Just (Table cap) ->
      return ( getStringList "volumes" cap
             , getStringList "env" cap
             , getStringList "path" cap
             , case getStringVal "init" cap of
                 Just s -> [s]
                 Nothing -> []
             , getStringList "security_opts" cap
             )
    _ -> do
      let available = if Map.null caps
                      then "(none defined)"
                      else intercalate ", " $ map T.unpack $ Map.keys caps
      error' $ "unknown capability '" ++ name ++ "'. Available:" +-+ available

getStringList :: String -> Table -> [String]
getStringList key table =
  case Map.lookup (T.pack key) table of
    Just (Array arr) -> mapMaybe valueToString arr
    _ -> []

getStringVal :: String -> Table -> Maybe String
getStringVal key table =
  case Map.lookup (T.pack key) table of
    Just (String t) -> Just (T.unpack t)
    _ -> Nothing

valueToString :: Value -> Maybe String
valueToString (String t) = Just (T.unpack t)
valueToString _ = Nothing

listCapsCmd :: IO ()
listCapsCmd = do
  config <- loadConfig
  let capabilities = getCapabilities config
  if Map.null capabilities
    then putStrLn "No capabilities defined"
    else do
      putStrLn "Available capabilities:"
      mapM_ (putStrLn . ("  " ++) . T.unpack) $ Map.keys capabilities
