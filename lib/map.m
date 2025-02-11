|| map.m -- implementation of a strict map from key to value, using AVL trees


%export + m_empty m_null m_size m_first m_last m_toList

%import <avl>   m_empty/a_empty m_null/a_null m_size/a_size m_first/a_first m_last/a_last m_toList/a_toList
%import <maybe> (<$>?)/mb_fmap


m_map * ** == avlTree (*, **)

m_singleton :: * -> ** -> m_map * **
m_singleton k v = v $seq a_singleton (k, v)     || strict value

m_member :: ordI * -> * -> m_map * ** -> bool
m_member cmp k m
    = go m
      where
        go AVLLeaf = False
        go (AVLNode (k', v) l r h)
            = case cmp k k' of
                EQ -> True
                LT -> go l
                GT -> go r

m_insert :: ordI * -> * -> ** -> m_map * ** -> m_map * **
m_insert cmp k v
    = go
      where
        go AVLLeaf = m_singleton k v
        go (AVLNode p l r h)
            = case fst p of
                k' -> case cmp k k' of
                        EQ -> case v of v' -> AVLNode (k, v') l r h       || strict value
                        LT -> case go l of l' -> a_balance $ AVLNode p l' r h
                        GT -> case go r of r' -> a_balance $ AVLNode p l r' h

m_insertWith :: ordI * -> (** -> ** -> **) -> * -> ** -> m_map * ** -> m_map * **
m_insertWith cmp f k v
    = go
      where
        go AVLLeaf = m_singleton k v
        go (AVLNode p l r h)
            = case p of
                (k', v') -> case cmp k k' of
                              EQ -> case f v v' of fv' -> AVLNode (k, fv') l r h      || strict value
                              LT -> case go l of l' -> a_balance $ AVLNode p l' r h
                              GT -> case go r of r' -> a_balance $ AVLNode p l r' h

|| delete the key k and its value from the map, if present,
|| or return the original map
m_delete :: ordI * -> * -> m_map * ** -> m_map * **
m_delete cmp k m
    = fromMaybe m $ go m
      where
        go AVLLeaf = Nothing
        go (AVLNode p l r h)
            = case fst p of
                k' -> case cmp k k' of
                        EQ -> Just $ a_moveR l r
                        LT -> insL <$>? go l
                        GT -> insR <$>? go r
              where
                insL l' = a_balance $ AVLNode p l' r h
                insR r' = a_balance $ AVLNode p l r' h

|| return Nothing if the key wasn't found, otherwise return the adjusted map
m_madjust :: ordI * -> (** -> **) -> * -> m_map * ** -> maybe (m_map * **)
m_madjust cmp f k
    = go
      where
        go AVLLeaf = Nothing
        go (AVLNode p l r h)
            = case p of
                (k', v') -> case cmp k k' of
                              EQ -> case f v' of fv' -> Just $ AVLNode (k, fv') l r h   || strict value
                              LT -> insL <$>? go l
                              GT -> insR <$>? go r
              where
                insL l'  = AVLNode p l' r h
                insR r'  = AVLNode p l r' h

|| return the original map if the key wasn't found, otherwise return the adjusted map
m_adjust :: ordI * -> (** -> **) -> * -> m_map * ** -> m_map * **
m_adjust cmp f k m = fromMaybe m $ m_madjust cmp f k m

m_lookup :: ordI * -> * -> m_map * ** -> maybe **
m_lookup cmp k m
    = go m
      where
        go AVLLeaf = Nothing
        go (AVLNode (k', v') l r h)
          = case cmp k k' of
              EQ -> Just v'
              LT -> go l
              GT -> go r

m_findWithDefault :: ordI * -> ** -> * -> m_map * ** -> **
m_findWithDefault cmp d k m
    = fromMaybe d $ m_lookup cmp k m

m_fromList :: ordI * -> [(*, **)] -> m_map * **
m_fromList cmp
    = foldl ins m_empty
      where
        ins m (k, v) = m_insert cmp k v m

m_elems :: m_map * ** -> [**]
m_elems AVLLeaf = []
m_elems (AVLNode (k, v) l r h)
    = m_elems l ++ [v] ++ m_elems r

m_keys :: m_map * ** -> [*]
m_keys AVLLeaf = []
m_keys (AVLNode (k, v) l r h)
    = m_keys l ++ [k] ++ m_keys r

|| extract the map's keys as a set
|| note that it extracts to an avlTree (parent of set) to prevent
|| having a dependency on the set module.  Since the map's keys
|| are guaranteed to be unique, they naturally form a set
m_keysSet :: m_map * ** -> avlTree *
m_keysSet AVLLeaf = AVLLeaf
m_keysSet (AVLNode (k, v) l r h)
    = case m_keysSet l of
        ls -> case m_keysSet r of
                rs -> AVLNode k ls rs h

m_union :: ordI * -> m_map * ** -> m_map * ** -> m_map * **
m_union cmp m1 m2
    = foldl addEntry m1 $ m_toList m2
      where
        addEntry m (k, v) = m_insert cmp k v m

m_filter :: ordI * -> (** -> bool) -> m_map * ** -> m_map * **
m_filter cmp p m
    = m_filterWithKey cmp (ignoreKey p) m
      where
        ignoreKey p (k, x) = p x

m_filterWithKey :: ordI * -> ((*, **) -> bool) -> m_map * ** -> m_map * **
m_filterWithKey cmp p = m_fromList cmp . filter p . m_toList

m_mapAccumL :: (**** -> ** -> (****, ***)) -> **** -> m_map * ** -> (****, m_map * ***)
m_mapAccumL f s AVLLeaf = (s, AVLLeaf)
m_mapAccumL f s (AVLNode (k, v) l r h)
    = case m_mapAccumL f s l of
        (s1, l') -> case f s1 v of
                      (s2, v') -> case m_mapAccumL f s2 r of
                                    (s3, r') -> (s3, AVLNode (k, v') l' r' h)


|| functor interface
|| note: lazy operation here, because some computations
|| like loeb depend upon that
m_fmap :: (** -> ***) -> m_map * ** -> m_map * ***
m_fmap f
    = go
      where
        go  AVLLeaf = AVLLeaf
        go (AVLNode (k, v) l r h)
            = AVLNode (k, v') l' r' h
              where
                v' = f v
                l' = go l
                r' = go r

m_fmapWithKey :: (* -> ** -> ***) -> m_map * ** -> m_map * ***
m_fmapWithKey f
    = go
      where
        go AVLLeaf = AVLLeaf
        go (AVLNode (k, v) l r h)
            = AVLNode (k, v') l' r' h
              where
                v' = f k v
                l' = go l
                r' = go r

|| foldable interface
m_foldr :: (** -> *** -> ***) -> *** -> m_map * ** -> ***
m_foldr f z
    = go z
      where
        go z' AVLLeaf                = z'
        go z' (AVLNode (k, v) l r h) = go z' r |> f v |> ($go l)

m_foldl :: (*** -> ** -> ***) -> *** -> m_map * ** -> ***
m_foldl f z
    = go z
      where
        go z1 AVLLeaf                = z1
        go z1 (AVLNode (k, v) l r h) = case go z1 l of z2 -> f z2 v |> ($go r)
