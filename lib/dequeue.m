|| dequeue.m -- a double-ended queue of elements that allows quick insertion / deletion at both ends
|| implemented using a fingerTree


%export + -cmpdequeue -isSat

%import <maybe>
%import <mirandaExtensions>     || (concatMap)


dequeue * ::=
    FT0         |
    FT1 *       |
    FT2 * *     |
    FT3 * * *   |
    FTN (dequeue *) (dequeue (dequeue *)) (dequeue *)

|| don't auto-derive ord instance for dq
cmpdequeue = undef

|| is the finger-tree node saturated?
isSat :: dequeue * -> bool
isSat (FT3 a b c) = True
isSat _           = False

dq_empty :: dequeue *
dq_empty = FT0

dq_singleton :: * -> dequeue *
dq_singleton x = FT1 x

dq_null :: dequeue * -> bool
dq_null FT0 = True
dq_null _   = False

dq_size :: dequeue * -> num
dq_size FT0         = 0
dq_size (FT1 a)     = 1
dq_size (FT2 a b)   = 2
dq_size (FT3 a b c) = 3
dq_size (FTN l m r) = dq_size l + 3 * dq_size m + dq_size r

dq_addL :: * -> dequeue * -> dequeue *
dq_addL a FT0         = FT1 a
dq_addL a (FT1 b)     = FT2 a b
dq_addL a (FT2 b c)   = FT3 a b c
dq_addL a (FT3 b c d) = FTN (FT1 a) FT0 (FT3 b c d)
dq_addL a (FTN l m r)
    = FTN (dq_addL a l) m r,       if ~isSat l
    = FTN (FT1 a) (dq_addL l m) r, otherwise

dq_addR :: * -> dequeue * -> dequeue *
dq_addR z FT0         = FT1 z
dq_addR z (FT1 y)     = FT2 y z
dq_addR z (FT2 x y)   = FT3 x y z
dq_addR z (FT3 w x y) = FTN (FT3 w x y) FT0 (FT1 z)
dq_addR z (FTN l m r)
    = FTN l m (dq_addR z r),       if ~isSat r
    = FTN l (dq_addR r m) (FT1 z), otherwise

dq_viewL :: dequeue * -> maybe (*, dequeue *)
dq_viewL FT0         = Nothing
dq_viewL (FT1 a)     = Just (a, FT0)
dq_viewL (FT2 a b)   = Just (a, FT1 b)
dq_viewL (FT3 a b c) = Just (a, FT2 b c)
dq_viewL (FTN l m r)
    = Just (a, fillL (FTN l' m r))
      where
        (a, l') = fromJust $ dq_viewL l

        fillL (FTN FT0 FT0 r) = r
        fillL (FTN FT0 m   r) = FTN l m' r where (l, m') = fromJust $ dq_viewL m
        fillL q               = q

dq_viewR :: dequeue * -> maybe (*, dequeue *)
dq_viewR FT0         = Nothing
dq_viewR (FT1 z)     = Just (z, FT0)
dq_viewR (FT2 y z)   = Just (z, FT1 y)
dq_viewR (FT3 x y z) = Just (z, FT2 x y)
dq_viewR (FTN l m r)
    = Just (z, fillR (FTN l m r'))
      where
        (z, r') = fromJust $ dq_viewR r

        fillR (FTN l FT0 FT0) = l
        fillR (FTN l m   FT0) = FTN l m' r where (r, m') = fromJust $ dq_viewR m
        fillR q               = q

dq_fromList :: [*] -> dequeue *
dq_fromList = foldl (converse dq_addR) dq_empty

dq_toList :: dequeue * -> [*]
dq_toList FT0         = []
dq_toList (FT1 a)     = [a]
dq_toList (FT2 a b)   = [a, b]
dq_toList (FT3 a b c) = [a, b, c]
dq_toList (FTN l m r) = dq_toList l ++ (concatMap dq_toList . dq_toList) m ++ dq_toList r
