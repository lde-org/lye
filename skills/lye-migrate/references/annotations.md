# Type upgrade reference

Use these when the code already guarantees the shape. Do not invent a type to silence a diagnostic.

## Classes and fields

```lua
---@class lupa.Mesh
---@field vertices ffi.array<ffi.float>
---@field indices ffi.array<ffi.int>
---@field stride number
---@field vertexCount number
---@field indexCount number
---@field private changed boolean?
```

Fields marked `private` or `protected` are checked against the method's class. A class declared
`---@class lupa.Assets` can be written on `local Assets = {}`; `function Assets:image()` is still a
method of `lupa.Assets`.

## Literal and union types

```lua
---@alias Mode "idle" | "run" | "paused"
---@alias LightKind 0 | 1

---@param mode Mode
---@return boolean
local function isRunning(mode)
	return mode == "run"
end
```

A literal union narrows on comparison. Prefer it to `string` when the set is closed.

## Generics

```lua
---@class Box<T>
---@field value T

---@generic T
---@param item T
---@return T
local function id(item)
	return item
end
```

Constrain a generic when the body requires it:

```lua
---@generic T: table
---@param value T
---@return T
```

Variadic generics:

```lua
---@generic T...
---@param ... T
---@return T...
local function pack(...)
	return ...
end
```

## Const generics

A const generic binds a literal value and can be folded:

```lua
---@class Vec<T: number, const N: integer>
---@field values ffi.array<T, N>
```

```lua
---@type fn<const A: string, const B: string>(a: A, b: B) -> A .. B
```

An operation between const arguments folds to the literal result: `concat("bar", "baz")` returns
`"barbaz"`, not `string`.

Use const generics for fixed C dimensions, protocol tags, and type-level string processing.

## Overloads

```lua
---@overload fun(path: string): lupa.Mesh
---@overload fun(path: string, options: lupa.ObjOptions): lupa.Mesh
---@param path string
---@return lupa.Mesh
function Assets:obj(path)
```

The call site is narrowed to the overload whose parameters fit.

## Narrowing

Prefer control flow to a cast:

```lua
---@param cache lupa.Texture?
local function use(cache)
	if not cache then
		return
	end
	return cache.width -- cache is lupa.Texture here
end
```

```lua
---@param value string|number
local function format(value)
	if type(value) == "string" then
		return value:upper()
	end
	return tostring(value)
end
```

A discriminated union:

```lua
---@class Circle
---@field kind "circle"
---@field radius number

---@class Rect
---@field kind "rect"
---@field width number
---@field height number

---@alias Shape Circle | Rect

---@param shape Shape
local function area(shape)
	if shape.kind == "circle" then
		return math.pi * shape.radius ^ 2
	end
	return shape.width * shape.height
end
```

## Casts and assertions

Use `assert` when the runtime check is the invariant:

```lua
local texture = assert(self.captureTexture)
texture:destroy()
```

Use `---@cast` only where the runtime already guarantees the type and the checker cannot see it:

```lua
local node = assert(nodeOrNil)
---@cast node lupa.Mesh
```

A cast that is not backed by a runtime check is a lie the checker will trust.

## Type-level forms

Use these only for stable, genuinely type-level relationships:

```lua
---@alias Keys<T> keyof T
---@alias ValueOf<T, K> T[K]
```

```lua
---@alias Set<T, V, P> { [K in keyof T]: K extends P ? V : T[K] }
```

Template literal types work too:

```lua
---@alias EventName `on${string}`
```

Do not encode ordinary runtime branching as a conditional type. Keep the type understandable to a
reader who is not an expert in the type system.

## Diagnostic directives

lye reads LuaLS diagnostic codes as aliases:

```lua
---@diagnostic disable-next-line: assign-type-mismatch, type
```

Use the narrowest code and line. A directive with no code disables every finding on the line or in
the range; avoid it unless the line is genuinely uncheckable.

## Return annotations

Drop `---@return` when the body already infers it and the hint says so. Keep the block form when the
signature is long, has optional results, or has several values.
