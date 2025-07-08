TDS ("TODO Stack") models todo items as a FIFO stack.

It uses a memory mapped file of max 64 stack items, up to max 64 bytes long. The file is all zeroed out apart from the TODO items, so should be diffable in version control.

The program operates as a REPL.

## Requirements

No dependencies.

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

## REPL Commands

In the REPL use the following commands:

- `"text"`: Push a string (e.g., "buy milk") onto the stack. Must be enclosed in double quotes. Max length: 64 bytes.

- `d`: Drop the top item from the stack.

- `s`: Swap the top two items on the stack (requires at least 2 items).

- `.`: Print all items on the stack, from bottom to top.

- `q`: Quit the program
