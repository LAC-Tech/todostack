# TDS (TODO Stack) - Agent Guidelines

## Build Commands
- Build: `zig build -Doptimize=ReleaseFast`
- Run: `zig build run -- <args>`
- Requires Zig 0.15.1 or later
- No lint command configured
- No test framework; no tests present

## Code Style Guidelines

### Imports
- Use `const std = @import("std");` first
- Import specific std modules: `const debug = std.debug;`
- Local imports: `const term = @import("./term.zig");`

### Formatting & Structure
- 4-space indentation
- PascalCase for structs/types, snake_case for variables/functions
- Use `const` for immutable values and compile-time constants
- Fixed-size arrays preferred: `[64]u8` over `[]u8`

### Types & Error Handling
- Explicit types required
- Error unions: `!void` for functions that can fail
- Use `try` for error propagation, `catch` for handling
- Custom errors: `error.StackOverflow`, `error.Underflow`

### Naming Conventions
- Structs: `App`, `Stack`, `Items`
- Functions: `init`, `deinit`, `mainLoop`, `push`, `drop`
- Constants: `max_stack_len`, `max_item_len`
- Variables: `filename_buf`, `input_buf`

### Memory & Safety
- Use `@memset` for buffer clearing
- `@memcpy` for safe copying
- `defer` for cleanup (file handles, terminal state)
- `unreachable` for impossible error paths

### Comments
- Minimal comments; code should be self-documenting
- Only comment complex logic or TODO items