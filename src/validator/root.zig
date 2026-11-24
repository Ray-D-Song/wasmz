/// WebAssembly specification validator.
///
/// Public entry point for validating modules during compilation.
pub const subtyping = @import("subtyping.zig");
pub const func_validator = @import("func_validator.zig");
pub const module_validator = @import("module_validator.zig");

pub const ValidationError = subtyping.ValidationError;
pub const ValidateFuncError = func_validator.ValidateFuncError;
pub const ValidateModuleError = module_validator.ValidateModuleError;

pub const TypeContext = subtyping.TypeContext;
pub const RecGroupRange = subtyping.RecGroupRange;
pub const GlobalTypeInfo = func_validator.GlobalTypeInfo;
pub const ValidatorEHMode = func_validator.ValidatorEHMode;
pub const TableDefInfo = module_validator.TableDefInfo;
pub const MemoryDefInfo = module_validator.MemoryDefInfo;
pub const LocalGlobalInfo = module_validator.LocalGlobalInfo;
pub const ExportCheckInfo = module_validator.ExportCheckInfo;
pub const ElemSegmentInfo = module_validator.ElemSegmentInfo;
pub const DataSegmentInfo = module_validator.DataSegmentInfo;
pub const ModuleValidationInput = module_validator.ModuleValidationInput;

pub const validateModule = module_validator.validateModule;
