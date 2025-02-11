|| normalize.m -- rewrite ASTs to A-Normal form (all operands to calls are simple literals, vars, or thunks)
||
|| also ensures that calls to known functions and constructors are applied with the exact arity,
|| breaking over-applied calls into sequential calls and returning a partial-application (PAP)
|| thunk for under-applied calls, which is required by STG.


%export normalize

%import <either>
%import <lens>
%import <map>
%import <maybe>
%import <mirandaExtensions>
%import <state>                 (>>=)/st_bind
%import "ast"
%import "config"
%import "exception"
%import "grammar"
%import "module"
%import "name"
%import "predef"


|| state passed through normalize
|| dynamic state:
|| genv:   globalEnvironment
|| thunks: added definitions
||
|| lexically-scoped state:
|| loc:  location info from enclosing definition
|| env:  stack of defnMaps defining the lexical environment
nmDynSt   == (globalEnv, [defn])
nmLexSt   == (locInfo, [defnMap])
nmSt      == (nmDynSt, nmLexSt)

|| lenses for nmSt fields
nmDyn      = lensFst
nmLex      = lensSnd
nmGenv     = composeLens nmDyn  lensFst
nmThunks   = composeLens nmDyn  lensSnd
nmLoc      = composeLens nmLex  lensFst
nmLenv     = composeLens nmLex  lensSnd
nmGen      = composeLens nmGenv lensTup3_2
nmLocation = composeLens nmLoc locInfoLocation

initNmSt :: globalEnv -> nmSt
initNmSt genv = ((genv, []), (emptyLocInfo, []))

clrThunks :: nmSt -> nmSt
clrThunks = set nmThunks []

|| getArity -- get the arity of a defn found in the lexical or global env, or return
|| Nothing if not found (defn arity not known)
getArity :: expr -> nmSt -> maybe num
getArity (Evar n) st
    = foldr lookFrame lookGenv $ view nmLenv st
      where
        lookGenv      = lookupArity (view nmGenv st) n
        lookFrame f k = (fnArity $mb_fmap m_lookup cmpname n f) $mb_alt k

|| handle polymorphic pseudo-functions pack and sel
getArity (Tname n as) st
    = Just 1,     if _eq cmpname n builtinSelName
    = Just nargs, if _eq cmpname n builtinPackName
    = Nothing,    otherwise
      where
        EprimInt nargs = as ! 2

getArity e st = Nothing


normalizeAst :: astRewriteTraverser nmSt

normalizeAst k (Ecall f args) st
    = (Ecall fSimp argsSimp, st1), if noArityNorm               || call with all arguments if unknown function arity, or exact arity
    = (Ecall overF args2,    st2), if argsArity > fArity        || over-applied function split into sequential calls
    = (Evar  pap,            st3), otherwise                    || under-applied function turned into return of partial-application thunk
      where
        (fSimp : argsSimp, st1) = st_mapM normalizeExpr (f : args) st   || normalize the function call and arguments
        mfArity                 = getArity f st
        fArity                  = fromJust mfArity
        argsArity               = #args
        noArityNorm             = isNothing mfArity \/ fArity == 0 \/ fArity == argsArity

        || over-applied function
        (args1, args2)          = splitAt fArity argsSimp               || split args into two calls
        (overF, st2)            = normalizeExpr (Ecall fSimp args1) st1 || normalize the first call as the simplified fn for the second call

        || under-applied function
        gen               = view nmGen st1
        (gen1, ns)        = genNames "var" gen [1 .. fArity - argsArity]        || generate partial application function variable names
        (gen2, pap)       = genName "`pap" gen1                                 || generate function name
        d                 = DefFn pap (map Pvar ns) (Ecall fSimp (argsSimp ++ map Evar ns)) $ mkAnno st1
        st3               = set nmGen gen2 . over nmThunks (d :) $ st1

        || create a new thunk defn for any complex expr
        normalizeExpr e st
            = (e, st),        if isSimpleExpr e
            = (e', st1),      if isSimpleExpr e'
            = (Evar tn, st2), otherwise
              where
                (e', st1)  = astRewriteLex normalizeAst e st
                (gen', tn) = genName "`thunk" $ view nmGen st1
                d          = DefPat (Pvar tn) e' $ mkAnno st1
                st2        = set nmGen gen' . over nmThunks (d :) $ st1

        mkAnno st = locAnno . fromMaybe emptyLocation . view nmLocation $ st

|| float any generated thunks out until reaching a Defn, Elet, or CaseAlt
|| then collect them into a nested sequence of Elets
normalizeAst k a st
    = (a, st),              if isDefType a || no normalization for type definitions
    = (k a >>= update) st1, if isDefn a \/ isCaseAlt a
    = (k a >>= update) st2, if isLet a                             || add new lexical frame for let defns
    = k a              st,  otherwise
      where
        inThunks = view nmThunks st
        loc      = defnLocInfo a, if isDefn a
                 = view nmLoc st, otherwise
        st1      = over nmLoc (mergeLocInfo loc) . clrThunks $ st
        st2      = over nmLenv (getDefns a :) st1

        getDefns (Elet b defs pats e) = defs
        getDefns a                    = m_empty

        update (DefFn n vars e an) st
            = (DefFn n vars e' an, st')
              where
                (e', st') = wrapLets e st

        update (DefPat p e an) st
            = (DefPat p e' an, st')
              where
                (e', st') = wrapLets e st

        update (Elet rec defs x e) st
            = (Elet rec defs x e', st')
              where (e', st') = wrapLets e st

        update (CaseAlt p e) st
            = (CaseAlt p e', st')
              where
                (e', st') = wrapLets e st

        update a st
            = (a, set nmThunks inThunks st)

        wrapLets a st
            = (foldl wrapLet a (view nmThunks st), set nmThunks inThunks st)
              where

                isEager (Ecall (Evar c) args) = isConstructor c
                isEager e                     = False

                wrapLet a (DefPat p e an)
                    = Ecase Csingle e [CaseAlt p a],                if useEagerCtors & isEager e

                wrapLet a d
                    = Elet False (m_singleton (defnName d) d) [] a, otherwise


|| normalize all the defns in a module
normalize :: globalEnv -> excpt globalEnv
normalize genv
    = ex_pure genv'
      where
        m          = view genvMod genv
        (defs, st) = astRewriteMap (astRewriteLex normalizeAst) (view modDefns m) (initNmSt genv)
        genv'      = over genvMod (set modDefns defs) (view nmGenv st)
