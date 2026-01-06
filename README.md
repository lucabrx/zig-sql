# ZigDB - A SQLite Clone in Zig

A learning project to build a fully functional SQL database engine from scratch using Zig 0.16.

## Why Build a Database?

Building a database teaches you:
- **Lexing & Parsing** - How SQL text becomes executable commands
- **Data Structures** - B-Trees, hash tables, page management
- **File I/O** - Persistent storage, memory-mapped files
- **Query Processing** - How SELECT, JOIN, WHERE actually work
- **Concurrency** - Transactions, locking, ACID properties

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                      SQL Interface                          │
│                   (User Input/REPL)                         │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                      SQL Compiler                           │
│  ┌─────────┐    ┌─────────┐    ┌─────────────────────────┐  │
│  │  Lexer  │───▶│ Parser  │───▶│ Query Planner/Optimizer │  │
│  │(Tokenizer)   │  (AST)  │    │   (Execution Plan)      │  │
│  └─────────┘    └─────────┘    └─────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                   Virtual Machine                           │
│            (Bytecode Interpreter/Executor)                  │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                    Storage Engine                           │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────┐  │
│  │ B-Tree      │    │   Pager     │    │  Record Format  │  │
│  │ (Indexes)   │    │ (Page Cache)│    │  (Serialization)│  │
│  └─────────────┘    └─────────────┘    └─────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                     OS Interface                            │
│              (File I/O, Memory Management)                  │
└─────────────────────────────────────────────────────────────┘
```

## Core Concepts

### 1. Tokenizer (Lexer)
Breaks SQL text into tokens:
```
"SELECT * FROM users WHERE id = 5"
    ↓
[SELECT] [STAR] [FROM] [IDENT:users] [WHERE] [IDENT:id] [EQUALS] [NUMBER:5]
```

### 2. Parser
Converts tokens into an Abstract Syntax Tree (AST):
```
SelectStatement {
    columns: [Star],
    table: "users",
    where: BinaryExpr {
        left: Column("id"),
        op: Equals,
        right: Literal(5)
    }
}
```

### 3. Query Planner
Decides HOW to execute the query:
- Full table scan vs index lookup
- Join order optimization
- Predicate pushdown

### 4. Virtual Machine
Executes the query plan step by step:
- Open table cursor
- Seek to matching rows
- Filter by WHERE clause
- Return results

### 5. B-Tree Storage
SQLite uses B+ Trees for both:
- **Table storage** (clustered by rowid)
- **Index storage** (secondary indexes)

```
                    [50]
                   /    \
            [20,30]      [70,80]
           /   |   \    /   |   \
        [10] [25] [35] [60] [75] [90]  ← Leaf nodes contain actual data
```

### 6. Page-Based Storage
Data is stored in fixed-size pages (typically 4KB):
- Page 0: Database header
- Page 1+: B-Tree pages (internal or leaf)
- Each page has a header + cells

## File Format

```
┌────────────────────────────────────────┐
│           Database Header (100 bytes)   │
│  - Magic number                         │
│  - Page size                            │
│  - File format version                  │
│  - Schema version                       │
└────────────────────────────────────────┘
┌────────────────────────────────────────┐
│              Page 1                     │
│  - Page header                          │
│  - Cell pointers                        │
│  - Free space                           │
│  - Cells (records)                      │
└────────────────────────────────────────┘
│                ...                      │
└────────────────────────────────────────┘
```



## Building & Running

```bash
# Build
zig build

# Run REPL
zig build run

# Run tests
zig build test
```

## Resources

- [SQLite Architecture](https://www.sqlite.org/arch.html)
- [SQLite File Format](https://www.sqlite.org/fileformat.html)
- [Let's Build a Simple Database](https://cstack.github.io/db_tutorial/)
- [Zig Documentation](https://ziglang.org/documentation/master/)
