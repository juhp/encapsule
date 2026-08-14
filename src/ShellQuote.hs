-- SPDX-License-Identifier: Apache-2.0

module ShellQuote (shellQuote) where

shellQuote :: String -> String
shellQuote s
  | all isSafe s = s
  | otherwise = "'" ++ concatMap escSQ s ++ "'"
  where
    isSafe c = c `elem` (['A'..'Z'] ++ ['a'..'z'] ++ ['0'..'9'] ++ "-_./=:@,+")
    escSQ '\'' = "'\\''"
    escSQ c = [c]
