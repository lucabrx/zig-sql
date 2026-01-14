pub const CompilerError = error{
    NotImplemented,
    TableNotFound,
    ColumnNotFound,
    OutOfMemory,
    ViewNotSupported,
    InvalidSyntax,
};
