{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main where

import           Data.ByteString.Char8 (ByteString)
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy.Char8 as L
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Maybe
import qualified Data.Text as T
import           Control.Applicative
import           Control.Concurrent
import           Control.Exception (evaluate, throwIO, SomeException)
import           Control.Monad
import           Control.Monad.CatchIO
import           Control.Monad.Trans
import           Data.Typeable
import           Prelude hiding (catch)
import           Snap.Http.Server
import           Snap.Types
import           Snap.Util.FileServe
import           Snap.Util.GZip
import           System
import           System.Directory
import           System.Posix.Env
import           System.Exit
import           System.IO
import           System.Process
import           Text.Templating.Heist
import qualified Text.XHtmlCombinators.Escape as XH
import           Text.XML.Expat.Tree hiding (Node)


setLocaleToUTF8 :: IO ()
setLocaleToUTF8 = do
    mapM_ (\k -> setEnv k "en_US.UTF-8" True)
          [ "LANG"
          , "LC_CTYPE"
          , "LC_NUMERIC"
          , "LC_TIME"
          , "LC_COLLATE"
          , "LC_MONETARY"
          , "LC_MESSAGES"
          , "LC_PAPER"
          , "LC_NAME"
          , "LC_ADDRESS"
          , "LC_TELEPHONE"
          , "LC_MEASUREMENT"
          , "LC_IDENTIFICATION"
          , "LC_ALL" ]


renderTmpl :: MVar (TemplateState Snap)
           -> ByteString
           -> Snap ()
renderTmpl tsMVar n = do
    ts <- liftIO $ readMVar tsMVar
    maybe pass writeBS =<< renderTemplate ts n


templateServe :: TemplateState Snap
              -> MVar (TemplateState Snap)
              -> MVar (Map ByteString [Node])
              -> Snap ()
templateServe orig tsMVar staticMVar = do
    p
    modifyResponse $ setContentType "text/html"

  where
    p = ifTop (renderTmpl tsMVar "index") <|>
        path "admin/reload" (reloadTemplates orig tsMVar staticMVar) <|>
        (renderTmpl tsMVar . B.pack =<< getSafePath)


loadError :: String -> String
loadError str = "Error loading templates\n"++str

reloadTemplates :: TemplateState Snap
                -> MVar (TemplateState Snap)
                -> MVar (Map ByteString [Node])
                -> Snap ()
reloadTemplates origTs tsMVar staticMVar = do
    liftIO $ modifyMVar_ staticMVar (const $ return Map.empty)
    ts <- liftIO $ loadTemplates "templates" origTs
    either bad good ts
  where
    bad msg = do writeBS $ B.pack $ loadError msg ++ "Keeping old templates."
    good ts = do liftIO $ modifyMVar_ tsMVar (const $ bindMarkdownTag ts)
                 writeBS "Templates loaded successfully"


site :: TemplateState Snap
     -> MVar (TemplateState Snap)
     -> MVar (Map ByteString [Node])
     -> Snap ()
site origTs tsMVar staticMVar =
    catch500 $ withCompression hndl

  where
    hndl = route [ ("docs/api", apidoc tsMVar) ] <|> fallThru

    fallThru = templateServe origTs tsMVar staticMVar
               <|> fileServe "static"


catch500 :: Snap a -> Snap ()
catch500 m = (m >> return ()) `catch` \(e::SomeException) -> do
    let t = T.pack $ show e
    putResponse r
    writeBS "<html><head><title>Internal Server Error</title></head>"
    writeBS "<body><h1>Internal Server Error</h1>"
    writeBS "<p>A web handler threw an exception. Details:</p>"
    writeBS "<pre>\n"
    writeText $ XH.escape t
    writeBS "\n</pre></body></html>"

  where
    r = setResponseStatus 500 "Internal Server Error" emptyResponse


bindMarkdownTag :: TemplateState Snap -> IO (TemplateState Snap)
bindMarkdownTag = return . bindSplice "markdown" markdownSplice


data PandocMissingException = PandocMissingException
   deriving (Typeable)

instance Show PandocMissingException where
    show PandocMissingException =
        "Cannot find the \"pandoc\" executable; is it on your $PATH?"

instance Exception PandocMissingException


data MarkdownException = MarkdownException L.ByteString
   deriving (Typeable)

instance Show MarkdownException where
    show (MarkdownException e) =
        "Markdown error: pandoc replied:\n\n" ++ L.unpack e

instance Exception MarkdownException


apidoc :: MVar (TemplateState Snap) -> Snap ()
apidoc mvar = do
    ts <- liftIO $ readMVar mvar
    -- remainder of pathInfo is the doc to lookup
    whichDoc <- liftM rqPathInfo getRequest

    title <- maybe pass return $ Map.lookup whichDoc titles
    let href = B.concat ["/docs/latest/", whichDoc, "/index.html"]

    let ts' = bindSplice "docframe" (docframe href) $
              bindSplice "subtitle" (return [mkText title]) ts

    maybe pass writeBS =<< renderTemplate ts' "docs/api"

  where
    titles = Map.fromList [ ("snap-core", ": snap-core APIs")
                          , ("snap-server", ": snap-server APIs")
                          , ("heist", ": heist APIs") ]

    docframe :: ByteString -> Splice Snap
    docframe src = return [ mkElement "frame" [ ("id" , "docframe")
                                              , ("src", src       ) ] [] ]



-- a version of readProcessWithExitCode that does I/O properly
readProcessWithExitCode'
    :: FilePath                 -- ^ command to run
    -> [String]                 -- ^ any arguments
    -> ByteString               -- ^ standard input
    -> IO (ExitCode,L.ByteString,L.ByteString) -- ^ exitcode, stdout, stderr
readProcessWithExitCode' cmd args input = do
    (Just inh, Just outh, Just errh, pid) <-
        createProcess (proc cmd args){ std_in  = CreatePipe,
                                       std_out = CreatePipe,
                                       std_err = CreatePipe }
    outMVar <- newEmptyMVar

    -- fork off a thread to start consuming stdout
    out <- L.hGetContents outh
    forkIO $ evaluate (L.length out) >> putMVar outMVar ()

    -- fork off a thread to start consuming stderr
    err  <- L.hGetContents errh
    forkIO $ evaluate (L.length err) >> putMVar outMVar ()

    -- now write and flush any input
    when (not (B.null input)) $ do B.hPutStr inh input; hFlush inh
    hClose inh -- done with stdin

    -- wait on the output
    takeMVar outMVar
    takeMVar outMVar
    hClose outh

    -- wait on the process
    ex <- waitForProcess pid

    return (ex, out, err)



pandoc :: FilePath -> FilePath -> IO ByteString
pandoc pandocPath inputFile = do
    (ex, sout, serr) <- readProcessWithExitCode' pandocPath args ""

    when (isFail ex) $ throw $ MarkdownException serr
    return $ B.concat $ L.toChunks
           $ L.concat [ "<div class=\"markdown\">\n"
                      , sout
                      , "\n</div>" ]

  where
    isFail ExitSuccess = False
    isFail _           = True

    -- FIXME: hardcoded path
    args = [ "-S", "--no-wrap", "templates/"++inputFile ]


pandocBS :: FilePath -> ByteString -> IO ByteString
pandocBS pandocPath s = do
    -- using the crummy string functions for convenience here
    (ex, sout, serr) <- readProcessWithExitCode' pandocPath args s

    when (isFail ex) $ throw $ MarkdownException serr
    return $ B.concat $ L.toChunks
           $ L.concat [ "<div class=\"markdown\">\n"
                      , sout
                      , "\n</div>" ]

  where
    isFail ExitSuccess = False
    isFail _           = True
    args = [ "-S", "--no-wrap" ]


markdownSplice :: Splice Snap
markdownSplice = do
    pdMD <- liftIO $ findExecutable "pandoc"

    when (isNothing pdMD) $ liftIO $ throwIO PandocMissingException

    tree <- getParamNode
    markup <- liftIO $
        case getAttribute tree "file" of
            Just f  -> pandoc (fromJust pdMD) $ B.unpack f
            Nothing -> pandocBS (fromJust pdMD) $ textContent tree

    let ee = parse' heistExpatOptions markup
    case ee of
      (Left e) -> throw $ MarkdownException
                        $ L.pack ("Error parsing markdown output: " ++ show e)
      (Right n) -> return [n]


-- FIXME: remove
killMe :: ThreadId -> Snap ()
killMe t = liftIO (exitSuccess >> killThread t)


main :: IO ()
main = do
    args   <- getArgs
    port   <- case args of
                []       -> error "You must specify a port!" >> exitFailure
                (port:_) -> return $ read port

    setLocaleToUTF8

    (origTs,staticMVar) <- (bindMarkdownTag >=> bindStaticTag) emptyTemplateState

    ets <- loadTemplates "templates" origTs
    let ts = either error id ets
    either (\s -> putStrLn (loadError s) >> exitFailure) (const $ return ()) ets
    tsMVar <- newMVar $ ts

    (try $ httpServe "*" port "achilles"
             (Just "access.log")
             (Just "error.log")
             (site origTs tsMVar staticMVar)) :: IO (Either SomeException ())

    threadDelay 1000000
    putStrLn "exiting"
    return ()

