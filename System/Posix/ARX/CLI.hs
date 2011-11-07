{-# LANGUAGE OverloadedStrings
           , TupleSections
           , StandaloneDeriving #-}

module System.Posix.ARX.CLI where

import Control.Applicative hiding (many)
import Control.Monad
import Data.ByteString (ByteString)
import qualified Data.ByteString as Bytes
import qualified Data.ByteString.Char8 as Char8
import qualified Data.ByteString.Lazy as LazyB
import Data.Either
import Data.List
import Data.Maybe
import Data.Monoid
import Data.Ord
import Data.Word
import System.Environment
import System.Exit

import qualified Blaze.ByteString.Builder as Blaze
import Text.Parsec hiding (satisfy, (<|>))

import System.Posix.ARX.CLI.CLTokens (Class(..))
import qualified System.Posix.ARX.CLI.CLTokens as CLTokens
import System.Posix.ARX.CLI.Options
import System.Posix.ARX.Programs
import qualified System.Posix.ARX.Sh as Sh
import System.Posix.ARX.Tar


main                         =  do
  args                      <-  (Char8.pack <$>) <$> getArgs
  case parse arx "<args>" args of
    Left _                  ->  do
      putStrLn "Argument error."
      exitSuccess
    Right (Left shdatArgs)  ->  do
      let (size, out, ins)   =  shdatResolve shdatArgs
      case shdatCheckStreams ins of Nothing  -> return ()
                                    Just err -> do Char8.putStrLn err
                                                   exitFailure
      let apply i            =  interpret (SHDAT size) <$> inIOStream i
      mapM_ ((send out =<<) . apply) ins
    Right (Right tmpxArgs)  ->  do
      let (size, out, ins, tars, env, (rm0, rm1), cmd) = tmpxResolve tmpxArgs
      (ins /= []) `when` do Char8.putStrLn pUnsupported
                            exitFailure
      case tmpxCheckStreams tars cmd of Nothing  -> return ()
                                        Just err -> do Char8.putStrLn err
                                                       exitFailure
      cmd'                  <-  openByteSource cmd
      let tmpx               =  TMPX (SHDAT size) cmd' env rm0 rm1
      (badAr, goodAr)       <-  partitionEithers <$> mapM openArchive tars
      (badAr /= []) `when` do (((Char8.putStrLn .) .) . blockMessage)
                                "The file magic of some archives:"
                                badAr
                                "could not be interpreted."
                              exitFailure
      send out (interpret tmpx goodAr)
 where
  arx                        =  Left <$> shdat <|> Right <$> tmpx
  name STDIO                 =  "-"
  name (Path b)              =  b
  pUnsupported = "Paths to archive are not supported in this version of tmpx."
  send o b                   =  (outIOStream o . Blaze.toLazyByteString) b
  openArchive io             =  do r <- arIOStream io
                                   return $ case r of Nothing -> Left (name io)
                                                      Just x  -> Right x

{-| Apply defaulting and overrides appropriate to 'SHDAT' programs.
 -}
shdatResolve                ::  ([Word], [IOStream], [IOStream])
                            ->  (Word, IOStream, [IOStream])
shdatResolve (sizes, outs, ins) = (size, out, ins')
 where
  size                       =  last (defaultBlock:sizes)
  out                        =  last (STDIO:outs)
  ins' | ins == []           =  [STDIO]
       | otherwise           =  ins

shdatCheckStreams           ::  [IOStream] -> Maybe ByteString
shdatCheckStreams ins        =  streamsMessage [ins']
 where
  ins'                       =  case [ x == STDIO | x <- ins ] of
      []                    ->  Zero
      [_]                   ->  One "as a file input"
      _:_:_                 ->  Many ["more than once as a file input"]


{-| Apply defaulting and overrides appropriate to 'TMPX' programs.
 -}
tmpxResolve :: ( [Word], [IOStream], [ByteString], [IOStream],
                 [(Sh.Var, Sh.Val)], [(Bool, Bool)], [ByteSource]  )
            -> ( Word, IOStream, [ByteString], [IOStream],
                 [(Sh.Var, Sh.Val)], (Bool, Bool), ByteSource  )
tmpxResolve (sizes, outs, ins, tars, env, rms, cmds) =
  (size, out, ins, tarsWithDefaulting, env, rm, cmd)
 where
  size                       =  last (defaultBlock:sizes)
  out                        =  last (STDIO:outs)
  rm                         =  last ((True,True):rms)
  cmd                        =  last (defaultTask:cmds)
  tarsWithDefaulting
    | ins == [] && tars == [] = [STDIO]
    | otherwise              =  tars

tmpxCheckStreams            ::  [IOStream] -> ByteSource -> Maybe ByteString
tmpxCheckStreams tars cmd    =  streamsMessage [tars', cmd']
 where
  tars'                      =  case [ x == STDIO | x <- tars ] of
      []                    ->  Zero
      [_]                   ->  One "as an archive input"
      _:_:_                 ->  Many ["more than once as an archive input"]
  cmd'
    | cmd == IOStream STDIO  =  One "as a command input"
    | otherwise              =  Zero

tmpxOpen :: Word -> [(Sh.Var, Sh.Val)] -> (Bool, Bool) -> ByteSource -> IO TMPX
tmpxOpen size env (rm0, rm1) cmd = do
  text                      <-  case cmd of
    ByteString b            ->  return (LazyB.fromChunks [b])
    IOStream STDIO          ->  LazyB.getContents
    IOStream (Path b)       ->  LazyB.readFile (Char8.unpack b)
  return (TMPX (SHDAT size) text env rm0 rm1)


openByteSource              ::  ByteSource -> IO LazyB.ByteString
openByteSource source        =  case source of
    ByteString b            ->  return (LazyB.fromChunks [b])
    IOStream STDIO          ->  LazyB.getContents
    IOStream (Path b)       ->  LazyB.readFile (Char8.unpack b)

inIOStream STDIO             =  LazyB.getContents
inIOStream (Path b)          =  LazyB.readFile (Char8.unpack b)

outIOStream STDIO            =  LazyB.putStr
outIOStream (Path b)         =  LazyB.writeFile (Char8.unpack b)

arIOStream                  ::  IOStream -> IO (Maybe (Tar, LazyB.ByteString))
arIOStream io                =  do opened <- inIOStream io
                                   return ((,opened) <$> magic opened)


{-| By default, we encode binary data to HERE docs 4MiB at a time. (The
    encoded result may be up to 10% larger, though 1% is more likely.)
 -}
defaultBlock                ::  Word
defaultBlock                 =  0x400000

{-| The default task is a no-op call to @/bin/true@.
 -}
defaultTask                 ::  ByteSource
defaultTask                  =  ByteString "/bin/true"


data ZOM                     =  Zero | One !ByteString | Many ![ByteString]
instance Monoid ZOM where
  mempty                     =  Zero
  Zero    `mappend` x        =  x
  x       `mappend` Zero     =  x
  One m   `mappend` One m'   =  Many [m, m']
  One m   `mappend` Many ms  =  Many (mappend [m] ms)
  Many ms `mappend` One m    =  Many (mappend ms  [m])
  Many ms `mappend` Many ms' =  Many (mappend ms  ms')

streamsMessage filtered      =  case foldl' mappend Zero filtered of
  Many messages             ->  Just (template messages)
  _                         ->  Nothing
 where
  template clauses           =  blockMessage
                                  "STDIN is specified multiple times:"
                                  clauses
                                  "but restreaming STDIN is not supported."

blockMessage a bs c          =  Char8.unlines
  [a, Bytes.intercalate ",\n" (mappend "  " <$> bs), c]
