|| parser.m -- a parser combinator library for strings, based upon the maybeState monad, which tracks line and column position for error reporting


%export + p_get p_put p_modify p_bind p_pure p_fail p_fmap p_apply p_liftA2 p_liftA3 p_liftA4 p_left p_right p_mapM p_foldM

%import <maybe>
%import <mirandaExtensions>
%import <maybeState> p_get/mst_get p_put/mst_put p_modify/mst_modify p_bind/mst_bind p_pure/mst_pure p_fail/mst_fail p_fmap/mst_fmap
                     p_apply/mst_apply p_liftA2/mst_liftA2 p_liftA3/mst_liftA3 p_liftA4/mst_liftA4 p_left/mst_left p_right/mst_right
                     p_mapM/mst_mapM p_foldM/mst_foldM


|| state passed through parser is current line and column numbers, and the list of chars not yet parsed
|| the line and column numbers are kept as unboxed word# values to optimize maintaining them during parsing
|| (allows better inlining of p_any and p_satisfy)

psSt     == (word#, word#, [char])       || current line#, col#, string yet to parse
parser * == maybeState psSt *

parse :: parser * -> [char] -> (maybe *, psSt)
parse p cs = p (1#, 1#, cs)

p_error :: psSt -> [char]
p_error (il, ic, cs)
    = "no error",                                                                 if null cs
    = "parse failed near line " ++ showint (I# il) ++ " col " ++ showint (I# ic), otherwise

|| alternative interface
|| note: a simple alias to maybeState mst_alt can't be used, here, because we need to return the
|| one with the the deepest progress of the two parses, if both fail
p_alt :: parser * -> parser * -> parser *
p_alt pa pb
    = go
      where
        go ps
            = ra,                if isJust $ fst ra
            = rb,                if isJust $ fst rb
            = max2 cmploc ra rb, otherwise
              where
                ra = mst_runState pa ps
                rb = mst_runState pb ps

                cmploc (_, (l1, c1, _)) (_, (l2, c2, _))
                    = cmpword# l1 l2 $thenCmp cmpword# c1 c2

|| p_peek and p_not check for the presence or absence of a token, but don't consume it
p_peek, p_not :: parser * -> parser ()
p_peek pa ps
    = (Just (), ps), if isJust ra
    = (Nothing, ps), otherwise
      where
        (ra, _) = pa ps

p_not pa ps
    = (Just (), ps), if isNothing ra
    = (Nothing, ps), otherwise
      where
        (ra, _) = pa ps

p_optional :: parser * -> parser (maybe *)
p_optional pa ps
    = (Just (Just a), psa), if isJust ra
    = (Just Nothing, ps),   otherwise
      where
        (ra, psa) = pa ps
        Just a    = ra

p_cons :: parser * -> parser [*] -> parser [*]
p_cons = p_liftA2 (:)

p_some :: parser * -> parser [*]
p_some p = p $p_cons p_many p

p_many :: parser * -> parser [*]
p_many p = p_some p $p_alt p_pure []

|| fixed count of p
p_count :: int -> parser * -> parser [*]
p_count n p = p_mapM (const p) [1 .. n]

|| 1 or more p seperated by ps
p_someSepBy :: parser * -> parser ** -> parser [**]
p_someSepBy ps p = p $p_cons p_many (ps $p_right p)

|| 0 or more p seperated by ps
p_manySepBy :: parser * -> parser ** -> parser [**]
p_manySepBy ps p = p_someSepBy ps p $p_alt p_pure []

|| 0 or more pa until pb, keeping the list of pas
p_manyUntil :: parser * -> parser ** -> parser [*]
p_manyUntil pa pb = (pb $p_right p_pure []) $p_alt (pa $p_cons p_manyUntil pa pb)

|| 0 or more pa until pb, keeping pb
p_skipUntil :: parser * -> parser ** -> parser **
p_skipUntil pa pb = pb $p_alt (pa $p_right p_skipUntil pa pb)

|| parser which passes only at end of input
p_end :: parser ()
p_end (il, ic, []) = (Just (), (il, ic, []))
p_end ps = (Nothing, ps)

|| parser which accepts any character
p_any :: parser char
p_any (il, ic, []) = (Nothing, (il, ic, []))
p_any (il, ic, (c : cs))
    = case c ==. '\n' of
        False -> case ic +# 1# of ic' -> (Just c, (il, ic', cs))
        True  -> case il +# 1# of il' -> (Just c, (il', 1#, cs))

|| parser for a character which satifies a condition
p_satisfy :: (char -> bool) -> parser char
p_satisfy f
    = p_any $p_bind fsat
      where
        fsat c = p_pure c, if f c
               = p_fail,   otherwise

|| parser which matches a specific character
p_char :: char -> parser char
p_char c = p_satisfy equal where equal c' = c' ==. c            || written this way to remove a partially-applied comparison passed to satisfy

p_notChar :: char -> parser char
p_notChar c = p_satisfy notEqual where notEqual c' = c' ~=. c   || written this way to remove a partially-applied comparison passed to satisfy

p_digit :: parser char
p_digit = p_satisfy digit

p_letter :: parser char
p_letter = p_satisfy letter

p_space :: parser char
p_space = p_satisfy (member cmpchar " \t\n")

p_spaces :: parser [char]
p_spaces = p_many p_space

p_comma :: parser char
p_comma = p_char ','

p_anyOf :: [char] -> parser char
p_anyOf s = p_satisfy (member cmpchar s)

p_noneOf :: [char] -> parser char
p_noneOf s
    = p_satisfy (not . member cmpchar s)
      where
        not x = ~ x

|| parser which matches a specific string
p_string :: [char] -> parser [char]
p_string s = foldr (p_right . p_char) (p_pure s) s

p_posint :: parser int
p_posint = p_fmap intval (p_some p_digit)

p_int :: parser int
p_int = p_liftA2 mkint (p_optional (p_char '-')) p_posint
        where
          mkint mn n =  n, if isNothing mn
                     = -n, otherwise

|| parse a word
p_word :: parser [char]
p_word = p_some p_letter

|| parse a list of ints separated by a comma
p_intlist :: parser [int]
p_intlist = p_someSepBy p_comma p_int

|| read an intlist from a string, or report an error
readIntlist :: string -> [int]
readIntlist s
    = fromMaybe err mns
      where
        (mns, ps) = parse p_intlist s
        err       = error (p_error ps)
