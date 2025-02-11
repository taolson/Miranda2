|| grammar.m -- Miranda2 expression, type, and definition grammars


%export + -precAssocTable

%import <lens>
%import <map>
%import <maybe>
%import <mirandaExtensions>
%import <set>
%import "name"


|| Miranda2 grammar
||
|| The grammar has a unified AST to allow for easy traversal and rewriting, but these
|| types are synonyms to document the actual types

expr    == ast
cond    == ast
caseAlt == ast
qual    == ast
pat     == ast
texpr   == ast
tform   == ast
defn    == ast

ast ::=
        || expr
        Evar        name                       |
        Eint        int                        |
        Echar       char                       |
        Estring     string                     |
        EprimInt    int                        |       || represents an unboxed Int#
        EprimChar   char                       |       || represents an unboxed Char#
        EprimString string                     |       || represents an unboxed Addr# for a primitive C String
        Eap         expr expr                  |
        Ecall       expr [expr]                |       || folded version of Eap e1 (Eap e2 ..) -- call a fn with arguments
        Econd       [cond]                     |       || conditional expr
        Ecase       caseSel expr [caseAlt]     |       || caseSel is case selection type for selecting a caseAlt
        Efail       expr                       |       || non-local jump to expr of the enclosing Efatbar
        Efatbar     pat  expr expr             |       || expr1, if not FAIL; expr2 otherwise
        Elet        bool defnMap [defn] expr   |       || bool selects Elet or EletRec, defnMap for DefFns, [defn] for DefPats, initially
        ElistComp   expr [qual] anno           |       || location used to report any errors encountered during desugaring

        || cond
        Cif         expr expr                  |
        Cdefault    expr                       |

        || caseAlt
        CaseAlt     pat expr                   |

        || qual
        Qgen        [pat] expr                 |       || list comprehension generator, e.g. x <- [1 .. 10]
        Qrecur      pat   expr expr            |       || list comprehension recurrence, e.g. x <- 1, 2 * x ...
        Qguard      expr                       |       || list comprehension guard, e.g. x > 5

        || pat
        Pvar        name                       |       || pattern is a variable to bind (irrefutable)
        Plit        expr                       |       || pattern is a literal to match against
        Pctor       name [pat]                 |       || pattern is a constructor to match against
        Pwildcard                              |       || pattern is an ignored wildcard (irrefutable)

        || texpr, tform
        Tname       name    [texpr]            |       || named constant type with optional list of Tvars (for defn tforms)
                                                       || or a fully-saturated application of a higher-kinded type

        Tvar        int                        |       || type variable
        Ttuple      [texpr]                    |       || n-tuple type
        Tlist       texpr                      |       || list type
        Tarr        texpr   texpr              |       || arrow (function type) e.g. int -> char
        Tstrict     texpr                      |       || strict form, used in constructor arguments

        || defn                           
        DefFn       name    [pat]  expr  anno  |       || name, vars, rhs
        DefMult     multSel [defn]             |       || grouping for multiple DefFns of the same name or a DefPat and its accessors
        DefPat      pat     expr         anno  |       || pattern to match, rhs
        DefSyn      tform   texpr        anno  |       || type synonym e.g. tform == (string, [texpr])
        DefData     tform   [tform]      anno  |       || constructor type
        DefSpec     tform   texpr        anno  |       || type specification
        DefAbs      tform   [defn] texpr anno          || abstract type definition, along with its implementation type


|| case selection type
|| generated during desugaring to qualify an Ecase and its CaseAlts
caseSel ::=
    Cnone       |       || no selection type specified
    Csingle     |       || single case alt
    Cpriority   |       || priority selection on case-by-case basis (for non-saturated alts list or for a too-large alt list)
    Cvectored           || vectored selection of a saturated case

|| mult selection type
|| DefMults are used to collect together fnforms of the same function name (which eventually get desugared to a single DefFn),
|| and collect together a pattern DefPat and its accessor patterns during pattern desugaring.  This type is used to differentiate
|| them, rather than having separate DefMultFn and DefMultPat constructors.
multSel ::=
    Mfun        |       || mult for DefFn
    Mpat                || mult for DefPat (and its accessor functions)

|| annotation for definitions
anno == (location, bool, int, int, s_set name, s_set int)         || loc, recursive, complexity, use count, free vars, strictness info

|| lenses for annotation fields
anLoc    = lensTup6_0
anRec    = lensTup6_1
anCpx    = lensTup6_2
anUses   = lensTup6_3
anFree   = lensTup6_4
anStrict = lensTup6_5

emptyAnno :: anno
emptyAnno = (emptyLocation, False, 0, 0, s_empty, s_empty)

locAnno :: location -> anno
locAnno loc = set anLoc loc emptyAnno


|| module name, line no for error reporting
location == (string, int, int)

emptyLocation :: location
emptyLocation = ("", 0, 0)

initLocation :: string -> location
initLocation mn = (mn, 0, 0)


|| showS is a difference list, which takes a string to append to the right to produce the final string.
|| this allows the final stream to be built from function composes, which can be traversed faster than a chain of (++)
|| which are left-associated
showS == string -> string

shows :: string -> showS
shows s = (s ++)

showsint :: int -> showS
showsint n = (showint n ++)

showschar :: char -> showS
showschar c
    = (("\'" ++ showEscChar c ++ "\'") ++)
      where
        showEscChar '\a' = "\\a"
        showEscChar '\b' = "\\b"
        showEscChar '\f' = "\\f"
        showEscChar '\n' = "\\n"
        showEscChar '\r' = "\\r"
        showEscChar '\t' = "\\t"
        showEscChar '\v' = "\\v"
        showEscChar '\\' = "\\"
        showEscChar c    = "\\" ++ showsint n "" , if n < 32
                         = [c],                    otherwise
                           where n = code c

showsstring :: string -> showS
showsstring s = shows $ showstring s

showsName :: name -> showS
showsName n = shows $ showName n

showsAnno :: anno -> showS
showsAnno (loc, rec, cpx, uses, free, strict)
    = ([] ++)
|| use the version below to see the full anno information
||    = shows "{" . showsRec . showsint cpx . shows " " . showsint uses .
||      shows " [" . interShows ", " (map showsName (s_toList free)) . shows "]" .
||      shows " [" . interShows ", " (map showsint (s_toList strict)) . shows "]}"
||      where
||        showsRec = shows "Rec ", if rec
||                 = shows "",     otherwise

showsLocation :: location -> showS
showsLocation (mn, el, ec)
    = shows "in module " . shows mn . showsLineCol el ec
      where
        showsLineCol 0 0   = id         || don't show if from empty location
        showsLineCol el ec = shows " near line " . showsint el . shows " col " . showsint ec

showsInParens, showsInBrackets, showsInBraces  :: showS -> showS
showsInParens   s = shows "(" . s . shows ")"
showsInBrackets s = shows "[" . s . shows "]"
showsInBraces   s = shows "{" . s . shows "}"

|| wrap a showS in parens if the boolean guard is true
showsInParensIf :: bool -> showS -> showS
showsInParensIf True  s = shows "(" . s . shows ")"
showsInParensIf False s = s

|| like intercalate, but for shows
interShows :: string -> [showS] -> showS
interShows s []         = id
interShows s (sh : shs) = foldl (.) sh . map (shows s .) $ shs

|| show a list of ast variables in a sequence
showsAstList :: [ast] -> showS
showsAstList as = interShows " " . map (showsAstPrec (apPrec + 1)) $ as

|| show an ast in the context of outer precedence d
showsAstPrec :: int -> ast -> showS

|| atomic asts can ignore precedence
showsAstPrec x (Evar n)        = showsName n
showsAstPrec x (Eint n)        = showsint n
showsAstPrec x (Echar c)       = showschar c
showsAstPrec x (Estring s)     = showsstring s
showsAstPrec x (EprimInt n)    = showsint n . shows "#"
showsAstPrec x (EprimChar c)   = showschar c . shows "#"
showsAstPrec x (EprimString s) = showsstring s . shows "#"
showsAstPrec x (Pvar n)        = showsName n
showsAstPrec x Pwildcard       = shows "_"
showsAstPrec x (Tvar n)        = shows s
                                 where
                                   s = rep n '*',       if n < 6
                                     = '*' : showint n, otherwise

|| check to see if an ap2 is an in-line operator
showsAstPrec d (Eap (Eap (Evar op) e1) e2)
    = showsOpPrec d op e1 e2, if isSymbol op

showsAstPrec d (Eap e1 e2)
    = showsInParensIf (d > apPrec) $ showsAstPrec apPrec e1 . shows " " . showsAstPrec (apPrec + 1) e2

showsAstPrec d (Ecall (Evar f) args)
    = showsOpPrec d f (args ! 0) (args ! 1), if isSymbol f & #args == 2
    = showsInParensIf (d > apPrec) s0, if null args
    = showsInParensIf (d > apPrec) s1, otherwise
      where
        s0 = showsName f
        s1 = showsName f . shows " " . showsAstList args

showsAstPrec d (Ecall ef args)
    = showsInParensIf (d > apPrec) $ showsAstPrec apPrec ef . shows " " . showsAstList args

showsAstPrec d (Efail e)
    = showsInParensIf (d > apPrec) $ shows "FAIL " . showsAstPrec (apPrec + 1) e

showsAstPrec d (Efatbar p e1 e2)
    = showsInParensIf (d > apPrec) $ shows "FATBAR " . showsAstPrec apPrec' p . shows " " . showsAstPrec apPrec' e1 . shows " " . showsAstPrec apPrec' e2
      where apPrec' = apPrec + 1

showsAstPrec d (Tarr t1 t2)
     = showsInParensIf (d > 0) $ showsAstPrec 1 t1 . shows " -> " . showsAstPrec 0 t2

showsAstPrec d (Pctor n vars)
    = showsOpPrec d n (vars ! 0) (vars ! 1), if isSymbol n & #vars == 2
    = showsName n,                           if null vars
    = showsInParensIf (d > apPrec) s,        otherwise
      where
        s = showsName n . shows " " . showsAstList vars

showsAstPrec d (Tname n vars)
    = shows (showName n),             if null vars
    = showsInParensIf (d > apPrec) s, otherwise
      where
        s = showsName n . shows " " . showsAstList vars

showsAstPrec d (Plit e)    = showsAstPrec d e
showsAstPrec d (Tstrict t) = showsAstPrec d t . shows " !"

|| asts with additional syntax that act at apPrec
showsAstPrec d a
    = showsInParensIf (d > apPrec) $ go a
      where
        go (Econd conds)         = showsInBraces $ interShows "; = " $ map (showsAstPrec apPrec) conds
        go (ElistComp e qs an)   = showsInBrackets $ showsAstPrec 0 e . shows " | " . (interShows "; " $ map (showsAstPrec 0) qs)
        go (Cif tst e)           = showsAstPrec 0 e . shows ", if " . showsAstPrec 0 tst
        go (Cdefault e)          = showsAstPrec 0 e . shows ", otherwise"
        go (CaseAlt p e)         = showsAstPrec 0 p . shows " -> " . showsAstPrec 0 e
        go (Qgen pats e)         = (interShows ", " $ map (showsAstPrec 0) pats) . shows " <- " . showsAstPrec 0 e
        go (Qrecur p e1 e2)      = showsAstPrec 0 p . shows " <- " . showsAstPrec 0 e1 . shows ", " . showsAstPrec 0 e2 . shows " .."
        go (Qguard e)            = showsAstPrec 0 e
        go (Ttuple elts)         = showsInParens $ (interShows ", " $ map (showsAstPrec 0) elts)
        go (Tlist t)             = showsInBrackets $ showsAstPrec 0 t
        go (DefMult m ds)        = interShows "; " $ map (showsAstPrec 0) ds
        go (DefFn n vars rhs an) = showsName n . showsAnno an . shows " " . showsAstList vars . shows " = " . showsAstPrec 0 rhs
        go (DefPat p rhs an)     = showsAstPrec 0 p . showsAnno an . shows " = "  . showsAstPrec 0 rhs
        go (DefSpec tf te an)    = showsAstPrec 0 tf . shows " :: " . showsAstPrec 0 te
        go (DefSyn tf te an)     = showsAstPrec 0 tf . shows " == " . showsAstPrec 0 te
        go (DefData tf [] an)    = showsAstPrec 0 tf . shows " :: type"
        go (DefData tf ctors an) = showsAstPrec 0 tf . shows " ::= " . interShows " | " (map (showsAstPrec 0) ctors)
        go (DefAbs tf ds te an)  = shows "abstype " . showsAstPrec 0 tf . shows " == " . showsAstPrec 0 te

        go (Ecase sel tst alts)
            = shows ("case" ++ sSel) . showsAstPrec apPrec tst . shows " of " . (showsInBraces $ interShows "; " $ map (showsAstPrec 0) alts)
              where
                sSel = "Vec ",    if _eq cmpcaseSel sel Cvectored
                     = " ",       otherwise

        go (Elet b fns pats e)
            = shows ("let" ++ sRec) . (showsInBraces $ interShows "; " $ map (showsAstPrec 0) defs) . shows " in " . showsAstPrec 0 e
              where
                defs = m_elems fns ++ pats
                sRec = "Rec ", if b
                     = " ",    otherwise

        go a = error $ "unhandled ast in showsprec: " ++ showast a

showsOpPrec :: int -> name -> expr -> expr -> showS
showsOpPrec d op e1 e2 
    = showsInParensIf (d > prec) s
      where
        s              = showsAstPrec precL e1 . shows (" " ++ showName op ++ " ") . showsAstPrec precR e2
        (prec, assoc)  = opPrecAssoc op
        (precL, precR) = (prec, prec + 1), if _eq cmpassoc assoc AssocLeft
                       = (prec + 1, prec), otherwise

showsAst :: ast -> showS
showsAst = showsAstPrec 0

showAst :: ast -> string
showAst a = showsAstPrec 0 a ""

showAstRaw :: ast -> string
showAstRaw a = showast a


reservedNames = s_fromList cmpstring ["if", "otherwise", "type", "where", "abstype", "with", "case", "of", "=", "::", "::=", "..", "|", "<-", "->"]

|| common name operations
isConstructor, isWildcard, isPrefix, isVar, isSymbol :: name -> bool
isTvarSymbol n  = all (==. '*') (getName n)
isConstructor n = isUpper c \/ c ==. ':' where c = hd (getName n)
isWildcard n    = getName n ==$ "_"
isPrefix n      = ((_eq cmpassoc AssocPrefix) . snd . opPrecAssoc) n
isVar n         = ~(isConstructor n \/ s_member cmpstring s reservedNames) where s = getName n

isSymbol n
    = ~letter c &  c ~=. '_'
      where
        s = getName n
        c0 = s ! 0
        c  = s ! 1, if c0 ==. '`'       || '`' used to mark internally-generated names; skip past it to get the real first char
           = c0,    otherwise


|| common expr operations

isEvar, isLit, isUnboxed, isCase, isFail, isCall, isLet, isCaseAlt, isSimpleExpr :: expr -> bool
isEvar (Evar n)           = True
isEvar e                  = False

isLit (Eint n)            = True
isLit (Echar c)           = True
isLit (Estring s)         = True
isLit (EprimInt n)        = True
isLit (EprimChar c)       = True
isLit (EprimString s)     = True
isLit e                   = False

isUnboxed (EprimInt n)    = True
isUnboxed (EprimChar n)   = True
isUnboxed (EprimString s) = True
isUnboxed e               = False

isCase (Ecase s tst alts) = True
isCase e                  = False

isFail (Efail e)          = True
isFail a                  = False

isCall (Ecall e args)     = True
isCall a                  = False

isLet (Elet b ds ps e)    = True
isLet a                   = False

isCaseAlt (CaseAlt p e)   = True
isCaseAlt a               = False

isSimpleExpr a = isEvar a \/ isUnboxed a \/ isTname a \/ isFail a

|| apply a function to two operands
ap2 :: expr -> expr -> expr -> expr
ap2 f e1 e2 = Eap (Eap f e1) e2


|| common pat operations

isPvar, isPlit, isPctor, isPwildcard, isPvarOrWild :: ast -> bool
isPvar (Pvar x)         = True
isPvar p                = False

isPlit (Plit x)         = True
isPlit pat              = False

isPctor (Pctor n vars)  = True
isPctor pat             = False

isPwildcard Pwildcard   = True
isPwildcard pat         = False

isPvarOrWild p          = isPvar p \/ isPwildcard p

unPvar :: texpr -> name
unPvar (Pvar n)         = n
unPvar a                = error $ "unPvar on non-pvar: " ++ showAst a

unTvar :: texpr -> int
unTvar (Tvar n)         = n
unTvar a                = error $ "unTvar on non-tvar: " ++ showAst a

ctorName :: ast -> name
ctorName (Pctor n vars) = n
ctorName p              = Unqualified ""

ctorVars :: ast -> [ast]
ctorVars (Pctor n vars) = vars
ctorVars p              = []

samePatType :: ast -> ast -> bool
samePatType (Pvar v1)     (Pvar v2)     = True
samePatType (Pctor n1 a1) (Pctor n2 a2) = True
samePatType (Plit l1)     (Plit l2)     = _eq cmpexpr l1 l2
samePatType Pwildcard     Pwildcard     = True
samePatType p1            p2            = False

qualifyPat :: string -> ast -> ast
qualifyPat modName (Pvar n) = Pvar $ qualifyName modName n
qualifyPat modName p        = p

|| names used for lexical bindings
patNames :: ast -> [name]
patNames (Pvar n)       = [n]
patNames (Pctor n vars) = concatMap patNames vars
patNames a              = []


|| common texpr and tform operations

isTname :: ast -> bool
isTname (Tname n vars)   = True
isTname a                = False

isTvar :: ast -> bool
isTvar (Tvar n)         = True
isTvar a                = False

isTarr :: ast -> bool
isTarr (Tarr t1 t2)      = True
isTarr a                 = False

tformName :: ast -> name
tformName (Tname n vars) = n
tformName a              = error $ "tformName on non-tform: " ++ showAst a

tformVars :: ast -> [ast]
tformVars (Tname n vars) = vars
tformVars a              = error $ "tformVars on non-tform: " ++ showAst a

qualifyTform :: string -> ast -> ast
qualifyTform modName (Tname n vars) = Tname (qualifyName modName n) vars
qualifyTform modName a              = error $ "qualifyTform on non-tform: " ++ showAst a

typeName :: texpr -> name
typeName (Tname n vars) = n
typeName (Ttuple tes)   = Builtin $ "tuple" ++ showint (#tes)
typeName (Tlist  te)    = Builtin $ "[" ++ getName (typeName te) ++ "]"
typeName (Tarr t1 t2)   = Builtin $ "(" ++ getName (typeName t1) ++ " -> " ++ getName (typeName t2) ++ ")"
typeName (Tstrict t)    = typeName t
typeName (Tvar n)       = Builtin "type"
typeName a              = error $ "typeName on non-tform: " ++ showAst a

isStrict :: ast -> bool
isStrict (Tstrict t) = True
isStrict t           = False

unStrict :: ast -> ast
unStrict (Tstrict t) = t
unStrict t           = t

|| return the individual components of a Tarr expr as a list, along with the final base type
typeList :: texpr -> ([texpr], texpr)
typeList (Tarr t1 t2)
    = (t1 : tl, bt)
      where
        (tl, bt) = typeList t2

typeList t = ([], t)

|| return the final type in a Tarr texpr
baseType :: texpr -> texpr
baseType t = snd . typeList $ t

|| return the nth type in a Tarr texpr
nthType :: int -> texpr -> texpr
nthType i t = fst (typeList t) ! i

|| return the arity of a texpr (count of the number of Tarrs at the top level)
typeArity :: texpr -> int
typeArity t = length . fst . typeList $ t


|| common defn operations

isDefn :: ast -> bool
isDefn (DefFn n vars e an)     = True
isDefn (DefMult m ds)          = True
isDefn (DefPat p e an)         = True
isDefn (DefSyn t ts an)        = True
isDefn (DefData tf ctors an)   = True
isDefn (DefSpec t1 t2 an)      = True
isDefn (DefAbs tf ds t an)     = True
isDefn a                       = False

|| used to differentiate defn types
isDefFn, isDefPat, isDefFnPat, isDefMult, isDefData, isDefSyn, isDefSpec, isDefAbs, isDefType, isSyn :: ast -> bool

isDefFn (DefFn n vars e an)     = True
isDefFn (DefMult m (d : ds))    = isDefFn d
isDefFn a                       = False

isDefPat (DefPat p e an)        = True
isDefPat (DefMult m (d : ds))   = isDefPat d
isDefPat a                      = False

isDefFnPat (DefFn n vars e an)  = True
isDefFnPat (DefPat p e an)      = True
isDefFnPat (DefMult m ds)       = True
isDefFnPat a                    = False

isDefMult (DefMult m ds)        = True
isDefMult a                     = False

isDefData (DefData tf ctors an) = True
isDefData a                     = False

isDefSyn (DefSyn tf te an)      = True
isDefSyn a                      = False

isDefSpec (DefSpec tf te an)    = True
isDefSpec a                     = False

isDefAbs (DefAbs tf ds t an)    = True
isDefAbs a                      = False

isDefType (DefData tf ctors an) = True
isDefType (DefSyn tf te an)     = True
isDefType (DefAbs tf ds t an)   = True
isDefType a                     = False

|| DefAbs act like DefSyns during synonym expansion
isSyn a = isDefSyn a \/ isDefAbs a

defnName :: ast -> name
defnName (DefFn n vars e an)    = n
defnName (DefMult m (d : ds))   = defnName d
defnName (DefPat (Pvar n) e an) = n
defnName (DefPat p e an)        = Unqualified "pattern"
defnName (DefSyn tf te an)      = tformName tf
defnName (DefData tf ctors an)  = tformName tf
defnName (DefSpec tf te an)     = tformName tf
defnName (DefAbs tf ds t an)    = tformName tf
defnName d                      = error $ "defnName on non-defn: " ++ showAst d

defnAnno :: ast -> anno
defnAnno (DefFn n vars e an)    = an
defnAnno (DefMult m (d : ds))   = defnAnno d
defnAnno (DefPat p e an)        = an
defnAnno (DefSyn tf te an)      = an
defnAnno (DefData tf ctors an)  = an
defnAnno (DefSpec tf te an)     = an
defnAnno (DefAbs tf ds t an)    = an
defnAnno d                      = error $ "defnAnno on non-defn: " ++ showAst d


|| lenses for anno field, to allow view / set / over operations on annotation fields of a definition
lensAnno :: lens defn anno
lensAnno
    = Lens defnAnno overf
      where
        overf fn (DefFn n vars e an)    = DefFn n vars e (fn an)
        overf fn (DefMult m (d : ds))   = DefMult m (overf fn d : ds)
        overf fn (DefPat (Pvar n) e an) = DefPat (Pvar n) e (fn an)
        overf fn (DefSyn tf te an)      = DefSyn tf te (fn an)
        overf fn (DefData tf ctors an)  = DefData tf ctors (fn an)
        overf fn (DefSpec tf te an)     = DefSpec tf te (fn an)
        overf fn (DefAbs tf ds t an)    = DefAbs tf ds t (fn an)
        overf fn d                      = d

defnAnLoc    = composeLens lensAnno anLoc
defnAnRec    = composeLens lensAnno anRec
defnAnCpx    = composeLens lensAnno anCpx
defnAnUses   = composeLens lensAnno anUses
defnAnFree   = composeLens lensAnno anFree
defnAnStrict = composeLens lensAnno anStrict

|| lens for accessing a definition's tform and type
defnTform :: lens defn tform
defnTform
    = Lens getf overf
      where
        getf (DefSyn tf te an)         = tf
        getf (DefData tf ctors an)     = tf
        getf (DefSpec tf te an)        = tf
        getf (DefAbs tf ds te an)      = tf
        getf a                         = error $ "defnTform on non-tform: " ++ showAst a

        overf fn (DefSyn tf te an)     = DefSyn (fn tf) te an
        overf fn (DefData tf ctors an) = DefData (fn tf) ctors an
        overf fn (DefSpec tf te an)    = DefSpec (fn tf) te an
        overf fn (DefAbs tf ds te an)  = DefAbs (fn tf) ds te an
        overf fn d                     = d

defnType :: lens defn texpr
defnType
    = Lens getf overf
      where
        getf (DefSyn tf te an)        = te
        getf (DefSpec tf te an)       = te
        getf (DefAbs tf ds te an)     = te
        getf d                        = error $ "defnType on non-tform: " ++ showAst d

        overf fn (DefSyn tf te an)    = DefSyn tf (fn te) an
        overf fn (DefSpec tf te an)   = DefSpec tf (fn te) an
        overf fn (DefAbs tf ds te an) = DefAbs tf ds (fn te) an
        overf fn d                    = d

dataCtors :: lens defn [tform]
dataCtors
    = Lens getf overf
      where
        getf (DefData tf ctors an)     = ctors
        getf a                         = error $ "defnCtors on non-DefData: " ++ showAst a

        overf fn (DefData tf ctors an) = DefData tf (fn ctors) an
        overf fn d                     = d

fnVars :: ast -> [ast]
fnVars (DefFn n vars e an)  = vars
fnVars (DefMult m (d : ds)) = fnVars d
fnVars d                    = []

fnExpr :: ast -> ast
fnExpr (DefFn n vars e an)  = e
fnExpr (DefPat p e an)      = e
fnExpr (DefMult m (d : ds)) = fnExpr d
fnExpr d                    = error $ "fnExpr on non-defn: " ++ showAst d

|| get the arity of a fn or spec defn -- special handling for constructors, where the arity is encoded in the builtinPack
fnArity :: ast -> int
fnArity (DefFn n vars e an)
    = ctorArity e, if isConstructor n
    = #vars,       otherwise
      where
        ctorArity (Tname pn [cn, t, EprimInt aty]) = aty
        ctorArity e                                = 0

fnArity (DefSpec tf te an)
    = countArrs 0 te
      where
        countArrs n (Tarr t1 t2) = countArrs (n + 1) t2
        countArrs n t            = n

fnArity (DefMult m (d : ds)) = fnArity d
fnArity d                    = 0

|| flatten a list of definitions
flattenDefns :: [ast] -> [ast]
flattenDefns
    = concatMap exp
      where
        exp (DefMult m defs) = defs
        exp d                = [d]

|| make definition name(s) at the top level qualified with the module name
qualifyDefn :: string -> ast -> ast
qualifyDefn modName (DefFn n vars e an)    = DefFn   (qualifyName modName n) vars e an
qualifyDefn modName (DefMult m defs)       = DefMult m $ map (qualifyDefn modName) defs
qualifyDefn modName (DefPat p expr an)     = DefPat  (qualifyPat modName p) expr an
qualifyDefn modName (DefSyn tf te an)      = DefSyn  (qualifyTform modName tf) te an
qualifyDefn modName (DefData tf ctors an)  = DefData (qualifyTform modName tf) (map (qualifyTform modName) ctors) an
qualifyDefn modName (DefSpec tf te an)     = DefSpec (qualifyTform modName tf) te an
qualifyDefn modName (DefAbs tf ds t an)    = DefAbs  (qualifyTform modName tf) ds t an
qualifyDefn modName d                      = d


|| common environment definitions
nameMap == m_map name name          || map from an Unqualified or Unresolved name to a Qualified name
defnMap == m_map name defn          || map from Qualified name to top-level definition in module

|| operator precedence and associativity
|| assocCompare allows comparison operators to be associative by chaining them with an '&'
|| e.g. 1 < a < 10 is rewritten as 1 < a & a < 10
assoc ::= AssocLeft | AssocRight | AssocPrefix | AssocCompare

|| note: this sets up a fixed precedence and associativity for common operators; all others
|| are treated as the default of highest precedence (apPrec) and AssocRight
|| eventually this should be migrated to an ability to define the prec and assoc of an operator
|| when the operator is defined, but that requires some work to the module, mirandaParser, and
|| reify modules
precAssocTable :: m_map string (int, assoc)
precAssocTable
    = m_fromList cmpstring
      [ ("$",   (0,  AssocRight))       || function application with lowest precedence
      , ("$!",  (0,  AssocRight))       || strict function application with lowest precedence
      , ("|>",  (1,  AssocLeft))        || reverse function application / chaining ('&' in Haskell)
      , (">>=", (1,  AssocLeft))        || generic monad bind
      , (">=>", (1,  AssocRight))       || generic monad Kleisli composition arrow
      , (">>",  (1,  AssocLeft))        || generic monad right
      , ("<<",  (1,  AssocLeft))        || generic monad left
      , (":",   (1,  AssocRight))       || list constructor
      , ("++",  (1,  AssocRight))       || list append
      , ("--",  (1,  AssocRight))       || list difference
      , ("\\/", (2,  AssocRight))       || boolean OR
      , ("&",   (3,  AssocRight))       || boolean AND
      , ("~",   (4,  AssocPrefix))      || boolean NOT
      , ("<$>", (4,  AssocLeft))        || generic functor fmap
      , ("<*>", (4,  AssocLeft))        || generic applicative apply
      , ("<*",  (4,  AssocLeft))        || generic applicative left
      , ("*>",  (4,  AssocLeft))        || generic applicative right

      , (">#",  (5,  AssocCompare))     || comparisons for unboxed word# type
      , (">=#", (5,  AssocCompare))     || Note: these are unused, since builtin comparisons are done with a strict
      , ("==#", (5,  AssocCompare))     || cmp# in a case..of.  Remove?
      , ("~=#", (5,  AssocCompare))
      , ("<=#", (5,  AssocCompare))
      , ("<#",  (5,  AssocCompare))

      , (">",   (5,  AssocCompare))     || comparisons for boxed int type
      , (">=",  (5,  AssocCompare))
      , ("==",  (5,  AssocCompare))
      , ("~=",  (5,  AssocCompare))
      , ("<=",  (5,  AssocCompare))
      , ("<",   (5,  AssocCompare))

      , (">.",  (5,  AssocCompare))     || comparisons for boxed char type
      , (">=.", (5,  AssocCompare))
      , ("==.", (5,  AssocCompare))
      , ("~=.", (5,  AssocCompare))
      , ("<=.", (5,  AssocCompare))
      , ("<.",  (5,  AssocCompare))

      , (">$",  (5,  AssocCompare))     || comparisons for boxed string type
      , (">=$", (5,  AssocCompare))
      , ("==$", (5,  AssocCompare))
      , ("~=$", (5,  AssocCompare))
      , ("<=$", (5,  AssocCompare))
      , ("<$",  (5,  AssocCompare))

      , (".&.", (5,  AssocLeft))        || bitwise boolean AND
      , (".|.", (5,  AssocLeft))        || bitwise boolean OR
      , (".^.", (5,  AssocLeft))        || bitwise boolean XOR
      , (".<<.", (6, AssocLeft))        || bit shift left
      , (".>>.", (6, AssocLeft))        || arithmetic bit shift right

      , ("+#",  (6,  AssocLeft))        || arithmetic on unboxed word# type
      , ("-#",  (6,  AssocLeft))        || Note: these are unused for assoc/prec, since builtin arithmetic is
      , ("*#",  (8,  AssocLeft))        || performed with strict case..of.  Remove?

      , ("+",   (6,  AssocLeft))        || arithmetic on boxed int type
      , ("-",   (6,  AssocLeft))
      , ("neg", (7,  AssocPrefix))
      , ("*",   (8,  AssocLeft))
      , ("div", (8,  AssocLeft))
      , ("mod", (8,  AssocLeft))
      , ("/",   (8,  AssocLeft))
      , ("^",   (9,  AssocRight))

      , (".",   (10, AssocRight))       || function composition
      , (".>",  (10, AssocLeft))        || flipped function composition
      , ("#",   (11, AssocPrefix))      || list length
      , ("!",   (12, AssocLeft))        || list indexing
      , ("!!",  (12, AssocLeft))        || vector indexing
      ]

apPrec = 13

|| look up operator in prec/assoc table, first removing any module qualifier
opPrecAssoc :: name -> (int, assoc)
opPrecAssoc op
    = m_findWithDefault cmpstring (apPrec, AssocRight) (getName op) precAssocTable
