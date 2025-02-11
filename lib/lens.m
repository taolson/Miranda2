|| lens.m -- optics for accessing nested structures


%export +

%import <maybe>
%import <mirandaExtensions>


lens * **
    ::= Lens
        (* -> **)               || view function
        ((** -> **) -> * -> *)  || over function

view :: lens * ** -> * -> **
view (Lens viewf overf) s = viewf s

over :: lens * ** -> (** -> **) -> * -> *
over (Lens viewf overf) f s = overf f s

set :: lens * ** -> ** -> * -> *
set (Lens viewf overf) x s = overf (const x) s

|| compose outer lens with inner lens
composeLens :: lens * ** -> lens ** *** -> lens * ***
composeLens (Lens view_a over_a) (Lens view_b over_b)
    = Lens viewf overf
      where
        viewf s   = view_b (view_a s)
        overf f s = over_a (over_b f) s


|| lenses for tuples 2 - 8
|| defines explicit view and over functions, as well as the lenses, to allow optimization of code that performs
|| explicit view/over operations on known tuples.  Also, by having the view/over functions defined at the top-level
|| of the module, inlining Lens operations have a better opportunity to inline the view or over fn as well, even
|| when composing lenses

|| lenses for 2-tuples
viewFst (a, b) = a; overFst fn (a, b) = (fn a, b); lensFst = Lens viewFst overFst
viewSnd (a, b) = b; overSnd fn (a, b) = (a, fn b); lensSnd = Lens viewSnd overSnd

|| lenses for 3-tuples
viewTup3_0 (a, b, c) = a; overTup3_0 fn (a, b, c) = (fn a, b, c); lensTup3_0 = Lens viewTup3_0 overTup3_0
viewTup3_1 (a, b, c) = b; overTup3_1 fn (a, b, c) = (a, fn b, c); lensTup3_1 = Lens viewTup3_1 overTup3_1
viewTup3_2 (a, b, c) = c; overTup3_2 fn (a, b, c) = (a, b, fn c); lensTup3_2 = Lens viewTup3_2 overTup3_2

|| lenses for 4-tuples
viewTup4_0 (a, b, c, d) = a; overTup4_0 fn (a, b, c, d) = (fn a, b, c, d); lensTup4_0 = Lens viewTup4_0 overTup4_0
viewTup4_1 (a, b, c, d) = b; overTup4_1 fn (a, b, c, d) = (a, fn b, c, d); lensTup4_1 = Lens viewTup4_1 overTup4_1
viewTup4_2 (a, b, c, d) = c; overTup4_2 fn (a, b, c, d) = (a, b, fn c, d); lensTup4_2 = Lens viewTup4_2 overTup4_2
viewTup4_3 (a, b, c, d) = d; overTup4_3 fn (a, b, c, d) = (a, b, c, fn d); lensTup4_3 = Lens viewTup4_3 overTup4_3 

|| lenses for 5-tuples
viewTup5_0 (a, b, c, d, e) = a; overTup5_0 fn (a, b, c, d, e) = (fn a, b, c, d, e); lensTup5_0 = Lens viewTup5_0 overTup5_0
viewTup5_1 (a, b, c, d, e) = b; overTup5_1 fn (a, b, c, d, e) = (a, fn b, c, d, e); lensTup5_1 = Lens viewTup5_1 overTup5_1
viewTup5_2 (a, b, c, d, e) = c; overTup5_2 fn (a, b, c, d, e) = (a, b, fn c, d, e); lensTup5_2 = Lens viewTup5_2 overTup5_2
viewTup5_3 (a, b, c, d, e) = d; overTup5_3 fn (a, b, c, d, e) = (a, b, c, fn d, e); lensTup5_3 = Lens viewTup5_3 overTup5_3
viewTup5_4 (a, b, c, d, e) = e; overTup5_4 fn (a, b, c, d, e) = (a, b, c, d, fn e); lensTup5_4 = Lens viewTup5_4 overTup5_4

|| lenses for 6-tuples
viewTup6_0 (a, b, c, d, e, f) = a; overTup6_0 fn (a, b, c, d, e, f) = (fn a, b, c, d, e, f); lensTup6_0 = Lens viewTup6_0 overTup6_0
viewTup6_1 (a, b, c, d, e, f) = b; overTup6_1 fn (a, b, c, d, e, f) = (a, fn b, c, d, e, f); lensTup6_1 = Lens viewTup6_1 overTup6_1
viewTup6_2 (a, b, c, d, e, f) = c; overTup6_2 fn (a, b, c, d, e, f) = (a, b, fn c, d, e, f); lensTup6_2 = Lens viewTup6_2 overTup6_2
viewTup6_3 (a, b, c, d, e, f) = d; overTup6_3 fn (a, b, c, d, e, f) = (a, b, c, fn d, e, f); lensTup6_3 = Lens viewTup6_3 overTup6_3
viewTup6_4 (a, b, c, d, e, f) = e; overTup6_4 fn (a, b, c, d, e, f) = (a, b, c, d, fn e, f); lensTup6_4 = Lens viewTup6_4 overTup6_4
viewTup6_5 (a, b, c, d, e, f) = f; overTup6_5 fn (a, b, c, d, e, f) = (a, b, c, d, e, fn f); lensTup6_5 = Lens viewTup6_5 overTup6_5

|| lenses for 7-tuples
viewTup7_0 (a, b, c, d, e, f, g) = a; overTup7_0 fn (a, b, c, d, e, f, g) = (fn a, b, c, d, e, f, g); lensTup7_0 = Lens viewTup7_0 overTup7_0
viewTup7_1 (a, b, c, d, e, f, g) = b; overTup7_1 fn (a, b, c, d, e, f, g) = (a, fn b, c, d, e, f, g); lensTup7_1 = Lens viewTup7_1 overTup7_1
viewTup7_2 (a, b, c, d, e, f, g) = c; overTup7_2 fn (a, b, c, d, e, f, g) = (a, b, fn c, d, e, f, g); lensTup7_2 = Lens viewTup7_2 overTup7_2
viewTup7_3 (a, b, c, d, e, f, g) = d; overTup7_3 fn (a, b, c, d, e, f, g) = (a, b, c, fn d, e, f, g); lensTup7_3 = Lens viewTup7_3 overTup7_3
viewTup7_4 (a, b, c, d, e, f, g) = e; overTup7_4 fn (a, b, c, d, e, f, g) = (a, b, c, d, fn e, f, g); lensTup7_4 = Lens viewTup7_4 overTup7_4
viewTup7_5 (a, b, c, d, e, f, g) = f; overTup7_5 fn (a, b, c, d, e, f, g) = (a, b, c, d, e, fn f, g); lensTup7_5 = Lens viewTup7_5 overTup7_5
viewTup7_6 (a, b, c, d, e, f, g) = g; overTup7_6 fn (a, b, c, d, e, f, g) = (a, b, c, d, e, f, fn g); lensTup7_6 = Lens viewTup7_6 overTup7_6

|| lenses for 8-tuples
viewTup8_0 (a, b, c, d, e, f, g, h) = a; overTup8_0 fn (a, b, c, d, e, f, g, h) = (fn a, b, c, d, e, f, g, h); lensTup8_0 = Lens viewTup8_0 overTup8_0
viewTup8_1 (a, b, c, d, e, f, g, h) = b; overTup8_1 fn (a, b, c, d, e, f, g, h) = (a, fn b, c, d, e, f, g, h); lensTup8_1 = Lens viewTup8_1 overTup8_0
viewTup8_2 (a, b, c, d, e, f, g, h) = c; overTup8_2 fn (a, b, c, d, e, f, g, h) = (a, b, fn c, d, e, f, g, h); lensTup8_2 = Lens viewTup8_2 overTup8_0
viewTup8_3 (a, b, c, d, e, f, g, h) = d; overTup8_3 fn (a, b, c, d, e, f, g, h) = (a, b, c, fn d, e, f, g, h); lensTup8_3 = Lens viewTup8_3 overTup8_0
viewTup8_4 (a, b, c, d, e, f, g, h) = e; overTup8_4 fn (a, b, c, d, e, f, g, h) = (a, b, c, d, fn e, f, g, h); lensTup8_4 = Lens viewTup8_4 overTup8_0
viewTup8_5 (a, b, c, d, e, f, g, h) = f; overTup8_5 fn (a, b, c, d, e, f, g, h) = (a, b, c, d, e, fn f, g, h); lensTup8_5 = Lens viewTup8_5 overTup8_0
viewTup8_6 (a, b, c, d, e, f, g, h) = g; overTup8_6 fn (a, b, c, d, e, f, g, h) = (a, b, c, d, e, f, fn g, h); lensTup8_6 = Lens viewTup8_6 overTup8_0 
viewTup8_7 (a, b, c, d, e, f, g, h) = h; overTup8_7 fn (a, b, c, d, e, f, g, h) = (a, b, c, d, e, f, g, fn h); lensTup8_7 = Lens viewTup8_7 overTup8_0
