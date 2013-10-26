module Graphics.UI.Lambency (
  makeWindow,
  destroyWindow,
  run
  ) where

--------------------------------------------------------------------------------

import qualified Graphics.UI.GLFW as GLFW
import qualified Graphics.Rendering.OpenGL as GL

import qualified Graphics.Rendering.Lambency as LR

import Control.Applicative
import Control.Monad (unless)

--------------------------------------------------------------------------------

makeWindow :: Int -> Int -> String -> IO (Maybe GLFW.Window)
makeWindow width height title = do
  r <- GLFW.init
  unless r $ return ()
  m <- GLFW.createWindow width height title Nothing Nothing
  LR.initLambency
  case m of
    Nothing -> return ()
    (Just _) -> GLFW.makeContextCurrent m
  return m

destroyWindow :: Maybe GLFW.Window -> IO ()
destroyWindow m = do
  case m of
    (Just win) -> do
      GLFW.destroyWindow win
    Nothing -> return ()
  GLFW.terminate  

run :: GLFW.Window -> [ LR.RenderObject ] -> IO ()
run win objs = do
  GLFW.pollEvents
  keyState <- GLFW.getKey win GLFW.Key'Q
  case keyState of
    GLFW.KeyState'Pressed -> GLFW.setWindowShouldClose win True
    _ -> return ()
  GL.clearColor GL.$= GL.Color4 0.0 0.0 0.5 1
  GL.clear [GL.ColorBuffer]
  sequence_ $ LR.render <$> objs
  GL.flush
  GLFW.swapBuffers win
  q <- GLFW.windowShouldClose win
  unless q $ run win objs