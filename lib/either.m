|| either.m -- sum type of two distinct types


%export +


either * ** ::= Left * | Right **

fromEither :: ** -> either * ** -> **
fromEither default (Left a)  = default
fromEither default (Right b) = b

eitherf :: (* -> ***) -> (** -> ***) -> either * ** -> ***
eitherf fl fr (Left x)  = fl x
eitherf fl fr (Right x) = fr x

partitionEithers :: [either * **] -> ([*], [**])
partitionEithers
    = foldr go ([], [])
      where
        || note: k is evaluated lazily rather than pattern matched, which would force its evaluation
        go (Left a)  k = (a : fst k, snd k)
        go (Right b) k = (fst k, b : snd k)


|| testing
isLeft :: (either * **) -> bool
isLeft (Left x)  = True
isLeft (Right x) = False

isRight :: (either * **) -> bool
isRight (Right x) = True
isRight (Left  x) = False


|| monad interface
e_bind :: either * ** -> (** -> either * ***) -> either * ***
e_bind (Left e)  f = Left e
e_bind (Right x) f = f x

e_pure :: ** -> either * **
e_pure = Right

e_kbind :: (* -> either ** ***) -> (*** -> either ** ****) -> * -> either ** ****
e_kbind f g = go where go x = f x $e_bind g

e_mapM :: (* -> either ** ***) -> [*] -> either ** [***]
e_mapM f = foldr (e_liftA2 (:) . f) (e_pure [])

e_foldM :: (** -> * -> either *** **) -> ** -> [*] -> either *** **
e_foldM f z0 xs
    = foldr c e_pure xs z0
      where
        c x k z = f z x $e_bind k

e_sequence :: [either * **] -> either * [**]
e_sequence xs = foldr (e_liftA2 (:)) (e_pure []) xs

|| functor interface
e_fmap :: (** -> ***) -> either * ** -> either * ***
e_fmap f ma = ma $e_bind (e_pure . f)


|| applicative interface
e_apply :: either * (** -> ***) -> either * ** -> either * ***
e_apply mf ma = mf $e_bind converse e_fmap ma

e_liftA2 :: (** -> *** -> ****) -> either * ** -> either * *** -> either * ****
e_liftA2 f ma mb = e_fmap f ma $e_apply mb
