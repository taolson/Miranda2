|| bfs.m -- implementation of a shortest path finder using a breadth-first search


%export bfsSolve

%import <avl>
%import <map>
%import <maybe>
%import <mirandaExtensions>
%import <set>


|| produce a list of positions as the solution to the shortest path, along with the final expansion state
backtrace :: ordI * -> * -> ** -> m_map * * -> ([*], **)
backtrace cmp move xs pm
    = (path, xs)
      where
        path       = (fst . hd . dropWhile (isJust . snd) . iterate bt) ([], Just move)
        bt (p, mm) = (m : p, lu)
                     where
                       lu       = m_lookup cmp m pm
                       (Just m) = mm

|| solve for the shortest path from start to an end goal, given:
||     cmp: comparison function for positions
||     start: a starting position
||     gf:    a goal function which returns True if its argument matches the goal
||     xf:    an expansion function which expands the search from the given position and the current expansion state
||     xs:    expansion state, which is passed to the expansion function
bfsSolve :: ordI * -> * -> (* -> bool) -> ((*, **) -> ([*], **)) -> ** -> ([*], **)
bfsSolve cmp start gf xf xs
    = go [start] (s_singleton start) m_empty xs
      where
        go []       cs pm xs = ([], xs)
        go (v : vs) cs pm xs
            = backtrace cmp v xs pm, if gf v
            = go vs' cs' pm' xs',    otherwise
              where
                vs'           = vs ++ adj'
                (adj, xs')    = xf (v, xs)
                (adj', cs')   = foldl addMove ([], cs) adj
                pm'           = foldl addPath pm adj'
                addPath pm v' = m_insert cmp v' v pm 

                addMove (adj, cs) v'
                    = (adj, cs),   if s_member cmp v' cs
                    = (adj', cs'), otherwise
                      where
                        adj' = v' : adj
                        cs'  = s_insert cmp v' cs

