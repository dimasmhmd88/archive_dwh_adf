"""
Builds SQL_Script/DWH_Retention_FULL_v0.7.1.sql: every object script of schema ret in deployment order,
in one file, for a NEW database or a complete redeploy:

    deploy/01_schema_tables.sql      tables + migration blocks
    deploy/02_triggers_seed.sql      triggers, parameter row, error codes
    deploy/03_functions.sql          functions (incl. v0.6.1 fn_ParquetColumnName)
    deploy/04_procedures.sql         procedures v0.6.1
    deploy/05_monitoring_views.sql   views (incl. v0.6.1 vw_ParquetColumnMap, v0.6.2 vw_MQ07_ArchiveFiles)
    deploy/20_OpsiB_DB_Objects.sql   opsi B v0.7.1 (columns, 9 procedures with #RetOut_, 6 wrappers)

deploy/08 and deploy/09 are not included: their content is already in 03..05.
deploy/07 (security, template with placeholders) is not included.

Usage (from the repository root): python3 SQL_Script/tools/make_full_bundle.py .
Run make_sql_opsiB.py first when deploy/04 or src/ changed.
"""
import os, sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
BASE = os.path.join(ROOT, "SQL_Script")
PARTS = ["deploy/01_schema_tables.sql", "deploy/02_triggers_seed.sql", "deploy/03_functions.sql",
         "deploy/04_procedures.sql", "deploy/05_monitoring_views.sql", "deploy/20_OpsiB_DB_Objects.sql"]
OUT = os.path.join(BASE, "DWH_Retention_FULL_v0.7.1.sql")

HEADER = """/* =====================================================================================
   DWH Data Retention and Archiving - schema ret - FULL BUNDLE (SQL v0.6.2 + opsi B v0.7.1)
   -------------------------------------------------------------------------------------
   Script    : SQL_Script/DWH_Retention_FULL_v0.7.1.sql
   Status    : DRAFT - not reviewed, not executed against any database
   Generated : by SQL_Script/tools/make_full_bundle.py - do not edit; change the part files and generate again
   Content   : %s
   Use       : new (empty) DWH database, or a complete redeploy of an existing one (re-runnable: migration
               blocks, IF NOT EXISTS seeds, CREATE OR ALTER). Run the WHOLE file in one session, connected to
               the DWH database, while no retention run is RUNNING. Then: config/00, config/10 (or 11 / 12),
               verify/90 and verify/21 - see SQL_Script/README.md.
   ===================================================================================== */
"""

def main():
    out = [HEADER % ", ".join(PARTS)]
    for p in PARTS:
        txt = open(os.path.join(BASE, p), encoding="utf-8").read().rstrip() + "\n"
        if not txt.rstrip().endswith("GO"):
            txt += "GO\n"
        out.append("\n/* #####################################################################################\n"
                   f"   PART {p}\n"
                   "   ##################################################################################### */\n")
        out.append(txt)
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write("".join(out))
    print(f"written {OUT}: {len(PARTS)} parts")

if __name__ == "__main__":
    main()
