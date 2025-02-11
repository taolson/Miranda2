|| fib.m -- Fibonacci sequence, implemented multiple ways

%import <io>            (>>=)/io_bind (>>)/io_right
%import <memoTrie>

|| canonical recursive version, showing exponential runtime: O(1.6^n)
fib1 :: int -> int
fib1 n = 1,                           if n < 2
       = fib1 (n - 1) + fib1 (n - 2), otherwise

|| iterative version shows use of a recurrence list comprehension to generate an
|| infinite lazy list of Fibonacci values, and indexing the list
fib2 :: int -> int
fib2 n = fibs ! n where fibs = [a | (a, b) <- (1, 1), (b, a + b) ..]

|| memoized version of fib1, showing O(n) performance
fib3 :: int -> int
fib3 = memofix memoint fib
       where
         fib f n = 1,                     if n < 2
                 = f (n - 1) + f (n - 2), otherwise     || recursion open-coded using f to allow memoization hook

|| find the 37th Fibonacci number 3 ways
main :: io ()
main = io_mapM_ run tests
       where
         tests      = [("recursive", fib1), ("iterative", fib2), ("memoized", fib3)]
         run (s, f) = putStr (s ++ ": ") >> (f 37 |> showint |> io_pure) >>= putStrLn
