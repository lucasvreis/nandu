{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Ema.App
  ( runEma,
    runEmaPure,
    runEmaWith,
    Ema (..),
  )
where

import Control.Concurrent.Async (race_)
import Data.LVar (LVar)
import qualified Data.LVar as LVar
import Ema.CLI (Action (..))
import qualified Ema.CLI as CLI
import Ema.Class (Ema (..))
import qualified Ema.Generate as Generate
import qualified Ema.Server as Server
import GHC.IO.Handle (BufferMode (LineBuffering), hSetBuffering)
import System.Environment (lookupEnv)

-- | Pure version of @runEmaWith@ (i.e with no model).
--
-- Due to purity, there is no impure state, and thus no time-varying model.
-- Neither is there a concept of route, as only a single route (index.html) is
-- expected, whose HTML contents is specified as the only argument to this
-- function.
runEmaPure ::
  -- | How to render a route
  LByteString ->
  IO ()
runEmaPure html = do
  action <- CLI.cliAction
  emptyModel <- LVar.new ()
  runEmaWith @() action emptyModel (\() () -> html)

-- | Convenient version of @runEmaWith@ that takes initial model and an update
-- function. You typically want to use this.
--
-- It uses @race_@ to properly clean up the update action when the ema thread
-- exits, and vice-versa.
runEma ::
  forall model route.
  (Ema model route, Show route) =>
  -- | How to render a route, given the model
  (model -> route -> LByteString) ->
  -- | A long-running IO action that will update the @model@ @LVar@ over time.
  -- This IO action must set the initial model value in the very beginning.
  (LVar model -> IO ()) ->
  IO ()
runEma render runModel = do
  action <- CLI.cliAction
  model <- LVar.empty
  race_
    (runModel model)
    (runEmaWith action model render)

-- | Run Ema live dev server
runEmaWith ::
  forall model route.
  (Ema model route, Show route) =>
  -- | CLI Action
  Action ->
  -- | Your site model type, as a @LVar@ in order to support modifications over
  -- time (for hot-reload).
  --
  -- Use @Data.LVar.new@ to create it, and then -- over time -- @Data.LVar.set@
  -- or @Data.LVar.modify@ to modify it. Ema will automatically hot-reload your
  -- site as this model data changes.
  LVar model ->
  -- | Your site render function. Takes the current @model@ value, and the page
  -- @route@ type as arguments. It must return the raw HTML to render to browser
  -- or generate on disk.
  (model -> route -> LByteString) ->
  IO ()
runEmaWith action model render = do
  -- TODO: Use a logging library, in place of managing buffering and using putStrLn
  hSetBuffering stdout LineBuffering
  hSetBuffering stderr LineBuffering
  putStrLn "Waiting for initial site model ..."
  putStrLn "  stuck here? set a model value using `LVar.set`"
  case action of
    Generate dest -> do
      val <- LVar.get model
      Generate.generate dest val render
    Run -> do
      void $ LVar.get model
      port <- fromMaybe 8000 . (readMaybe @Int =<<) <$> lookupEnv "PORT"
      putStrLn $ "Launching Ema at http://localhost:" <> show port
      Server.runServerWithWebSocketHotReload port model render
