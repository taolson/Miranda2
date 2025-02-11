|| exception.m -- errors and warnings
||
|| should all exceptions be unified, here?
|| lexer exceptions are returned in-line in the token stream as a form of token (Terror), rather than as an either alternative
|| parser exceptions are collected while parsing alternative potential parse paths, and need to be compared by location and
||        severity when merging (keeping the deepest error as part of the parser state) -- would need a form of "no error" as default


%export +

%import <either>
%import <lens>
%import <maybe>
%import <mirandaExtensions>
%import "grammar"
%import "name"


|| Notes are info to be passed up to the top-level IO where they are displayed (but no control flow change)
|| Warns are similar to Notes, but printed on Stderr instead of Stdout
|| Error terminates after being passed up to the top-level IO and being printed on Stderr
exceptionType ::= Note | Warn | Error

showsExceptionType :: exceptionType -> showS
showsExceptionType Note  = id
showsExceptionType Warn  = shows "warning "
showsExceptionType Error = shows "error "


|| indentifying information for each exception
exceptionInfo ::=
    Arity                            |       || arity mismatch in arguments for function or type 
    BadCtor        name  name        |       || constructor is not a member of the data defn
    BadPattern     pat               |       || pattern is not a constructor or variable
    CtorArity      name              |       || constructor used with wrong arity in formal
    DepCycle       string            |       || dependency cycle in type definitions or module includes
    IncorrDecl     defn  defn        |       || incorrect declaration (specified vs inferred type)
    NameClash      name              |       || previously-defined, qualified name (includes module info)
    NonExhaustive                    |       || non-exhaustive patterns in function
    NotType        name              |       || name is not defined as a type
    Occurs         int   texpr       |       || type var n occurs in its substitution (infinite type)
    QualBind       name              |       || qualified name in binding position
    RepeatedTvar   int               |       || type var n used multiple times in a definition
    SpecNoDef      name              |       || specified, but not defined
    TypeHole       texpr             |       || type hole found when unifying with texpr
    TypeIdent      name              |       || typename used as an identifier
    UnboundTvar    int               |       ||
    UnboxedPat                       |       || pattern type cannot be an unboxed value
    Undefined      name              |       || undefined name referenced
    Unify          texpr texpr       |       || cannot unify types
    Unreachable    pat               |       || pattern for function definition is redundant (unreachable)
    Unsupported    string            |       || unsupported feature
    Unused         name              |       || local definition unused
    WrongType      name              |       || type inferred for name is wrong
    Info           string            |       || generic information
    ExMult         [exceptionInfo]           || multiple exceptionInfo at the same location (used to add Info to an existing exception)

showsExName :: name -> showS
showsExName (Unqualified n) = shows n        || show name without annotating '?' for Unqualified
showsExName (Internal n d)  = shows n        || show name without uniquifying number
showsExName n               = shows (showName n)

showsExceptionInfo :: exceptionInfo -> showS
showsExceptionInfo Arity                = shows "arity mismatch in argument count to a function or type definition"
showsExceptionInfo (BadCtor dn cn)      = showsExName cn . shows " is not a constructor for " . showsExName dn
showsExceptionInfo (BadPattern p)       = shows "bad pattern " . showsAst p
showsExceptionInfo (CtorArity cn)       = shows "constructor " . showsExName cn . shows " used with wrong arity in formal"
showsExceptionInfo (DepCycle s)         = shows "dependency cycle in " . shows s
showsExceptionInfo (IncorrDecl d1 d2)   = shows "incorrect type declaration:\n    specified: " . showsAst d1 . shows "\n    inferred:  " . showsAst d2
showsExceptionInfo (NameClash n)        = shows "name clash with " . showsName n
showsExceptionInfo NonExhaustive        = shows "non-exhaustive patterns"
showsExceptionInfo (NotType n)          = showsExName n . shows " is not a typename"
showsExceptionInfo (Occurs n t2)        = shows "cannot construct the infinite type " . showsAst (Tvar n) . shows " ~ " . showsAst t2
showsExceptionInfo (QualBind n)         = shows "qualified name in binding position: " . showsName n
showsExceptionInfo (RepeatedTvar n)     = shows "repeated type var " . showsAst (Tvar n)
showsExceptionInfo (SpecNoDef n)        = showsExName n . shows " specified but not defined"
showsExceptionInfo (TypeHole t)         = shows "type hole found with type " . showsAst t
showsExceptionInfo (TypeIdent n)        = shows "typename " . showsExName n . shows " used as an expression identifier"
showsExceptionInfo (UnboundTvar n)      = shows "unbound type var " . showsAst (Tvar n)
showsExceptionInfo UnboxedPat           = shows "pattern type cannot be an unboxed value"
showsExceptionInfo (Undefined n)        = showsExName n . shows " is undefined"
showsExceptionInfo (Unify t1 t2)        = shows "cannot unify\n\t" . showsAst t1 . shows "\n    with\n\t" . showsAst t2
showsExceptionInfo (Unreachable p)      = shows "unreachable pattern"
showsExceptionInfo (Unsupported s)      = shows s . shows " is unsupported"
showsExceptionInfo (Unused n)           = showsExName n . shows " is unused"
showsExceptionInfo (WrongType n)        = shows "type inferred for " . showsExName n . shows " is wrong"
showsExceptionInfo (Info s)             = shows s
showsExceptionInfo (ExMult es)          = interShows "\n    " (map showsExceptionInfo es)

|| limit the length of an Info
limitInfo :: int -> string -> string
limitInfo lim [] = []
limitInfo lim (c : cs)
    = "...", if lim <= 0
    = c : limitInfo (lim - 1) cs, otherwise

|| definition name path (inner-most first), location pair to identify where exception occurred
locInfo == ([name], maybe location)

|| lenses for locInfo
locInfoDefnPath = lensFst
locInfoLocation = lensSnd

emptyLocInfo :: locInfo
emptyLocInfo = ([], Nothing)

|| create a locInfo from a location
locOnlyInfo :: location -> locInfo
locOnlyInfo loc = ([], Just loc)

|| create a locInfo from a name
pathOnlyLocInfo :: name -> locInfo
pathOnlyLocInfo n = ([n], Nothing)

|| create a locInfo from a defn
defnLocInfo :: defn -> locInfo
defnLocInfo d
    = ([defnName d], Just (view defnAnLoc d)), if isDefn d
    = emptyLocInfo,                            otherwise

|| merge a locInfo into an existing one, ignoring any path with a name beginning with '`',
|| which is used to mark internally generated functions and thunks
mergeLocInfo :: locInfo -> locInfo -> locInfo
mergeLocInfo (p1, ml1) (p2, ml2)
    = (p2,       ml2), if null p1 \/ ~null n & hd n ==. '`'
    = (p1 ++ p2, ml'), otherwise
      where
        n   = getName (hd p1)
        ml' = appendMaybe ml1 ml2

showsLocInfo :: locInfo -> showS
showsLocInfo (ns, ml)
    = showsMaybeLoc ml . showsPathName ns
      where
        showsPathName [] = id
        showsPathName ns = shows "\n    in definition of " . interShows ", subdef of " (map (shows . getName) ns)

        showsMaybeLoc Nothing    = id
        showsMaybeLoc (Just loc) = showsLocation loc


|| every exception contains the enclosing function definition name and the closest location info
exception == (exceptionType, exceptionInfo, locInfo)

showsException :: exception -> showS
showsException (et, ei, li)
    = shows "\n" . showsExceptionType et . showsLocInfo li . shows "\n    " . showsExceptionInfo ei

showException :: exception -> string
showException e = showsException e ""

|| lenses for exception
excptType   = lensTup3_0
excptInfo   = lensTup3_1
excptLoc    = lensTup3_2


|| either a list of Errors, or a result along with a list of Notes and Warns
excpt * == either [exception] (*, [exception])

|| lenses for excpt *
excptResult = lensFst
excptWarns  = lensSnd


|| testing

isError :: exception -> bool
isError e = _eq cmpexceptionType Error $ view excptType e

isWarn :: exception -> bool
isWarn e = _eq cmpexceptionType Warn $ view excptType e

isNote :: exception -> bool
isNote e = _eq cmpexceptionType Note $ view excptType e


|| monad interface
ex_bind :: excpt * -> (* -> excpt **) -> excpt **
ex_bind (Left errs)        f = Left errs
ex_bind (Right (x, warns)) f
    = r, if isLeft r
    = Right (x', warns ++ warns'), otherwise
      where
        r                  = f x
        Right (x', warns') = r

ex_pure :: * -> excpt *
ex_pure x = Right (x, [])

ex_error :: exceptionInfo -> locInfo -> excpt *
ex_error ei loc = Left [(Error, ei, loc)]

ex_note :: string -> * -> excpt *
ex_note s x = Right (x, [(Note, Info s, emptyLocInfo)])

|| like pure, but also include any warnings
ex_return :: * -> [exception] -> excpt *
ex_return x warns = Right (x, warns)

|| return a group of errors
ex_errs :: [exception] -> excpt *
ex_errs = Left

ex_kbind :: (* -> excpt **) -> (** -> excpt ***) -> * -> excpt ***
ex_kbind f g = go where go x = f x $ex_bind g

ex_foldM :: (* -> ** -> excpt *) -> * -> [**] -> excpt *
ex_foldM f z0 xs
    = foldr c ex_pure xs z0
      where
        c x k z = f z x $ex_bind k


|| functor interface
ex_fmap :: (* -> **) -> excpt * -> excpt **
ex_fmap f ma = ma $ex_bind (ex_pure . f)


|| applicative interface
|| note: merges errors and warnings from both sides, so not written as the normal bind with fmap
ex_apply :: excpt (* -> **) -> excpt * -> excpt **
ex_apply (Left errs1)        (Left errs2)        = Left (errs1 ++ errs2)
ex_apply (Left errs1)        (Right (a, warns))  = Left errs1
ex_apply (Right (f, warns1)) (Left errs2)        = Left errs2
ex_apply (Right (f, warns1)) (Right (a, warns2)) = Right (f a, warns1 ++ warns2)

ex_liftA2 :: (* -> ** -> ***) -> excpt * -> excpt ** -> excpt ***
ex_liftA2 f ma mb = (f $ex_fmap ma) $ex_apply mb


|| alternative interface
ex_alt :: excpt * -> excpt * -> excpt *
ex_alt (Left x)  er = er
ex_alt (Right x) er = (Right x)
