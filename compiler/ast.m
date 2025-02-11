|| AST.m -- Abstract Syntax Tree Accumulations / Traversals


%export +

%import <avl>
%import <map>
%import <mirandaExtensions>
%import <state>                 (>>=)/st_bind (<*>)/st_apply (<<)/st_left (>>)/st_right
%import "grammar"
%import "name"


|| an astAccum takes an ast and a state *, and pattern matches on the ast
|| if the match fails, it returns the old state, otherwise it returns the new state
|| the state * may be a compound state (tuple), where some parts are dynamically accumulated,
|| and other parts track lexical scope (e.g. environment, definition location).  Lexically
|| scoped state should be captured and restored at the appropriate locations
astAccum * == ast -> * -> *

|| an astAccumTraverser transforms an astAccum into one that traverses an ast
astAccumTraverser * == astAccum * -> astAccum *

|| accumulate top-down or bottom-up over an ast
|| they are analogous to foldr, foldl on lists
astAccumBU, astAccumTD :: astAccumTraverser *
astAccumBU f a = f a . astAccumSubs (astAccumBU f) a
astAccumTD f a = astAccumSubs (astAccumTD f) a . f a

|| accumulate top-down, passing the subs traversal as a continuation which can be
|| modified by the astAccumulator (e.g. let it perform a custom traversal of subs, rather than the default)
|| note that the accumulators used in astAccumTDCont cannot be meaningfully composed, because they may
|| not call the continuation
astAccumTDCont :: astAccumTraverser * -> astAccum *
astAccumTDCont f = f $ astAccumSubs (astAccumTDCont f)

|| like astAccumTDCont, but the state is split into a tuple of dynamically-scoped state and lexically-scoped state
|| the lexically-scoped part is reset to its original value after the traversal of the sub-asts, and acts like a
|| separate Reader monad
astAccumLex :: astAccumTraverser (*, **) -> astAccum (*, **)
astAccumLex f a (ds, ls)
    = (ds', ls)
      where
        ds' = fst $ f (astAccumSubs (astAccumLex f)) a (ds, ls)


|| accumulate over all sub-asts of an ast using the given astAccumTraverser
astAccumSubs :: astAccumTraverser *
astAccumSubs t (Eap e1 e2)         = t e2 . t e1
astAccumSubs t (Ecall e args)      = astAccumList t args . t e
astAccumSubs t (Econd cs)          = astAccumList t cs
astAccumSubs t (Ecase s e as)      = astAccumList t as . t e
astAccumSubs t (Efail e)           = t e
astAccumSubs t (Efatbar p e1 e2)   = t e2 . t e1
astAccumSubs t (Elet b ds ps e)    = t e . astAccumList t ps . astAccumMap t ds
astAccumSubs t (ElistComp e qs a)  = astAccumList t qs . t e
astAccumSubs t (Cif e1 e2)         = t e2 . t e1
astAccumSubs t (Cdefault e)        = t e
astAccumSubs t (CaseAlt p e)       = t e . t p
astAccumSubs t (Qgen ps e)         = t e . astAccumList t ps
astAccumSubs t (Qrecur p e1 e2)    = t e2 . t e1 . t p
astAccumSubs t (Qguard e)          = t e
astAccumSubs t (Pctor n as)        = astAccumList t as
astAccumSubs t (Tname n as)        = astAccumList t as
astAccumSubs t (Ttuple ts)         = astAccumList t ts
astAccumSubs t (Tlist t1)          = t t1
astAccumSubs t (Tarr t1 t2)        = t t2 . t t1
astAccumSubs t (Tstrict t1)        = t t1
astAccumSubs t (DefFn n as e a)    = t e . astAccumList t as
astAccumSubs t (DefMult m ds)      = astAccumList t ds
astAccumSubs t (DefPat p e a)      = t e . t p
astAccumSubs t (DefSyn tf t1 a)    = t t1 . t tf
astAccumSubs t (DefData tf cs a)   = astAccumList t cs . t tf
astAccumSubs t (DefSpec tf t1 a)   = t t1 . t tf
astAccumSubs t (DefAbs tf ds t1 a) = t t1 . astAccumList t ds . t tf
astAccumSubs t x                   = id

astAccumList :: astAccum * -> [ast] -> * -> *
astAccumList t = converse (foldr t)

astAccumMap :: astAccum * -> m_map ** ast -> * -> *
astAccumMap t = converse (m_foldr t)


|| AST traversal with rewriting

|| an astRewriter takes an ast and a state *, and pattern matches on the ast
|| if the match fails, it should return the old ast and state, otherwise it should return the new ast and state
|| astRewriters can be composed like: compose r1 r2 = (>>= r1) . r2
astRewriter * == ast -> state * ast

|| an astRewriteTraverser transforms an astRewriter into one that traverses an ast
|| it is analogous to mapAccumR, mapAccumL for lists
|| astRewriteTraversers can be composed with (.)
astRewriteTraverser * == astRewriter * -> astRewriter *

|| rewrite bottom-up or top-down over an ast
astRewriteBU, astRewriteTD :: astRewriteTraverser *
astRewriteBU r a = astRewriteSubs (astRewriteBU r) a >>= r
astRewriteTD r a = r a >>= astRewriteSubs (astRewriteTD r)

|| rewrite top-down, passing the rewrite subs traversal as a continuation which can be
|| modified by the astRewriter (e.g. let it perform a custom traversal of subs, rather than the default)
|| note that the rewriters used in astRewriteTDCont cannot be meaningfully composed, because they may
|| not call the continuation
astRewriteTDCont :: astRewriteTraverser * -> astRewriter *
astRewriteTDCont r = r (astRewriteSubs (astRewriteTDCont r))

|| like astRewriteTDCont, but the state is split into a tuple of dynamically-scoped state and lexically-scoped state
|| the lexically-scoped part is reset to its original value after the traversal of the sub-asts, and acts as
|| a separate Reader monad
astRewriteLex :: astRewriteTraverser (*, **) -> astRewriter (*, **)
astRewriteLex r a
    = st_get >>= doLex
      where
        doLex (ds, ls) = r (astRewriteSubs (astRewriteLex r)) a << (st_modify (converse setSnd ls))


|| rewrite all sub-asts of an ast using the given astRewriteTraverser
astRewriteSubs :: astRewriteTraverser *
astRewriteSubs t (Eap e1 e2)         = st_liftA2 Eap       (t e1)                (t e2)
astRewriteSubs t (Ecall e args)      = st_liftA2 Ecall     (t e)                 (st_mapM t args)
astRewriteSubs t (Econd cs)          = st_fmap   Econd     (st_mapM t cs)
astRewriteSubs t (Ecase s e as)      = st_liftA2 (Ecase s) (t e)                 (st_mapM t as)
astRewriteSubs t (Efail e)           = st_fmap   Efail     (t e)
astRewriteSubs t (Efatbar p e1 e2)   = st_liftA2 (Efatbar p) (t e1)              (t e2)
astRewriteSubs t (Elet b ds ps e)    = st_liftA3 (Elet b)  (astRewriteMap t ds)  (st_mapM t ps)  (t e)
astRewriteSubs t (ElistComp e qs a)  = st_liftA3 ElistComp (t e)                 (st_mapM t qs)  (st_pure a)
astRewriteSubs t (Cif e1 e2)         = st_liftA2 Cif       (t e1)                (t e2)
astRewriteSubs t (Cdefault e)        = st_fmap   Cdefault  (t e)
astRewriteSubs t (CaseAlt p e)       = st_liftA2 CaseAlt   (t p)                 (t e)
astRewriteSubs t (Qgen ps e)         = st_liftA2 Qgen      (st_mapM t ps)        (t e)
astRewriteSubs t (Qrecur p e1 e2)    = st_liftA3 Qrecur    (t p)                 (t e1)          (t e2)
astRewriteSubs t (Qguard e)          = st_fmap   Qguard    (t e)
astRewriteSubs t (Pctor n as)        = st_fmap   (Pctor n) (st_mapM t as)
astRewriteSubs t (Tname n as)        = st_fmap   (Tname n) (st_mapM t as)
astRewriteSubs t (Ttuple ts)         = st_fmap   Ttuple    (st_mapM t ts)
astRewriteSubs t (Tlist t1)          = st_fmap   Tlist     (t t1)
astRewriteSubs t (Tarr t1 t2)        = st_liftA2 Tarr      (t t1)                (t t2)
astRewriteSubs t (Tstrict t1)        = st_fmap   Tstrict   (t t1)
astRewriteSubs t (DefFn n as e a)    = st_liftA3 (DefFn n) (st_mapM t as)        (t e)           (st_pure a)
astRewriteSubs t (DefMult m ds)      = st_fmap   (DefMult m) (st_mapM t ds)
astRewriteSubs t (DefPat p e a)      = st_liftA3 DefPat    (t p)                 (t e)           (st_pure a)
astRewriteSubs t (DefSyn tf t1 a)    = st_liftA3 DefSyn    (t tf)                (t t1)          (st_pure a)
astRewriteSubs t (DefData tf cs a)   = st_liftA3 DefData   (t tf)                (st_mapM t cs)  (st_pure a)
astRewriteSubs t (DefSpec tf t1 a)   = st_liftA3 DefSpec   (t tf)                (t t1)          (st_pure a)
astRewriteSubs t (DefAbs tf ds t1 a) = st_liftA4 DefAbs    (t tf)                (st_mapM t ds)  (t t1)      (st_pure a)
astRewriteSubs t x                   = st_pure x

|| rewrite a list of asts
astRewriteList :: astRewriter * -> [ast] -> state * [ast]
astRewriteList t xs = st_mapM t xs

|| rewrite a map of ast elements
astRewriteMap :: astRewriter * -> m_map ** ast -> state * (m_map ** ast)
astRewriteMap t AVLLeaf = st_pure AVLLeaf
astRewriteMap t (AVLNode (k, v) l r h)
    = st_liftA3 (mkNode k h) (t v) (astRewriteMap t l) (astRewriteMap t r)
      where
        mkNode k h v l r = AVLNode (k, v) l r h              

|| wrap a defnMap and pat list in an Elet to allow easy traversal of both, unwrapping when done
astRewriteInLet :: astRewriter * -> defnMap -> [defn] -> state * (defnMap, [defn])
astRewriteInLet t defs pats
    = unpack $st_fmap t (Elet True defs pats (Eint 0))
      where
        unpack (Elet _ defs' pats' _) = (defs', pats')
        unpack _                      = undef   || added to remove compiler warning
