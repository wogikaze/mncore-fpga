"""mnisa: MN-Core 2 flat instruction words (j 426 bit / m 82 bit) <-> named fields.

The field definitions live in mncore/spec/isa/{j_flat,m}.yaml. Typical use (with mncore/tools on sys.path):

    from mnisa import decode, encode, read_asm
    for ln in read_asm("prog.asm"):
        if ln.kind in ("j", "m"):
            f = decode(ln.bits)          # {'ll': 1, 'pe_mrc_imr': 0, ...}
            assert encode(f, ln.kind) == ln.bits
"""
from .asm_io import AsmLine, format_asm, parse_asm, read_asm, write_asm
from .codec import (cycle_addrs, decode, decode_bits, encode, from_int, imm_insert, imm_payload, imm_replicas_ok,
                    is_imm, nonzero, to_int)
from .csv_import import CsvFile, CsvRow, parse_csv, read_csv, to_fields
from .schema import Field, Schema, load as load_schema

__all__ = [
    "AsmLine", "CsvFile", "CsvRow", "Field", "Schema", "cycle_addrs", "decode", "decode_bits", "encode", "format_asm",
    "from_int", "imm_insert", "imm_payload", "imm_replicas_ok", "is_imm", "load_schema", "nonzero", "parse_asm",
    "parse_csv", "read_asm", "read_csv", "to_fields", "to_int", "write_asm",
]
