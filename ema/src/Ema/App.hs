{-# LANGUAGE AllowAmbiguousTypes #-}

module Ema.App (
  SiteConfig (..),
  runSite,
  runSite_,
  runSiteWith,
) where

import Colog (logInfo, logWarning)
import Data.Default (Default, def)
import Data.LVar qualified as LVar
import Ema.CLI (getLogger, usingAppM)
import Ema.CLI qualified as CLI
import Ema.Dynamic (Dynamic (Dynamic))
import Ema.Generate (generateSiteFromModel)
import Ema.Route.Class (IsRoute (RouteModel))
import Ema.Server qualified as Server
import Ema.Site (EmaSite (SiteArg, siteInput), EmaStaticSite)
import System.Directory (getCurrentDirectory)
import UnliftIO.Async (concurrently_)

data SiteConfig r = SiteConfig
  { siteConfigCli :: CLI.Cli
  , siteConfigWebSocketOptions :: Server.EmaWebSocketOptions r
  }

instance Default (SiteConfig r) where
  def =
    SiteConfig
      { siteConfigCli = def
      , siteConfigWebSocketOptions = def
      }

{- | Run the given Ema site,

  Takes as argument the associated `SiteArg`.

  In generate mode, return the generated files.  In live-server mode, this
  function will never return.
-}
runSite ::
  forall r.
  (Show r, Eq r, EmaStaticSite r) =>
  -- | The input required to create the `Dynamic` of the `RouteModel`
  SiteArg r ->
  IO (FilePath, [FilePath])
runSite input = do
  cli <- CLI.cliAction
  let cfg = SiteConfig cli def
  snd <$> runSiteWith @r cfg input

-- | Like @runSite@ but discards the result
runSite_ :: forall r. (Show r, Eq r, EmaStaticSite r) => SiteArg r -> IO ()
runSite_ = void . runSite @r

{- | Like @runSite@ but takes custom @SiteConfig@.

 Useful if you are handling the CLI arguments yourself and/or customizing the
 server websocket handler.

 Use "void $ Ema.runSiteWith def ..." if you are running live-server only.
-}
runSiteWith ::
  forall r.
  (Show r, Eq r, EmaStaticSite r) =>
  SiteConfig r ->
  SiteArg r ->
  IO
    ( -- The initial model value.
      RouteModel r
    , -- Out path, and the list of statically generated files
      (FilePath, [FilePath])
    )
runSiteWith cfg siteArg = do
  let opts = siteConfigWebSocketOptions cfg
      cli = siteConfigCli cfg
  usingAppM (getLogger cli) $ do
    cwd <- liftIO getCurrentDirectory
    logInfo $ "Launching Ema under: " <> toText cwd
    Dynamic (model0 :: RouteModel r, cont) <- siteInput @r (CLI.action cli) siteArg
    case CLI.action cli of
      CLI.Generate dest -> do
        fs <- generateSiteFromModel @r dest model0
        pure (model0, (dest, fs))
      CLI.Run (host, mport, CLI.unNoWebSocket -> noWebSocket) -> do
        model <- LVar.new model0
        let mWsOpts = if noWebSocket then Nothing else Just opts
        concurrently_
          ( cont (LVar.set model)
              >> logWarning "modelPatcher exited; no more model updates!"
          )
          (Server.runServerWithWebSocketHotReload @r mWsOpts host mport model)
        CLI.crash "Live server unexpectedly stopped"
