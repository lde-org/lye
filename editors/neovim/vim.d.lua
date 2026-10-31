---@meta
-- The parts of Neovim's own `vim` API the editor wrapper reads. Kept as a definition file so
-- `lye check` gives the wrapper the same environment Neovim injects at runtime.

---@class VimHealth
---@field start fun(name: string)
---@field ok fun(message: string, advice?: string[])
---@field info fun(message: string)
---@field warn fun(message: string, advice?: string[])
---@field error fun(message: string, advice?: string[])

---@class VimFn
---@field exepath fun(name: string): string
---@field executable fun(name: string): integer
---@field system fun(command: string|(string|number)[], ...: any): string
---@field getcwd fun(): string
---@field mkdir fun(path: string, flags?: string)
---@field tempname fun(): string
---@field fnamemodify fun(path: string, modifiers: string): string
---@field fnameescape fun(path: string): string
---@field expand fun(text: string): string
---@field delete fun(path: string, flags?: string): integer
---@field writefile fun(lines: string[], path: string): integer

---@class VimSystemResult
---@field code integer
---@field signal integer
---@field stdout string?
---@field stderr string?

---@class VimSystem
---@field wait fun(self: VimSystem): VimSystemResult

---@class VimFiletype
---@field add fun(mapping: table): nil

---@class VimLspConfig
---@field cmd string[]|fun(...: any) a command line, or a function for a custom transport
---@field filetypes string[]?
---@field root_markers (string|string[])[]?
---@field root_dir string|fun(...: any): string?
---@field [string] any any other field of a `vim.lsp.Config`: `on_attach`, `capabilities`, and the rest.

-- `vim.lsp.config` is both a table — `vim.lsp.config["lye"]` reads a config — and a function:
-- `vim.lsp.config("lye", {...})` writes one.
---@class VimSystemResult
---@field code integer
---@field signal integer
---@field stdout string?
---@field stderr string?

---@class VimSystem
---@field wait fun(self: VimSystem): VimSystemResult

---@class VimFiletype
---@field add fun(mapping: table): nil

---@class VimLspConfigMap
---@field [string] VimLspConfig?
---@field __call fun(self: VimLspConfigMap, name: string, config?: table): VimLspConfig?

---@class VimSystemResult
---@field code integer
---@field signal integer
---@field stdout string?
---@field stderr string?

---@class VimSystem
---@field wait fun(self: VimSystem): VimSystemResult

---@class VimFiletype
---@field add fun(mapping: table): nil

---@class VimLspClient
---@field id integer
---@field name string
---@field root_dir string?
---@field stop fun(self: VimLspClient)

---@class VimSystemResult
---@field code integer
---@field signal integer
---@field stdout string?
---@field stderr string?

---@class VimSystem
---@field wait fun(self: VimSystem): VimSystemResult

---@class VimFiletype
---@field add fun(mapping: table): nil

---@class VimLspResponse
---@field result table<string, any>?
---@field err table<string, any>?

---@class VimSemanticToken
---@field type string
---@field modifiers string[]

---@class VimSemanticTokens
---@field get_at_pos fun(bufnr: integer, row: integer, col: integer): VimSemanticToken[]?

---@class VimDiagnostic
---@field message string
---@field lnum integer
---@field col integer
---@field severity integer

---@class VimDiagnosticNamespace
---@field get fun(bufnr?: integer): VimDiagnostic[]

---@class VimSystemResult
---@field code integer
---@field signal integer
---@field stdout string?
---@field stderr string?

---@class VimSystem
---@field wait fun(self: VimSystem): VimSystemResult

---@class VimFiletype
---@field add fun(mapping: table): nil

---@class VimLsp
---@field config VimLspConfigMap
---@field enable fun(name: string, enable?: boolean?)
---@field is_enabled fun(name: string): boolean
---@field get_clients fun(filter?: table): VimLspClient[]
---@field get_client_by_id fun(id: integer): VimLspClient?
---@field buf_request_sync fun(bufnr: integer, method: string, params?: table, timeout?: integer): table<integer, VimLspResponse>?
---@field buf table
---@field semantic_tokens VimSemanticTokens
---@field codelens table
---@field inlay_hint table

---@class VimOptValue
---@field append fun(value: string)
---@field prepend fun(value: string)

---@class VimOpt
---@field runtimepath VimOptValue

---@class Vim
---@field health VimHealth
---@field fn VimFn
---@field lsp VimLsp
---@field filetype VimFiletype
---@field system fun(command: (string|number)[], opts?: table): VimSystem
---@field api table<string, fun(...: any): any>
---@field opt VimOpt
---@field bo table<string, string>
---@field v table<string, integer>
---@field diagnostic VimDiagnosticNamespace
---@field cmd fun(command: string)
---@field trim fun(text: string): string
---@field tbl_contains fun(list: any[], value: any): boolean
---@field inspect fun(value: any): string
---@field deepcopy fun<T>(value: T): T
---@field deep_equal fun(a: any, b: any): boolean
---@field wait fun(timeout: integer, condition: fun(): boolean, interval?: integer): boolean
---@field uri_from_bufnr fun(bufnr: integer): string

vim = {}
---@cast vim Vim
