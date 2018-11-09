{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PatternSynonyms   #-}
{-# LANGUAGE DoAndIfThenElse   #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications  #-}

module Unison.Codebase.Watch where

import qualified Unison.Builtin                as B
import           Control.Concurrent             ( forkIO
                                                , threadDelay
                                                )
import           Control.Concurrent.MVar
import           Control.Concurrent.STM         ( atomically )
import           Control.Exception              ( finally )
import           Control.Monad                  ( forever
                                                , void
                                                )
import           Data.Foldable                  ( toList )
import           Data.IORef
import           Data.List                      ( isSuffixOf )
import qualified Data.Map                      as Map
import           Data.Text                      ( Text )
import qualified Data.Text                     as Text
import qualified Data.Text.IO
import           Data.Time.Clock                ( UTCTime
                                                , diffUTCTime
                                                )
import qualified System.Console.ANSI           as Console
import           System.Directory               ( canonicalizePath )
import           System.FSNotify                ( Event(Added, Modified)
                                                , watchTree
                                                , withManager
                                                )
import           System.Random                  ( randomIO )
import           Unison.Codebase                ( Codebase )
import           Unison.Codebase.Runtime        ( Runtime(..) )
import qualified Unison.Codebase.Runtime       as RT
import qualified Unison.FileParsers            as FileParsers
import           Unison.Names                   ( Names )
import qualified Unison.Parsers                as Parsers
import           Unison.PrintError              ( renderParseErrorAsANSI
                                                , renderNoteAsANSI
                                                )
import           Unison.Result                  ( pattern Result )
import qualified Unison.TermPrinter             as TermPrinter
import           Unison.Term                    ( Term )
import qualified Unison.UnisonFile              as UF
import           Unison.Util.Monoid
import qualified Unison.PrettyPrintEnv         as PPE
import           Unison.Util.TQueue             ( TQueue )
import qualified Unison.Util.TQueue            as TQueue
import           Unison.Var                     ( Var )
-- import Debug.Trace

watchDirectory' :: FilePath -> IO (IO (FilePath, UTCTime))
watchDirectory' d = do
  mvar <- newEmptyMVar
  let doIt fp t = do
        _ <- tryTakeMVar mvar
        putMVar mvar (fp, t)
      handler e = case e of
        Added    fp t False -> doIt fp t
        Modified fp t False -> doIt fp t
        _                   -> pure ()
  _ <- forkIO $ withManager $ \mgr -> do
    _ <- watchTree mgr d (const True) handler
    forever $ threadDelay 1000000
  pure $ takeMVar mvar


collectUntilPause :: TQueue a -> Int -> IO [a]
collectUntilPause queue minPauseµsec = do
-- 1. wait for at least one element in the queue
  void . atomically $ TQueue.peek queue

  let go = do
        before <- atomically $ TQueue.enqueueCount queue
        threadDelay minPauseµsec
        after <- atomically $ TQueue.enqueueCount queue
        -- if nothing new is on the queue, then return the contents
        if before == after
          then do
            atomically $ TQueue.flush queue
          else go
  go

watchDirectory :: FilePath -> (FilePath -> Bool) -> IO (IO (FilePath, Text))
watchDirectory dir allow = do
  previousFiles <- newIORef Map.empty
  watcher       <- watchDirectory' dir
  let
    await = do
      (file, t) <- watcher
      if allow file
        then do
          contents <- Data.Text.IO.readFile file
          prevs    <- readIORef previousFiles
          case Map.lookup file prevs of
            -- if the file's content's haven't changed and less than a second has passed,
            -- wait for the next update
            Just (contents0, t0)
              | contents == contents0 && (t `diffUTCTime` t0) < 1 -> await
            _ -> (file, contents) <$ writeIORef
              previousFiles
              (Map.insert file (contents, t) prevs)
        else await
  pure await

watchPrinter :: Var v => Names -> Text -> Term v -> IO ()
watchPrinter names label term = do
  -- I guess this string constant comes from somewhere, and we are using
  -- a bunch of spaces of the same total length.
  let lead = const ' ' <$> "      | > "
  -- weird that this doesn't incorporate the previous constant somehow
  let arr = "          ⧩"
  -- todo: replace 80 with some number calculated from the terminal width
  -- e.g. http://hackage.haskell.org/package/terminal-size
  let tm = TermPrinter.pretty' (Just 80) (PPE.fromNames names) term
  let tm2 = tm >>= \case
       '\n' -> '\n' : lead
       c -> pure c
  putStrLn $ Text.unpack label
  putStrLn arr
  putStrLn $ lead ++ tm2 ++ "\n"


watcher
  :: Var v
  => Maybe FilePath
  -> FilePath
  -> Runtime v
  -> Codebase IO v a
  -> IO ()
watcher initialFile dir runtime codebase = do
  Console.setTitle "Unison"
  Console.clearScreen
  Console.setCursorPosition 0 0
  cdir <- canonicalizePath dir
  putStrLn $ "\n🆗  I'm awaiting changes to *.u files in " ++ cdir
  -- putStrLn $ "   Note: I'm using the Unison runtime at " ++ show address
  d <- watchDirectory dir (".u" `isSuffixOf`)
  n <- randomIO @Int >>= newIORef
  let
    go sourceFile source0 = do
      let source = Text.unpack source0
      Console.clearScreen
      Console.setCursorPosition 0 0
      marker <- do
        n0 <- readIORef n
        writeIORef n (n0 + 1)
        pure ["🌻🌸🌵🌺🌴" !! (n0 `mod` 5)]
        -- pure ["🕐🕑🕒🕓🕔🕕🕖🕗🕘🕙🕚🕛" !! (n0 `mod` 12)]
      Console.setTitle "Unison"
      putStrLn ""
      putStrLn $ marker ++ "  " ++ sourceFile ++ " has changed, reloading...\n"
      parseResult <- Parsers.readAndParseFile B.names sourceFile
      case parseResult of
        Left parseError -> do
          Console.setTitle "Unison \128721"
          print $ renderParseErrorAsANSI source parseError
        Right (env0, parsedUnisonFile) -> do
          let
            (Result notes' r) =
              FileParsers.synthesizeFile B.typeLookup B.names parsedUnisonFile
            showNote notes =
              intercalateMap "\n\n" (show . renderNoteAsANSI env0 source) notes
          putStrLn . showNote . toList $ notes'
          case r of
            Nothing -> do
              Console.setTitle "Unison \128721"
              pure () -- just await next change
            Just typecheckedUnisonFile -> do
              Console.setTitle "Unison ✅"
              putStrLn
                "✅  Typechecked! Any watch expressions (lines starting with `>`) are shown below.\n"
              void $ RT.evaluate runtime (UF.discardTypes' typecheckedUnisonFile) codebase
  (`finally` RT.terminate runtime) $ do
    case initialFile of
      Just sourceFile -> do
        contents <- Data.Text.IO.readFile sourceFile
        go sourceFile contents
      Nothing -> pure ()
    forever $ do
      (sourceFile, contents) <- d
      go sourceFile contents
