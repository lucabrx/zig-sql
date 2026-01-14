# ZigDB - A SQLite Clone in Zig

A SQL database engine built from scratch using Zig 0.15.

## Features

- Full SQL parsing (SELECT, INSERT, UPDATE, DELETE, CREATE/DROP TABLE)
- B-Tree storage engine with dynamic row format
- Type system: INTEGER, TEXT, REAL, BOOLEAN, BLOB
- Constraints: PRIMARY KEY, NOT NULL
- WHERE clause with AND/OR/comparison operators
- Secondary indexes with CREATE INDEX / DROP INDEX
- VM-based bytecode execution
- Full transaction support with ACID guarantees

## Quick Start

```bash
zig build

# In-memory database
./zig-out/bin/zig_sql :memory:

# File-based database
./zig-out/bin/zig_sql mydb.db
```

```sql
CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, email TEXT);
INSERT INTO users (id, name, email) VALUES (1, 'jimmy dzomlia', 'jimmy@example.com');
INSERT INTO users (id, name, email) VALUES (2, 'sohn of indian johns', 'sohn@example.com');
SELECT * FROM users;
DELETE FROM users WHERE id = 2;
DROP TABLE users;
```

## Transactions

Full ACID transaction support with multiple isolation levels.

```sql
BEGIN;
INSERT INTO accounts (id, balance) VALUES (1, 1000);
INSERT INTO accounts (id, balance) VALUES (2, 500);
COMMIT;

BEGIN;
UPDATE accounts SET balance = balance - 100 WHERE id = 1;
UPDATE accounts SET balance = balance + 100 WHERE id = 2;
ROLLBACK;  -- undo all changes
```

### Savepoints

```sql
BEGIN;
INSERT INTO users (id, name) VALUES (1, 'jimmy dzomlia');
SAVEPOINT sp1;
INSERT INTO users (id, name) VALUES (2, 'sohn of indian johns');
ROLLBACK TO sp1;  -- keeps jimmy, removes sohn
COMMIT;
```

### Isolation Levels

```sql
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
BEGIN;
-- transaction runs at specified isolation level
COMMIT;
```

## Indexes

```sql
CREATE INDEX idx_name ON users (name);
CREATE UNIQUE INDEX idx_email ON users (email);
DROP INDEX idx_name;
```

Indexes are automatically used for equality lookups in WHERE clauses.

## REPL Commands

```
.help       - Show available commands
.tables     - List all tables
.indexes    - List all indexes
.debug      - Toggle debug mode
.checkpoint - Force WAL checkpoint
.exit       - Exit
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
                          │
                          ▼
                    ┌─────────────┐
                    │   Storage   │
                    │  (B-Tree)   │
                    └─────────────┘
                          │
              ┌───────────┴───────────┐
              ▼                       ▼
        ┌─────────┐             ┌─────────┐
        │  Pager  │             │   WAL   │
        │ (Pages) │             │  (Log)  │
        └─────────┘             └─────────┘
```

### Transaction Implementation

Transactions use shadow paging for rollback support:

1. **BEGIN** - Marks transaction as active
2. **Page Modification** - Original page data is copied to shadow storage before any write
3. **COMMIT** - Logs commit to WAL, flushes dirty pages to disk, clears shadows
4. **ROLLBACK** - Restores original page data from shadows

### Write-Ahead Logging (WAL)

For file-based databases, WAL ensures durability:

1. All page modifications are logged to the WAL file before commit
2. COMMIT writes a commit record to WAL
3. On crash recovery, committed transactions are replayed from WAL
4. Checkpoint flushes WAL changes to main database file

## Resources

- [SQLite Architecture](https://www.sqlite.org/arch.html)
- [SQLite File Format](https://www.sqlite.org/fileformat.html)
- [Let's Build a Simple Database](https://cstack.github.io/db_tutorial/)
