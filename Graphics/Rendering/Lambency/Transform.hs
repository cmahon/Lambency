module Graphics.Rendering.Lambency.Transform (
  Transform(..), identityXForm,
  localRight, localUp, localForward,

  rotate, rotateWorld, translate, uniformScale,
  
  xform2Matrix,
) where

--------------------------------------------------------------------------------

import Graphics.Rendering.Lambency.Utils

import Data.Vect.Float
import Data.Vect.Float.Util.Quaternion

import Data.Function (on)

--------------------------------------------------------------------------------

-- A Transform consists of a right vector, an up vector, a forward vector, a
-- position in world space, and a scaling vector.
data Transform = XForm {
  right :: Normal3,
  up :: Normal3,
  forward :: Normal3,
  position :: Vec3,
  scale :: Vec3
} deriving (Show)

instance Eq Transform where
  a == b =
    (&&) ((compareClose `on` right) a b) $
    (&&) ((compareClose `on` up) a b) $
    (&&) ((compareClose `on` forward) a b) $
    (&&) ((compareClose `on` position) a b) $
    (compareClose `on` scale) a b

localRight :: Normal3
localRight = toNormalUnsafe vec3X

localUp :: Normal3
localUp = toNormalUnsafe vec3Y

localForward :: Normal3
localForward = toNormalUnsafe vec3Z

identityXForm :: Transform
identityXForm = XForm {
  right = localRight,
  up = localUp,
  forward = localForward,
  position = zero,
  scale = Vec3 1 1 1
}

updateAxis :: Normal3 -> Normal3 -> Normal3 -> Transform -> Transform
updateAxis nr nu nf =
  (\xf -> xf { up = nu }) .
  (\xf -> xf { forward = nf }) .
  (\xf -> xf { right = nr })

renormalize :: Transform -> Transform
renormalize xf = updateAxis (right xf) u' f' xf
  where f' = (right xf) &^ (up xf)
        u' = f' &^ (right xf)

-- Rotates the coordinate axis of the transform by the given quaternion. This
-- function performs a local rotation
rotate :: UnitQuaternion -> Transform -> Transform
rotate quat xf = let
  fn :: Normal3 -> Normal3
  fn = toNormalUnsafe . (actU quat) . fromNormal
  in updateAxis (fn $ right xf) (fn $ up xf) (fn $ forward xf) xf

rotateWorld :: UnitQuaternion -> Transform -> Transform
rotateWorld quat xf = let

  r = right xf
  u = up xf
  f = forward xf
  
  invWorldMat :: Mat3
  invWorldMat = Mat3 (fromNormal r) (fromNormal u) (fromNormal f)

  worldMat :: Mat3
  worldMat = transpose invWorldMat

  rotateAxis :: Normal3 -> Normal3
  rotateAxis = mkNormal . (worldMat *.) . (actU quat) . (invWorldMat *.) . fromNormal

  in
   renormalize $ updateAxis (rotateAxis r) (rotateAxis u) (rotateAxis f) xf
  

uniformScale :: Float -> Transform -> Transform
uniformScale s = \xf -> xf { scale = (Vec3 s s s) }

translate :: Vec3 -> Transform -> Transform
translate t xf' = (\xf -> xf { position = t &+ (position xf') }) xf'

-- Returns a matrix where that transforms a coordinate space such that the
-- new coordinate system's origin is located at the value of 'p' of the old
-- coordinate space, and the three axes that define forward up and right are
-- now the basis in Z, Y, and X respectively.
xform2Matrix :: Transform -> Mat4
xform2Matrix xf =
  let te n sc = extendWith ((position xf) &. (fromNormal n)) (sc (scale xf) *& (fromNormal n))
  in transpose $ Mat4 (te (right xf) _1) (te (up xf) _2) (te (forward xf) _3) (Vec4 0 0 0 1)