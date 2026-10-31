--[[
	A Brainfuck interpreter written entirely in the type system. The program is a string literal,
	memory is a const table of numbers, and recursion is the step function.

	The two aliases worth reading are `SkipTo`, which finds the `]` matching a `[`, and
	`BrainFuck`, whose conditionals read one instruction off the front of the program.

	    lye check tools/type-brainfuck.lua
	    ROUNDS=20 lde run -C packages/lye-lsp tools/bench.lua tools/type-brainfuck.lua

	`SetTable` replaces one cell through a mapped type and `Append` grows the loop stack. Alias
	arguments are canonicalized when they are read, so a recursive step carries the current table
	instead of repeating the expression that produced it.
]]

---@alias Increment<Value> Value + 1
---@alias Decrement<Value> Value - 1

--- Copy a table, replacing the value at one position.
---@alias SetTable<Table, Value, Position> { [K in keyof Table]: K extends Position ? Value : Table[K] }

--- A table with one more cell: the memory growth and the loop stack's push.
---@alias Append<Table, Value> { ...Table, Value }

--- Walk a program to the `]` matching the `[` just consumed. `Depth` counts nested loops.
---@alias SkipTo<Program, Depth = 0> Program extends "" ? "" : Program extends `[${infer Rest}` ? SkipTo<Rest, Depth + 1> : Program extends `]${infer Rest}` ? Depth extends 0 ? Rest : SkipTo<Rest, Depth - 1> : Program extends `${infer _}${infer Rest}` ? SkipTo<Rest, Depth> : ""

---@alias BrainFuck<Program, Memory = { 0, 0, 0 }, Input = 0, Pointer = 1, Output = "", Loops = {}, Depth = 0> Program extends "" ? Output : Program extends `>${infer Tail}` ? BrainFuck<Tail, Append<Memory, 0>, Input, Pointer + 1, Output, Loops, Depth> : Program extends `<${infer Tail}` ? BrainFuck<Tail, Memory, Input, Pointer - 1, Output, Loops, Depth> : Program extends `+${infer Tail}` ? BrainFuck<Tail, SetTable<Memory, Increment<Memory[Pointer]>, Pointer>, Input, Pointer, Output, Loops, Depth> : Program extends `-${infer Tail}` ? BrainFuck<Tail, SetTable<Memory, Decrement<Memory[Pointer]>, Pointer>, Input, Pointer, Output, Loops, Depth> : Program extends `.${infer Tail}` ? BrainFuck<Tail, Memory, Input, Pointer, `${Output}${Memory[Pointer]}`, Loops, Depth> : Program extends `,${infer Tail}` ? BrainFuck<Tail, SetTable<Memory, Input, Pointer>, Input, Pointer, Output, Loops, Depth> : Program extends `[${infer Tail}` ? Memory[Pointer] extends 0 ? BrainFuck<SkipTo<Tail>, Memory, Input, Pointer, Output, Loops, Depth> : BrainFuck<Tail, Memory, Input, Pointer, Output, Append<Loops, Tail>, Depth + 1> : Program extends `]${infer Tail}` ? Memory[Pointer] extends 0 ? BrainFuck<Tail, Memory, Input, Pointer, Output, Loops, Depth - 1> : BrainFuck<Loops[Depth], Memory, Input, Pointer, Output, Loops, Depth> : ""

---@type BrainFuck<"+++.>++.>++-.">
local linear
---@type "321"
local linearCheck = linear

---@type BrainFuck<"+++[>++<-]>.">
local loop
---@type "6"
local loopCheck = loop

return linearCheck, loopCheck
