|| dependency.m -- dependency graph operations


%export makeDependencyGraph addDependency dependencyOrder findSCCs edges fwd rev

%import <either>
%import <map>
%import <maybe>
%import <mirandaExtensions>
%import <set>


|| a dependency graph is represented by a map from a node to a pair of sets (fwd, rev), where
|| fwd are the nodes it is connected to in the forward direction (uses), and rev are the nodes
|| that it is connected to in the reverse direction (users)
nodeEdges *       == (s_set *, s_set *) || fwd set, rev set
dependencyGraph * == m_map * (nodeEdges *)

emptyNodeEdges :: (s_set *, s_set *)
emptyNodeEdges = (s_empty, s_empty)

|| alternate names for specifying direction accessors
fwd, rev :: (*, *) -> *
fwd = fst
rev = snd

|| extract the list of forward or reverse edges of a node
edges :: ordI * -> (nodeEdges * -> s_set *) -> * -> dependencyGraph * -> [*]
edges cmp dir n g = (s_toList . dir . m_findWithDefault cmp emptyNodeEdges n) g

|| add a dependency pair (a -> b), (a <- b) to the graph
addDependency :: ordI * -> * -> * -> dependencyGraph * -> dependencyGraph *
addDependency cmp a b g
    = m_insert cmp a (s_insert cmp b fwda, reva) . m_insert cmp b (fwdb, s_insert cmp a revb) $ g
      where
        (fwda, reva) = m_findWithDefault cmp emptyNodeEdges a g
        (fwdb, revb) = m_findWithDefault cmp emptyNodeEdges b g

|| make a dependency graph from a list of (node, uses-list) pairs
makeDependencyGraph :: ordI * -> [(*, [*])] -> dependencyGraph *
makeDependencyGraph cmp
    = foldl addDependencies m_empty
      where
        addDependencies g (a, bs)
            = m_insert cmp a emptyNodeEdges g,  if null bs
            = foldr (addDependency cmp a) g bs, otherwise

|| return an ordered list of nodes based upon the dependency graph
|| if a cycle is detected in the graph, return the list of recursive dependencies
dependencyOrder :: ordI * -> dependencyGraph * -> either [[*]] [*]
dependencyOrder cmp g
    = Right (concat d2),        if null mutRec & null dirRec
    = Left  (mutRec ++ dirRec), otherwise
      where
        sccs         = findSCCs cmp g
        (mutRec, d1) = partition ((> 1) . length) sccs        || detect any mutually-recursive components
        (dirRec, d2) = partition isDirRec d1                  || detect any directly-recursive compoenents
        isDirRec [c] = member cmp (edges cmp fwd c g) c
        isDirRec _   = False

|| find the Strongly-Connected Components of the graph, in forward order
|| uses Kosaraju's algorithm
findSCCs :: ordI * -> dependencyGraph * -> [[*]]
findSCCs cmp g
    = cs
      where
        (ns, _) = foldl dfsFwd  ([], s_empty) (m_keys g)
        (cs, _) = foldl newRoot ([], s_empty) ns

        || depth-first-search forward from node n, prepending n to the result
        dfsFwd (ns, vs) n
            = (ns, vs),       if s_member cmp n vs
            = (n : ns', vs'), otherwise
              where
                (ns', vs') = foldl dfsFwd (ns, s_insert cmp n vs) fwdRefs
                fwdRefs    = edges cmp fwd n g

        || start a new component with root n
        newRoot (cs, vs) n
            = (cs, vs'),     if null c
            = (c : cs, vs'), otherwise
              where
                (c, vs') = dfsRev ([], vs) n

        || depth-first-search reverse from node n, adding them to the component
        dfsRev (c, vs) n
            = (c, vs),                        if s_member cmp n vs
            = foldl dfsRev (c', vs') revRefs, otherwise
              where
                c'      = n : c
                vs'     = s_insert cmp n vs
                revRefs = edges cmp rev n g
