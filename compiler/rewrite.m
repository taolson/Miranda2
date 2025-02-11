|| rewrite.m -- AST rewriting for simplification and optimizations


%export rewrite

%import <either>
%import <lens>
%import <map>
%import <maybe>
%import <mirandaExtensions>
%import <set>
%import <state>
%import "ast"
%import "config"
%import "dependency"
%import "exception"
%import "grammar"
%import "module"
%import "name"
%import "predef"


|| state passed through rewrite:
|| dynamic state:
|| genv:      global environment (for lookup of constructor type specs and generator access)
|| errs:      exceptions collected during traversal
|| failCount: dynamic count of number of Efails seen (used for replacement optimizations)
||
|| lexically-scoped state:
|| loc:       location info from enclosing definition
rwDynSt   == (globalEnv, [exception], int)
rwLexSt   == locInfo
rwSt      == (rwDynSt, rwLexSt)

|| lenses for rwSt fields
rwDyn       = lensFst
rwLex       = lensSnd
rwGenv      = composeLens rwDyn  lensTup3_0
rwErrs      = composeLens rwDyn  lensTup3_1
rwFailCount = composeLens rwDyn  lensTup3_2
rwLoc       = rwLex
rwEnv       = composeLens rwLex  lensSnd
rwGen       = composeLens rwGenv lensTup3_2

initRwSt :: globalEnv -> rwSt
initRwSt genv = ((genv, [], 0), emptyLocInfo)

|| add an error to the rewrite state
addRwErr :: exceptionInfo -> rwSt -> rwSt
addRwErr ei st = over rwErrs ((Error, ei, view rwLoc st) :) st

|| add a warning to the rewrite state
addRwWarn :: exceptionInfo -> rwSt -> rwSt
addRwWarn ei st = over rwErrs ((Warn, ei, view rwLoc st) :) st

|| clear the fail count
clrFails :: rwSt -> rwSt
clrFails = set rwFailCount 0

|| add to the fail count
addFails :: int -> rwSt -> rwSt
addFails n = over rwFailCount (+ n)

|| rewriteAst is an astRewriteTraverser that is passed an explicit continuation to use to
|| traverse its subexpressions; this can be replaced with a custom traverser, or discarded to prevent further traversal.
|| during traversal, it collects information on Efail occurrences for Efatbar optimization
rewriteAst :: astRewriteTraverser rwSt


|| rewrite chains of Eap applications to Ecalls
|| also take this opportunity to inline fully-saturated calls to stdApply, stdRapply, and stdCompose, since
||  they are used so frequently to make computation pipelines, and it is cheaper to do it here than in the general
|| inline pass
rewriteAst k (Eap e1 e2) st
    = (k (Eap e1 e2) $st_bind mkCall) st        || rewrite sub-expressions e1 & e2, then make them into an Ecall
      where
        mkCall (Eap f e) st = (checkInline f e, st)
        mkCall _         _  = undef     || added to remove compiler warning

        checkInline (Ecall c [f])    e = checkInline f e,           if _eq cmpexpr c stdApply
        checkInline (Ecall c [e])    f = checkInline f e,           if _eq cmpexpr c stdRapply
        checkInline (Ecall c [f, g]) e = Ecall f [checkInline g e], if _eq cmpexpr c stdCompose
        checkInline (Ecall c [g, f]) e = Ecall f [checkInline g e], if _eq cmpexpr c stdRcompose
        checkInline (Ecall f args)   e = Ecall f $ args ++ [e]
        checkInline f                e = Ecall f [e]

|| rewrite simple accessor Ecase patterns to a builtinSel: {case e of [(a, b, c) -> b]} => builtinSel (Tuple3, 1) e
|| Note: performance comparison shows that this rewrite actually degrades performance a slight amount (when inlining), due to
|| some inlining rewrites not being performed, so it is conditioned here upon the config parameter useSel.
rewriteAst k (Ecase s e alts) st
    = (k (Ecase s e alts) $st_bind mkSel) st, if useSel
      where
        mkSel (Ecase s e [CaseAlt (Pctor c vars) (Evar n)]) st
            = (Ecall (builtinSel c idx) [e], st), if isJust midx
              where
                midx = elemIndex cmppat (Pvar n) vars
                idx  = fromJust midx

        mkSel e st = (e, st)

|| desugaring complex patterns and conditionals changes them into chains of case expressions which
|| can fail, separated by fatbar operators that mark targets for the fail.  This rewrite
|| optimizes most of them away, using the following axioms:
||
||    E1   || E2   -> unreachablePatWarn, if E1 can't fail and E2 can't be deleted
||    E1   || E2   -> E1, if E1 can't fail and E2 can be deleted
||    E1   || Fail -> E1
||    Fail || E2   -> E2
rewriteAst k (Efatbar p e1 e2) st
    = (e1', st1w),               if fc1 == 0 & normE2           || replace with e1' and mark e2' as unreachable
    = (e1', st1'),               if fc1 == 0                    || replace with e1' and ignore e2'
    = (e2', st2'),               if isFail e1'                  || can use st2 while ignoring e1', since no use/cpx info added from e1'
    = (e1r, st2'),               if canReplace                  || replace fails in e1' with e2'
    = (Efatbar p e1' e2', st2'), otherwise
      where
        fn         = unPvar p                                   || unique name for matching a fatbar to its fails
        inFails    = view rwFailCount st                        || count of fails seen so far in expr enclosing this fatbar
        (e1', st1) = astRewriteLex rewriteAst e1 (clrFails st)  || perform traversal of e1 & e2 separately
        (e2', st2) = astRewriteLex rewriteAst e2 (clrFails st1) || to collect fail inclusion info for each of them
        fc1        = view rwFailCount st1                       || count of fails seen only in e1
        normE2     = ~isFailOrSDF e2'                           || e2' is not a fail or SDF
        canReplace = fc1 == 1 \/ isSimpleExpr e2'               || replace single fails in e1' with a normal e2', or multiple with a simple e2'
        st1'       = addFails inFails st1
        st2'       = addFails inFails st2
        st1w       = addRwWarn (Unreachable e2') st1'
        e1r        = fst $ astRewriteTDCont repFail e1' e2'     || replace matching Efails in e1 with e2

        || replace Efails matching fn in e1 with e2
        repFail k (Efail (Evar n)) er = (er, er), if _eq cmpname n fn
        repFail k e er                = k e er

        || is the expr a call to stdCaseFail or stdMatchFail?
        isSDF (Ecall f args) = _eq cmpexpr f stdCaseFail \/ _eq cmpexpr f stdMatchFail
        isSDF (Eap f arg)    = _eq cmpexpr f stdCaseFail \/ _eq cmpexpr f stdMatchFail    || rewrite from Eap -> Ecall may not have happened, yet
        isSDF e              = False

        || is the expr a Fail or SDF?
        isFailOrSDF (Efail e) = True
        isFailOrSDF e         = isSDF e

rewriteAst k (Efail e) st = (Efail e, addFails 1 st)

|| Hindly-Milner type checking requires that Lets be broken down into a nested dependent sequence of strongly-connected components
|| rewrite Elets to a sequence of Elets and EletRecs based upon free variable and strongly-connected-component analysis of the defs
rewriteAst k (Elet x1 defs x2 e) st
    = (lets, st2)
      where
        (defs', st1)  = astRewriteMap (astRewriteLex rewriteAst) defs st                || rewrite the let defns
        (e', st2)     = astRewriteLex rewriteAst e st1                                  || rewrite the let expr
        sccs          = findSCCs cmpname . makeDependencyGraph cmpname . makeDefnDependencyList $ defs'
        lets          = foldr mkLet e' sccs                                             || build a series of lets from the sccs

        || make a let with a single defn, discovering and marking its recursive status
        mkLet [n] e
            = Elet isRec (m_singleton n d') [] e
              where
                d     = fromJust $ m_lookup cmpname n defs'
                isRec = s_member cmpname n $ view defnAnFree d
                d'    = set defnAnRec isRec d

        || make a let with multiple, mutually-recursive defns
        mkLet ns e
            = Elet True (foldl addRecEntry m_empty ns) [] e
              where
                addRecEntry m n
                    = m_insert cmpname n d' m
                      where
                        d' = set defnAnRec True . fromJust . m_lookup cmpname n $ defs'

|| handle extra info around rewriting defns
rewriteAst k a st
    = k (fixup a) st', if isDefn a
    = k a st,          otherwise
      where
        loc = defnLocInfo a
        st' = over rwLoc (mergeLocInfo loc) st

        || caseFail and matchFail are runtime fail routines that use a number of other stdlib functions to print an error message.
        || Calls to these fails are appended with an Efatbar onto function and patterns during desugaring, and the ones that aren't
        || needed are removed during rewrite.  However, this temporarily sets up a false recursion between functions used by the fails,
        || since they themselves can have one of the fails appended before rewriting.  To prevent this, we remove the fail names from
        || the free vars discovered during the analyze pass prior to rewrite, breaking the false recursion.  A subsequent analyze pass
        || will recover any remaining dependencies on caseFail or matchFail.
        fixup = over defnAnFree (s_delete cmpname stdCaseFailName . s_delete cmpname stdMatchFailName)

|| rewrite of desugared code:
||   rewrite Eap applications to function calls with simple arguments
||   inline saturated apply/rapply/compose/rcompose functions
||   rewrite simple accessors in Ecase patterns
||   remove extraneous fatbar / Efails and check for unreachable / non-exhaustive patterns
||   rewrite Elets to separate (nested) Elet and EletRec based upon the free-variable and dependency analysis
||   add recursion info to top-level defs
rewrite :: globalEnv -> excpt globalEnv
rewrite genv
    = ex_return genv' warns, if null errs
    = ex_errs   errs,        otherwise
      where
        m             = view genvMod genv
        defs          = view modDefns m
        (defs1, st)   = astRewriteMap (astRewriteLex rewriteAst) defs $ initRwSt genv
        sccs          = findSCCs cmpname . makeDependencyGraph cmpname . makeDefnDependencyList $ defs1
        defs2         = foldl markRec defs1 sccs
        genv'         = over genvMod (set modDefns defs2) $ view rwGenv st
        (errs, warns) = partition isError $ view rwErrs st

        || mark a single defn with its discovered recursive status
        markRec defs [n]
            = m_adjust cmpname setRec n defs
              where
                setRec d = set defnAnRec (s_member cmpname n (view defnAnFree d)) d

        || mark mutally-recursive defns as recursive
        markRec defs ns
            = foldr (m_adjust cmpname (set defnAnRec True)) defs ns
