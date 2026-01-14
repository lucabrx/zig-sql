const std = @import("std");

pub const VmErrors = error{
    Halted,
    InvalidOp,
    RegisterOOB,
    NoCursor,
    NoTable,
    NullConstraintViolation,
    TypeMismatch,
};
