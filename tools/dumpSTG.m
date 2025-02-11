|| dumpSTG -- extract and dump the STG Instructions from a .s file comments

%import <io>                    (>>=)/io_bind
%import <maybe>                 (>>=?)/mb_bind
%import <mirandaExtensions>

stg ::= Insn string | Label string | Comment string

|| custom showI instance for stg to format insns and labels
showstg :: stg -> string
showstg (Insn s)    = "    " ++ s
showstg (Label s)   = s
showstg (Comment s) = "\n# " ++ s

|| classify a line into an STG insn, a code Label, or Nothing
classify :: string -> maybe stg
classify ('#' : ' ' : '(' : s) = init s |> Insn |> Just
classify ('#' : ' ' : s)       = Comment s      |> Just
classify ('c' : 'o' : s)       = Label s        |> Just
classify _                     = Nothing

|| extract the STG insns from the file and print
process :: string -> io ()
process fn
    = mtimeFile fs >>= exists
      where
        fs = withSuffix "s" fn

        exists tsm
            = error (fs ++ "required, but not found"), if tsm < 0
            = readFile fs >>= dumpSTG,                 otherwise

        dumpSTG = lines .> map classify .> catMaybes .> io_mapM_ (showstg .> putStrLn)

main :: io ()
main = getArgs >>= go
       where
         go [fn] = process fn
         go _    = error "usage: dumpSTG <file name>"
