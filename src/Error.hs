module Error (error') where

import System.Exit (exitFailure)

error':: String -> IO a
error' err = do
  putStrLn err
  exitFailure
