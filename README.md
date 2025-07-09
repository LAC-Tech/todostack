TDS ("TODO Stack") models todo items as a FIFO stack.

It uses a memory mapped file of max 64 stack items, up to max 64 bytes long. The file is all zeroed out apart from the TODO items, so should be diffable in version control.

It operates as a TUI program.

## Requirements

A terminal that recognises ECMA-48 / ANSI control codes.

I've only tested this on linux 64 bit. I use POSIX functions exclusively, so I hope it works on other Unix-like systems.

I don't personally care about windows but pull requests welcome.

## Building

You'll need Zig 0.14.1 or later to build.

`zig build -Doptimize=ReleaseFast`

## Running

To create a new todo stack file:
```
tds -n <name>
```

To open an existing one:
```
tds -n <name>.tds.bin
```

## Usage

- `p`: Push an item onto the stack. Press enter when you're done writing. To cancel, push an empty value onto the stack (no-op).
- `d`: Drop the top item from the stack.
- `s`: Swap the top two items on the stack (requires at least 2 items).
- `q`: Quit the program
