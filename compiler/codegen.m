|| 
|| codegen.m -- x86-64 asm code generator for MacOS / Linux (System V calling convention)


%export codegen

%import <either>
%import <lens>
%import <map>
%import <maybe>
%import <mirandaExtensions>
%import "config"
%import "exception"
%import "grammar"
%import "module"
%import "name"
%import "stg"


|| note on value tagging:
|| GC needs to differentiate word# values from heapPtrs, since it moves heapPtrs around during compaction.  The original STG machine did this
|| without per-address tags by having information about the various closure free vars in the info section, but there still are issues with trying
|| to trace the Reg/Arg register values, which can also hold word# values or heaPtrs.  Instead, we use the lower bit of a value to distinguish
|| between a word# (0) and heapPtr (1).  Since heapPtrs must always be 8-byte aligned, the bottom 3 bits are implicitly 0, so we can tag them
|| with an lsb of '1' and use an offset of -1 in any address calculation to strip the tag bit.  This allows '0' to be used as the tag bit
|| for word# values, which simplifies calculations using them.
||
||
|| Tagging / Untagging word# values
||
|| A tag bit of 0 on a word# value means we have 63-bit ints with bit 0 = 0,
|| so arithmetic on raw words works like this:
|| add# a b = a + b        (no change)
|| sub# a b = a - b        (no change)
|| mul# a b = a * (b >> 1) (to adjust for the bottom 0 bits of a and b creating 2 bottom zero bits in the product)
|| div# a b = ((a >> 1) / (b >> 1)) << 1
|| mod# a b = ((a >> 1) % (b >> 1)) << 1
|| sra# a n = ((a >> (n >> 1)) & ~1)
|| sll# a n = (a << (n >> 1))
|| and#, or#, xor#         (no change)
||
||
|| Tagging / Untagging heapPtr values:
||
|| heapPtr values stored in Args or Regs registers, or the env of a closure must be tagged with the lsb set to 1.  The base
|| values stored in Env and Frm registers are also tagged.  Immediate heapPtr values are not tagged, because they only exist
|| in code objs, and point to global closures which are not moved during garbage collection.  Any time an effective 
|| heap address is calulated using an offset from the Frm, an implicit '1' bit should be added.  And every time a pointer to
|| a closure is dereferenced (to get its tag, cp, or env values), the tag bit should be counteracted with an explicit offset
|| of (-1).  Tagging should occur when a Frm operand is generated, or when an immediate heapPtr is used as an operand.
|| Untagging should occur during EnterInd and Apply operations.


|| Code generation consists of converting various objects (literal strings, names, refs, operands, and stgInsns) to
|| showS difference lists representing their corresponding x86-64 assembly-language

|| generate a C string with escaped characters
|| this is almost the same as Miranda's show for a string, except Miranda shows a single quote as escaped,
|| which is not compatible with what other MacOS tools (asm) expect.  Also, it appears as if asm strings
|| assume that numeric escape sequences eg '\27' are implicitly octal, so explicitly use an octal representaion,
|| rather than decimal.

genCString :: string -> showS
genCString s
    = shows "\"" . foldr (.) id (map showsCchar s) . shows "\""
      where
        showsCchar c
            = (s ++)
              where
                s = "\\a",                    if c ==. '\a'
                  = "\\b",                    if c ==. '\b'
                  = "\\f",                    if c ==. '\f'
                  = "\\n",                    if c ==. '\n'
                  = "\\r",                    if c ==. '\r'
                  = "\\t",                    if c ==. '\t'
                  = "\\v",                    if c ==. '\v'
                  = "\\\\",                   if c ==. '\\'
                  = "\\\"",                   if c ==. '\"'
                  = [c],                      if ' ' <=. c <=. '~'
                  = "\\" ++ showoct (code c), otherwise                 || .ascii string in asm appears to only support octal numeric escapes

|| Generate a name without annotations or uniquifying numbers
|| The names will appear in comments, but may themselves be symbols that look like comments.
|| To prevent the assembler from getting confused, convert certain symbol characters to other
|| strings
convertSpecial :: string -> showS
convertSpecial
    = foldr (.) id . map conv
      where
        conv '%' = ("%pcnt" ++)
        conv '#' = ("%hash" ++)
        conv '/' = ("%slash" ++)
        conv '*' = ("%star" ++)
        conv c   = ([c] ++)

genAsmName :: name -> showS
genAsmName (Unqualified n) = convertSpecial n
genAsmName (Internal n d)  = convertSpecial n
genAsmName n               = convertSpecial (showName n)

genSection :: string -> showS
genSection s = shows "\n\t." . shows s . shows "\n"

|| generate a label for a Miranda function
genGlobal :: string -> showS
genGlobal lbl
    = shows "\n\t.globl\t" . shows lbl . shows "\n" .
      shows lbl . shows ":\n"

|| generate a label for a C-callable function
genCGlobal lbl
    = shows "\n\t.globl\t" . shows codegenCsymbolPrefix . shows lbl . shows "\n" .
      shows codegenCsymbolPrefix . shows lbl . shows ":\n"

|| generate padding after a string to align to the next 8-byte quadword
|| if the string is empty, generate 8 bytes of padding to allow for a minimum of 1 quadword of space
genPad :: string -> showS
genPad s
    = id,              if len > 0 & extra == 0  || no padding if we are on an 8-byte boundary of a non-empty string
    = pad (8 - extra), otherwise
      where
        len   = #s
        extra = #s $mod 8
        pad n = shows "\t.byte\t" . interShows ", " (map showsint (rep n 0)) . shows "\n"

genQuad :: showS -> showS
genQuad f = shows "\t.quad\t" . f . shows "\n"

genAscii :: string -> showS
genAscii s
    = id,                                             if #s == 0 
    = shows "\t.ascii\t" . genCString s . shows "\n", otherwise

genCodeLabel :: codePtr -> showS
genCodeLabel cp = shows "co" . showsint cp

genHeapLabel :: heapPtr -> showS
genHeapLabel hp = shows "ho" . showsint hp

genLocComment :: locInfo -> showS
genLocComment (path, mloc)
    = shows "# " . interShows "`" (map genAsmName (reverse path)) . shows "\n"

|| generate a value to store in a heapObj env (tag appropriately)
genValue :: value -> showS
genValue (Word n)   = genQuad (showsint (n * 2))                || Note: tag bit '0' added to word# values
genValue (Caddr cp) = genQuad (genCodeLabel cp)                 || Note: codePtr values are untagged
genValue (Haddr hp) = genQuad (genHeapLabel hp . shows "+1")    || Note: tag bit '1' added to heapPtr values


|| an x86Opr is an x86 instruction operand, either an immediate value, a register, or a memory address
x86Opr ::=
    X86Imm int                          |    || an immediate value
    X86Reg string                       |    || an x86 register name
    X86Mem (maybe x86Opr) string int    |    || a memory address, with optional base reg, the symbolic offset, the numeric offset
    X86Idx x86Opr x86Opr int int             || a memory address, with a base x86Reg, an index x86Reg, a scale value, and an offset

isX86Imm, isX86Imm64, isX86Reg, isX86Mem :: x86Opr -> bool
isX86Imm (X86Imm n)       = True
isX86Imm x                = False

isX86Imm64 (X86Imm n)     = abs n > 0x7fffffff
isX86Imm64 x              = False

isX86Reg (X86Reg s)       = True
isX86Reg x                = False

isX86Mem (X86Mem b o n)   = True
isX86Mem (X86Idx b i s n) = True
isX86Mem x                = False


|| add a numeric offset to an existing x86Opr
addX86Offset :: int -> x86Opr -> x86Opr
addX86Offset a (X86Imm n)       = X86Imm (n + a)
addX86Offset a (X86Reg r)       = X86Mem (Just (X86Reg r)) "" a
addX86Offset a (X86Mem b o n)   = X86Mem b o (n + a)
addX86Offset a (X86Idx b i s n) = X86Idx b i s (n + a)

genX86Opr :: x86Opr -> showS
genX86Opr (X86Imm n) = shows "$" . showsint n
genX86Opr (X86Reg s) = shows "%" . shows s
genX86Opr (X86Mem b s n)
    = showsOffset s n . showsBase b
      where
        showsOffset "" 0 = id
        showsOffset "" n = showsint n
        showsOffset o  0 = shows o
        showsOffset o  n = shows o . shows "+" . showsint n

        showsBase Nothing  = id
        showsBase (Just b) = showsInParens (genX86Opr b)

genX86Opr (X86Idx b i s n)
    = showsOffset n . showsIdx
      where
        showsOffset 0 = id
        showsOffset n = showsint n
        showsIdx      = showsInParens (interShows ", " [genX86Opr b, genX86Opr i, showsint s])

|| x86Jmp instructions have a slightly different format for memory addresses than other x86 insns
genX86JmpOpr :: x86Opr -> showS
genX86JmpOpr o
    = showsInd o . genX86Opr o
      where
        showsInd (X86Mem Nothing o n) = id
        showsInd o                    = shows "*"

|| x86 register usage, matching System V AMD64 ABI (MacOS and Linux)
x86ArgNames = ["rdi", "rsi", "rdx", "rcx", "r8", "r9"]          || STG arg0 .. arg5, matches x86-64 calling convention for args
x86RegNames = ["rax", "r10", "r11", "r13", "r14", "r15"]        || STG r0 .. r5
x86IP       = X86Reg "rip"                                      || instruction pointer for PC-relative addressing
x86SP       = X86Reg "rsp"                                      || stack pointer
x86Frm      = X86Reg "r12"                                      || STG Frm ptr
x86GcAlloc  = X86Reg "rbp"                                      || heap allocation pointer
x86MovTmp   = X86Reg "rbx"                                      || reserved tmp register for moves, can be used as general temp if not used by genInsn/Move
x86Tmp0     = cvtReg 0                                          || Reg[0] can be used as a tmp when the result tag isn't live and not in mul/div
x86Tmp1     = cvtReg 1                                          || Reg[1] can be used as a tmp when the result tag isn't live
x86Env      = cvtReg 2                                          || Reg[2] = env / ptr to closure
x86rdx      = X86Reg "rdx"                                      || used for mul/div
x86rax      = X86Reg "rax"                                      || used for mul/div
x86rcx      = X86Reg "rcx"                                      || used for shift count

|| modify an X86Reg name to a sub-register name
subRegModifier ::= Byte0 | Byte1 | Word0

subRegister :: subRegModifier -> string -> string
subRegister m (r : c : cs)
    = r : subNew (c : cs) m, if digit c
    = subOld (c : cs) m,     otherwise
      where
        err      = error ("subRegister: illegal modifier for register " ++ (r : c : cs))
        subNew []       Byte0 = ['b']
        subNew []       Byte1 = err
        subNew []       Word0 = ['w']
        subNew (c : cs) m     = c : subNew cs m

        subOld []       _     = []
        subOld ['x']    Byte0 = ['l']
        subOld ['x']    Byte1 = ['h']
        subOld ['x']    Word0 = ['x']
        subOld (c : cs) m     = c : subOld cs m

subRegister n s = error ("subRegister: illegal register name " ++ s)

|| create names for sub-register elements
byte0, byte1, word0 :: x86Opr -> x86Opr
byte0 (X86Reg s) = X86Reg (subRegister Byte0 s)
byte0 _          = error "byte0: not an X86Reg"

byte1 (X86Reg s) = X86Reg (subRegister Byte1 s)
byte1 _          = error "byte1: not an X86Reg"

word0 (X86Reg s) = X86Reg (subRegister Word0 s)
word0 _          = error "word0: not an X86Reg"

cvtMemAddr, cvtCMemAddr :: string -> x86Opr
cvtMemAddr s  = X86Mem (Just x86IP) s 0
cvtCMemAddr s = X86Mem (Just x86IP) (codegenCsymbolPrefix ++ s) 0

cvtJmpAddr, cvtCJmpAddr :: string -> x86Opr
cvtJmpAddr  s = X86Mem Nothing s 0
cvtCJmpAddr s = X86Mem Nothing (codegenCsymbolPrefix ++ s) 0

|| convert a codePtr for use in a jmp instruction
cvtJmpCodePtr :: codePtr -> x86Opr
cvtJmpCodePtr cp = cvtJmpAddr (genCodeLabel cp "")

|| convert a codePtr for use as an operand addr
cvtMemCodePtr :: codePtr -> x86Opr
cvtMemCodePtr cp = cvtMemAddr (genCodeLabel cp "")

cvtHeapPtr :: heapPtr -> x86Opr
cvtHeapPtr hp = cvtMemAddr (genHeapLabel hp "")

cvtIndexAddr :: ref -> ref -> int -> int -> x86Opr
cvtIndexAddr b i s n = X86Idx (cvtRef b) (cvtRef i) s n

|| convert an Arg reference to an x86Opr
cvtArgState, cvtArg :: int -> x86Opr
cvtArgState n = addX86Offset (n * 8) (cvtCMemAddr "Arg")
cvtArg n
    = err,                                if n >= codegenMaxArgs
    = X86Reg (x86ArgNames ! n),           if n < 6      || first 6 stg args passed in x86 registers
    = cvtArgState n,                      otherwise     || remaining passed in ArgState
      where
        err = error $ "Arg " ++ showint n ++ " exceeds limit -- increase codegenMaxArgs?"

|| convert a Reg reference to an x86Opr
cvtRegState, cvtReg :: int -> x86Opr
cvtRegState n = addX86Offset (n * 8) (cvtCMemAddr "Reg")
cvtReg n
    = err,                             if n >= codegenMaxRegs
    = X86Reg (x86RegNames ! n),        if n < 6      || first 6 stg regs allocated in x86 registers
    = cvtRegState n,                   otherwise     || remaining passed in RegState
      where
        err = error $ "Reg " ++ showint n ++ " exceeds limit -- increase codegenMaxRegs?"

|| convert an stgInsn reference to an x86Opr
cvtRef :: ref -> x86Opr
cvtRef (Env, n) = addX86Offset (n * 8 + 15) x86Env   || x86Env holds tagged closure base; adjust to remove tag bit and point to env field
cvtRef (Frm, n) = addX86Offset (n * 8 - 1)  x86Frm   || x86Frm holds tagged Frame base; untag frm base pointer
cvtRef (Arg, n) = cvtArg n
cvtRef (Reg, n) = cvtReg n

|| convert an stgInsn operand to an x86Opr
cvtOpr :: opr -> x86Opr
cvtOpr (Imm (Word n))   = X86Imm (n * 2)                        || tag bit '0' added to word# values
cvtOpr (Imm (Caddr cp)) = cvtMemCodePtr cp
cvtOpr (Imm (Haddr hp)) = addX86Offset 1 (cvtHeapPtr hp)        || tag bit '1' added to heapPtr values
cvtOpr (Ref (Frm, n))   = addX86Offset (n * 8) x86Frm           || Frm register already has tag bit
cvtOpr (Ref r)          = cvtRef r


|| generate an x86-64 opcode
genOpcode :: string -> [x86Opr] -> showS

|| handle the case where both operands are mem by moving the first to a register
genOpcode op [a, b]
    = genMovTmp op, if isX86Mem a & isX86Mem b
      where
        genMovTmp "leaq" = genOpcode op [a, x86MovTmp] . genOpcode "movq" [x86MovTmp, b]
        genMovTmp op     = genOpcode "movq" [a, x86MovTmp] . genOpcode op [x86MovTmp, b]

|| handle the case where the first operand is a 64-bit immediate, but op is not a movq or the second operand is not a register
genOpcode op [imm, dst]
    = genOpcode "movq" [imm, x86MovTmp] . genOpcode op [x86MovTmp, dst], if isX86Imm64 imm & (op ~=$ "movq" \/ ~isX86Reg dst)

genOpcode op args
    = shows "\t" . shows op . shows "\t" . interShows ", " (map genX86Opr args) . shows "\n"

|| generate an x86-64 jump opcode (uses slightly different syntax)
genJmpOpcode :: string -> x86Opr -> showS
genJmpOpcode op arg = shows "\t" . shows op . shows "\t" . genX86JmpOpr arg . shows "\n"

|| generate an x86-64 conditional jump opcode from a Jeq stgInsn
|| This assumes that a prior Cmp has generated an x86 cmpq which has placed the comparison results in the x86 flags register
|| Then we select which conditional branch opcode to use based upon the value of operand b, which will be a 0 (eq), 1 (lt), or 2 (gt)
|| operand a is unused, here (was used by the prior Cmp)
genCondJmp :: stgInsn -> showS
genCondJmp (Jeq a b cp)
    = genJmpOpcode (opFor b)(cvtJmpCodePtr cp)
      where
        opFor (Imm (Word 0)) = "je"
        opFor (Imm (Word 1)) = "jl"
        opFor (Imm (Word 2)) = "jg"
        opFor b              = error ("genCondJmp: no opFor " ++ showopr b)

genCondJmp _ = error "genCondJmp: not a Jeq insn"


|| common x86-64 building blocks

|| determine the correct x86 opcode to use to move a value (addresses use leaq, other values use movq)
movOpForOpr :: opr -> string
movOpForOpr (Imm (Caddr hp)) = "leaq"
movOpForOpr (Imm (Haddr hp)) = "leaq"
movOpForOpr (Ref (Frm, n))   = "leaq"
movOpForOpr a                = "movq"

|| force an opr to an x86Reg, if it doesn't already resolve to one
|| returns the final destination x86Reg and a showS representing the (possible empty)
|| move operation
ensureX86Reg :: x86Opr -> opr -> (x86Opr, showS)
ensureX86Reg default a
    = (xa, id),      if isX86Reg xa
    = (default, op), otherwise
      where
        xa = cvtOpr a
        op = genOpcode (movOpForOpr a) [xa, default]

|| same as above, but for a destination reference
ensureX86DstReg :: x86Opr -> ref -> (x86Opr, showS)
ensureX86DstReg default d
    = (xd, id),      if isX86Reg xd
    = (default, op), otherwise
      where
        xd = cvtRef d
        op = genOpcode "movq" [default, xd]

|| move opr to ref
genMove :: ref -> opr -> showS
genMove d a
    = id,                                             if _eq cmpopr (Ref d) a || don't gen anything if it is already in place
    = genOpcode (movOpForOpr a) [cvtOpr a, cvtRef d], otherwise

|| generate a series of instructions to move a list of operands to Args registers
|| relocate any Arg about to be overwritten to the ArgState area, if it is still needed for subsequent moves
genMoveToArgs :: [opr] -> showS
genMoveToArgs
    = genMoves m_empty . enumerate
      where
        genMoves alts [] = id
        genMoves alts ((i, v) : vs)
            = relocate . moveArg . genMoves alts' vs
              where
                d        = (Arg, i)
                x86d     = cvtRef d
                doReloc  = member cmpopr (map snd vs) (Ref d)
                x86dAlt  = cvtArgState i        || alt location for arg, if it is still needed
                x86v     = m_findWithDefault cmpopr (cvtOpr v) v alts
                moveArg  = id,                                     if _eq cmpx86Opr x86v x86d   || don't move if already there
                         = genOpcode (movOpForOpr v) [x86v, x86d], otherwise

                alts'    = m_insert cmpopr (Ref d) x86dAlt alts,   if doReloc
                         = alts,                                   otherwise

                relocate = genOpcode "movq" [x86d, x86dAlt],       if doReloc
                         = id,                                     otherwise

|| generate a series of instructions to move a list of operands to a memory area
|| the first argument is the x86Opr holding the base address to move to
genMoveToMem :: x86Opr -> [opr] -> showS
genMoveToMem dBase
    = foldr (.) id . map movEnv . enumerate
      where
        movEnv (i, a)
            = genOpcode (movOpForOpr a) [cvtOpr a, addX86Offset (i * 8) dBase]

|| add with untagged immediate
genAddI :: ref -> int -> showS
genAddI d n = genOpcode "addq" [X86Imm n, cvtRef d]

|| shifts by 1 bit
genSar1, genShl1 :: ref -> showS
genSar1 d = genOpcode "sarq" [cvtRef d]
genShl1 d = genOpcode "shlq" [cvtRef d]

|| Generate the first common part of a combined div/mod operation
|| Since the x86-64 idivq instruction operates on fixed registers
|| %rax(Reg 0) and %rdx (Arg 2), move the operands to those registers.
|| the quotient is in %rax and the remainder in %rdx at the end.
|| Code that calls this is in charge of adding an Int tag and moving the correct result to the destination
|| Note: %rax and %rdx are destroyed, and must be saved and restored around this operation, if required
genDivRem :: ref -> opr -> opr -> showS
genDivRem d a b
    = genMove d b                                  .    || copy opr b to destination so we can manipulate it (done first because cqto destroys rdx)
      genSar1 d                                    .    || remove value tag
      genOpcode (movOpForOpr a) [cvtOpr a, x86rax] .    || copy opr a to %rax, lower 64 bits of dividend
      genOpcode "sarq" [x86rax]                    .    || remove value tag
      genOpcode "cqto" []                          .    || sign-extend to %rdx for upper 64 bits of dividend)
      genOpcode "idivq" [cvtRef d]                      || perform 128b/64b divide; quotient in %rax

|| generate code to perform a write-barrier check on the addr in register upd
genWriteBarrier :: x86Opr -> showS
genWriteBarrier upd
    = genOpcode    "cmpq"  [cvtCMemAddr "gcNewBase", upd]          .
      genJmpOpcode "jae"   (cvtJmpAddr "0f")                       .    || skip if upd >= gcNewBase (unsigned)
      genOpcode    "movq"  [cvtCMemAddr "gcRootsAlloc", x86MovTmp] .    || note: move is done before check so that the update is recorded if a GC happens
      genOpcode    "subq"  [X86Imm 8, x86MovTmp]                   .    || decrement the roots table alloc pointer (roots table grows down)
      genOpcode    "movq"  [upd, addX86Offset 0 x86MovTmp]         .    || put the update thunk addr in the roots table
      genOpcode    "movq"  [x86MovTmp, cvtCMemAddr "gcRootsAlloc"] .
      genOpcode    "cmpq"  [x86MovTmp, cvtCMemAddr "gcHeapTop"]    .    || check for root table overflow
      genJmpOpcode "jl"    (cvtJmpAddr "0f")                       .    || still space; proceed
      genOpcode    "movq"  [X86Imm 0, cvtCMemAddr "gcRequestSize"] .    || set request size of 0 for GC (since this is for roots rather than heap)
      genJmpOpcode "call"  (cvtJmpAddr "GC")                       .    || and jump to the GC handler to compact the roots table
      shows "0:\n"                                                 
      || fall through to code after write barrier

|| generate code to allocate a fixed number of words from the heap, generating a jump to
|| the GC handler if out of space
genAlloc :: x86Opr -> int -> showS
genAlloc allocReg size
    = shows "0:\n"                                                    . || label for restarting after gc
      genOpcode    "movq"  [x86GcAlloc, allocReg]                     . || alloc ptr is frame base
      genOpcode    "addq"  [X86Imm (8 * size), x86GcAlloc]            . || add size in bytes to gcAlloc
      genOpcode    "cmpq"  [x86GcAlloc, cvtCMemAddr "gcHeapTop"]      . || check if out of space
      genJmpOpcode "jg"    (cvtJmpAddr "0f")                          . || still space; proceed
      genOpcode    "leaq"  [cvtMemAddr "0b", x86MovTmp]               . || out of space; push restart label
      genOpcode    "pushq" [x86MovTmp]                                .
      genOpcode    "movq"  [X86Imm size, cvtCMemAddr "gcRequestSize"] . || set request size for GC
      genJmpOpcode "jmp"   (cvtJmpAddr "GC")                          . || and jump to the GC handler
      shows "0:\n"                                                      || label for continuation of succesful alloc

|| generate code to allocate a variable number of qwords from the heap, generating a jump to
|| the GC handler if out of space
|| note: implicitly adds 1 word to the size for tagword allocation
|| note: allocReg and szReg must be an x86Reg
genAllocVar :: x86Opr -> x86Opr -> showS
genAllocVar allocReg szReg
    = shows "0:\n"                                                   .  || label for restarting after gc
      genOpcode    "movq"  [x86GcAlloc, allocReg]                    .  || alloc ptr is frame base
      genOpcode    "leaq"  [X86Idx x86GcAlloc szReg 4 8, x86GcAlloc] .  || sz is tagged, so scale factor is 4 to get * 8, offset 8 to add tagword
      genOpcode    "cmpq"  [x86GcAlloc, cvtCMemAddr "gcHeapTop"]     .  || check if out of space
      genJmpOpcode "jg"    (cvtJmpAddr "0f")                         .  || still space; proceed
      genOpcode    "leaq"  [cvtMemAddr "0b", x86MovTmp]              .  || out of space; push restart label
      genOpcode    "pushq" [x86MovTmp]                               .
      genOpcode    "movq"  [szReg, cvtCMemAddr "gcRequestSize"]      .  || set request size for GC
      genJmpOpcode "jmp"   (cvtJmpAddr "GC")                         .  || and jump to the GC handler
      shows "0:\n"                                                      || label for continuation of succesful alloc

|| generate the individual Pack functions to pack r0, args into a new closure
|| these functions are called from various locations in Update code and return using a ret insn
|| Note: no need to save r1, since it is only needed by Update and Vclosure stgInsns to
|| redirect to the correct PackArgs fn.
genPackArgs :: showS
genPackArgs
    = foldr (.) id (map genPack [0 .. codegenMaxArgs])
      where
        genPack n
            = genCGlobal ("PackArgs" ++ showint n)                          .
              genAlloc x86Env (n + 3)                                       .        || alloc heap space for tagword, unpackFn, r0, args
              genOpcode "movq" [X86Imm tag, addX86Offset 0 x86Env]          .
              genOpcode "leaq" [cvtMemAddr unpackFn, addX86Offset 8 x86Env] .        || move unpackFn for this pack into the codePtr
              genOpcode "movq" [cvtReg 0, addX86Offset 16 x86Env]           .        || copy R0 to first location in env
              genMoveToMem (addX86Offset 24 x86Env) args                    .        || copy args into remaining env locations
              genOpcode "ret" []                                                     || return to the next continuation closure
              where
                tag      = genThunkTag (n + 1)                                       || r0, args
                unpackFn = "UnpackArgs" ++ showint n
                args     = map (Ref . pair Arg) [0 .. n - 1]

|| generate the individual Unpack continuation closure functions to unpack pack r0, args from a closure,
|| then pop a continuation from the stack and return to it
|| Note: need to restore the correct PackArgs function in r1 for this unpack, since
|| the continuation we are returning to may also perform a PackArgs
genUnpackArgs :: showS
genUnpackArgs
    = foldr (.) id (map genUnpack [0 .. codegenMaxArgs])
      where
        genUnpack n
            = shows ("\nUnpackArgs" ++ showint n ++ ":\n")    .
              genMove (Reg, 0) (Ref (Env, 0))                 .  || unpack tag
              genOpcode "leaq" [cvtCMemAddr packFn, cvtReg 1] .  || restore packFn (if we need to pack again due to another update)
              genMoveToArgs env                               .  || move the rest of the Env to the Args
              genOpcode "ret" []                                 || return to the continuation
              where
                packFn = "PackArgs" ++ showint n
                env    = map (Ref . pair Env) [1 .. n]

|| generate the individual ApplyToEnv continuation closure functions to apply r0
|| to the continuation env which is on the stack
|| instead of popping into the Env save area, we pop directly into the Args registers to prevent double-copying
genApplyToEnvs
    = foldr (.) id (map genAppToEnv [0 .. codegenMaxArgs - 1]) .
      genSection "data"                                        .
      genCGlobal "ApplyToEnvFns"                               .
      foldr (.) id (map genLabel [0 .. codegenMaxArgs - 1])    .
      genSection "text"
      where
        genLabel n = genQuad (shows "ApplyToEnv" . showsint n)

        genAppToEnv n
            = shows ("\nApplyToEnv" ++ showint n ++ ":\n") .
              foldr (.) id (map doPop [0 .. n - 1])        .    || pop env on stack into Args registers
              genInsn (Apply r0Opr env)
              where
                env     = map (Ref . pair Arg) [0 .. n - 1]
                doPop n = genOpcode "popq" [cvtRef (Arg, n)]

|| generate the individual OverApplyThunk functions to push an ApplyToEnv, then enter the thunk
genOverApplyThunk
    = foldr (.) id (map genApp [1 .. codegenMaxArgs - 1])      || no over-application for 0 args
      where
        genApp nargs
            = shows ("\nOverApplyThunk" ++ showint nargs ++ ":\n") .
              genInsn (PushCont applyToEnvPtr env)                 .
              genJmpOpcode "jmp"  (addX86Offset 7 x86Env)                               || untag and jump to closure's cp
              where
                env = (map (Ref . pair Arg) [0 .. nargs - 1])

|| generate the individual RetArg functions to return a particular Arg
|| move it into r0, then do a Ret
genRetArg :: showS
genRetArg
    = foldr (.) id (map genRet [0 .. codegenMaxArgs - 1]), if useSel
    = id,                                                  otherwise
      where
        genRet n
            = shows ("\nRetArg" ++ showint n ++ ":\n") .
              genInsn (Ret (Ref (Arg, n)) (Imm (Word 0)))

|| generate the individual ApplyArg functions to perform an Apply on a particular Arg
genApplyArg :: showS
genApplyArg
    = foldr (.) id (map genApply [0 .. codegenMaxArgs - 1]), if useSel
    = id,                                                    otherwise
      where
        genApply n
            = shows ("\nApplyArg" ++ showint n ++ ":\n") .
              genInsn (Apply (Ref (Arg, n)) [])

|| generate an stgInsn
genInsn :: stgInsn -> showS

|| call cp, moving args to Arg registers
genInsn (Call cp args)
    = genMoveToArgs args .
      genJmpOpcode "jmp" (cvtJmpCodePtr cp)

|| enter closure pointed to by the heapPtr, setting r2 to the Env addr (hp + 16) and jumping to the codePtr at hp + 8
genInsn (Enter hp args)
    = genMoveToArgs args                                           .
      genOpcode    "leaq" [addX86Offset 1 (cvtHeapPtr hp), x86Env] .    || add tag bit to raw heapPtr
      genJmpOpcode "jmp"  (addX86Offset 7 x86Env)                       || jump to closure's codePtr

|| enter the closure pointed to by the fopr
genInsn (EnterInd fopr args)
    = genArgs fopr . genEnter
      where
        || save fopr in r0 if it will be overwritten during genMoveToArgs
        genArgs (Ref (Arg, n))
            = genMove r0Ref fopr .
              genMoveToArgs args .
              genMove r2Ref r0Opr, if member cmpint [0 .. #args - 1] n

        genArgs fopr = genMoveToArgs args . genMove r2Ref fopr

        genEnter = genJmpOpcode "jmp" (addX86Offset 7 x86Env)       || untag and jump to closure's cp

|| apply -- check heapInfo for common cases of Hfun, Hthunk, or Hfwd with correct arity, then enter
|| otherwise punt to more extensive out-of-line code
genInsn (Apply fopr args)
    = genArgs fopr . genApply
      where
        nargs     = #args
        applyAddr = cvtJmpAddr "GeneralApply"

        || save fopr in r0 if it will be overwritten during genMoveToArgs
        || then move to r2 (x86Env)
        genArgs (Ref (Arg, n))
            = genMove r0Ref fopr .
              genMoveToArgs args .
              genMove r2Ref r0Opr, if member cmpint [0 .. nargs - 1] n

        genArgs fopr = genMoveToArgs args . genMove r2Ref fopr

        genApply
            = genOpcode    "movq" [X86Imm (nargs), cvtReg 3]          . || put #args in Miranda R3 to pass to GeneralApply (R3 is temp at this point)
              genOpcode    "movq" [addX86Offset (-1) x86Env, tagword] . || load the heapInfo tagword, removing the tag bit from the addr first
              genOpcode    "cmpb" [X86Imm 2, tag]                     . || compare tag byte with 1
              genJmpOpcode "ja"   applyAddr                           . || tag was > 2; need to perform general apply
              genOpcode    "cmpb" [X86Imm (nargs), arity]             . || compare arity
              genJmpOpcode "jne"  (cvtJmpAddr "0f")                   . || unequal: do special unequal arity handling checks
              genJmpOpcode "jmp"  (addX86Offset 7 x86Env)             . || equal: jump to closure's cp
              shows "0:\n"                                            .
              genUnequalArities nargs arity                             || generate special, but still common cases, or punt to GeneralApply
              where
                tagword = x86Tmp0
                arity   = byte1 tagword
                tag     = byte0 tagword

        || under-applied with no args: return the original fopr as a value
        genUnequalArities 0 arity
            = genMove r0Ref r2Opr       .               || return fopr (which was copied into r2 above)
              genInsn (Ret r0Opr (Imm (Word 0)))        || set arity to 0

        || check for over-application of a thunk, or jump to GeneralApply
        genUnequalArities x arity
            = genOpcode    "cmpb" [X86Imm 0, arity]    .        || check for over-applied thunk (most common case)
              genJmpOpcode "je"   (cvtJmpAddr overApp) .        || jump to special handler, if so
              genJmpOpcode "jmp" applyAddr                      || otherwise, jump to GeneralApply
              where
                overApp = "OverApplyThunk" ++ showint nargs


|| the generic ApplyToEnv is replaced by the individual ApplyToEnv routines, and is not directly called
genInsn ApplyToEnv = id

|| enter the Hfbalt closure pointed to by fopr, unwinding the stack to the saved sp
genInsn (Fail fopr)
    = genMove r2Ref fopr                                          .     || copy fopr into x86Env
      genOpcode    "movzwq" [addX86Offset 1 x86Env, x86Tmp0]      .     || extract the env size field and use it to index into the env
      genOpcode    "movq"   [X86Idx x86Env x86Tmp0 8 7, x86SP]    .     || copy saved sp to x86SP to unwind stack (7 to remove tag and get last word)
      genJmpOpcode "jmp"    (addX86Offset 7 x86Env)                     || untag and jump to closure's cp

genInsn (Ret val aty)
    = genMove r0Ref  val                          .             || update the returned tag value
      genArity aty                                .             || generate the arity-setting move
      genOpcode    "ret" []                                     || return to continuation addr on top of stack
      where
        genArity (Imm (Word n))
            = genOpcode "leaq" [cvtCMemAddr packFn, cvtReg 1]   || set r1 to packArgs fn corresponding to #of args
              where
                packFn = "PackArgs" ++ showint n

        genArity r = genMove (Reg, 1) aty                       || copy aty operand (a previously set value) to r1


|| The generic RetEnv is replaced by the individual UnpackArgs routines, and is not directly called
genInsn RetEnv = id

|| Note: this generates inline data which results in absolute addresses being used for the indirect jmp.  When assembled
|| it generates a warning that PIE is disabled, unless the warning is supressed with appropriate compiler flags
genInsn (CaseVec c cps)
    = genOpcode    "leaq" [cvtMemAddr "1f", x86MovTmp]  .  || addr of base of table of codePtrs
      genJmpOpcode "jmp"  (X86Idx x86MovTmp tag 4 0)    .  || index into it by scaling the tag value by 4 (because tag bit is already present)
      shows "1:\n"                                      .  || generate inline table of codePtrs
      foldr (.) id (map (genValue . Caddr) cps)
      where
        tag = cvtReg 0

genInsn (Jmp cp) = genJmpOpcode "jmp" (cvtJmpCodePtr cp)

|| a Jeq by itself is an equality comparison between a tag value in r0 (a) and an immediate word value (b)
|| Generate an explicit Cmp for this, followed by the conditional jmp, replacing b with an immediate word 0
|| to signify we want an equality comparison
genInsn (Jeq a b cp)
    = genOpcode "cmpq" [cvtOpr b, cvtOpr a] .
      genCondJmp (Jeq a (Imm (Word 0)) cp)

|| generate a thunk in the heap for the continuation, then push its heap addr onto the stack
|| special handling for pushing a continuation to the generic applyToEnvPtr, selRetPtr or
|| selApply ptr: these get turned into direct calls to individually-expanded handlers
genInsn (PushCont cp env)
    = genPushAppEnv (#env), if cp == applyToEnvPtr
    = genPushRetArg env,    if useSel & cp == selRetPtr
    = genPushAppArg env,    if useSel & cp == selApplyPtr
    = genPushGeneric,       otherwise
      where
        genPushAppEnv n              = genPushCont (cvtMemAddr ("ApplyToEnv" ++ showint n)) env

        genPushRetArg [Imm (Word n)] = genPushCont (cvtMemAddr ("RetArg"   ++ showint n)) []
        genPushRetArg _              = undef    || added to remove compiler warning

        genPushAppArg [Imm (Word n)] = genPushCont (cvtMemAddr ("ApplyArg" ++ showint n)) []
        genPushAppArg _              = undef    || added to remove compiler warning

        genPushGeneric               = genPushCont (cvtMemCodePtr cp) env

        genPushCont ptr env
            = genAllocStk (#env)                        .       || allocate stack space for the env
              genMoveToMem      x86SP env               .       || move env oprs to stack
              genOpcode "leaq"  [ptr, x86MovTmp]        .       || push continuation codePtr to return to
              genOpcode "pushq" [x86MovTmp]

        genAllocStk 0 = id                                      || no insn required for 0 env args
        genAllocStk n = genOpcode "subq" [X86Imm (n * 8), x86SP]

|| pop a saved context environment from the stack and put in the global Env space
|| this is to solve the problem of having an active environment on the stack while
|| needing to push a new continuation environment, and requiring that tail calls
|| not actually grow the stack
genInsn (PopEnv 0) = id                                         || nothing required for a null closure env
genInsn (PopEnv n)
    = err,                                            if n >= codegenMaxEnv
    = foldr (.) id (map doPop [2 .. n + 1])       .             || leaves 2 slots at beginning of Env to emulate a heap closure tag and codePtr
      genOpcode "leaq" [addX86Offset 1 genv, x86Env], otherwise || set the x86Env to the global Env area
      where
        genv    = cvtCMemAddr "Env"
        doPop n = genOpcode "popq" [addX86Offset (n * 8) genv]
        err     = error $ "Env " ++ showint n ++ " exceeds limit -- increase codegenMaxEnv?"

genInsn (AllocFrame n)
    = genAlloc x86Frm n         .
      genOpcode "incq" [x86Frm] .                               || tag Frm register
      genOpcode "movq" [X86Imm n, cvtCMemAddr "FrmSize"]        || save size in FrmSize for GC to use

|| generate an function closure
genInsn (Fclosure d cp ar env)
    = genOpcode "movq" [X86Imm tag, dBase]                      .
      genOpcode "leaq" [cvtMemCodePtr cp, addX86Offset 8 dBase] .
      genMoveToMem     (addX86Offset 16 dBase) env
      where
        dBase = cvtRef d
        tag   = genFunTag ar (#env)

|| generate a thunk closure
genInsn (Tclosure d cp env)
    = genOpcode "movq" [X86Imm tag, dBase]                      .
      genOpcode "leaq" [cvtMemCodePtr cp, addX86Offset 8 dBase] .
      genMoveToMem     (addX86Offset 16 dBase) zenv
      where
        dBase = cvtRef d
        zenv  = [Imm (Word 0)], if null env     || if no env, fill reserved update word with 0
              = env,            otherwise
        tag   = genThunkTag (#zenv)

|| generate a fatbar alternate closure, capturing the current stack pointer value
|| if the destination is a Reg ref, then allocate space for the closure
|| if the destination is a Frm ref, then space has already been allocated
genInsn (Sclosure d cp env)
    = mbAlloc          d (#env + 3)                             .       || +3 = slot for tag, slot for codePtr, slot for stackPtr value
      genOpcode "movq" [X86Imm tag, addX86Offset 0 dBase]       .
      genOpcode "leaq" [cvtMemCodePtr cp, addX86Offset 8 dBase] .
      genMoveToMem     (addX86Offset 16 dBase) env              .       || copy env to closure env
      genOpcode "movq" [x86SP, addX86Offset spLoc dBase]        .       || save current SP after env
      mbTag            d                                                || tag destination as heapPtr, if we performed an alloc
      where
        dBase = cvtRef d
        nenv  = #env
        tag   = genFbAltTag nenv
        spLoc = (2 + nenv) * 8                  || tagword + cp + env words in front of spLoc

        mbAlloc (Frm, _) n = id                 || destination is a frm ref, allocation already performed
        mbAlloc _ n        = genAlloc dBase n   || destination is a register -- perform allocation

        mbTag (Frm, _) = id
        mbTag _        = genOpcode "incq" [dBase]

|| generate a thunk closure for a saturated constructor value, capturing its tag and args
|| The tag and arg arity are not known at compile time, so the constructor puts the
|| correct PackArgs routine to use in Reg 1
|| routine to generate the closure from the dynamic Args arity value in r1.
genInsn (Vclosure d cp)
    = genOpcode    "pushq" [x86Env]                          .       || save envReg
      genJmpOpcode "call"  (cvtReg 1)                        .       || create a new closure and pack args into it (addr returned in x86Env)
      genOpcode    "leaq"  [addX86Offset 1 x86Env, cvtRef d] .       || move tagged closure heapPtr to destination register
      genOpcode    "popq"  [x86Env]                                  || restore envReg

|| update is used two different ways: to update a closure's codePtr with the blackHolePtr upon
|| entry to a thunk, and to update the thunk with its evaluated value.  The first can just
|| overwrite the cp without touching the env, etc.  The second is more involved, having to create
|| a new thunk for the value, fwd the old closure to it, and update the gcRootsList if the updated
|| closure is in old space
|| Note: ref d is always R2 (x86Env), so we just assume that in the code below
genInsn (Update d (Imm (Caddr cp)))
    = genUpdateBH, if cp == blackHolePtr
    = genUpdate,   otherwise
      where
        genUpdateBH
            = genOpcode "leaq" [cvtMemCodePtr cp, x86MovTmp] .
              genOpcode "movq" [x86MovTmp, addX86Offset 7 x86Env]

        || a full Update only occurs at the beginning of the updatePtr generic update code block, which
        || is pushed as a continuation on the stack.  Instead of generating code to pop the Env into the
        || Env space, we know that the single parameter (env ptr to update) is on the top of the stack,
        || so we just pop it into the upd tmp register
        || Reg 0, Reg 1 are live, so use Reg 3 as a temp
        genUpdate
            = genOpcode    "popq" [upd]                                   . || get heapPtr to update
              genJmpOpcode "call" packFn                                  . || create a new closure and pack args into it
              genOpcode    "movb" [X86Imm 2, addX86Offset (-1) upd]       . || update old closure's tag byte to Hfwd (2)
              genOpcode    "leaq" [fwdPtr, addX86Offset 7 upd]            . || update old closure's code ptr to do forwarding
              genOpcode    "leaq" [addX86Offset 1 x86Env, x86MovTmp]      . || update env 0 in old closure to point to new closure
              genOpcode    "movq" [x86MovTmp, addX86Offset 15 upd]        .
              genWriteBarrier upd                                           || perform a write barrier check on upd
              where
                packFn = cvtReg 1
                upd    = cvtReg 3       || x86MovTmp is used, and R0, R1 (x86Tmp0, x86Tmp1) are live, but R3 is available
                                        || and is not destroyed by the packFns, so it doesn't need to be saved
                fwdPtr = cvtMemCodePtr enterEnv0Ptr

genInsn (Mov d a)   = genMove d a
genInsn (Add d a b) = genMove d a . genOpcode "addq" [cvtOpr b, cvtRef d]
genInsn (Sub d a b) = genMove d a . genOpcode "subq" [cvtOpr b, cvtRef d]

|| x86-64 multiply is limited to reg/mem operands, so if one is Imm, make sure
|| it is the first operand, since that is explicitly moved to the destination register
genInsn (Mul d a (Imm b)) = genInsn (Mul d (Imm b) a)

|| multiplication needs one of the operand's implicit 0 Int tag bits to be removed so that the
|| actual multiply creates a single implicit 0 Int tag bit in the result
genInsn (Mul d a b)
    = genOpcode "movq"  [cvtOpr a, dreg] .
      genOpcode "sarq"  [dreg]           .      || remove value tag
      genOpcode "imulq" [cvtOpr b, dreg] .
      movd                                      || move result to final destination, if it isn't dreg
      where
        (dreg, movd) = ensureX86DstReg x86Tmp1 d

|| x86-64 idiv instruction performs integer division with round towards zero, while Miranda div
|| is defined as round towards -Inf, so we need to fix up the quotient if the signs of the divisor
|| and the remainder are unequal
genInsn (Div d a b)
    = genOpcode    "push" [x86rdx]               .      || save %rdx, as it is destroyed during DivRem
      genDivRem d a b                            .      || perform a DivRem (quotient in rax, remainder in rdx))
      genOpcode    "cmpq" [X86Imm 0, x86rdx]     .      || check if remainder is zero
      genJmpOpcode "jz"   (cvtJmpAddr "0f")      .      || if so, no fixup required
      genOpcode    "movq" [cvtOpr b, x86MovTmp]  .
      genOpcode    "sarq" [X86Imm 63, x86MovTmp] .      || sign of b extended as mask
      genOpcode    "sarq" [X86Imm 63, x86rdx]    .      || sign of rem extended as mask
      genOpcode    "xorq" [x86rdx, x86MovTmp]    .      || mask if sign b ~= sign rem (adjustment required)
      genOpcode    "addq" [x86MovTmp, x86rax]    .      || add adjustment to quotient (0 or -1)
      shows "0:\n"                               .
      genOpcode    "shlq" [x86rax]               .      || add Int tag bit (0) to quotient
      genOpcode    "movq" [x86rax, cvtRef d]     .      || and move it to the destination
      genOpcode    "pop"  [x86rdx]                      || restore original %rdx

|| x86-64 idiv instruction performs integer division with round towards zero, while Miranda mod
|| is defined as round towards -Inf, so we need to fix up the remainder if the signs of the divisor
|| and the remainder are unequal
genInsn (Mod d a b)
    = genOpcode    "push" [x86rdx]               .      || save %rdx, as it is destroyed during DivRem
      genDivRem d a b                            .      || perform a DivRem (quotient in rax, remainder in rdx)
      genOpcode    "cmpq" [X86Imm 0, x86rdx]     .      || check if remainder is zero
      genJmpOpcode "jz"   (cvtJmpAddr "0f")      .      || if so, no fixup required
      genOpcode    "movq" [cvtOpr b, x86MovTmp]  .
      genOpcode    "sarq" [X86Imm 63, x86MovTmp] .      || sign of b extended as mask
      genOpcode    "movq" [x86rdx, x86rax]       .
      genOpcode    "sarq" [X86Imm 63, x86rax]    .      || sign of rem extended as mask
      genOpcode    "cmpq" [x86rax, x86MovTmp]    .      || check if signs are equal or not
      genJmpOpcode "je"   (cvtJmpAddr "0f")      .      || no fixup required, if equal
      genOpcode    "movq" [cvtOpr b, x86MovTmp]  .
      genOpcode    "sarq" [x86MovTmp]            .      || untag divisor
      genOpcode    "addq" [x86MovTmp, x86rdx]    .      || add into remainder to create correct mod
      shows "0:\n"                               .
      genOpcode    "shlq" [x86rdx]               .      || add Int tag bit (0) to remainder
      genOpcode    "movq" [x86rdx, cvtRef d]     .      || and move it to the destination
      genOpcode    "pop"  [x86rdx]                      || restore original %rdx

|| the stgInsn Cmp semantics generate a 0# (eq), 1# (lt), or 2# (gt) result, but that would
|| be somewhat expensive to generate x86 code for.  Instead we perform an x86 cmpq insn, which
|| leaves its result in the flags register.  
|| Since the x86 cmp doesn't have an explicit destination register, it can be optimized to a single
|| instruction if the operands are compatible.
genInsn (Cmp d a b)
    = genMove d a .
      genOpcode "cmpq" [xb, cvtRef d], if isX86Mem xa & isX86Mem xb \/ isX86Imm xa
    = genOpcode "cmpq" [xb, xa],       otherwise
      where
        xa = cvtOpr a
        xb = cvtOpr b

|| bitwise operations on words
|| and, or, and xor correctly keep the tag bit 0
genInsn (Band d a b) = genMove d a . genOpcode "andq" [cvtOpr b, cvtRef d]
genInsn (Bor  d a b) = genMove d a . genOpcode "orq"  [cvtOpr b, cvtRef d]
genInsn (Bxor d a b) = genMove d a . genOpcode "xorq" [cvtOpr b, cvtRef d]

|| bitwise shifts must remove the tag bit from the shift amount before shifting
|| specialized version for shift amount known at compile-time
genInsn (Bshl d a (Imm (Word b)))
    = genMove d a .
      genOpcode "shlq" [X86Imm b, cvtRef d]

|| general version for shift amount known at runtime
|| shift count must be placed in %cl
genInsn (Bshl d a b)
    = genOpcode "movq" [x86rcx, x86Tmp0]  .     || save rcx so that it can be used for shift count
      genMove d a                         .
      genOpcode "movq" [cvtOpr b, x86rcx] .
      genOpcode "sarq" [x86rcx]           .     || remove tag bit from shift amount
      genOpcode "shlq" [xcl, cvtRef d]    .
      genOpcode "movq" [x86Tmp0, x86rcx]        || restore rcx
      where
        xcl = byte0 x86rcx

|| specialized version for shift amount known at compile-time
genInsn (Bshr d a (Imm (Word b)))
    = genMove d a                           .
      genOpcode "sarq" [X86Imm b, cvtRef d] .
      genOpcode "andq" [X86Imm (-2), cvtRef d]  || ensure the tag bit is 0

|| general version for shift amount known at runtime
genInsn (Bshr d a b)
    = genOpcode "movq" [x86rcx, x86Tmp0]       .        || save rcx so that it can be used for shift count
      genMove d a                              .
      genOpcode "movq" [cvtOpr b, x86rcx]      .
      genOpcode "sarq" [x86rcx]                .        || remove tag bit from shift amount
      genOpcode "sarq" [xcl, cvtRef d]         .
      genOpcode "andq" [X86Imm (-2), cvtRef d] .        || ensure the tag bit is 0
      genOpcode "movq" [x86Tmp0, x86rcx]                || restore rcx
      where
        xcl = byte0 x86rcx

|| a bitwise NOT must set the bottom bit to 0 to maintain the tag bit
genInsn (Bnot d a)
    = genOpcode "movq" [cvtOpr a, cvtRef d] .
      genOpcode "notq" [cvtRef d]           .
      genOpcode "andq" [X86Imm (-2), cvtRef d]  || ensure the tag bit is 0

|| Note: generic selRet and selApply are expanded to individual functions for each of the Arg registers
|| and reference during the generation of a PushCont insn, so Sel insn shouldn't be generated, here; just ignore it
genInsn (Sel d a) = id

|| allocate a new Hstream obj of the specified number of qwords and initialize
|| specialized version for size known at compile-time
genInsn (AllocStream d (Imm (Word fd)) (Imm (Word sz)))
    = genAlloc  xd (sz + 1)                            .        || tagword + stream size
      genOpcode "movq" [X86Imm tag, addX86Offset 0 xd] .
      genOpcode "incq" [xd]
      where
        xd  = cvtRef d
        tag = genHstreamTag fd sz

|| general version for fd and size known at runtime
genInsn (AllocStream d fd sz)
   =  genOpcode (movOpForOpr sz) [cvtOpr sz, x86Tmp1]   .       || note: tmp0 can't be used here, as it may be the dst register d
      genAllocVar xd x86Tmp1                            .       || allocate the heap space to the dst location
      genOpcode "shlq" [X86Imm 15, x86Tmp1]             .       || move Hstream buffer size in qwords to correct field in tagword
      genOpcode (movOpForOpr fd) [cvtOpr fd, x86MovTmp] .       || move fd value to x86MovTmp prepare for shift
      genOpcode "shlq" [X86Imm 7, x86MovTmp]            .       || untag fd value and shift it into the fd field location of the tagword
      genOpcode "addq" [x86MovTmp, x86Tmp1]             .       || add it to the tagword
      genOpcode "addq" [X86Imm 5, x86Tmp1]              .       || add tag value 5 for Hstream to tagword
      genOpcode "movq" [x86Tmp1, addX86Offset 0 xd]     .       || move the tagword into the heapObj
      genOpcode "incq" [xd]                                     || and return the tagged heapObj addr
      where
        xd         = cvtRef d

|| read a byte from the Hstream a, returning -1 if at the end of the stream
genInsn (ReadStream d s)
    = genMove      d (Imm (Word (-1)))                      .   || move default end-of-stream to destination
      movs                                                  .   || ensure stream value (heapPtr) is in a register
      genOpcode    "movzwq" [addX86Offset 5 sreg, pos]      .   || extract position field from the tag (into whole register pos)
      genOpcode    "cmpw"   [addX86Offset 3 sreg, posw]     .   || compare pos to limit
      genJmpOpcode "jae"    (cvtJmpAddr "1f")               .   || jump if pos >= limit
      genOpcode    "movzbq" [X86Idx sreg pos 1 7, cvtRef d] .   || extract byte from stream at pos
      genShl1      d                                        .   || shift by one to add value tag
      genOpcode    "incw"   [posw]                          .   || increment pos in tag
      genOpcode    "movw"   [posw, addX86Offset 5 sreg]     .
      shows "1:\n"      
      where
        pos          = x86MovTmp
        posw         = word0 pos
        (sreg, movs) = ensureX86Reg x86Tmp1 s

|| write a byte to the Hstream s
|| return 0 if the byte was succesfully written, -1 otherwise
genInsn (WriteStream d s c)
    = genMove      d (Imm (Word (-1)))                      .   || move default buffer full indication to destination
      movs                                                  .   || ensure stream value (heaptr) is in a register
      genOpcode    "movzwq" [addX86Offset 3 sreg, lim]      .   || extract limit field from tag
      genOpcode    "movzwq" [addX86Offset 1 sreg, creg]     .   || extract buffer qwords field from tag
      genOpcode    "shlq"   [X86Imm 3, creg]                .   || convert buffer size to bytes
      genOpcode    "cmpq"   [creg, lim]                     .   || compare current limit to buffer size
      genJmpOpcode "jae"    (cvtJmpAddr "1f")               .   || jump if lim >= buffer size
      genOpcode    "movq"   [cvtOpr c, creg]                .   || move char value to creg to allow lsb aliasing
      genOpcode    "sarq"   [creg]                          .   || remove value tag
      genOpcode    "movb"   [cregb, X86Idx sreg lim 1 7]    .   || insert byte into stream at lim
      genOpcode    "incw"   [limw]                          .   || increment limit in tag
      genOpcode    "movw"   [limw, addX86Offset 3 sreg]     .
      genMove      d (Imm (Word 0))                         .   || success indication
      shows "1:\n"      
      where
        lim          = x86MovTmp
        limw         = word0 lim
        creg         = x86Tmp0                  || note: d could also be R0 (x86Tmp0), but is written after the creg temp use
        cregb        = byte0 creg
        (sreg, movs) = ensureX86Reg x86Tmp1 s

|| allocate an array
|| specialized version for size known at compile-time
genInsn (AllocArray d (Imm (Word sz)))
    = genAlloc  xd (sz + 1)                            . || tag word + array size
      genOpcode "movq" [X86Imm tag, addX86Offset 0 xd] .
      genOpcode "incq" [xd]
      where
        xd  = cvtRef d
        tag = genHarrayTag sz

|| general version for size known at runtime
genInsn (AllocArray d a)
    = genOpcode (movOpForOpr a) [cvtOpr a, x86Tmp1] . || note: tmp0 can't be used here, because d may be tmp0
      genAllocVar xd x86Tmp1                        . || note: xa contains a tagged value at runtime, so it is already scaled by 2
      genOpcode "shlq" [X86Imm 31, x86Tmp1]         . || move Harray size in qwords to correct field in tagword
      genOpcode "addq" [X86Imm 6, x86Tmp1]          . || add tag value 6 for Harray
      genOpcode "movq" [x86Tmp1, addX86Offset 0 xd] . || move the tagword into the heapObj
      genOpcode "incq" [xd]                           || and return the tagged heapObj addr
      where
        xd         = cvtRef d

|| fill an array with a replicated value
genInsn (FillArray a v)
    = mova                                                .   || ensure operands are in registers
      movv                                                .
      genOpcode    "movq" [addX86Offset (-1) areg, ireg]  .   || areg is tagged heapPtr of array; get tagword
      genOpcode    "sarq" [X86Imm 32, ireg]               .   || extract array size (untagged)
      genOpcode    "cmpq" [X86Imm 0, ireg]                .   || test for empty array
      genJmpOpcode "jle"  (cvtJmpAddr "1f")               .   || note: test for index <= 0 to compensate for starting at size
      shows "0:\n"                                        .   || loop top
      genOpcode    "movq" [vreg, X86Idx areg ireg 8 (-1)] .   || note: offset of (-1) to remove tag; idx starts at size to compensate for tagword
      genOpcode    "decq" [ireg]                          .
      genJmpOpcode "jg"   (cvtJmpAddr "0b")               .   || note: test for index > 0 to compensate for starting at size
      shows "1:\n"                                            || loop exit
      where
        ireg         = x86Tmp0
        (areg, mova) = ensureX86Reg x86Tmp1 a
        (vreg, movv) = ensureX86Reg x86MovTmp v

|| copy an array
|| note: assumes sizes match!
genInsn (CopyArray d a)
    = mova                                               .   || ensure array operand a is in a register
      genOpcode    "movq" [addX86Offset (-1) areg, ireg] .   || xa is tagged heapPtr of array; get tagword
      genOpcode    "sarq" [X86Imm 32, ireg]              .   || extract array size (untagged)
      genOpcode    "cmpq" [X86Imm 0, ireg]               .   || test for empty array
      genJmpOpcode "jle"  (cvtJmpAddr "1f")              .   || note: test for index <= 0 to compensate for starting at size
      shows "0:\n"                                       .   || loop top
      genOpcode    "movq" [X86Idx areg ireg 8 (-1), tmp] .   || note: offset of (-1) to remove tag; idx starts at size to compensate for tagword
      genOpcode    "movq" [tmp, X86Idx xd ireg 8 (-1)]   .   || note: offset of (-1) to remove tag; idx starts at size to compensate for tagword
      genOpcode    "decq" [ireg]                         .
      genJmpOpcode "jg"   (cvtJmpAddr "0b")              .   || note: test for index > 0 to compensate for starting at size
      shows "1:\n"                                           || loop exit
      where
        ireg         = x86Tmp0
        (areg, mova) = ensureX86Reg x86Tmp1 a
        tmp          = x86MovTmp
        xd           = cvtOpr d

|| read an array at an index
|| specialized version for index known at compile-time
genInsn (ReadArray d a (Imm (Word i)))
    = mova                                            . || ensure array a operand is in a register
      genOpcode "movq" [addX86Offset idx areg, cvtRef d]
      where
        (areg, mova) = ensureX86Reg x86Tmp0 a
        idx          = i * 8 + 7        || add 7 to get to the base of the array

|| general version for index known at runtime
genInsn (ReadArray d a i)
    = mova                                      .
      movi                                      .
      genOpcode "movq" [X86Idx areg ireg 4 7, xd]       || offset of 8 -1 to subtract the tag bit
      where
        (areg, mova) = ensureX86Reg x86Tmp0 a
        (ireg, movi) = ensureX86Reg x86Tmp1 i
        xd           = cvtRef d

|| write an array at an index
|| specialized version for index known at compile-time
genInsn (WriteArray a (Imm (Word i)) v)
    = mova                                                       . || ensure array a operand is in a register
      genOpcode    movv   [vreg, addX86Offset idx areg]          . || perform write
      genOpcode    "cmpb" [X86Imm 7, addX86Offset (-1) areg]     . || check if we've already added areg to the roots list
      genJmpOpcode "je"   (cvtJmpAddr "2f")                      .
      genOpcode    "cmpq" [cvtCMemAddr "gcNewBase", vreg]        . || check if vreg is in new space
      genJmpOpcode "jb"   (cvtJmpAddr "2f")                      . || not in new space, 
      genOpcode    "movb" [X86Imm 7, addX86Offset (-1) areg]     . || mark as being added to roots list
      genWriteBarrier areg                                       .
      shows "2:\n"
      where
        (areg, mova) = ensureX86Reg x86Tmp0  a
        vreg         = cvtOpr v
        movv         = movOpForOpr v
        idx          = i * 8 + 7        || add 7 to get to the base of the array

|| general version for index known at runtime
genInsn (WriteArray a i v)
    = mova                                                       . || ensure all operands are in x86 registers for x86Idx insn
      movi                                                       .
      movv                                                       .
      genOpcode    "movq" [vreg, X86Idx areg ireg 4 7]           . || offset of 8 - 1 to subtract the tag bit
      genOpcode    "cmpb" [X86Imm 7, addX86Offset (-1) areg]     . || check if we've already added areg to the roots list
      genJmpOpcode "je"   (cvtJmpAddr "2f")                      .
      genOpcode    "cmpq" [cvtCMemAddr "gcNewBase", vreg]        . || check if vreg is in new space
      genJmpOpcode "jb"   (cvtJmpAddr "2f")                      . || not in new space, 
      genOpcode    "movb" [X86Imm 7, addX86Offset (-1) areg]     . || mark as being added to roots list
      genWriteBarrier areg                                       .
      shows "2:\n"
      where
       (areg, mova) = ensureX86Reg x86Tmp0 a
       (ireg, movi) = ensureX86Reg x86Tmp1 i
       (vreg, movv) = ensureX86Reg x86MovTmp v

|| perform a system op, putting the op# in arg0, the destination register number in arg1, and the source operand in arg2
genInsn (SystemOp n (Reg, d) s)
    = genSaveState                                      .
      genMoveToArgs [(Imm (Word n)), (Imm (Word d)), s] .
      genJmpOpcode "call" (cvtCJmpAddr "systemOp")      .
      genRestoreState

genInsn x = error ("## missing genInsn " ++ showstgInsn x ++ "\n")

|| an stg Cmp insn generates a word# value of 0 (eq), 1 (lt), or 2 (gt), depending upon the compare result
|| the CaseVec then uses the numeric value to index into eq, lt, gt codePtrs.  This is expensive to do in x86,
|| so we optimize the pair here to do an x86 cmpq, follwed by explicit je/jl/jg jump insns
genCmpCaseVec :: stgInsn -> stgInsn -> showS
genCmpCaseVec cmp (CaseVec (Ref (Reg, creg)) [cpEq, cpLt, cpGt])
    = error "mismatched cmp / caseVec registers!", if cmpRslt ~= creg
    = (shows "# Cmp / CaseVec\n"             .
      genInsn cmp                            .
      genJmpOpcode "je" (cvtJmpCodePtr cpEq) .
      genJmpOpcode "jl" (cvtJmpCodePtr cpLt) .
      genJmpOpcode "jg" (cvtJmpCodePtr cpGt)),        otherwise
      where
        (Cmp (Reg, cmpRslt) _ _) = cmp

genCmpCaseVec _ _ = undef       || added to remove compiler warning

|| if an explicit Cmp preceeds a Jeq, then we don't need to generate an implicit compare
|| (see genInsn Jeq for more details)
genCmpJeq :: stgInsn -> stgInsn -> showS
genCmpJeq cmp jmp
    = shows ("# " ++ showstgInsn cmp ++ "\n# " ++ showstgInsn jmp ++ "\n") .
      genInsn cmp . genCondJmp jmp

|| generate a codeObj
|| do checks for Cmp/CaseVec, Cmp/Jeq pairs and handle them specially
genCodeObj :: (codePtr, codeObj) -> showS
genCodeObj (cp, (locInfo, insns))
    = genLocComment locInfo          .
      genGlobal (genCodeLabel cp "") .
      go insns
      where
        isCmp     (Cmp a b c)   = True
        isCmp     x             = False
        isCaseVec (CaseVec a b) = True
        isCaseVec x             = False
        isJeq     (Jeq a b c)   = True
        isJeq     x             = False

        genInfoInsn a = shows ("# " ++  showstgInsn a ++ "\n") . genInsn a

        go []  = id
        go [a] = genInfoInsn a
        go (a : b : insns)
            = genCmpCaseVec a b . go insns,          if isCmp a & isCaseVec b
            = genCmpJeq     a b . go insns,          if isCmp a & isJeq b
            = genInfoInsn   a   . go (b : insns),    otherwise

|| heapObj layout: tagWord {codePtr, heapPtr, or string label} [env]
|| tagWord: byte 0   = heapInfo type [Hfun = 0, Hthunk = 1, Hfwd = 2, Hpap = 3, Hfbalt = 4, Hstream = 5, Harray = 6]
||                     also, used by runtime: [HarrayR = 7 (Harray in Roots List), Hreloc = 8 (used by GC to mark relocated heapObjs)
||          byte 1   = arity of fn or thunk (0), or file descriptor for Hstream used as a file buffer
||          byte 2-3 = # of env entries or Hstream buffer size (in qwords, max 8191 limited by 16-bit read/write ptr fields)
||          byte 4-5 = stream buffer write ptr / limit (length in bytes)
||          byte 6-7 = stream buffer read ptr
||          byte 4-7 = size of Array in qwords, for Array

genFunTag :: int -> int -> int
genFunTag arity envSize = envSize .<<. 16 .|. arity .<<. 8 .|. 0x00

genThunkTag :: int -> int
genThunkTag envSize = envSize .<<. 16 .|. 0x01

genFbAltTag :: int -> int
genFbAltTag envSize = (envSize + 1) .<<. 16 .|. 0x04    || add 1 to account for stack pointer slot

genHstreamTag :: int -> int -> int
genHstreamTag fd envSize = envSize .<<. 16 .|. fd .<<. 8 .|. 0x05

genPrimStringTag :: string -> int
genPrimStringTag s
    = size .<<. 32 .|. envSize .<<. 16 .|. 0x05
      where
        size    = #s
        envSize = max2 cmpint 1 $ stringWords s         || always generate at least 1 env word for forwarding

genHarrayTag :: int -> int
genHarrayTag size = size .<<. 32 .|. 0x06

genHeapObj :: (heapPtr, heapObj) -> showS
genHeapObj (hp, (hi, env))
    = genHeapLabel hp . shows ":\n" .
      genTagBody hi                 .
      foldr (.) id (map genValue env)
      where
        genTagBody (Hfun cp ar)
            = genQuad tagword           .
              genQuad (genCodeLabel cp)
              where
                tagword = showsint $ genFunTag ar (#env)

        genTagBody (Hthunk cp)
            = genQuad tagword           .
              genQuad (genCodeLabel cp) .
              genQuad (showsint 0)              || space for holding the forwarding thunk for updating
              where
                nenv    = max2 cmpint 1 (#env)  || always allocate at least 1 env word for forwarding use
                tagword = showsint $ genThunkTag nenv

        genTagBody (Hstream s)
            = genQuad tagword .
              genAscii s      .
              genPad s                                  || ensure we are on an 8-byte boundary after ascii string 
              where
                tagword = showsint $ genPrimStringTag s

        genTagBody _ = error "genTagBody: not a heap obj"

|| generate code to save Miranda register state
genSaveState :: showS
genSaveState
    = foldr (.) id (map saveArgs [0 .. 5])                    .
      foldr (.) id (map saveRegs [0 .. 5])                    .
      genOpcode "movq" [x86Frm, cvtCMemAddr "Frm"]            .
      genOpcode "movq" [x86GcAlloc, cvtCMemAddr "gcNewAlloc"] .
      genOpcode "movq" [x86SP, cvtCMemAddr "Stk"]             .
      genOpcode "subq" [X86Imm (8 * codegenMaxEnv), x86SP]    . || subtract maxEnv space for possibly saving ApplyToEnv args
      genOpcode "andq" [X86Imm (-16), x86SP]                    || and force 16-byte alignment for x86-64 calling convention
      where
        saveArgs n = genOpcode "movq" [cvtArg n, cvtArgState n]
        saveRegs n = genOpcode "movq" [cvtReg n, cvtRegState n]

|| generate code to restore Miranda state
genRestoreState :: showS
genRestoreState
    = foldr (.) id (map restoreArgs [0 .. 5])              .
      foldr (.) id (map restoreRegs [0 .. 5])              .
      genOpcode "movq" [cvtCMemAddr "Frm", x86Frm]         .
      genOpcode "movq" [cvtCMemAddr "Stk", x86SP]          .
      genOpcode "movq" [cvtCMemAddr "gcNewAlloc", x86GcAlloc]
      where
        restoreArgs n = genOpcode "movq" [cvtArgState n, cvtArg n]
        restoreRegs n = genOpcode "movq" [cvtRegState n, cvtReg n]

|| generate the GeneralApply routine, which saves the Miranda register
|| state and jumps to a C code handler
genGeneralApply :: showS
genGeneralApply
    = genGlobal "GeneralApply" .
      genSaveState             .
      genJmpOpcode "call" (cvtCJmpAddr "apply") || note: does not return, but call used to force correct stack alignment

|| generate the GC routine, which saves the Miranda register state
|| and calls a C code handler; then restores the Miranda register state and
|| returns to the gcAlloc restart point (which was pushed on the stack)
genGC :: showS
genGC
    = genGlobal "GC"                              .
      genSaveState                                .
      genJmpOpcode "call" (cvtCJmpAddr "gcMinor") .
      genRestoreState                             .
      genOpcode "ret" []

|| generate the C-callable function that returns the start closure
genGetStartClosure :: opr -> showS
genGetStartClosure ha
    = genCGlobal "GetStartClosure" .
      genMove   r0Ref ha           .
      genOpcode "ret" []

|| generate the EnterMiranda routine, which restores the Miranda register
|| state, pushes a continuation to the ioClosure routine in the runtime,
|| then enters the closure in Arg0
genEnterMiranda :: showS
genEnterMiranda
    = genCGlobal "EnterMiranda"                         .
      genRestoreState                                   .  || restore saved state, including %rsp
      genInsn (EnterInd (Ref (Arg, 0)) [])

|| generate the CallMiranda routine, which restores the Miranda register
|| state, then jumps to the codePtr in R0
genCallMiranda :: showS
genCallMiranda
    = genCGlobal "CallMiranda" .
      genRestoreState          .
      genJmpOpcode "jmp" (cvtReg 0)     || does not return

|| generate the RetMiranda routine, which restores the Miranda register
|| state, then returns to the closure on the top of the stack, passing Reg0 and Reg1
genRetMiranda :: showS
genRetMiranda
    = genCGlobal "RetMiranda"  .
      genRestoreState          .
      genInsn (Ret r0Opr r1Opr)

|| generate the C interface routines
genInterface :: opr -> showS
genInterface start
    = genSection "text"        .
      genGeneralApply          .
      genGC                    .
      genGetStartClosure start .
      genEnterMiranda          .
      genCallMiranda           .
      genRetMiranda

|| generate the expanded routines that replace generic handlers
genGenerics :: showS
genGenerics
    = genPackArgs       .
      genUnpackArgs     .
      genApplyToEnvs    .
      genOverApplyThunk .
      genRetArg         .
      genApplyArg

|| generate the code section, emitting the string for each codeObj as it is generated
genCode :: stgCode -> string
genCode cd
    = genSection "text" "" ++
      (concatMap (converse genCodeObj "\n") . m_toList . fst) cd

|| generate the heap section, emitting the string for each heapObj as it is generated
genHeap :: stgHeap -> string
genHeap hp
    = genSection "data" ""                                       ++
      genCGlobal "GlobalBase" ""                                 ++
      (concatMap (converse genHeapObj "\n") . m_toList . fst) hp ++
      genCGlobal "GlobalTop" ""

codegen :: name -> (localEnv, stgCode, stgHeap) -> string
codegen start (lenv, cd, hp)
    = genInterface ha "" ++
      genGenerics ""     ++
      genCode cd         ++
      genHeap hp
      where
        ha = fromJust (m_lookup cmpname start lenv)
