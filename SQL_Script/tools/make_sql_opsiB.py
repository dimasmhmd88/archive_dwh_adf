"""
Builds SQL_Script/deploy/20_OpsiB_DB_Objects.sql (SQL v0.7.1-opsiB) from
  - SQL_Script/deploy/04_procedures.sql (SQL v0.6, unchanged source)
  - SQL_Script/src/<proc>_opsiB.sql (opsi B source of one v0.6 procedure, used instead of 04 when present;
    v0.7.1: usp_BatchDelete_opsiB.sql - ChildDeleteMode KEY_TABLE, D-8)
  - SQL_Script/src/opsiB_new_objects.sql (hand-written new objects)

Change applied to the v0.6 procedures listed in TARGETS (nothing else is changed):
every result-set SELECT that ADF reads is rewritten as

    IF OBJECT_ID(N'tempdb..#RetOut_<proc>') IS NULL
        <original SELECT>;            -- called by ADF / by a person: result set as in v0.6
    ELSE
        INSERT INTO #RetOut_<proc>
        <original SELECT>;            -- called by an opsi B wrapper: result kept in the caller's temp table

so that the opsi B wrapper procedures can call several procedures in one ADF Lookup without
INSERT ... EXEC (which would run the called procedure inside one transaction: unacceptable for the
per-batch commits of usp_BatchDelete and for the TRY/CATCH blocks of usp_BeginTable).
Without the temp table the behaviour is identical to v0.6, so the existing ADF packages keep working.

Usage: python3 make_sql_opsiB.py <repo root>
"""
import os, re, sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
SRC = os.path.join(ROOT, "SQL_Script", "deploy", "04_procedures.sql")
NEW = os.path.join(ROOT, "SQL_Script", "src", "opsiB_new_objects.sql")
OUT = os.path.join(ROOT, "SQL_Script", "deploy", "20_OpsiB_DB_Objects.sql")

# procedure -> text that starts each result statement (checked), in source order
TARGETS = {
    "usp_StartRun": ["SELECT r.RunId, r.ProcessType", "SELECT @RunId AS RunId"],
    "usp_GetTablesToProcess": ["SELECT c.TableConfigId, c.SchemaName, c.TableName, c.RetentionColumn, c.ParentTableConfigId,"],
    "usp_BeginTable": ["SELECT l.TableLogId, 'SKIPPED' AS BeginResult"] +
                      ["SELECT @TableLogId AS TableLogId, "] * 6,
    "usp_IdentifyEligibleData": ["SELECT @TableLogId AS TableLogId, "] * 4,
    "usp_ValidateArchive": ["SELECT 'PASSED' AS ValidationResult", "SELECT 'FAILED' AS ValidationResult",
                            "SELECT 'NOT_REQUIRED' AS ValidationResult", "SELECT 'PASSED' AS ValidationResult",
                            "SELECT 'FAILED' AS ValidationResult"],
    "usp_BatchDelete": ["SELECT @Result AS DeleteResult"],
    "usp_PostCheck": ["SELECT 'FAILED' AS PostCheckResult", "SELECT CASE WHEN @Pass = 1",
                      "SELECT 'FAILED' AS PostCheckResult"],
    "usp_GetExpiredArchiveFolders": ["SELECT CAST(NULL AS NVARCHAR(400)) AS ItemName", "SELECT i.ItemName,"],
    "usp_EndRun": ["SELECT RunId, ProcessType, CONVERT(CHAR(10), RunDate, 23) AS RunDate, Status, TablesSelected"],
}

SRC_LINES = open(SRC, encoding="utf-8").read().split("\n")
OVERRIDE_DIR = os.path.join(ROOT, "SQL_Script", "src")
lines = SRC_LINES

def source_lines(name):
    """opsi B override of a v0.6 procedure (src/<name>_opsiB.sql) or the v0.6 source"""
    ov = os.path.join(OVERRIDE_DIR, f"{name}_opsiB.sql")
    return (open(ov, encoding="utf-8").read().split("\n"), True) if os.path.exists(ov) else (SRC_LINES, False)

def proc_bounds(name):
    s = next(i for i, l in enumerate(lines) if re.match(r"CREATE OR ALTER PROCEDURE ret\." + name + r"\b", l))
    e = next(i for i in range(s, len(lines)) if lines[i].startswith("GO"))
    return s, s, e

def scan_state(block):
    """yield (index, at_line_start_is_code) for each line of block; tracks strings and comments"""
    instr = inblk = False
    out = []
    for line in block:
        out.append(not instr and not inblk)
        j = 0
        while j < len(line):
            two = line[j:j + 2]
            if inblk:
                if two == "*/": inblk = False; j += 2; continue
            elif instr:
                if line[j] == "'":
                    if two == "''": j += 2; continue
                    instr = False
            else:
                if two == "--": break
                if two == "/*": inblk = True; j += 2; continue
                if line[j] == "'": instr = True
            j += 1
    return out

def stmt_end(block, start):
    """index of the line holding the terminating ';' of the statement starting at block[start]"""
    instr = inblk = False
    depth = 0
    for i in range(start, len(block)):
        line = block[i]
        j = 0
        while j < len(line):
            two = line[j:j + 2]
            if inblk:
                if two == "*/": inblk = False; j += 2; continue
            elif instr:
                if line[j] == "'":
                    if two == "''": j += 2; continue
                    instr = False
            else:
                if two == "--": break
                if two == "/*": inblk = True; j += 2; continue
                c = line[j]
                if c == "'": instr = True
                elif c == "(": depth += 1
                elif c == ")": depth -= 1
                elif c == ";" and depth == 0:
                    if line[j + 1:].strip() and not line[j + 1:].strip().startswith("--"):
                        raise SystemExit(f"code after ';' on line: {line}")
                    return i
            j += 1
    raise SystemExit("statement end not found")

def transform(name, expected):
    global lines
    lines, overridden = source_lines(name)
    c, s, e = proc_bounds(name)
    if overridden:
        # keep the leading comment block of the override file's procedure (starts at the "/* " line before CREATE)
        c = max(i for i in range(0, s + 1) if lines[i].startswith("/* "))
    block = lines[c:e + 1]
    code_start = scan_state(block)
    def prev_code(i):
        k = i - 1
        while k >= 0 and not block[k].strip(): k -= 1
        return block[k] if k >= 0 else ""
    cand = [i for i, l in enumerate(block)
            if code_start[i] and re.match(r"\s*SELECT\b", l)
            and not re.match(r"\s*SELECT\s+(TOP\s*\(\s*\d+\s*\)\s*)?@\w+\s*(=|\+=)", l)
            and "INSERT INTO" not in prev_code(i) and not prev_code(i).rstrip().endswith(")")]
    # keep only the expected result statements
    found = [i for i in cand if any(block[i].strip().startswith(x) for x in set(expected))]
    if len(found) != len(expected):
        raise SystemExit(f"{name}: expected {len(expected)} result SELECTs, found {len(found)}: "
                         + "; ".join(block[i].strip()[:60] for i in found))
    for i, x in zip(found, expected):
        if not block[i].strip().startswith(x): raise SystemExit(f"{name}: unexpected statement order at {block[i]}")
    tmp = f"#RetOut_{name}"
    out, k = [], 0
    for i in found:
        j = stmt_end(block, i)
        stmt = block[i:j + 1]
        ind = re.match(r"\s*", stmt[0]).group(0)
        out += block[k:i]
        out.append(f"{ind}IF OBJECT_ID(N'tempdb..{tmp}') IS NULL")
        out += ["    " + l if l.strip() else l for l in stmt]
        out.append(f"{ind}ELSE")
        out.append(f"{ind}    INSERT INTO {tmp}")
        out += ["    " + l if l.strip() else l for l in stmt]
        k = j + 1
    out += block[k:]
    return "\n".join(out), len(found), overridden

HEADER = """/* =====================================================================================
   DWH Data Retention and Archiving - schema ret - OPSI B objects (SQL v0.7.1-opsiB)
   -------------------------------------------------------------------------------------
   Script        : SQL_Script/deploy/20_OpsiB_DB_Objects.sql
   Version       : 0.7.1-opsiB (DRAFT - not reviewed, not executed against any database)
   Date          : 27 November 2026
   History       : 0.7-opsiB    17 Nov 2026  initial opsi B objects
                   0.7.1-opsiB  27 Nov 2026  D-8: RetentionParameter.ChildDeleteMode (JOIN / KEY_TABLE);
                                             usp_BatchDelete deletes child rows through a header-key temp table
   Generated by  : SQL_Script/tools/make_sql_opsiB.py (do not edit the procedures of section B by hand;
                   change the generator or the v0.6 source and generate again)
   Requires      : SQL v0.6 deployed (SQL_Script/deploy/01..05; verify/90_verify_v06_deployment.sql all OK)
   Used by       : ADF package pipeline_opsi_B (option B: parallel export per chunk, merged Lookups)
   Compatibility : the existing ADF packages pipeline-agus / pipeline (v0.3) keep working unchanged:
                   section B only adds an alternative output target used when the caller created
                   #RetOut_<procedure>; without it every procedure returns exactly the v0.6 result set.

   CONTENT
     A. Columns ExportParallelism (ret.RetentionParameter, ret.RetentionConfig) and
        ChildDeleteMode (ret.RetentionParameter, default JOIN)
     B. v0.6 procedures with the #RetOut_<procedure> output option (generated):
        %s
        (usp_BatchDelete from SQL_Script/src/usp_BatchDelete_opsiB.sql: ChildDeleteMode)
     C. New procedures (hand-written, SQL_Script/src/opsiB_new_objects.sql):
        usp_StartRunAndGetTables, usp_BeginTableAndIdentify, usp_GetExportChunk,
        usp_ValidateDeleteAndCheck, usp_GetCleanupDecision, usp_GetExpiredArchiveItems

   Run the whole file in one session, connected to the DWH database. Re-runnable.
   ===================================================================================== */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO
"""

def main():
    new_objects = open(NEW, encoding="utf-8").read()
    schema_part, procs_part = new_objects.split("-- @@PROCEDURES@@\n", 1)
    parts = [HEADER % ", ".join(TARGETS), schema_part.rstrip() + "\n",
             "/* =====================================================================================\n"
             "   B. v0.6 PROCEDURES WITH THE #RetOut_<procedure> OUTPUT OPTION (generated from SQL v0.6)\n"
             "   ===================================================================================== */\n"]
    total = 0
    for name, exp in TARGETS.items():
        txt, n, ov = transform(name, exp)
        total += n
        src = f"SQL_Script/src/{name}_opsiB.sql" if ov else "SQL_Script/deploy/04_procedures.sql"
        parts.append(f"-- opsi B: {n} result statement(s) of ret.{name} can write to #RetOut_{name} (source: {src})\n{txt}\n")
    parts.append(procs_part)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(parts))
    print(f"written {OUT}: {len(TARGETS)} procedures, {total} result statements")

if __name__ == "__main__":
    main()
