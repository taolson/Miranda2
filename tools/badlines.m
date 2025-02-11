|| check the files specified on the command line for lines that exceed 159 columns or are not empty but blank


%import <io>                    (>>=)/io_bind
%import <mirandaExtensions>


(<&>) = converse io_fmap

result == (string, [num])

blankOrLong :: string -> bool
blankOrLong s = ~null s & (all isSpace s \/ #s >= 160)

processFile :: string -> io result
processFile fn
    = readFile fn <&> process
      where
        process = lines .> zip2 [1 ..] .> filter (blankOrLong . snd) .> map fst .> pair fn

main :: io ()
main
    = getArgs >>= io_mapM processFile >>= report
      where
        report = filter (not . null . snd) .> map showresult .> io_mapM_ putStrLn
