# ZigDB - A SQLite Clone in Zig

A SQL database engine built from scratch using Zig 0.15.

## Features

- Full SQL parsing (SELECT, INSERT, UPDATE, DELETE, CREATE/DROP TABLE)
- B-Tree storage engine with dynamic row format
- Type system: INTEGER, TEXT, REAL, BOOLEAN, BLOB
- Constraints: PRIMARY KEY, NOT NULL
- WHERE clause with AND/OR/comparison operators
- VM-based bytecode execution

## Quick Start

```bash
zig build

# In-memory database (default)
./zig-out/bin/zig_sql

# File-based database
./zig-out/bin/zig_sql mydb.db
```

```sql
CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT, balance REAL, active BOOLEAN);
INSERT INTO users (id, name, email, balance, active) VALUES (1, 'luka', 'luka@proton.me', 100.50, TRUE);
INSERT INTO users (id, name, email, balance, active) VALUES (2, 'mile', 'mile@skiff.rip', 250.75, FALSE);
INSERT INTO users (id, name, balance) VALUES (3, 'skrr', 0.0);
SELECT * FROM users;
SELECT id, name, balance FROM users;
DELETE FROM users WHERE id = 3;
DROP TABLE users;
```

## Architecture

```
SQL String → Lexer → Parser → Compiler → VM → Storage → Results
```

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

- **Lexer**: Tokenizes SQL strings into meaningful tokens
- **Parser**: Converts tokens into Abstract Syntax Trees (AST)
- **Compiler**: Translates AST into VM bytecode instructions
- **VM**: Executes bytecode against the storage engine
- **Storage**: Manages B-Tree data structures on disk

## Resources

- [SQLite Architecture](https://www.sqlite.org/arch.html)
- [SQLite File Format](https://www.sqlite.org/fileformat.html)
- [Let's Build a Simple Database](https://cstack.github.io/db_tutorial/)
