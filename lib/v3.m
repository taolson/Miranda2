||  v3.m -- 3D vectors and associated operations


%export +

%import <lens>
%import <maybe>
%import <mirandaExtensions>


v3 * ::= V3 * * *

|| lenses for v3
viewV3_0 (V3 a b c) = a; overV3_0 fn (V3 a b c) = V3 (fn a) b c; lensV3_0 = Lens viewV3_0 overV3_0
viewV3_1 (V3 a b c) = b; overV3_1 fn (V3 a b c) = V3 a (fn b) c; lensV3_1 = Lens viewV3_1 overV3_1
viewV3_2 (V3 a b c) = c; overV3_2 fn (V3 a b c) = V3 a b (fn c); lensV3_2 = Lens viewV3_2 overV3_2


|| monad interface

v3_bind :: v3 * -> (* -> v3 **) -> v3 **
v3_bind (V3 a b c) f
    = V3 a' b' c'
      where
        V3 a' _  _  = f a
        V3 _  b' _  = f b
        V3 _  _  c' = f c

v3_pure :: * -> v3 *
v3_pure x = V3 x x x

v3_sequence :: [v3 *] -> v3 [*]
v3_sequence xs = foldr (v3_liftA2 (:)) (v3_pure []) xs


|| functor interface
v3_fmap :: (* -> **) -> v3 * -> v3 **
v3_fmap f (V3 a b c) = V3 (f a) (f b) (f c)


|| applicative interface
v3_apply :: v3 (* -> **) -> v3 * -> v3 **
v3_apply (V3 fa fb fc) (V3 a b c) = V3 (fa a) (fb b) (fc c)

v3_liftA2 :: (* -> ** -> ***) -> v3 * -> v3 ** -> v3 ***
v3_liftA2 f (V3 a b c) (V3 g h i) = V3 (f a g) (f b h) (f c i)


|| foldable interface
v3_foldr :: (* -> ** -> **) -> ** -> v3 * -> **
v3_foldr f z (V3 a b c) = f c z |> f b |> f a

v3_foldl :: (** -> * -> **) -> ** -> v3 * -> **
v3_foldl f z (V3 a b c) = f z a |> ($f b) |> ($f c)


v3_abs, v3_neg, v3_signum :: v3 int -> v3 int
v3_abs    a = v3_fmap abs a
v3_neg    a = v3_fmap neg a
v3_signum a = v3_fmap signum a

v3_add, v3_sub, v3_mul, v3_div, v3_mod :: v3 int -> v3 int -> v3 int
v3_add a b = v3_liftA2 (+) a b
v3_sub a b = v3_liftA2 (-) a b
v3_mul a b = v3_liftA2 (*) a b
v3_div a b = v3_liftA2 div a b
v3_mod a b = v3_liftA2 mod a b

v3_max, v3_min :: ordI * -> v3 * -> v3 * -> v3 *
v3_max cmp a b = v3_liftA2 (max2 cmp) a b
v3_min cmp a b = v3_liftA2 (min2 cmp) a b

v3_sum, v3_product :: v3 int -> int
v3_sum     a = v3_foldl (+) 0 a
v3_product a = v3_foldl (*) 1 a

|| manhattan distance
v3_dist :: v3 int -> v3 int -> int
v3_dist a b = v3_sub a b |> v3_abs |> v3_sum
