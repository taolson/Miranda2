|| vector.m -- immutable and mutable vectors, and the ST monad for sequencing in-place modification
||  O(1) read accesses
||  O(N) write accesses (replace, //) for immutable vectors
||  O(1) write accesses (write, modify) for mutable vectors
||  mutable vector operations sequenced through ST monad


%export +

%import <maybe>
%import <mirandaExtensions>
%import <state>                 (>>=)/st_bind (<$>)/st_fmap (>>)/st_right
%import <stream>


|| ST monad for performing actions on mutable vectors
|| Note: the ST monad in Haskell uses an existential type for the state, which is bound
|| to the particular reference to the array being modified.  However, Miranda does not
|| have existential types, so here the ST monad is just the state monad with Unit state
st * == state () *

|| run an STaction on a mutable copy of a vector, then freeze it and return the new vector
runSTVector :: (mvector * -> st **) -> vector * -> vector *
runSTVector f v
    = st_evalState (f mv >> v_unsafeFreeze mv) ()
      where
        mv = v_thaw v

|| immutable and mutable vectors holding elements of type *
vector  * ::= Vector  int word# || vector with size and unboxed pointer to base of vector in memory
mvector * ::= MVector int word# || mutable vector with size and unboxed pointer to base of vector in memory

|| custom ordI instance for vector that compares elements
cmpvector :: ordI * -> vector * -> vector * -> ordering
cmpvector cmp' v1 v2 = cmpstream cmp' (v_toStream v1) (v_toStream v2)

|| custom showI instance for vector that shows its elements
showvector :: showI * -> vector * -> string
showvector si v = "(Vector " ++ intercalate ", " (map si (v_toList v)) ++ ")"

|| ensure that a vector index is within bounds
safeIndex :: int -> int -> int
safeIndex n i
    = i,                                 if 0 <= i < n
    = error "vector index out of bounds", otherwise


|| vector creation

|| create a vector with a single value
v_singleton :: * -> vector *
v_singleton x
    = case allocArray# 1# of
        p# -> case writeArray# p# 0# x of
                _ -> Vector 1 p#

|| make a new vector and fill with a repeated value (uses fillArray# which is a low-level memset)
v_rep :: int -> * -> vector *
v_rep n x
    = case n of
        I# n# -> case allocArray# n# of
                   p# -> case fillArray# p# x of
                           _ -> Vector n p#

|| generate a vector from its index values
v_generate :: int -> (int -> *) -> vector *
v_generate n f = (v_fromStream n . mapS f . rangeFromS) 0

|| iterate a function from an initial value to produce a vector
v_iterateN :: int -> (* -> *) -> * -> vector *
v_iterateN n f = v_fromStream n . iterateS f


|| vector accessing

v_length :: vector * -> int
v_length (Vector n p#) = n

v_index, (!!) :: vector * -> int -> *
v_index (Vector n p#) i
    = case safeIndex n i of I# i# -> case readArray# p# i# of e -> e

v !! i  = v_index v i

v_first :: vector * -> *
v_first v = v !! 0

v_last :: vector * -> *
v_last v = v !! (v_length v - 1)

v_replace, (//) :: vector * -> [(int, *)] -> vector *
v_replace v ies
    = runSTVector go v
      where
        n     = v_length v
        go mv = v_unsafeReplace mv [(safeIndex n i, e) | (i, e) <- ies]

v // ies = v_replace v ies


|| common list-like operations on vectors

v_map :: (* -> **) -> vector * -> vector **
v_map f v
    = st_evalState (go mv >> v_unsafeFreeze mv) ()
      where
        n  = v_length v
        mv = v_unsafeThaw $ v_rep n undef
        go mv
            = st_mapM_ update [0 .. n - 1]
              where
                update i = v_unsafeWrite mv i . f . v_unsafeIndex v $ i

v_mapWithIndex :: (int -> * -> **) -> vector * -> vector **
v_mapWithIndex f v
    = st_evalState (go mv >> v_unsafeFreeze mv) ()
      where
        n  = v_length v
        mv = v_unsafeThaw $ v_rep n undef
        go mv
            = st_mapM_ update [0 .. n - 1]
              where
                update i = v_unsafeWrite mv i . f i . v_unsafeIndex v $ i

|| filter can change size of a vector, so it's easiest just to convert to/from stream
v_filter :: (* -> bool) -> vector * -> vector *
v_filter f = v_fromList . filter f . v_toList   || list used so we can get length of filtered list

|| lazy right-fold, to allow early-out of folding function
v_foldr :: (* -> ** -> **) -> ** -> vector * -> **
v_foldr f z v
    = go 0
      where
        n = v_length v

        go i
            = z,                                  if i == n
            = f (v_unsafeIndex v i) (go (i + 1)), otherwise

|| strict left fold
v_foldl :: (** -> * -> **) -> ** -> vector * -> **
v_foldl f z v
    = go z 0
      where
        n = v_length v

        go r i
            = r,                     if i == n
            = r' $seq go r' (i + 1), otherwise
              where
                r' = f r (v_unsafeIndex v i)

v_append :: vector * -> vector * -> vector *
v_append va vb
    = v_fromStream n (appendS (v_toStream va) (v_toStream vb))
      where
        n = v_length va + v_length vb

v_zipWith :: (* -> ** -> ***) -> vector * -> vector ** -> vector ***
v_zipWith f v1 v2
    = st_evalState (doZip mv >> v_unsafeFreeze mv) ()
      where
        n  = min2 cmpint (v_length v1) (v_length v2)
        mv = v_unsafeThaw $ v_rep n undef

        doZip mv
            = st_mapM_ go [0 .. n - 1]
              where
                go i = v_unsafeWrite mv i (f (v_unsafeIndex v1 i) (v_unsafeIndex v2 i))

v_min, v_max :: ordI * -> vector * -> *
v_min cmp v = v_foldl (min2 cmp) (v_first v) v
v_max cmp v = v_foldl (max2 cmp) (v_first v) v

v_sum, v_product :: vector int -> int
v_sum     = v_foldl (+) 0
v_product = v_foldl (*) 1

v_any, v_all :: (* -> bool) -> vector * -> bool
v_any p = v_foldr ((\/) . p) False
v_all p = v_foldr ((&) . p) True

v_find :: (* -> bool) -> vector * -> maybe *
v_find p
    = v_foldr match Nothing
      where
      match x k
          = Just x, if p x
          = k,      otherwise

|| in-place quicksort algorithm on the vector
v_sortBy :: ordI * -> vector * -> vector *
v_sortBy cmp v
    = st_evalState (fullSort >> v_unsafeFreeze mv) 0 || state being passed through sort is the index i
      where
        mv       = v_thaw v
        fullSort = sort mv 0 (v_length v - 1)

        sort mv lo hi
            = st_pure (),            if lo >= hi \/ lo < 0
            = sortStep >>= sortRest, otherwise
              where
                sortStep   = st_put (lo - 1) >> v_unsafeRead mv hi >>= part
                sortRest p = sort mv lo (p - 1) >> sort mv (p + 1) hi

                part pivot
                    = st_mapM_ cmpSwap [lo .. hi - 1] >> swapWith hi >> st_get
                      where
                        swapWith j
                            = st_modify (+ 1) >> st_get >>= doReads
                              where
                                doReads i        = st_bind2 (v_unsafeRead mv i) (v_unsafeRead mv j) (doWrites i)
                                doWrites i vi vj = v_unsafeWrite mv i vj >> v_unsafeWrite mv j vi

                        cmpSwap j
                            = v_unsafeRead mv j >>= check
                              where
                                check vj
                                    = st_pure (), if _gt cmp vj pivot
                                    = swapWith j, otherwise

|| binary search a sorted vector for a matching entry, based upon the result of the cmp fn
v_search :: (* -> ordering) -> vector * -> maybe *
v_search cmp v
    = go 0 (v_length v - 1)
      where
        choose x eqf ltf gtf
            = case x of
                EQ -> eqf
                LT -> ltf
                GT -> gtf

        go lo hi
            = choose (cmp vl) (Just vl) Nothing (check vh),      if hi - lo < 2
            = choose (cmp vm) (Just vm) (go lo mid) (go mid hi), otherwise
              where
                mid = (lo + hi) $div 2
                vl  = v !! lo
                vm  = v !! mid
                vh  = v !! hi

        check h = choose (cmp h) (Just h) Nothing Nothing


|| conversions

v_fromStream :: int -> stream * ** -> vector *
v_fromStream n (Stream next s)
    = case n of
        I# n# -> case allocArray# n# of
                   p# -> doWrites p# n# 0# s
      where
        doWrites p# n# i# s
            = go i# s
              where
                go i# s
                    = case i# $cmp# n# of
                        1# -> case next s of
                                Done       -> Vector n p#
                                Skip s'    -> go i# s'
                                Yield x s' -> case writeArray# p# i# x of
                                                _ -> case i# +# 1# of
                                                       i'# -> go i'# s'
                        _  -> Vector n p#

v_toStream :: vector * -> stream * int
v_toStream v
    = Stream next 0
      where
        n = v_length v
        next i
            = Done,                              if i >= n
            = Yield (v_unsafeIndex v i) (i + 1), otherwise

v_fromList :: [*] -> vector *
v_fromList es = v_fromStream n (toStream es) where n = #es

v_toList :: vector * -> [*]
v_toList = fromStream . v_toStream


|| unsafe operations on vectors

v_unsafeIndex :: vector * -> int -> *
v_unsafeIndex (Vector n p#) (I# i#) = case readArray# p# i# of e -> e

v_unsafeThaw :: vector * -> mvector *
v_unsafeThaw (Vector n p#) = (MVector n p#)


|| operations on mutable vectors

v_mlength :: mvector * -> int
v_mlength (MVector n p#) = n

v_thaw :: vector * -> mvector *
v_thaw (Vector n p#)
    = case n of
        I# n# -> case allocArray# n# of
                   d# -> case copyArray# d# p# of
                           _ -> MVector n d#

|| operations on mutable vectors within the state monad
|| note: uses state ** rather than st to allow for mutable
|| vector operations using more general state

v_freeze :: mvector * -> state ** (vector *)
v_freeze (MVector n p#)
    = case n of
        I# n# -> case allocArray# n# of
                   d# -> case copyArray# d# p# of
                           _ -> st_pure (Vector n d#)

|| make a mutable copy of a mutable vector
v_clone :: mvector * -> state ** (mvector *)
v_clone (MVector n p#)
    = case n of
        I# n# -> case allocArray# n# of
                   d# -> case copyArray# d# p# of
                           _ -> st_pure (MVector n d#)

v_read :: mvector * -> int -> state ** *
v_read (MVector n p#) i
    = case safeIndex n i of
        I# i# -> case readArray# p# i# of
                   e -> st_pure e

v_write :: mvector * -> int -> * -> state ** ()
v_write (MVector n p#) i e
    = case safeIndex n i of
        I# i# -> case writeArray# p# i# e of
                   _ -> st_pure ()

v_modify :: mvector * -> (* -> *) -> int -> state ** ()
v_modify (MVector n p#) f i
    = case safeIndex n i of
        I# i# -> case readArray# p# i# of
                   e -> case f e of
                          e' -> case writeArray# p# i# e' of
                                  _ -> st_pure ()

v_fill :: mvector * -> * -> state ** ()
v_fill (MVector _ p#) e = case fillArray# p# e of _ -> st_pure ()


|| unsafe in-place operations on mutable vectors without copying or bounds-checking

v_unsafeFreeze :: mvector * -> state ** (vector *)
v_unsafeFreeze (MVector n p#) = st_pure (Vector n p#)

v_unsafeRead :: mvector * -> int -> state ** *
v_unsafeRead (MVector n p#) (I# i#)
    = case readArray# p# i# of
        e -> st_pure e

v_unsafeWrite :: mvector * -> int -> * -> state ** ()
v_unsafeWrite (MVector n p#) (I# i#) e
    = case writeArray# p# i# e of
        _ -> st_pure ()

v_unsafeModify :: mvector * -> (* -> *) -> int -> state ** ()
v_unsafeModify (MVector n p#) f (I# i#)
    = case readArray# p# i# of
        e -> case f e of
               e' -> case writeArray# p# i# e' of
                       _ -> st_pure ()

v_unsafeReplace :: mvector * -> [(int, *)] -> state ** ()
v_unsafeReplace (MVector n p#) ies
    = doRep ies
      where
        doRep [] = st_pure ()

        doRep ((I# i#, e) : ies')
            = case writeArray# p# i# e of
                _ -> doRep ies'


|| STRef implemented using a singleton mvector

stRef * == mvector *

newSTRef :: * -> st (stRef *)
newSTRef = st_pure . v_unsafeThaw . v_singleton

readSTRef :: stRef * -> st *
readSTRef a = v_unsafeRead a 0

writeSTRef :: stRef * -> * -> st ()
writeSTRef a = v_unsafeWrite a 0

modifySTRef :: stRef * -> (* -> *) -> st ()
modifySTRef a f = v_unsafeModify a f 0
