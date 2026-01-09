# ZigDB - A SQLite Clone in Zig

A SQL database engine built from scratch using Zig 0.15.

## Architecture

```
SQL String → Lexer → Parser → Compiler → VM → Storage → Results
```

### Execution Pipeline

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Lexer     │────▶│   Parser    │────▶│  Compiler   │
│  (Tokens)   │     │   (AST)     │     │ (Bytecode)  │
└─────────────┘     └─────────────┘     └─────────────┘
                                              │
                                              ▼
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Results   │◀────│     VM      │◀────│  Bytecode   │
│             │     │ (Executor)  │     │ Instructions│
└─────────────┘     └─────────────┘     └─────────────┘
```

## Project Structure

```
src/
├── lexer/          # SQL tokenizer
│   ├── lexer.zig
│   └── token.zig
├── parser/         # SQL parser → AST
│   ├── parser.zig
│   ├── ast.zig
│   ├── expressions.zig
│   ├── select.zig
│   ├── insert.zig
│   └── ...
├── compiler/       # AST → VM bytecode
│   ├── compiler.zig
│   ├── select.zig
│   ├── insert.zig
│   ├── delete.zig
│   ├── update.zig
│   ├── schema.zig
│   └── expression.zig
├── vm/             # Bytecode executor
│   ├── vm.zig
│   └── opcode.zig
├── storage/        # B-Tree storage engine
│   ├── btree.zig
│   ├── cursor.zig
│   ├── pager.zig
│   ├── table.zig
│   ├── row.zig
│   └── node.zig
├── repl.zig        # Interactive shell
└── main.zig
```

## Compiler Design

The compiler converts AST statements to VM bytecode. Each statement type has its own handler:

```zig
switch (stmt) {
    .select_stmt => |s| try select.compile_select(self, s),
    .insert_stmt => |s| try insert.compile_insert(self, s),
    .create_table_stmt => |s| try schema.compile_create_table(self, s),
    .delete_stmt => |s| try delete.compile_delete(self, s),
    .update_stmt => |s| try update.compile_update(self, s),
    .drop_table_stmt => |s| try schema.compile_drop_table(self, s),
}
```

### VM Opcodes

| Opcode            | Description        |
| ----------------- | ------------------ |
| `INIT`            | Initialize VM      |
| `HALT`            | Stop execution     |
| `OPEN_READ/WRITE` | Open table cursor  |
| `REWIND`          | Move to first row  |
| `NEXT`            | Move to next row   |
| `COLUMN`          | Read column value  |
| `RESULT_ROW`      | Output result      |
| `INSERT`          | Insert row         |
| `DELETE`          | Delete current row |
| `EQ/NE/LT/GT`     | Comparisons        |

### Example: SELECT Compilation

```sql
SELECT id, name FROM users WHERE id = 1
```

Compiles to:

```
INIT
OPEN_READ    cursor=0, table="users"
REWIND       cursor=0, jump_if_empty=9
COLUMN       cursor=0, col=0 → r0
INTEGER      r1 = 1
EQ           r0, r1 → r2
IF_ZERO      r2, jump=8
COLUMN       cursor=0, col=0 → r3
COLUMN       cursor=0, col=1 → r4
RESULT_ROW   r3, 2 cols
NEXT         cursor=0, jump=3
CLOSE        cursor=0
HALT
```

## Building & Running

```bash
zig build          # Build
zig build run      # Run REPL
zig build test     # Run tests
```

## Resources

- [SQLite Architecture](https://www.sqlite.org/arch.html)
- [SQLite File Format](https://www.sqlite.org/fileformat.html)
- [Let's Build a Simple Database](https://cstack.github.io/db_tutorial/)
