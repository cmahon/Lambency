module Lambency (
  initLambency,
  module Lambency.Bounds,
  module Lambency.Camera,
  module Lambency.Font,
  module Lambency.GameObject,
  module Lambency.Light,
  module Lambency.Loaders,  
  module Lambency.Material,
  Mesh, triangle, cube, plane, quad,
  module Lambency.Render,
  module Lambency.Shader,
  module Lambency.Sprite,
  module Lambency.Texture,
  module Lambency.Transform,
  Camera, CameraType, CameraViewDistance,
  LightType, Light,
  ShaderValue(..), ShaderMap,
  Material,
  RenderFlag(..), RenderObject(..),
  OutputAction(..),
  TimeStep,
  Game(..), GameWire, GameMonad,
  module Lambency.Utils,

  makeWindow, destroyWindow, run, runWindow,
  quitWire,
  module Lambency.Sound
) where

--------------------------------------------------------------------------------

import qualified Graphics.UI.GLFW as GLFW
import qualified Graphics.Rendering.OpenGL as GL

import Lambency.Bounds
import Lambency.Camera
import Lambency.Font
import Lambency.GameObject
import Lambency.Light
import Lambency.Loaders
import Lambency.Material
import Lambency.Mesh
import Lambency.Render
import Lambency.Shader
import Lambency.Sound
import Lambency.Sprite
import Lambency.Texture
import Lambency.Transform
import Lambency.Types
import Lambency.Utils

import Control.Applicative
import Control.Monad.RWS.Strict
import Control.Monad.Reader
import Control.Monad.State
import qualified Control.Wire as W

import Data.Time

import GHC.Float

import FRP.Netwire.Input
import FRP.Netwire.Input.GLFW
--------------------------------------------------------------------------------

initLambency :: IO ()
initLambency = do
  putStrLn "Initializing..."
  printInfo GL.vendor "Vendor: "
  printInfo GL.renderer "Renderer: "
  printInfo GL.glVersion "OpenGL Version: "
  printInfo GL.shadingLanguageVersion "GLSL Version: "
  -- (mapM_ putStrLn) =<< (GL.get GL.glExtensions)
  putStrLn "Done initializing..."
  where
    printInfo :: (GL.GettableStateVar String) -> String -> IO ()
    printInfo sv s = (=<<) (putStrLn . ((++) s)) $ GL.get sv

errorCallback :: GLFW.Error -> String -> IO()
errorCallback e s = putStrLn $ "GLFW Error: " ++ (show e ++ s)

makeWindow :: Int -> Int -> String -> IO (Maybe GLFW.Window)
makeWindow width height title = do
  putStr "Initializing GLFW..."
  r <- GLFW.init
  if not r then ioError (userError "Failed!") else return ()
  putStrLn "Done"

  GLFW.setErrorCallback $ Just errorCallback
  putStr $ "Creating window of size (" ++ (show width) ++ ", " ++ (show height) ++ ")..."
  GLFW.windowHint $ GLFW.WindowHint'Samples 4
  jm <- GLFW.createWindow width height title Nothing Nothing
  m <- case jm of
    Nothing -> ioError (userError "Failed!")
    Just m' -> return m'
  putStrLn "Done."

  GLFW.makeContextCurrent (Just m)

  -- Implement the viewport size to be the framebuffer size
  -- in order to properly deal with retina displays...
  -- !FIXME! The user should have some say over this
  (szx, szy) <- GLFW.getFramebufferSize m
  GL.viewport GL.$= (GL.Position 0 0, GL.Size (fromIntegral szx) (fromIntegral szy))

  -- Initial defaults
  GL.blend GL.$= GL.Enabled
  GL.blendFunc GL.$= (GL.SrcAlpha, GL.OneMinusSrcAlpha)
  GL.cullFace GL.$= Just GL.Back
  initLambency
  initSound
  GL.dither GL.$= GL.Disabled

  -- !FIXME! Why is this Maybe?
  return (Just m)

destroyWindow :: Maybe GLFW.Window -> IO ()
destroyWindow m = do
  case m of
    (Just win) -> do
      GLFW.destroyWindow win
    Nothing -> return ()
  GLFW.terminate
  freeSound

-- The physics framerate in frames per second
physicsDeltaTime :: Double
physicsDeltaTime = 1.0 / 60.0

physicsDeltaUTC :: NominalDiffTime
physicsDeltaUTC = fromRational . toRational $ physicsDeltaTime

playSounds :: [OutputAction] -> IO ([OutputAction])
playSounds [] = return []
playSounds (SoundAction sound cmd : rest) = handleCommand sound cmd >> return rest
playSounds (act : acts) = pure (act :) <*> playSounds acts

printLogs :: [OutputAction] -> IO ([OutputAction])
printLogs [] = return []
printLogs (LogAction s : rest) = putStrLn s >> printLogs rest
printLogs (act : acts) = pure (act :) <*> printLogs acts

-- When we handle actions, only really print logs and play any sounds
-- that may need to start or stop.
handleActions :: [OutputAction] -> IO ()
handleActions actions =
  foldM_ (\acts f -> f acts) actions [
    printLogs,
    playSounds
  ]

step :: a -> Game a -> TimeStep -> GameMonad (Either String a, Camera, [Light], Game a)
step go game t = do
  (Right cam, nCamWire) <- W.stepWire (mainCamera game) t (Right ())
  (result, gameWire) <- W.stepWire (gameLogic game) t (Right go)
  lightObjs <- mapM (\w -> W.stepWire w t $ Right ()) (dynamicLights game)
  let (lights, lwires) = collect lightObjs
  return (result, cam, lights ++ (staticLights game), newGame nCamWire lwires gameWire)
    where
      collect :: [(Either e b, GameWire a b)] -> ([b], [GameWire a b])
      collect [] = ([], [])
      collect ((Left _, _) : rest) = collect rest
      collect ((Right obj, wire) : rest) = (obj : objs, wire : wires)
        where
          (objs, wires) = collect rest

      newGame cam lights logic = game {
        mainCamera = cam,
        dynamicLights = lights,
        gameLogic = logic}

type GameLoopM a =
  -- Reader
  ReaderT (RenderConfig, GLFWInputControl, GLFW.Window) (
  -- State  (gameObject, logic, session and time)
  StateT (a, Game a, GameSession, NominalDiffTime) IO)

runLoop :: UTCTime -> GameLoopM a ()
runLoop lastFrameTime = do
  (_, _, _, accumulator) <- get
  -- Step
  thisFrameTime <- liftIO getCurrentTime
  let newAccum = accumulator + (diffUTCTime thisFrameTime lastFrameTime)
  modify $ \(o, l, s, _) -> (o, l, s, newAccum)
  (go, (nextsession, accum), (nextGame, _)) <- stepGame emptyRenderActions

  case go of
    Right gobj -> do
      put (gobj, nextGame, nextsession, accum)
      runLoop thisFrameTime
    Left _ -> return ()

type TimeStepper = (GameSession, NominalDiffTime)
type StateStepper a = (Game a, GameState)

stepGame :: GameState -> GameLoopM a (Either String a, TimeStepper, StateStepper a)
stepGame gs = do
  (go, game, session, accum) <- get
  if (accum < physicsDeltaUTC)
    then return (Right go, (session, accum), (game, gs))
    else runGame gs

runGame :: GameState -> GameLoopM a (Either String a, TimeStepper, StateStepper a)
runGame gs = do

  (rcfg, ictl, win) <- ask
  (go, g, sess, accum) <- get

  ipt <- liftIO $ getInput ictl

  -- Retreive the next time step from our game session
  (ts, nextSess) <- liftIO $ W.stepSession sess

  let
    -- The game step is the complete GameMonad computation that
    -- produces four values: Either inhibition or a new game value
    -- A new camera, a list of dynamic lights, and the next simulation
    -- wire
    gameStep = step go g ts

    -- In order to get at the underlying RWS monad, let's create an
    -- RWS program that works with the passed in input.
    -- rwsPrg :: RWS () [OutputAction] RenderAction
    --           ((Either () a, Camera, [Light], Game a), GLFWInputState)
    rwsPrg = runStateT gameStep ipt

    -- This is the meat of the step routine. This calls runRWS on the
    -- main game wire, and uses the results to figure out what needs
    -- to be done.
    (((result, cam, lights, nextGame), newIpt), newGS, actions) = runRWS rwsPrg () gs

    -- We need to render if we're going to fall below the physics threshold
    -- on the next frame. This simulates a while loop. If we don't fall
    -- through this threshold, we will perform another physics step before
    -- we finally decide to render.
    needsRender = ((accum - physicsDeltaUTC) < physicsDeltaUTC)

    -- If we do render, we need to build the renderObjects and their
    -- corresponding renderActions from the static geometry. These won't
    -- get built or evaluated unless we actually render though.
    sgRAs = map (uncurry xformObject) (staticGeometry g)

    -- The ReaderT RenderConfig IO program that will do the actual rendering
    renderPrg = performRenderActions lights cam $
                newGS { renderScene = RenderCons (RenderObjects sgRAs) (renderScene newGS) }

  if needsRender
    then liftIO $ do
      -- !FIXME! This should be moved to the camera...
      GL.clearColor GL.$= GL.Color4 0.0 0.0 0.0 1
      clearBuffers
      _ <- evalRWST renderPrg rcfg identity
      GL.flush
      GLFW.swapBuffers win
    else return ()

  _ <- liftIO $ do
    -- Actually do the associated actions
    handleActions actions

    -- Poll the input
    pollGLFW newIpt ictl

  -- If our main wire inhibited, return immediately.
  case result of
    Right obj -> do
      put (obj, nextGame, nextSess, (accum - physicsDeltaUTC))
      stepGame emptyRenderActions
    Left _ -> return (result, (nextSess, accum), (nextGame, gs))

run :: GLFW.Window -> a -> Game a -> IO ()
run win initialGameObject initialGame = do
  GLFW.swapInterval 1
  ictl <- mkInputControl win
  let session = W.countSession (double2Float physicsDeltaTime) W.<*> W.pure ()
  curTime <- getCurrentTime

  -- Create our rendering config
  renderCfg <- mkRenderConfig

  -- Stick in an initial poll events call...
  GLFW.pollEvents

  let statePrg = runReaderT (runLoop curTime) (renderCfg, ictl, win)
  evalStateT statePrg (initialGameObject, initialGame, session, toEnum 0)
  
runWindow :: Int -> Int -> String -> a -> IO (Game a) -> IO ()
runWindow width height title initialGameObject loadGamePrg = do
  Just win <- makeWindow width height title
  loadGamePrg >>= run win initialGameObject
  destroyWindow (Just win)

-- Wire that behaves like the identity wire until the given key
-- is pressed, then inhibits forever.
quitWire :: GLFW.Key -> GameWire a a
quitWire key =
  (W.mkId W.&&& ((keyPressed key W.>>> W.pure W.mkEmpty W.>>> W.now) W.<|> W.never)) W.>>>
  (W.rSwitch W.mkId)
