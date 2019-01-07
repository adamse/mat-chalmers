{-# LANGUAGE BangPatterns, LambdaCase, OverloadedStrings, TemplateHaskell #-}

module Main
  ( main
  )
where

import           Control.Concurrent                       ( MVar
                                                          , forkIO
                                                          , newMVar
                                                          , threadDelay
                                                          , tryPutMVar
                                                          )
import           Control.Monad                            ( forever )
import           Control.Monad.Log                        ( defaultBatchingOptions
                                                          , renderWithTimestamp
                                                          , runLoggingT
                                                          , withFDHandler
                                                          )
import           Control.Monad.Reader                     ( runReaderT )
import           Control.Monad.Trans                      ( liftIO )
import           Data.FileEmbed                           ( embedDir )
import           Data.IORef                               ( IORef
                                                          , readIORef
                                                          )
import           Data.Time.Format                         ( defaultTimeLocale
                                                          , formatTime
                                                          , iso8601DateFormat
                                                          )
import           Lens.Micro.Platform                      ( (<&>)
                                                          , set
                                                          , view
                                                          )
import           Network.HTTP.Client.TLS                  ( newTlsManager )
import           Network.Wai.Middleware.RequestLogger     ( logStdout )
import           Network.Wai.Middleware.StaticEmbedded    ( static )
import           System.Console.GetOpt                    ( ArgDescr(..)
                                                          , ArgOrder(..)
                                                          , OptDescr(..)
                                                          , getOpt
                                                          , usageInfo
                                                          )
import           System.Environment                       ( getArgs )
import           System.IO                                ( IOMode(AppendMode)
                                                          , openFile
                                                          )
import           Web.Scotty                               ( get
                                                          , html
                                                          , middleware
                                                          , redirect
                                                          , scotty
                                                          )

import           Config
import           Model
import           Model.Types                              ( ClientContext(..) )
import           View                                     ( render )

opts :: [OptDescr (Config -> Config)]
opts =
  [ Option [] ["help"]    (NoArg (set cHelp True))           "Show usage info"
  , Option [] ["port"]    (ReqArg (set cPort . read) "PORT") "Port to run on"
  , Option [] ["logfile"] (ReqArg (set cLog) "LOGFILE")      "Path to logfile."
  , Option []
           ["interval"]
           (ReqArg (set cInterval . (1000000 *) . read) "INTERVAL (s)")
           "Update interval"
  ]

main :: IO ()
main =
  getArgs
    <&> getOpt Permute opts
    >>= \case
          (_     , _    , _ : _) -> usage
          (_     , _ : _, _    ) -> usage
          (!confs, _    , _    ) -> do
            let config = foldl (flip id) defaultConfig confs
            if view cHelp config
              then usage
              else do
                upd                      <- newMVar () -- putMVar when to update
                mgr                      <- newTlsManager
                logHandle <- openFile (view cLog config) AppendMode
                (viewRef, refreshAction) <- runLoggingT
                  (runReaderT refresh (ClientContext config mgr))
                  print
                -- updater thread
                forkIO
                  . forever
                  $ withFDHandler defaultBatchingOptions logHandle 1.0 80
                  $ \logToHandle ->
                      runReaderT (refreshAction upd) (ClientContext config mgr)
                        `runLoggingT` ( logToHandle
                                      . renderWithTimestamp
                                          (formatTime
                                            defaultTimeLocale
                                            (iso8601DateFormat
                                              (Just "%H:%M:%S")
                                            )
                                          )
                                          id
                                      )
                -- timer thread
                forkIO . forever $ tryPutMVar upd () >> threadDelay
                  (view cInterval config)
                -- Web server thread
                serve config viewRef upd
  where usage = putStrLn $ usageInfo "mat-chalmers [OPTION...]" opts

serve
  :: Config
  -> IORef View -- ^ View model
  -> MVar () -- ^ Update signal
  -> IO ()
serve conf viewRef upd = scotty (view cPort conf) $ do
  middleware logStdout
  middleware (static $(embedDir "static"))
  get "/"  ((html . render) =<< liftIO (readIORef viewRef))
  get "/r" (liftIO (tryPutMVar upd ()) >> redirect "/") -- force update

