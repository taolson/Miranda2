|| avl.m -- AVL tree


%export + -height -computeHeight -delta -rotL -rotR -balanceL -balanceR

%import <maybe> (<$>?)/mb_fmap


avlTree * ::= AVLLeaf | AVLNode * (avlTree *) (avlTree *) int

|| custom ord instance for avlTree, since two trees may hold the same contents, but with
|| differing structures. This instance is also used for the modules that build on avl (bag, map, set)
cmpavlTree :: ordI * -> ordI (avlTree *)
cmpavlTree cmp'
    = cmp
      where
        cmp ta tb = cmplist cmp' (a_toList ta) (a_toList tb)

height :: avlTree * -> int
height AVLLeaf           = 0
height (AVLNode _ _ _ h) = h

computeHeight :: avlTree * -> avlTree *
computeHeight AVLLeaf = AVLLeaf
computeHeight (AVLNode v l r _) = case max2 cmpint (height l) (height r) + 1 of h' -> AVLNode v l r h'

delta :: avlTree * -> int
delta AVLLeaf           = 0
delta (AVLNode _ l r _) = height l - height r

rotL :: avlTree * -> avlTree *
rotL (AVLNode v l (AVLNode vr lr rr hr) h)
    = case a_balance $ AVLNode v l lr h of
        lr' -> a_balance $ AVLNode vr lr' rr hr

rotL n = n

rotR :: avlTree * -> avlTree *
rotR (AVLNode v (AVLNode vl ll rl hl) r h)
    = case a_balance $ AVLNode v rl r h of
        rl' -> a_balance $ AVLNode vl ll rl' hl

rotR n = n

a_moveR :: avlTree * -> avlTree * -> avlTree *
a_moveR (AVLLeaf)         rn = rn
a_moveR (AVLNode v l r h) rn
    = case a_moveR r rn of
        r' -> a_balance $ AVLNode v l r' h

a_balance :: avlTree * -> avlTree *
a_balance AVLLeaf = AVLLeaf
a_balance n
    = balanceR n,      if d < -1
    = balanceL n,      if d >  1
    = computeHeight n, otherwise
      where
        d = delta n

balanceR :: avlTree * -> avlTree *
balanceR n
    = go n
      where
        go AVLLeaf = error "balanceR AVLLeaf"
        go (AVLNode v l r h)
            = rotL n', if delta r > 0
            = rotL n,  otherwise
              where
                n' = case rotR r of r' -> AVLNode v l r' h

balanceL :: avlTree * -> avlTree *
balanceL n
    = go n
      where
        go AVLLeaf = error "balanceL AVLLeaf"
        go (AVLNode v l r h)
            = rotR n', if delta l < 0
            = rotR n,  otherwise
              where
                n' = case rotL l of l' -> AVLNode v l' r h

a_empty :: avlTree *
a_empty = AVLLeaf

a_null :: avlTree * -> bool
a_null AVLLeaf = True
a_null _       = False

a_singleton :: * -> avlTree *
a_singleton v = AVLNode v AVLLeaf AVLLeaf 1

a_size :: avlTree * -> int
a_size AVLLeaf           = 0
a_size (AVLNode v l r h) = a_size l + a_size r + 1

a_member :: ordI * -> * -> avlTree * -> bool
a_member cmp v
    = go
      where
        go  AVLLeaf = False
        go (AVLNode v' l r h)
            = case cmp v v' of
                EQ -> True
                LT -> go l
                GT -> go r

a_first :: avlTree * -> *
a_first AVLLeaf = error "a_first: null tree"
a_first (AVLNode v l r h)
    = v,         if a_null l
    = a_first l, otherwise

a_last :: avlTree * -> *
a_last AVLLeaf           = error "a_last: null tree"
a_last (AVLNode v l r h)
    = v,        if a_null r
    = a_last r, otherwise

a_insert :: ordI * -> * -> avlTree * -> avlTree *
a_insert cmp v
    = go
      where
        go AVLLeaf = a_singleton v
        go (AVLNode v' l r h)
            = case cmp v v' of
                LT -> case go l of l' -> a_balance $ AVLNode v' l' r h
                _  -> case go r of r' -> a_balance $ AVLNode v' l r' h  || EQ case same as GT case, to allow multiple insertions of the same value

|| delete v from tree if present, or return the original tree
a_delete :: ordI * -> * -> avlTree * -> avlTree *
a_delete cmp v n
    = fromMaybe n $ go n
      where
        go AVLLeaf = Nothing
        go (AVLNode v' l r h)
            = case cmp v v' of
                EQ -> Just $ a_moveR l r
                LT -> insL <$>? go l
                GT -> insR <$>? go r
              where
                insL l' = a_balance $ AVLNode v' l' r h
                insR r' = a_balance $ AVLNode v' l r' h

a_fromList :: ordI * -> [*] -> avlTree *
a_fromList cmp = foldl (converse (a_insert cmp)) a_empty

a_toList :: avlTree * -> [*]
a_toList AVLLeaf           = []
a_toList (AVLNode v l r h) = a_toList l ++ [v] ++ a_toList r

a_union :: ordI * -> avlTree * -> avlTree * -> avlTree *
a_union cmp a1 a2 = foldr (a_insert cmp) a1 (a_toList a2)


|| functor interface
a_fmap :: ordI ** -> (* -> **) -> avlTree * -> avlTree **
a_fmap cmp f = a_fromList cmp . map f . a_toList        || mapping can change value order, so rebuild from mapped list


|| foldable interface
a_foldr :: (* -> ** -> **) -> ** -> avlTree * -> **
a_foldr f z
    = go z
      where
        go z' AVLLeaf           = z'
        go z' (AVLNode v l r h) = go z' r |> f v |> ($go l)

a_foldl :: (** -> * -> **) -> ** -> avlTree * -> **
a_foldl f z
    = go z
      where
        go z1 AVLLeaf           = z1
        go z1 (AVLNode v l r h) = case go z1 l of z2 -> f z2 v |> ($go r)
