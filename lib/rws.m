|| rws.m -- reader+writer+state functor/applicative/monad with strict writer and state


%export +

%import <dequeue>
%import <mirandaExtensions>


|| *    is reader (environment) type
|| **   is writer (logging) type, which will be appended to a dequeue
|| ***  is state type
|| **** is result value type
rws * ** *** **** == * -> *** -> dequeue ** -> (****, ***, dequeue **)

|| running
rws_runRWS :: rws * ** *** **** -> * -> *** -> dequeue ** -> (****, ***, dequeue **)
rws_runRWS m r s w = m r s w

rws_evalRWS :: rws * ** *** **** -> * -> *** -> dequeue ** -> (****, dequeue **)
rws_evalRWS m r s w = case rws_runRWS m r s w of (a, s', w') -> (a, w')

rws_execRWS :: rws * ** *** **** -> * -> *** -> dequeue ** -> (***, dequeue **)
rws_execRWS m r s w = case rws_runRWS m r s w of (a, s', w') -> (s', w')


|| reader operations
rws_ask :: rws * ** *** *
rws_ask = go where go r s w = (r, s, w)

rws_asks :: (* -> ****) -> rws * ** *** ****
rws_asks f = go where go r s w = (f r, s, w)

rws_local :: (* -> *) -> rws * ** *** **** -> rws * ** *** ****
rws_local f m = go where go r s w = rws_runRWS m (f r) s w


|| writer operations
rws_tell :: ** -> rws * ** *** ()
rws_tell w = go where go _ s q = case dq_addR w q of q' -> ((), s, q')

rws_tells :: (dequeue ** -> dequeue **) -> rws * ** *** ()
rws_tells f = go where go _ s q = case f q of q' -> ((), s, q')


|| state operations
rws_get :: rws * ** *** ***
rws_get = go where go _ s w = (s, s, w)

rws_put :: *** -> rws * ** *** ()
rws_put s = go where go _ _ w = ((), s, w)

rws_modify :: (*** -> ***) -> rws * ** *** ()
rws_modify f = go where go _ s w = case f s of s' -> ((), s', w)


|| monad interface
rws_bind :: rws * ** *** **** -> (**** -> rws * ** *** *****) -> rws * ** *** *****
rws_bind m f
    = go
      where
        go r s w
            = case rws_runRWS m r s w of
                (a, s', w') -> rws_runRWS (f a) r s' w'

rws_join :: rws * ** *** (rws * ** *** ****) -> rws * ** *** ****
rws_join ma
    = go
      where
        go r s w
            = case rws_runRWS ma r s w of
                (mb, s', w') -> rws_runRWS mb r s' w'

rws_pure :: **** -> rws * ** *** ****
rws_pure a = go where go _ s w = (a, s, w)

rws_kbind :: (**** -> rws * ** *** *****) -> (***** -> rws * ** *** ******) -> **** -> rws * ** *** ******
rws_kbind f g = go where go x = f x $rws_bind g

rws_mapM :: (**** -> rws * ** *** *****) -> [****] -> rws * ** *** [*****]
rws_mapM f = foldr (rws_liftA2 (:) . f) (rws_pure [])

rws_mapM_ :: (**** -> rws * ** *** *****) -> [****] -> rws * ** *** ()
rws_mapM_ f = foldr (rws_right . f) (rws_pure ())

rws_filterM :: (**** -> rws * ** *** bool) -> [****] -> rws * ** *** [****]
rws_filterM p
    = foldr check (rws_pure [])
      where
        check x       = rws_liftA2 (cond x) (p x)
        cond  x False = id
        cond  x True  = (x :)

rws_foldM :: (***** -> **** -> rws * ** *** *****) -> ***** -> [****] -> rws * ** *** *****
rws_foldM f z0 xs
    = foldr c rws_pure xs z0
      where
        c x k z = f z x $rws_bind k

rws_sequence :: [rws * ** *** ****] -> rws * ** *** [****]
rws_sequence xs = foldr (rws_liftA2 (:)) (rws_pure []) xs


|| functor interface
rws_fmap :: (**** -> *****) -> rws * ** *** **** -> rws * ** *** *****
rws_fmap f m = m $rws_bind (rws_pure . f)


|| applicative interface
rws_apply :: rws * ** *** (**** -> *****) -> rws * ** *** **** -> rws * ** *** *****
rws_apply mf ma = mf $rws_bind ($rws_fmap ma)

rws_liftA2 :: (**** -> ***** -> ******) -> rws * ** *** **** -> rws * ** *** ***** -> rws * ** *** ******
rws_liftA2 f ma mb = (f $rws_fmap ma) $rws_apply mb

rws_liftA3 :: (**** -> ***** -> ****** -> *******) -> rws * ** *** **** -> rws * ** *** ***** -> rws * ** *** ****** -> rws * ** *** *******
rws_liftA3 f ma mb mc = rws_liftA2 f ma mb $rws_apply mc

rws_liftA4 :: (**** -> ***** -> ****** -> ******* -> ********) -> rws * ** *** **** -> rws * ** *** ***** -> rws * ** *** ****** ->
               rws * ** *** ******* -> rws * ** *** ********
rws_liftA4 f ma mb mc md = rws_liftA3 f ma mb mc $rws_apply md

rws_left :: rws * ** *** **** -> rws * ** *** ***** -> rws * ** *** ****
rws_left ma mb = rws_liftA2 const ma mb

rws_right :: rws * ** *** **** -> rws * ** *** ***** -> rws * ** *** *****
rws_right ma mb = rws_liftA2 (converse const) ma mb


|| lift multiple independent RWS actions and bind them to an N-ary function
rws_bind2 :: rws * ** *** **** -> rws * ** *** ***** -> (**** -> ***** -> rws * ** *** ******) -> rws * ** *** ******
rws_bind2 ma mb f = rws_join (rws_liftA2 f ma mb)

rws_bind3 :: rws * ** *** **** -> rws * ** *** ***** -> rws * ** *** ****** -> (**** -> ***** -> ****** -> rws * ** *** *******) -> rws * ** *** *******
rws_bind3 ma mb mc f = rws_join (rws_liftA3 f ma mb mc)

