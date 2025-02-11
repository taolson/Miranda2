|| desugar.m -- AST desugaring to a more simplified AST form
||
|| TODO: look at unifying the desugaring of explicit case exprs with "matchCtor"


%export desugar

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


|| state passed through desugar
||
|| dynamic state:
|| genv: global environment
|| errs: exceptions
|| lits: map of literals to unique literal definitions
||
|| lexical state:
|| loc:  location info from enclosing definition
||
dsDynSt == (globalEnv, [exception], m_map expr name)
dsLexSt == locInfo
dsSt    == (dsDynSt, dsLexSt)

|| lenses for dsSt fields
dsDyn      = lensFst
dsLex      = lensSnd
dsGenv     = composeLens dsDyn lensTup3_0
dsErrs     = composeLens dsDyn lensTup3_1
dsLits     = composeLens dsDyn lensTup3_2
dsLoc      = dsLex
dsDefnPath = composeLens dsLoc locInfoDefnPath
dsLocation = composeLens dsLoc locInfoLocation
dsGen      = composeLens dsGenv lensTup3_2
dsModName  = dsGenv $composeLens genvMod $composeLens modName

initDsSt :: globalEnv -> dsSt
initDsSt genv = ((genv, [], m_empty), emptyLocInfo)

|| add an exception to the desugar state
addDsErr :: exceptionInfo -> dsSt -> dsSt
addDsErr ei st = over dsErrs ((Error, ei, view dsLoc st) :) st


|| an equation is a tuple of unmatched patterns, a final expression, and a rename map 
equation == ([pat], expr, nameMap)

equationPats :: equation -> [pat]
equationPats (pats, e, m) = pats


|| algorithm for desugaring function definitions with multiple (possibly complex) patterns:
|| convert a list of equations into a case tree with only simple patterns, performing them
|| in parallel on the first argument, breaking that down into other case trees on the subsequent arguments
|| can return exceptions
match :: [name] -> [equation] -> state dsSt expr

|| general base case: insert the renameMap into the rhs by introducing an Elet with simple DefPats,
|| then fold the new rhs values into a fatbar sequence with an Efail at the end
match [] eqns st
    = (builtinFail, addDsErr Arity st),           if any (not . null . equationPats) eqns
    = (hd rhss, st),                              if #rhss == 1         || optimization for common case to remove extraneous fatbars
    = (foldr builtinFatbar builtinFail rhss, st), otherwise             || can there ever be more than one eqn?
      where
        loc                    = fromMaybe emptyLocation . view dsLocation $ st
        rhss                   = map addRenames eqns
        addRenames (x, rhs, m) = rhs,                                            if m_null m
                               = Elet True m_empty (map mkPat (m_toList m)) rhs, otherwise      || introduce a new Let binding to rename the vars 
        mkPat (k, v)           = DefPat (Pvar k) (Evar v) (locAnno loc)                         || rename k to v -- will be optimized out during rename

match (var : vars) eqns st
    = (builtinFail, addDsErr Arity st),              if any (null . equationPats) eqns
    = handleEqnGroup (hd eqnGroups) st,              if #eqnGroups == 1 || optimization for common case to remove extraneous fatbars
    = foldr seqEqnGroup (builtinFail, st) eqnGroups, otherwise
      where
        eqnGroups                 = groupBy sameFirstPatType eqns
        seqEqnGroup eqns (e2, st) = (builtinFatbar e1 e2, st') where (e1, st') = handleEqnGroup eqns st

        handleEqnGroup eqns
            = match         vars eqns',        if isPwildcard firstPat
            = matchVar  var vars peqns,        if isPvar      firstPat
            = matchLit  var vars peqns,        if isPlit      firstPat
            = matchCtor var vars peqns,        if isPctor     firstPat
            = error "match: unknown eqnGroup", otherwise
              where
                peqns     = map extractFirstPat eqns
                pats      = map fst peqns
                firstPat  = hd pats
                eqns'     = map snd peqns

        sameFirstPatType e1 e2
            = ~null ps1 & ~null ps2 & samePatType p1 p2
              where
                ps1 = equationPats e1
                ps2 = equationPats e2
                p1  = hd ps1
                p2  = hd ps2

        extractFirstPat ((p : ps), e, m) = (p, (ps, e, m))
        extractFirstPat _                = error "match: extractFirstPat empty patterns"

|| match a group of variables (irrefutable)
|| rename the peqn Pvar name to the common var, or report a name clash error
|| if the name already exists in the rename map
matchVar :: name -> [name] -> [(pat, equation)] -> state dsSt expr
matchVar var vars peqns
    = st_mapM (addRename var) peqns >>= match vars
      where
        addRename n' (Pvar n, (p, e, m))
            = st_pure (p, e, m_insert cmpname n n' m),                        if isNothing mn
            = st_fmap (const (p, e, m)) (st_modify (addDsErr (NameClash n))), otherwise
              where
                mn = m_lookup cmpname n m
        addRename n' (p, eqn) = st_pure eqn

|| match a group on the same literal (refutable)
matchLit :: name -> [name] -> [(pat, equation)] -> state dsSt expr
matchLit var vars peqns st
    = (Ecase Cvectored (tst (hd pats)) [falseCase, trueCase], st')
      where
        (pats, eqns)   = unzip2 peqns
        (e', st')      = match vars eqns st
        falseCase      = CaseAlt (Pctor stdFalseName []) builtinFail
        trueCase       = CaseAlt (Pctor stdTrueName  []) e'

        tst (Plit lit) = ap2 (eqOpForLit lit) (Evar var) lit
        tst _          = undef           || added to remove compiler warning



|| match a group of constructors of the same type (irrefutable, if all ctor groups are irrefutable)
matchCtor :: name -> [name] -> [(pat, equation)] -> state dsSt expr
matchCtor var vars peqns st
    = (builtinFail, addDsErr (Undefined ctor) st), if isNothing mcns \/ isNothing mspec
    = (Ecase sel (Evar var) alts', st2),           otherwise
      where
        genv              = view dsGenv st
        ctor              = getCn (hd peqns)
        mspec             = lookupSpec genv ctor
        dname             = typeName . baseType . view defnType . fromJust $ mspec
        mcns              = lookupCtorNames genv ctor
        cns               = fromJust mcns
        sel               = Csingle, if #cns == 1
                          = Cvectored, if #cns <= maxCaseVectored
                          = Cpriority, otherwise
        (ctorGroups, st1) = partitionByCtorName sel cns peqns st
        (st2, alts)       = mapAccumL handleCtorGroup st1 ctorGroups
        alts'             = alts,                                    if #alts == #cns
                          = alts ++ [CaseAlt Pwildcard builtinFail], otherwise
        getCn (p, e)      = ctorName p

        handleCtorGroup st (ctor, [])     || empty group is unhandled ctor; create dummy vars to match to pass typecheck
            = (st', (CaseAlt (Pctor ctor vars) builtinFail))
              where
                arity      = fromMaybe 0 (lookupArity (view dsGenv st) ctor)
                (gen', ns) = genNames "var" (view dsGen st) [1 .. arity]
                vars       = map Pvar ns
                st'        = set dsGen gen' st

        handleCtorGroup st (ctor, grp)
            = (st', alt)
              where
                (ps, es)           = unzip2 grp
                cVars              = map ctorVars ps
                (gen', vars')      = genNames "var" (view dsGen st) (hd cVars)
                es'                = zipWith insertPats cVars es
                (e', st')          = match (vars' ++ vars) es' (set dsGen gen' st)
                alt                = CaseAlt (Pctor ctor (map Pvar vars')) e'
        insertPats ps1 (ps2, e, m) = (ps1 ++ ps2, e, m)

        partitionByCtorName sel []         []   st = ([], st)
        partitionByCtorName sel []         elts st = ([], addDsErr ((BadCtor dname . ctorName . fst . hd) elts) st)
        partitionByCtorName sel (cn : cns) elts st = ((cn, p1) : rest, st'), if ~null p1 \/ _eq cmpcaseSel sel Cvectored
                                                   = (rest, st'),            otherwise
                                                     where
                                                       cs          = getName cn
                                                       (p1, p2)    = partition ((==$ cs) . getName . getCn) elts
                                                       (rest, st') = partitionByCtorName sel cns p2 st


|| a ctorEqn is a ctor name, its pattern vars, and an expression 
ctorEqn == (name, [pat], expr)

|| algorithm for desugaring (possibly complex) pattern definitions
|| build a case tree from a list of ctorEqns, renaming all the patterns to local variables and collecting a rename
|| mapping of the Pvars
patCaseTree :: [ctorEqn] -> nameMap -> state dsSt (expr, [name])

|| base case: return a tuple expr of all the Evars renaming Pvars in the case tree, along with the corresponding Pvar names
patCaseTree [] mr st = ((makeTupleExpr . map Evar . m_elems $ mr, m_keys mr), st)

|| build a case tree, converting ctorEqns to Ecase exprs
|| works bidirectionally, building the rename map going down, then building the case tree coming back up
patCaseTree ((c, ps, rhs) : cs) mr st
    = ((Ecase sel rhs alts, vns), st2)
      where
        mcns                = lookupCtorNames (view dsGenv st) c
        sel                 = Csingle,   if isJust mcns & #(fromJust mcns) == 1 || case is irrefutable if there is a single ctor
                            = Cpriority, otherwise
        (vs, cs', mr', st1) = foldr renameVar ([], [], mr, st) ps
        ((ct, vns), st2)    = patCaseTree (cs ++ cs') mr' st1
        ctorAlt             = CaseAlt (Pctor c vs) ct
        failAlt             = CaseAlt Pwildcard builtinFail
        alts                = [ctorAlt],          if _eq cmpcaseSel sel Csingle
                            = [ctorAlt, failAlt], otherwise
        renameVar p rvs
            = go p
              where
                (vs, cs, mr, st) = rvs

                go Pwildcard     = (Pwildcard : vs, cs, mr, st)

                go (Pvar n)
                    = (vs, cs, mr, addDsErr (NameClash n) st),           if m_member cmpname n mr
                    = (Pvar n' : vs, cs, m_insert cmpname n n' mr, st'), otherwise
                      where
                        (n', st') = st_genName (getName n) st

                go (Plit e)
                    = (Pvar n : vs, (stdTrueName, [], ap2 (eqOpForLit e) (Evar n) e) : cs, mr, st')
                      where
                        (n, st') = st_genName "lit" st

                go (Pctor c pats)
                    = (Pvar n : vs, (c, pats, Evar n) : cs, mr, st')
                      where
                        (n, st') = st_genName "ctor" st

                go _ = undef    || added to remove compiler warning

                st_genName n st
                    = (n', set dsGen gen' st)
                      where
                        (gen', n') = genName n (view dsGen st)


desugarAst :: astRewriteTraverser dsSt

|| desugar defs and pats in an Elet, then fold the desugared pats (now simple Pvars) into the defs
desugarAst k (Elet rec defs pats e) st
    = (Elet rec defs2 [] e', st2)
      where
        topLevel                      = null (view dsDefnPath st)       || see if we are desugaring a top-level defn
        mn                            = view dsModName st
        (Elet _ defs1 pats' e', st1)  = k (Elet rec defs pats e) st     || desugar the sub-asts of the Elet
        (defs2, st2)                  = foldl insOrAddErrs (defs1, st1) $ flattenDefns pats'
        insOrAddErrs (defs, st) d     = (defs, over dsErrs (errs ++) st), if isLeft dm
                                      = (defs', st'),                     if isUnresolved dn
                                      = (defs', st),                      otherwise
                                        where
                                          dn               = defnName d
                                          dm               = insDefnMap d' defs
                                          Right (defs', _) = dm
                                          Left errs        = dm
                                          d'               = qualifyDefn mn d, if topLevel
                                                           = d,                otherwise
                                          st'              = addDsErr (QualBind dn) st

|| desugar a list comprehension e.g. [(x * x, y) | x, y <- [1 .. 10]]
|| instead of using a strategy similar to the list monad (bind = concatMap, return x = [x]), which does a lot of extra
|| consing and unconsing, this implementation threads the list building code through the desugaring of the qualifiers
|| with the variable 'c'.  The subfunctions dsGenSingle and dsGenMult are written in continuation-passing style
|| (passing a nextQual continuation) to allow the threading of the variable 'k' and allow dsGenSingle to be called from
|| both dsQuals and dsGenMult
desugarAst k (ElistComp e quals an) st
    = k e' st'
      where
        (e', st')                            = dsQuals quals builtinNil st
        dsQuals []                      c st = (ap2 builtinCons e c, st)
        dsQuals ((Qgen [p] ge) : qs)    c st = dsGenSingle ge p    c st $ dsQuals qs
        dsQuals ((Qgen ps  ge) : qs)    c st = dsGenMult   ge ps   c st $ dsQuals qs
        dsQuals ((Qrecur p be fe) : qs) c st = dsGenRecur  be fe p c st $ dsQuals qs
        dsQuals ((Qguard tst)  : qs)    c st = dsGenGuard  tst     c st $ dsQuals qs
        dsQuals _                       _ _  = error "dsQuals: non-qualifier"

        || desugar a guard generator e.g. x > 10;
        dsGenGuard tst c st nextQual
            = (Ecase Cvectored tst [mkCase stdFalseName [] c, mkCase stdTrueName [] e], st')
              where
                (e, st')        = nextQual c st
                mkCase n vars e = CaseAlt (Pctor n vars) e

        || desugar a recurrence pattern generator e.g. (a, b) <- (1, 2), (a + b, b * 2) ...
        dsGenRecur be fe p c st nextQual
            = (Elet True (m_singleton fn fnDef) [] (Eap (Evar fn) be), st')
              where
                (gen', fn) = genName "`gen" (view dsGen st)                             || name of generator function
                (e, st')   = nextQual (Eap (Evar fn) fe) (set dsGen gen' st)            || pass (go fe) as the threaded list builder "c"
                fnDef      = DefMult Mfun [DefFn fn [p] e an]                           || built as DefMult to allow easy complex pattern desugaring later

        || desugar a single-pattern generator e.g. x <- xs;
        dsGenSingle ge p c st nextQual
            = (Elet True (m_singleton fn fnDef) [] (Eap (Evar fn) ge), st')
              where
                (gen1, fn) = genName "`gen" $ view dsGen st                             || name of generator function
                (gen2, a1) = genName "var" gen1                                         || a1 is rest of list for (p : a1) pattern in cons case
                goA1       = Eap (Evar fn) (Evar a1)                                    || expr to do rest of list
                (e, st')   = nextQual goA1 $ set dsGen gen2 st                          || pass goA1 as threaded list builder "c"
                nilCaseFn  = DefFn fn [(Pctor builtinNilName [])] c an                  || call c (either builtinNil or the fn of an outer generator)
                consCaseFn = mkConsCase p e                                             || case for passing pattern match of p
                failCaseFn = mkConsCase Pwildcard goA1                                  || case for failing pattern match of p, (silently discard)
                fnDef      = DefMult Mfun [nilCaseFn, consCaseFn, failCaseFn], if refutable p
                           = DefMult Mfun [nilCaseFn, consCaseFn],             otherwise

                mkConsCase p e = DefFn fn [(Pctor builtinConsName [p, (Pvar a1)])] e an

                || patterns which fail matching should silently continue with the rest of the list
                || however, adding a wildcard match to the end of each case results in a lot of "unreachable pattern"
                || warnings.  Since most patterns are irrefutable, we track refutability, and only add the fail case
                || when the pattern can be refutable:
                refutable (Plit _)       = True
                refutable (Pctor n vars) = isNothing mcns \/ #cns > 1 \/ any refutable vars
                                           where
                                             mcns = lookupCtorNames (view dsGenv st) n
                                             cns  = fromJust mcns
                refutable p              = False

        || desugar a multiple-pattern generator e.g. x, y <- zs;
        dsGenMult ge ps c gen nextQual
            = (Elet True (m_singleton n (DefPat (Pvar n) ge an)) [] e, st')           
              where
                (gen', n)        = genName "lst" $ view dsGen st                        || define a common variable n for the generator ge to use
                                                                                        || on multiple quals
                (e, st')         = go ps c $ set dsGen gen' st                          || generate for each pattern in a qualifier
                go []       c st = nextQual c st                                        || base case -- continue with next qualifier
                go (p : ps) c st = dsGenSingle (Evar n) p c st (go ps)                  || generate first pat using dsGenSingle with a continuation of the rest

|| desugar if/otherwise conditionals
desugarAst k (Econd conds) st
    = k caseTree st
      where
        caseTree                 = foldr mkCase builtinFail conds
        mkCase (Cdefault e) rest = e            || early-out on default so that the base case Efail is not importd
        mkCase (Cif tst e)  rest = Ecase Cvectored tst [CaseAlt (Pctor stdFalseName []) rest, CaseAlt (Pctor stdTrueName []) e]
        mkCase _            _    = undef        || added to remove compiler warning

|| desugar explicit case exprs (set the caseSel flag correctly)
desugarAst k (Ecase Cnone e alts) st
    = k (builtinFatbar (Ecase sel e alts') (Eap stdCaseFail (genLoc loc))) st
      where
        genv                  = view dsGenv st
        loc                   = fromJust . snd . view dsLoc $ st
        (sel, alts')          = checkPats $ map getPat alts
        sequentialFromZero xs = and $ zipWith (==) [0 ..] xs
        sortedLitAlts         = sortOn cmpint getLit alts
        sortedCtorAlts        = sortOn cmpint getCtorTag alts
        failAlt               = CaseAlt Pwildcard builtinFail
        allCtors              = map getName . fromMaybe [] . lookupCtorNames genv . getCtorName . hd $ alts

        getPat (CaseAlt p e)  = p
        getPat _              = undef   || added to remove compiler warning

        getLit (CaseAlt (Plit (EprimInt n)) e) = n
        getLit _                               = undef || added to remove compiler warning

        getCtorName (CaseAlt (Pctor n vars) e) = n
        getCtorName _                          = undef || added to remove compiler warning

        getCtorTag (CaseAlt (Pctor n vars) e) = fromMaybe 0 $ elemIndex cmpstring (getName n) allCtors
        getCtorTag _                          = undef || added to remove compiler warning

        checkPats ps
            = (Csingle,   alts),              if #ps == 1 & irrefutable lastPat
            = (Cvectored, sortedCtorAlts),    if all isPctor ps & #ps == #allCtors & sequentialFromZero (map getCtorTag sortedCtorAlts)
            = (Cvectored, sortedLitAlts),     if all isPlit ps & #ps == 3 & sequentialFromZero (map getLit sortedLitAlts) || 0#,1#,2# for cmp# result value
            = (Cpriority, alts),              if irrefutable lastPat
            = (Cpriority, alts ++ [failAlt]), otherwise
              where
                lastPat       = last ps
                irrefutable p = isPvarOrWild p \/ isPctor p & #allCtors == 1

|| add defn names and locations to lexical state while traversing
|| rewrite literals to common dsLits references
desugarAst k a st
    = desugarDef k a top (over dsLoc (mergeLocInfo loc) st), if isDefn a
    = desugarLit k a st,                                     if isLit a & ~isUnboxed a
    = k a st,                                                otherwise
      where
        loc     = defnLocInfo a
        top     = null (view dsDefnPath st)


|| desugar a pattern definition
|| strategy:
|| * collect all ((Pvar n), rename) pairs while building a caseTree for the constructors and literals
|| * generate a new var that is a tuple of all (Evar n) bindings from the case tree
|| * for each Pvar, make a new DefPat (Pvar n) rhs' where rhs' is the correct selection from the generated tuple
|| * return the rewritten DefPat, along with the new accessor definitions in a DefMult
|| also includes optimizations for common, simple patterns
|| note: top-level patterns need to generate a Private name for the common tuple and qualify the accessors with the module name
desugarDef k (DefPat (Pctor c pats) rhs an) topLevel st
    = k (DefMult Mpat (caseDef ns : accs)) st2, if numPatVars > 0
      where
        mn                    = view dsModName st
        gen                   = view dsGen st
        (gen1, ctn)           = genPrivateName mn "patMatch" gen, if topLevel
                              = genName "`patMatch" gen,          otherwise
        st1                   = set dsGen gen1 st
        ((caseTree, ns), st2) = ((rhs, map unPvar pats), st1),                                      if simpleCtor
                              = patCaseTree [(c, pats, rhs)] m_empty st1,                           otherwise
        numPatVars            = #ns
        singlePatVar          = numPatVars == 1
        cn                    = c,                                                                  if simpleCtor                              
                              = builtinTupleName numPatVars,                                        otherwise

        patMatch              = Eap (builtinSel c 0) caseTree,                                      if simpleCtor & singlePatVar & useSel
                              = makeSel c 0 caseTree,                                               if simpleCtor & singlePatVar
                              = caseTree,                                                           if simpleCtor
                              = builtinFatbar caseTree . Eap stdMatchFail . genLoc $ view anLoc an, otherwise

        caseDef [n]           = DefPat (Pvar n)   patMatch an  || single renamed variable
        caseDef ns            = DefPat (Pvar ctn) patMatch an  || allocate var for tuple of renamed variables
        accs                  = [],                                if singlePatVar
                              = map makeAccessor $ zip2 ns [0 ..], otherwise

        makeAccessor (n, i)   = DefPat (Pvar n) (Eap (builtinSel cn i) (Evar ctn)) an, if useSel
                              = DefPat (Pvar n) (makeSel cn i (Evar ctn)) an,          otherwise

        makeSel c i    e      = Ecase Csingle e [CaseAlt (Pctor c args) (Evar a)]
                                where
                                   a    = Internal "a" 0
                                   args = map mkVar [0 .. numPatVars - 1]

                                   mkVar n
                                     = Pvar a, if n == i
                                     = Pwildcard, otherwise

        singleCtor            = (== 1) . length . fromMaybe [] . lookupCtorNames (view dsGenv st)
        simpleCtor            = singleCtor c & all isPvar pats

|| a DefPat that isn't a Pctor or Pvar, or has no variables to bind is a bad pattern
desugarDef k (DefPat p rhs an) topLevel st
    = (DefPat p rhs an, addDsErr (BadPattern p) st), if ~isPvar p

|| desugar patterns in a DefMult of function definitions, replacing it with a single DefFn
|| with an irrefutable pattern desugared using a case tree
desugarDef k (DefMult Mfun defs) topLevel st
    = k (DefFn fname (map Pvar varNames) caseExpr an) st2
      where
        d                = hd defs
        pats             = map fnVars defs
        rhss             = map fnExpr defs
        arity            = max cmpint (map length pats)        || use max pat as arity for all pats
        gen              = view dsGen st
        fname            = defnName d
        an               = defnAnno d
        (gen', varNames) = genNames "var" gen [1 .. arity]
        st1              = set dsGen gen' st
        (caseTree, st2)  = match varNames (zip3 pats rhss (repeat m_empty)) st1
        caseExpr         = builtinFatbar caseTree . Eap stdCaseFail . genLoc $ view anLoc an

desugarDef k a topLevel st = k a st


|| rewrite literal values in an expression to var references to a canonical literal
|| and collect them in a map
desugarLit k e st
    = (Evar v', st'), if isNothing mv
    = (Evar v,  st),  otherwise
      where
        mn         = view dsModName st
        gen        = view dsGen st
        mv         = m_lookup cmpexpr e $ view dsLits st
        v          = fromJust mv
        (gen', v') = genPrivateName mn "lit" gen
        st'        = over dsLits (m_insert cmpexpr e v') $ set dsGen gen' st

|| make a common definition for a literal expression
mkLit :: string -> (expr, name) -> defn
mkLit mn (l, v)
    = DefPat (Pvar v) (Eap ctor l') an
      where
        an             = locAnno $ initLocation mn
        (ctor, l')     = go l
        go (Eint n)    = (stdIntCtor, EprimInt n)
        go (Echar c)   = (stdCharCtor, EprimChar c)
        go (Estring s) = (stdReadByteStream, EprimString s)
        go _           = error "mkLit: non literal pattern"

|| desugar the complex patterns, list comprehensions, and conditionals in a module to simpler AST forms,
|| merging the desugared patterns into the defnMap
desugar :: globalEnv -> excpt globalEnv
desugar genv
    = ex_return genv' warns, if null errs
    = ex_errs   errs,        otherwise
      where
        m                 = view genvMod genv
        mn                = view modName m
        defs              = view modDefns m
        pats              = view modPats m
        ((defs1, _), st') = astRewriteInLet (astRewriteLex desugarAst) defs pats $ initDsSt genv
        litPats           = (map (mkLit mn) . m_toList . view dsLits) st'
        defs2             = foldr insDefnMapUnchecked defs1 litPats
        genv'             = over genvMod (set modDefns defs2 . set modPats []) $ view dsGenv st'
        (errs, warns)     = partition isError $ view dsErrs st'
