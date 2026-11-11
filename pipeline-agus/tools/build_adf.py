"""
Generator for the ADF resources of FSD-DWH-RET-001 v0.2 (DWH Data Retention and Archiving).
VARIANT pipeline-agus: uses the linked services that already exist in the factory (created by the user):
  Agus_SqlServer_dwh      type SqlServer         -> DWH database (schema ret)
  Agus_AzureBlobStorage1  type AzureBlobStorage  -> storage account stormsfsax01loc10dev
Linked services are NOT generated; datasets reference them by name. SQL dataset type SqlServerTable,
Lookup/Copy source type SqlServerSource.
Contract source: DWH_Retention_DB_Objects_v0.4.sql ("ADF CALL SEQUENCE PER TABLE").

Output:
  <out>/adf/linkedService|dataset|pipeline|trigger/*.json   (ADF Git-integration layout)
  <out>/arm/ARMTemplateForFactory.json + ARMTemplateParametersForFactory.json
"""
import json, os, sys, copy

OUT = sys.argv[1] if len(sys.argv) > 1 else "out"
FOLDER = "DWH Retention"
FOLDER_RUN = "DWH Retention"
FOLDER_INT = "DWH Retention/Internal"
ANN = ["FSD-DWH-RET v1.1", "SQL v0.6", "DRAFT - not approved"]

LS_SQL, LS_BLOB = "Agus_SqlServer_dwh", "Agus_AzureBlobStorage1"   # existing linked services (not generated)
EXTERNAL_LS = {LS_SQL, LS_BLOB}
DS_SQL, DS_PARQ, DS_FOLDER = "DS_RET_SqlDb", "DS_RET_ArchiveParquet", "DS_RET_ArchiveFolder"

# ------------------------------------------------------------------ helpers
def E(expr):
    """ADF expression object."""
    return {"value": expr if expr.startswith("@") else "@" + expr, "type": "Expression"}

def dep(name, cond="Succeeded"):
    return {"activity": name, "dependencyConditions": [cond]}

def policy(timeout="0.00:30:00", retry=1, interval=60):
    return {"timeout": timeout, "retry": retry, "retryIntervalInSeconds": interval,
            "secureOutput": False, "secureInput": False}

def spp(**params):
    """Stored procedure parameters: name=(type, expr-or-literal)."""
    out = {}
    for k, (t, v) in params.items():
        out[k] = {"type": t, "value": E(v) if isinstance(v, str) and v.startswith("@") else v}
    return out

def lookup_sp(name, proc, params, deps=None, first_row=True, qt="00:30:00", pol=None, desc=None):
    a = {"name": name, "type": "Lookup", "dependsOn": deps or [], "policy": pol or policy(),
         "userProperties": [],
         "typeProperties": {
             "source": {"type": "SqlServerSource", "sqlReaderStoredProcedureName": proc,
                        "storedProcedureParameters": spp(**params), "queryTimeout": qt,
                        "partitionOption": "None"},
             "dataset": {"referenceName": DS_SQL, "type": "DatasetReference"},
             "firstRowOnly": first_row}}
    if desc: a["description"] = desc
    return a

def lookup_query(name, expr, deps=None, first_row=True, qt="00:30:00", pol=None, desc=None):
    a = {"name": name, "type": "Lookup", "dependsOn": deps or [], "policy": pol or policy(),
         "userProperties": [],
         "typeProperties": {
             "source": {"type": "SqlServerSource", "sqlReaderQuery": E(expr), "queryTimeout": qt,
                        "partitionOption": "None"},
             "dataset": {"referenceName": DS_SQL, "type": "DatasetReference"},
             "firstRowOnly": first_row}}
    if desc: a["description"] = desc
    return a

def setvar(name, var, expr, deps=None, desc=None):
    a = {"name": name, "type": "SetVariable", "dependsOn": deps or [], "userProperties": [],
         "typeProperties": {"variableName": var,
                            "value": E(expr) if expr.startswith("@") else expr}}
    if desc: a["description"] = desc
    return a

def execp(name, pipeline, params, deps=None, desc=None):
    a = {"name": name, "type": "ExecutePipeline", "dependsOn": deps or [], "userProperties": [],
         "typeProperties": {"pipeline": {"referenceName": pipeline, "type": "PipelineReference"},
                            "waitOnCompletion": True,
                            "parameters": {k: (E(v) if isinstance(v, str) and v.startswith("@") else v)
                                           for k, v in params.items()}}}
    if desc: a["description"] = desc
    return a

def ifc(name, expr, true_acts, false_acts=None, deps=None, desc=None):
    a = {"name": name, "type": "IfCondition", "dependsOn": deps or [], "userProperties": [],
         "typeProperties": {"expression": E(expr), "ifTrueActivities": true_acts,
                            "ifFalseActivities": false_acts or []}}
    if desc: a["description"] = desc
    return a

def fail(name, msg_expr, code, deps=None):
    return {"name": name, "type": "Fail", "dependsOn": deps or [], "userProperties": [],
            "typeProperties": {"message": E(msg_expr), "errorCode": code}}

def folder_ds(container, path):
    return {"referenceName": DS_FOLDER, "type": "DatasetReference",
            "parameters": {"Container": E(container), "FolderPath": E(path)}}

def pipeline(name, desc, params, variables, activities, concurrency=None, folder=FOLDER_INT):
    p = {"name": name, "properties": {
        "description": desc,
        "activities": activities,
        "parameters": params,
        "variables": {k: {"type": "String", "defaultValue": v} for k, v in variables.items()},
        "folder": {"name": folder},
        "annotations": ANN}}
    if concurrency: p["properties"]["concurrency"] = concurrency
    return p

def sp(t="string", default=None):
    d = {"type": t}
    if default is not None: d["defaultValue"] = default
    return d

P = lambda n: f"pipeline().parameters.{n}"
V = lambda n: f"variables('{n}')"
FR = lambda a: f"activity('{a}').output.firstRow"

def sql_nstr(expr):
    """T-SQL N'...' literal of a (non-null) ADF string expression, quotes doubled."""
    return f"concat('N''', replace({expr}, '''', ''''''), '''')"

def sql_nstr_or_null(expr):
    return f"if(empty(trim({expr})), 'NULL', {sql_nstr(f'trim({expr})')})"

# Lookup policies (FSD 13.4: ADF retry for transient errors, values TBD; rebuild: no automatic retry)
POL_CTRL  = policy("0.00:30:00", 1, 60)
POL_SCAN  = policy("0.04:15:00", 1, 60)     # procedures that scan DWH tables
POL_LONG  = policy("0.08:30:00", 0, 60)     # batch delete / rebuild (long, no ADF retry)
POL_LOG   = policy("0.00:10:00", 2, 30)
POL_ENDRUN = policy("0.00:30:00", 0, 30)    # raises an error by design when the run did not succeed
QT_SCAN, QT_LONG = "04:00:00", "08:00:00"

# ------------------------------------------------------------------ linked services, datasets
def linked_services(arm=False):
    sql_cs = ("[concat('Integrated Security=False;Encrypt=True;Connection Timeout=30;Data Source=', "
              "parameters('sqlServerFqdn'), ';Initial Catalog=', parameters('sqlDatabaseName'))]") if arm else \
             "Integrated Security=False;Encrypt=True;Connection Timeout=30;Data Source=<sql-server-name>.database.windows.net;Initial Catalog=<dwh-database-name>"
    blob_ep = "[concat('https://', parameters('archiveStorageAccountName'), '.blob.core.windows.net/')]" if arm \
              else "https://<archive-storage-account>.blob.core.windows.net/"
    ir = "[parameters('integrationRuntimeName')]" if arm else "AutoResolveIntegrationRuntime"
    return [
        {"name": LS_SQL, "properties": {
            "description": "DWH database (Azure SQL Database, schema ret). Authentication: ADF system-assigned managed identity "
                           "(no credential in the definition, SEC-01/SEC-06). Identity needs EXECUTE on the ret procedures only "
                           "(role ret_adf_executor, SQL script section 13). INT-01/INT-02.",
            "annotations": ANN, "type": "AzureSqlDatabase",
            "typeProperties": {"connectionString": sql_cs},
            "connectVia": {"referenceName": ir, "type": "IntegrationRuntimeReference"}}},
        {"name": LS_BLOB, "properties": {
            "description": "Archive storage account. Authentication: ADF system-assigned managed identity with a "
                           "container-scoped data role (Storage Blob Data Contributor) on the archive container (SEC-05). INT-02/INT-03.",
            "annotations": ANN, "type": "AzureBlobStorage",
            "typeProperties": {"serviceEndpoint": blob_ep, "accountKind": "StorageV2"},
            "connectVia": {"referenceName": ir, "type": "IntegrationRuntimeReference"}}},
    ]

def datasets():
    return [
        {"name": DS_SQL, "properties": {
            "description": "Generic dataset (SQL Server connector, linked service Agus_SqlServer_dwh) for Lookup and Copy activities that call schema ret procedures (no table bound).",
            "linkedServiceName": {"referenceName": LS_SQL, "type": "LinkedServiceReference"},
            "annotations": ANN, "folder": {"name": FOLDER},
            "type": "SqlServerTable", "schema": [], "typeProperties": {}}},
        {"name": DS_PARQ, "properties": {
            "description": "One Parquet file per table and business date: <container>/<BlobPath>/year=YYYY/month=MM/day=DD/"
                           "<schema>_<table>_<yyyyMMdd>_<RunId>.parquet (FR-007, MD-07, DEC-04).",
            "linkedServiceName": {"referenceName": LS_BLOB, "type": "LinkedServiceReference"},
            "parameters": {"Container": {"type": "string"}, "FolderPath": {"type": "string"}, "FileName": {"type": "string"}},
            "annotations": ANN, "folder": {"name": FOLDER},
            "type": "Parquet",
            "typeProperties": {"location": {"type": "AzureBlobStorageLocation",
                                            "fileName": E("dataset().FileName"),
                                            "folderPath": E("dataset().FolderPath"),
                                            "container": E("dataset().Container")},
                               "compressionCodec": "snappy"},
            "schema": []}},
        {"name": DS_FOLDER, "properties": {
            "description": "Archive folder (binary) for Get Metadata (child items) and Delete activities (FR-013, FR-018).",
            "linkedServiceName": {"referenceName": LS_BLOB, "type": "LinkedServiceReference"},
            "parameters": {"Container": {"type": "string"}, "FolderPath": {"type": "string"}},
            "annotations": ANN, "folder": {"name": FOLDER},
            "type": "Binary",
            "typeProperties": {"location": {"type": "AzureBlobStorageLocation",
                                            "folderPath": E("dataset().FolderPath"),
                                            "container": E("dataset().Container")}}}},
    ]

# ------------------------------------------------------------------ pipeline names
PL01 = "PL_RET_01_InitialCutoff_Master"
PL02 = "PL_RET_02_DailyRoutine_Master"
PL03 = "PL_RET_03_Table_Process"
PL03A = "PL_RET_03A_Table_DataSteps"
PL03B = "PL_RET_03B_Table_ResumeDelete"
PL03C = "PL_RET_03C_Path_BatchDelete"
PL03D = "PL_RET_03D_Path_TableRebuild"
PL03E = "PL_RET_03E_Export_BusinessDates"
PL03F = "PL_RET_03F_Table_FileCleanup"
PL04 = "PL_RET_04_ArchiveExpiry"
PL04A = "PL_RET_04A_ArchiveExpiry_Level"
PL05 = "PL_RET_05_DryValidation_Master"
TR02 = "TR_RET_DailyRoutine_2100_WIB"

TABLE_CTX = ["RunId", "TableConfigId", "TableLogId", "ProcessType", "ArchiveContainer", "BlobPath",
             "SchemaName", "TableName"]

def pass_ctx(*names, **extra):
    d = {n: f"@{P(n)}" for n in names}
    d.update(extra)
    return d

# ------------------------------------------------------------------ PL-03F file cleanup (FSD 4.18, 6.1)
def pl03f():
    lst = "LKP_GetRunArchiveFiles"
    fe = "FE_DeleteRunFiles"
    gmd = "GMD_RunFileFolderExists"
    tl = ("Int64", f"@{P('TableLogId')}")
    delete = {"name": "DEL_RunFile", "type": "Delete", "dependsOn": [],
              "policy": policy("0.00:30:00", 2, 60), "userProperties": [],
              "description": "Deletes exactly one file of this run: <FolderPath>/<FileName> from ret.RetentionArchiveDate "
                             "(no pattern; files of other runs are never touched).",
              "typeProperties": {"dataset": folder_ds(P("ArchiveContainer"), "item().FolderPath"),
                                 "enableLogging": False,
                                 "storeSettings": {"type": "AzureBlobStorageReadSettings", "recursive": False,
                                                   "wildcardFileName": E("item().FileName"),
                                                   "enablePartitionDiscovery": False}}}
    acts = [
        lookup_sp(lst, "ret.usp_GetRunArchiveFiles", dict(TableLogId=tl), first_row=False, pol=POL_CTRL,
                  desc="FSD 4.18: files this table log may have written (ExportStatus SUCCEEDED, FAILED or STOPPED)."),
        {"name": fe, "type": "ForEach", "dependsOn": [dep(lst)], "userProperties": [],
         "description": "One file per business date; a missing folder means the file was never written.",
         "typeProperties": {
             "items": E(f"activity('{lst}').output.value"), "isSequential": False, "batchCount": 4,
             "activities": [
                 {"name": gmd, "type": "GetMetadata", "dependsOn": [], "policy": policy("0.00:30:00", 2, 60),
                  "userProperties": [],
                  "typeProperties": {"dataset": folder_ds(P("ArchiveContainer"), "item().FolderPath"),
                                     "fieldList": ["exists"],
                                     "storeSettings": {"type": "AzureBlobStorageReadSettings", "recursive": False,
                                                       "enablePartitionDiscovery": False},
                                     "formatSettings": {"type": "BinaryReadSettings"}}},
                 ifc("IF_RunFileFolderExists", f"activity('{gmd}').output.exists", [delete], deps=[dep(gmd)])]}},
        lookup_sp("LKP_LogCleanup_Succeeded", "ret.usp_LogCleanupResult",
                  dict(TableLogId=tl, Status=("String", "SUCCEEDED"),
                       FilesRemoved=("Int32", f"@length(activity('{lst}').output.value)")),
                  deps=[dep(fe)], pol=POL_LOG),
        lookup_sp("LKP_LogCleanup_DeleteFailed", "ret.usp_LogCleanupResult",
                  dict(TableLogId=tl, Status=("String", "FAILED"),
                       ErrorMessage=("String", f"@concat('One or more archive files of this run could not be deleted (', "
                                               f"{P('BlobPath')}, '). ADF run ', pipeline().RunId)")),
                  deps=[dep(fe, "Failed")], pol=POL_LOG),
        lookup_sp("LKP_LogCleanup_ListFailed", "ret.usp_LogCleanupResult",
                  dict(TableLogId=tl, Status=("String", "FAILED"),
                       ErrorMessage=("String", f"@activity('{lst}').error.message")),
                  deps=[dep(lst, "Failed")], pol=POL_LOG),
    ]
    return pipeline(PL03F,
        "FSD 4.18 / 5.4 / 6.1: remove exactly the archive files that this table log wrote, as listed by "
        "ret.usp_GetRunArchiveFiles (layout MD-07, no RunId in the file name), then record the result with "
        "ret.usp_LogCleanupResult (success: dates marked REMOVED; failure: orphan-file flag, ERR-EXP-03).",
        {"TableLogId": sp(), "RunId": sp(), "ArchiveContainer": sp(), "BlobPath": sp(), "SchemaName": sp(), "TableName": sp()},
        {}, acts)

# ------------------------------------------------------------------ PL-03E export loop (FR-006, FR-019)
def pl03e():
    nxt = "LKP_NextExportDate"
    cpy = "CPY_ExportBusinessDate"
    copy_act = {
        "name": cpy, "type": "Copy", "dependsOn": [dep("SET_ExportStartTime")],
        "policy": policy("0.04:00:00", 2, 120), "userProperties": [],
        "description": "IC-02 / DR-02: rows of one business date -> one Parquet file. Source ret.usp_ExportSourceRows "
                       "(all columns, ordinal order, no transformation). File name carries the RunId (DBR-07).",
        "inputs": [{"referenceName": DS_SQL, "type": "DatasetReference"}],
        "outputs": [{"referenceName": DS_PARQ, "type": "DatasetReference",
                     "parameters": {"Container": E(P("ArchiveContainer")),
                                    "FolderPath": E(f"{FR(nxt)}.FolderPath"),
                                    "FileName": E(f"{FR(nxt)}.FileName")}}],
        "typeProperties": {
            "source": {"type": "SqlServerSource", "sqlReaderStoredProcedureName": "ret.usp_ExportSourceRows",
                       "storedProcedureParameters": spp(TableLogId=("Int64", f"@{P('TableLogId')}"),
                                                        BusinessDate=("String", f"@{FR(nxt)}.BusinessDate")),
                       "queryTimeout": "04:00:00", "partitionOption": "None"},
            "sink": {"type": "ParquetSink",
                     "storeSettings": {"type": "AzureBlobStorageWriteSettings"},
                     "formatSettings": {"type": "ParquetWriteSettings"}},
            "enableStaging": False,
            "translator": {"type": "TabularTranslator", "typeConversion": True,
                           "typeConversionSettings": {"allowDataTruncation": False, "treatBooleanAsNumber": False}}}}
    log_ok = lookup_sp("LKP_LogExport_Succeeded", "ret.usp_LogExportResult",
        dict(TableLogId=("Int64", f"@{P('TableLogId')}"),
             BusinessDate=("String", f"@{FR(nxt)}.BusinessDate"),
             ExportStatus=("String", "SUCCEEDED"),
             RowsRead=("Int64", f"@activity('{cpy}').output.rowsRead"),
             RowsWritten=("Int64", f"@activity('{cpy}').output.rowsCopied"),
             FilesWritten=("Int32", f"@activity('{cpy}').output.filesWritten"),
             ExportStartTime=("String", f"@{V('vExportStartTime')}")),
        deps=[dep(cpy)], pol=POL_LOG,
        desc="Records the Copy result; in an IC also checks the window (ERR-WIN-01). Returns ContinueExport, CleanupRequired, RemainingDates.")
    log_fail = lookup_sp("LKP_LogExport_Failed", "ret.usp_LogExportResult",
        dict(TableLogId=("Int64", f"@{P('TableLogId')}"),
             BusinessDate=("String", f"@{FR(nxt)}.BusinessDate"),
             ExportStatus=("String", "FAILED"),
             ExportStartTime=("String", f"@{V('vExportStartTime')}"),
             ErrorMessage=("String", f"@activity('{cpy}').error.message")),
        deps=[dep(cpy, "Failed")], pol=POL_LOG, desc="ERR-EXP-01: export failed after retries; loop stops, cleanup required.")
    true_acts = [
        setvar("SET_ExportStartTime", "vExportStartTime",
               "@convertFromUtc(utcNow(), 'SE Asia Standard Time', 'yyyy-MM-dd HH:mm:ss.fff')"),
        copy_act, log_ok,
        setvar("SET_Continue_AfterOk", "vContinue",
               f"@if(and(bool({FR('LKP_LogExport_Succeeded')}.ContinueExport), "
               f"greater({FR('LKP_LogExport_Succeeded')}.RemainingDates, 0)), '1', '0')",
               deps=[dep("LKP_LogExport_Succeeded")]),
        setvar("SET_Cleanup_AfterOk", "vCleanup",
               f"@if(bool({FR('LKP_LogExport_Succeeded')}.CleanupRequired), '1', '0')",
               deps=[dep("SET_Continue_AfterOk")]),
        log_fail,
        setvar("SET_Continue_AfterFail", "vContinue", "0", deps=[dep("LKP_LogExport_Failed", "Completed")]),
        setvar("SET_Cleanup_AfterFail", "vCleanup", "1", deps=[dep("SET_Continue_AfterFail")]),
        setvar("SET_Continue_LogError", "vContinue", "0", deps=[dep("LKP_LogExport_Succeeded", "Failed")],
               desc="Fail-safe: result of a written file could not be recorded; stop and remove this run's files."),
        setvar("SET_Cleanup_LogError", "vCleanup", "1", deps=[dep("SET_Continue_LogError")]),
    ]
    until = {
        "name": "UNT_ExportBusinessDates", "type": "Until", "dependsOn": [dep("IF_OutsideWindowAtStart")],
        "userProperties": [],
        "description": "One iteration per business date still PENDING (usp_GetExportPlan with MaxRows = 1). "
                       "Stops when ContinueExport = 0, no date remains, or an error occurs.",
        "typeProperties": {
            "expression": E(f"not(equals({V('vContinue')}, '1'))"),
            "timeout": "0.12:00:00",
            "activities": [
                lookup_sp(nxt, "ret.usp_GetExportPlan",
                          dict(TableLogId=("Int64", f"@{P('TableLogId')}"), MaxRows=("Int32", 1)), pol=POL_CTRL),
                ifc("IF_HasPendingDate",
                    f"and(equals({V('vContinue')}, '1'), contains(activity('{nxt}').output, 'firstRow'))",
                    true_acts,
                    [setvar("SET_Continue_NoDate", "vContinue", "0")],
                    deps=[dep(nxt)]),
            ]}}
    acts = [
        lookup_sp("LKP_CheckExecutionWindow", "ret.usp_CheckExecutionWindow",
                  dict(RunId=("Int64", f"@{P('RunId')}")), pol=POL_CTRL,
                  desc="FR-019: IC window 21:00-05:00 UTC+7 before the first export (always 1 for the Daily Routine)."),
        ifc("IF_OutsideWindowAtStart", f"not(bool({FR('LKP_CheckExecutionWindow')}.IsWithinWindow))",
            [lookup_sp("LKP_FirstPendingDate", "ret.usp_GetExportPlan",
                       dict(TableLogId=("Int64", f"@{P('TableLogId')}"), MaxRows=("Int32", 1)), pol=POL_CTRL),
             lookup_sp("LKP_LogExport_StoppedAtStart", "ret.usp_LogExportResult",
                       dict(TableLogId=("Int64", f"@{P('TableLogId')}"),
                            BusinessDate=("String", f"@{FR('LKP_FirstPendingDate')}.BusinessDate"),
                            ExportStatus=("String", "STOPPED"),
                            ErrorMessage=("String", "Initial Cut-off window end reached before the export started (FR-019).")),
                       deps=[dep("LKP_FirstPendingDate")], pol=POL_LOG),
             setvar("SET_Continue_WindowClosed", "vContinue", "0", deps=[dep("LKP_LogExport_StoppedAtStart", "Completed")]),
             setvar("SET_Cleanup_WindowClosed", "vCleanup", "1", deps=[dep("SET_Continue_WindowClosed")])],
            deps=[dep("LKP_CheckExecutionWindow")]),
        until,
        ifc("IF_CleanupOnStop", f"and({P('CleanupOnStop')}, equals({V('vCleanup')}, '1'))",
            [execp("EXEC_FileCleanup", PL03F,
                   pass_ctx("TableLogId", "RunId", "ArchiveContainer", "BlobPath", "SchemaName", "TableName"))],
            deps=[dep("UNT_ExportBusinessDates", "Completed")],
            desc="Batch-delete path: remove this run's files on export failure or window stop (E2). "
                 "Rebuild path passes CleanupOnStop = false: usp_TableRebuildAbort runs first (SQL contract)."),
    ]
    return pipeline(PL03E,
        "FR-006 / FR-007 / FR-019 (IC-02, DR-02, RB-06): export every PENDING business date of a table log to Parquet, "
        "one Copy activity per date, sequential (DEC-07), each result recorded with ret.usp_LogExportResult.",
        {"RunId": sp(), "TableLogId": sp(), "ProcessType": sp(), "ArchiveContainer": sp(), "BlobPath": sp(),
         "SchemaName": sp(), "TableName": sp(), "CleanupOnStop": sp("bool", True)},
        {"vContinue": "1", "vCleanup": "0", "vExportStartTime": ""}, acts)

# ------------------------------------------------------------------ PL-03C batch-delete path
def pl03c():
    ctx = pass_ctx("RunId", "TableLogId", "ProcessType", "ArchiveContainer", "BlobPath", "SchemaName", "TableName")
    clean_ctx = pass_ctx("TableLogId", "RunId", "ArchiveContainer", "BlobPath", "SchemaName", "TableName")
    acts = [
        ifc("IF_ExportRequired", f"equals({P('NextAction')}, 'EXPORT')",
            [execp("EXEC_ExportBusinessDates", PL03E, dict(ctx, CleanupOnStop=True))],
            desc="NextAction VALIDATE (IC, expired rows only, DBR-03) skips the export."),
        lookup_sp("LKP_ValidateArchive", "ret.usp_ValidateArchive",
                  dict(TableLogId=("Int64", f"@{P('TableLogId')}")),
                  deps=[dep("IF_ExportRequired", "Completed")], pol=POL_CTRL,
                  desc="IC-03 / DR-03 / FR-008 (BR-08 gate): per-date and total row counts. Always called after the export "
                       "step; a failed or stopped export makes it return FAILED, so nothing is removed."),
        setvar("SET_ValidationResult", "vValidationResult", f"@{FR('LKP_ValidateArchive')}.ValidationResult",
               deps=[dep("LKP_ValidateArchive")]),
        setvar("SET_Cleanup_FromValidation", "vCleanup",
               f"@if(bool({FR('LKP_ValidateArchive')}.CleanupRequired), '1', '0')",
               deps=[dep("SET_ValidationResult")]),
        ifc("IF_ValidationPassed", f"equals({V('vValidationResult')}, 'PASSED')",
            [lookup_sp("LKP_BatchDelete", "ret.usp_BatchDelete",
                       dict(RunId=("Int64", f"@{P('RunId')}"), TableLogId=("Int64", f"@{P('TableLogId')}")),
                       qt=QT_LONG, pol=POL_LONG,
                       desc="IC-04a / DR-04 / FR-009: recount (DBR-06), DELETE TOP (BatchSize) + pause, window stop in IC."),
             setvar("SET_DeleteResult", "vDeleteResult", f"@{FR('LKP_BatchDelete')}.DeleteResult",
                    deps=[dep("LKP_BatchDelete")]),
             setvar("SET_Cleanup_FromDelete", "vCleanup",
                    f"@if(bool({FR('LKP_BatchDelete')}.CleanupRequired), '1', '0')",
                    deps=[dep("SET_DeleteResult")],
                    desc="CleanupRequired = 1 only for ERR-VAL-02 (recount differs, nothing deleted).")],
            deps=[dep("SET_Cleanup_FromValidation")]),
        ifc("IF_DeleteCompleted", f"equals({V('vDeleteResult')}, 'COMPLETED')",
            [lookup_sp("LKP_PostCheck", "ret.usp_PostCheck", dict(TableLogId=("Int64", f"@{P('TableLogId')}")),
                       qt=QT_SCAN, pol=POL_SCAN,
                       desc="FR-020 / AC-03 / AC-07: no rows before the DWH cut-off; IC: retained rows not reduced, status COMPLETED.")],
            deps=[dep("IF_ValidationPassed")]),
        ifc("IF_CleanupRequired", f"equals({V('vCleanup')}, '1')",
            [execp("EXEC_FileCleanup", PL03F, clean_ctx)],
            deps=[dep("IF_DeleteCompleted", "Completed")],
            desc="E3: validation failure or ERR-VAL-02 -> remove this run's files; nothing removed from the DWH."),
        execp("EXEC_FileCleanup_OnValidationError", PL03F, clean_ctx,
              deps=[dep("LKP_ValidateArchive", "Failed")],
              desc="Validation could not be executed: remove this run's files (fail-safe, BR-08)."),
        fail("FAIL_ValidationNotExecuted",
             f"concat('ret.usp_ValidateArchive failed for TableLogId ', {P('TableLogId')}, ': ', "
             f"activity('LKP_ValidateArchive').error.message)",
             "RET-VALIDATE-ERROR", deps=[dep("EXEC_FileCleanup_OnValidationError", "Completed")]),
    ]
    return pipeline(PL03C,
        "PRC-02 batch-delete path (IC-01..IC-04a) and PRC-03 (DR-02..DR-04): export -> validate -> batch delete -> "
        "post-check; this run's files are removed when validation fails (FR-018).",
        {"RunId": sp(), "TableLogId": sp(), "ProcessType": sp(), "NextAction": sp(), "ArchiveContainer": sp(),
         "BlobPath": sp(), "SchemaName": sp(), "TableName": sp()},
        {"vValidationResult": "NOT_RUN", "vDeleteResult": "NOT_RUN", "vCleanup": "0"}, acts)

# ------------------------------------------------------------------ PL-03D table rebuild path (FR-010, Section 8.4)
def pl03d():
    ctx = pass_ctx("RunId", "TableLogId", "ProcessType", "ArchiveContainer", "BlobPath", "SchemaName", "TableName")
    clean_ctx = pass_ctx("TableLogId", "RunId", "ArchiveContainer", "BlobPath", "SchemaName", "TableName")
    acts = [
        lookup_sp("LKP_RebuildPrepare", "ret.usp_TableRebuildPrepare",
                  dict(RunId=("Int64", f"@{P('RunId')}"), TableLogId=("Int64", f"@{P('TableLogId')}")),
                  qt=QT_LONG, pol=POL_LONG,
                  desc="RB-01..RB-05 (MD-04 steps 1-2): checks, new table <table>__RBD_<RunId> with the retained rows, "
                       "keys/constraints/indexes, count check. Original table unchanged."),
        setvar("SET_PrepareResult", "vPrepareResult", f"@{FR('LKP_RebuildPrepare')}.PrepareResult",
               deps=[dep("LKP_RebuildPrepare")]),
        ifc("IF_ExportRequired",
            f"and(equals({V('vPrepareResult')}, 'COMPLETED'), equals({P('NextAction')}, 'EXPORT'))",
            [execp("EXEC_ExportBusinessDates", PL03E, dict(ctx, CleanupOnStop=False))],
            deps=[dep("SET_PrepareResult")],
            desc="RB-06 (MD-04 step 3): archived segment exported from the ORIGINAL table."),
        ifc("IF_Prepared", f"equals({V('vPrepareResult')}, 'COMPLETED')",
            [lookup_sp("LKP_ValidateArchive", "ret.usp_ValidateArchive",
                       dict(TableLogId=("Int64", f"@{P('TableLogId')}")), pol=POL_CTRL,
                       desc="RB-07: archive row-count validation."),
             setvar("SET_ValidationResult", "vValidationResult", f"@{FR('LKP_ValidateArchive')}.ValidationResult",
                    deps=[dep("LKP_ValidateArchive")])],
            deps=[dep("IF_ExportRequired", "Completed")]),
        ifc("IF_ValidationPassed", f"equals({V('vValidationResult')}, 'PASSED')",
            [lookup_sp("LKP_RebuildSwap", "ret.usp_TableRebuildSwap",
                       dict(RunId=("Int64", f"@{P('RunId')}"), TableLogId=("Int64", f"@{P('TableLogId')}")),
                       qt=QT_LONG, pol=POL_LONG,
                       desc="RB-07 recount, RB-08 truncate + drop + rename in one transaction (MD-04 steps 4-5, MD-06, DEC-13), "
                            "RB-09 reseed / view refresh, RB-10 definition check."),
             setvar("SET_SwapResult", "vSwapResult", f"@{FR('LKP_RebuildSwap')}.SwapResult",
                    deps=[dep("LKP_RebuildSwap")]),
             setvar("SET_SwapDeleteStatus", "vSwapDeleteStatus",
                    f"@string(coalesce({FR('LKP_RebuildSwap')}?.DeleteStatus, ''))",
                    deps=[dep("SET_SwapResult")])],
            deps=[dep("IF_Prepared", "Completed")]),
        ifc("IF_SwapCompleted", f"equals({V('vSwapResult')}, 'COMPLETED')",
            [lookup_sp("LKP_PostCheck", "ret.usp_PostCheck", dict(TableLogId=("Int64", f"@{P('TableLogId')}")),
                       qt=QT_SCAN, pol=POL_SCAN, desc="Post-check; IC status COMPLETED (FR-020).")],
            deps=[dep("IF_ValidationPassed", "Completed")]),
        ifc("IF_AbortRequired",
            f"and(equals({V('vPrepareResult')}, 'COMPLETED'), not(equals({V('vSwapDeleteStatus')}, 'COMPLETED')))",
            [lookup_sp("LKP_RebuildAbort", "ret.usp_TableRebuildAbort",
                       dict(RunId=("Int64", f"@{P('RunId')}"), TableLogId=("Int64", f"@{P('TableLogId')}"),
                            MarkOrphanFiles=("Boolean", False)), pol=POL_CTRL,
                       desc="Any failure before RB-08 commits: drop the new table, revoke validation, request file cleanup."),
             setvar("SET_AbortCleanup", "vAbortCleanup",
                    f"@if(bool({FR('LKP_RebuildAbort')}.CleanupRequired), '1', '0')",
                    deps=[dep("LKP_RebuildAbort")])],
            deps=[dep("IF_SwapCompleted", "Completed")]),
        ifc("IF_CleanupRequired", f"equals({V('vAbortCleanup')}, '1')",
            [execp("EXEC_FileCleanup", PL03F, clean_ctx)],
            deps=[dep("IF_AbortRequired", "Completed")]),
    ]
    return pipeline(PL03D,
        "FR-010 / Section 8.4 table rebuild (Initial Cut-off Run, method TABLE_REBUILD, downtime reference required): "
        "Prepare (RB-01..05) -> export from original (RB-06) -> validate (RB-07) -> Swap (RB-07..10) -> post-check; "
        "Abort + file cleanup on any failure before the swap commits.",
        {"RunId": sp(), "TableLogId": sp(), "ProcessType": sp(), "NextAction": sp(), "ArchiveContainer": sp(),
         "BlobPath": sp(), "SchemaName": sp(), "TableName": sp()},
        {"vPrepareResult": "NOT_RUN", "vValidationResult": "NOT_RUN", "vSwapResult": "NOT_RUN",
         "vSwapDeleteStatus": "", "vAbortCleanup": "0"}, acts)

# ------------------------------------------------------------------ PL-03B resume (FR-017)
def pl03b():
    until = {
        "name": "UNT_ResumePendingRanges", "type": "Until", "dependsOn": [dep("SET_InitPendingId")],
        "userProperties": [],
        "typeProperties": {
            "expression": E(f"or(empty({V('vPendingTableLogId')}), equals({V('vStop')}, '1'))"),
            "timeout": "0.12:00:00",
            "activities": [
                lookup_sp("LKP_BatchDelete_Resume", "ret.usp_BatchDelete",
                          dict(RunId=("Int64", f"@{P('RunId')}"), TableLogId=("Int64", f"@{V('vPendingTableLogId')}")),
                          qt=QT_LONG, pol=POL_LONG,
                          desc="Removes the remaining rows of a validated range of an earlier run without export (DBR-09)."),
                setvar("SET_Stop_FromResult", "vStop",
                       f"@if(equals({FR('LKP_BatchDelete_Resume')}.DeleteResult, 'COMPLETED'), '0', '1')",
                       deps=[dep("LKP_BatchDelete_Resume")]),
                lookup_sp("LKP_GetPendingResume", "ret.usp_GetPendingResume",
                          dict(RunId=("Int64", f"@{P('RunId')}"), TableConfigId=("Int32", f"@{P('TableConfigId')}")),
                          deps=[dep("SET_Stop_FromResult")], pol=POL_CTRL),
                setvar("SET_NextPendingId", "vPendingTableLogId",
                       f"@if(contains(activity('LKP_GetPendingResume').output, 'firstRow'), "
                       f"string(activity('LKP_GetPendingResume').output?.firstRow?.PendingResumeTableLogId), '')",
                       deps=[dep("LKP_GetPendingResume")]),
                setvar("SET_Stop_OnError", "vStop", "1", deps=[dep("LKP_BatchDelete_Resume", "Failed")]),
                setvar("SET_Unexpected_OnError", "vUnexpectedError", "@activity('LKP_BatchDelete_Resume').error.message",
                       deps=[dep("SET_Stop_OnError")]),
            ]}}
    acts = [
        setvar("SET_InitPendingId", "vPendingTableLogId", f"@{P('PendingResumeTableLogId')}"),
        until,
        ifc("IF_UnexpectedError", f"not(empty({V('vUnexpectedError')}))",
            [fail("FAIL_ResumeError", f"concat('Resume of a validated range failed: ', {V('vUnexpectedError')})",
                  "RET-RESUME-ERROR")],
            deps=[dep("UNT_ResumePendingRanges", "Completed")],
            desc="Only an ADF/connection error fails the pipeline; FAILED/STOPPED results are already recorded by the procedure."),
    ]
    return pipeline(PL03B,
        "FR-017 / PRC-05: resume validated batch-delete ranges of earlier runs, oldest first, until none is pending. "
        "A non-COMPLETED result stops the loop; the table log status set by ret.usp_BatchDelete then blocks further steps.",
        {"RunId": sp(), "TableConfigId": sp(), "PendingResumeTableLogId": sp()},
        {"vPendingTableLogId": "", "vStop": "0", "vUnexpectedError": ""}, acts)

# ------------------------------------------------------------------ PL-03A data steps
def pl03a():
    path_ctx = pass_ctx("RunId", "TableLogId", "ProcessType", "ArchiveContainer", "BlobPath", "SchemaName", "TableName",
                        NextAction=f"@{FR('LKP_IdentifyEligibleData')}.NextAction")
    idf = FR("LKP_IdentifyEligibleData")
    path_expr = (f"@if(not(equals({idf}.Result, 'SUCCEEDED')), 'NONE', "
                 f"if(equals({idf}.NextAction, 'NONE'), "
                 f"if(equals({P('ProcessType')}, 'INITIAL_CUTOFF'), 'IC_NODATA', 'NONE'), "
                 f"if(and(equals({P('ProcessType')}, 'INITIAL_CUTOFF'), equals({P('InitialCutoffMethod')}, 'TABLE_REBUILD')), "
                 f"'REBUILD', 'BATCH')))")
    switch = {
        "name": "SW_ProcessingPath", "type": "Switch", "dependsOn": [dep("SET_ProcessingPath")], "userProperties": [],
        "description": "BATCH: Daily Routine or IC with BATCH_DELETE. REBUILD: IC with TABLE_REBUILD (BR-11). "
                       "IC_NODATA: IC without eligible rows - post-check only, so the table reaches COMPLETED. "
                       "NONE: nothing eligible (DR) or the step before failed (status already recorded).",
        "typeProperties": {
            "on": E(V("vProcessingPath")),
            "cases": [
                {"value": "BATCH", "activities": [execp("EXEC_Path_BatchDelete", PL03C, path_ctx)]},
                {"value": "REBUILD", "activities": [execp("EXEC_Path_TableRebuild", PL03D, path_ctx)]},
                {"value": "IC_NODATA", "activities": [
                    lookup_sp("LKP_PostCheck_NoData", "ret.usp_PostCheck", dict(TableLogId=("Int64", f"@{P('TableLogId')}")),
                              qt=QT_SCAN, pol=POL_SCAN)]},
            ],
            "defaultActivities": []}}
    acts = [
        ifc("IF_PendingResume", f"not(empty({P('PendingResumeTableLogId')}))",
            [execp("EXEC_ResumeDelete", PL03B, pass_ctx("RunId", "TableConfigId", "PendingResumeTableLogId"))],
            desc="FR-017: resume pending ranges before new data is identified."),
        lookup_sp("LKP_IdentifyEligibleData", "ret.usp_IdentifyEligibleData",
                  dict(TableLogId=("Int64", f"@{P('TableLogId')}")), deps=[dep("IF_PendingResume")],
                  qt=QT_SCAN, pol=POL_SCAN,
                  desc="IC-01 / DR-01 / FR-005 (FR-023 for child tables): per business-date snapshot; NextAction EXPORT / VALIDATE / NONE."),
        setvar("SET_ProcessingPath", "vProcessingPath", path_expr, deps=[dep("LKP_IdentifyEligibleData")]),
        switch,
    ]
    return pipeline(PL03A,
        "Per-table data steps after usp_BeginTable returned PROCEED: resume -> identify eligible data -> "
        "batch-delete path or table-rebuild path (IC only) -> post-check.",
        {"RunId": sp(), "TableConfigId": sp(), "TableLogId": sp(), "ProcessType": sp(), "InitialCutoffMethod": sp(),
         "ArchiveContainer": sp(), "BlobPath": sp(), "SchemaName": sp(), "TableName": sp(),
         "PendingResumeTableLogId": sp("string", "")},
        {"vProcessingPath": "NONE"}, acts)

# ------------------------------------------------------------------ PL-04A / PL-04 archive expiry (FSD 4.13, 5.4)
def pl04a():
    gmd = "GMD_ListChildItems"
    lkp = "LKP_GetExpiredArchiveFolders"
    flt = "FLT_ItemsToDelete"
    fe = "FE_DeleteExpiredItems"
    gx = "GMD_ItemFolderExists"
    tl = ("Int64", f"@{P('TableLogId')}")
    is_year = f"equals({P('Level')}, 'YEAR')"
    cnt = f"activity('{flt}').output.FilteredItemsCount"
    delete = {"name": "DEL_ExpiredItem", "type": "Delete", "dependsOn": [],
              "policy": policy("0.01:00:00", 2, 60), "userProperties": [],
              "description": "YEAR: whole folder <yyyy>/<BlobPath> (recursive). FILE: one file <BlobPath>_<yyyyMMdd>.parquet.",
              "typeProperties": {"dataset": folder_ds(P("ArchiveContainer"), "item().FolderPath"),
                                 "enableLogging": False,
                                 "storeSettings": {"type": "AzureBlobStorageReadSettings",
                                                   "recursive": E(is_year),
                                                   "wildcardFileName": E("if(empty(item().FileName), '*', item().FileName)"),
                                                   "enablePartitionDiscovery": False}}}
    acts = [
        {"name": gmd, "type": "GetMetadata", "dependsOn": [], "policy": policy("0.00:30:00", 2, 60),
         "userProperties": [],
         "description": "YEAR: container root (year folders). FILE: folder <cut-off year>/<BlobPath>. "
                        "'exists' keeps a missing folder from failing the activity.",
         "typeProperties": {"dataset": folder_ds(P("ArchiveContainer"), P("FolderPath")),
                            "fieldList": ["exists", "childItems"],
                            "storeSettings": {"type": "AzureBlobStorageReadSettings", "recursive": False,
                                              "enablePartitionDiscovery": False},
                            "formatSettings": {"type": "BinaryReadSettings"}}},
        lookup_sp(lkp, "ret.usp_GetExpiredArchiveFolders",
                  dict(TableLogId=tl,
                       ChildItemsJson=("String", f"@string(coalesce(activity('{gmd}').output?.childItems, json('[]')))"),
                       Level=("String", f"@{P('Level')}"),
                       Year=("Int16", f"@{P('CutoffYear')}")),
                  deps=[dep(gmd)], first_row=False, pol=POL_CTRL,
                  desc="Names and dates parsed in SQL; returns DELETE rows only (YEAR: <yyyy>/<BlobPath> before the cut-off "
                       "year; FILE: files dated before the archive cut-off). Non-matching names are never deleted."),
        {"name": flt, "type": "Filter", "dependsOn": [dep(lkp)], "userProperties": [],
         "typeProperties": {"items": E(f"activity('{lkp}').output.value"),
                            "condition": E("equals(item().Action, 'DELETE')")}},
        {"name": fe, "type": "ForEach", "dependsOn": [dep(flt)], "userProperties": [],
         "description": "Parallel, batch 4 (FSD 6.1). The year folder is shared by all tables, so the table folder may not exist.",
         "typeProperties": {
             "items": E(f"activity('{flt}').output.value"), "isSequential": False, "batchCount": 4,
             "activities": [
                 {"name": gx, "type": "GetMetadata", "dependsOn": [], "policy": policy("0.00:30:00", 2, 60),
                  "userProperties": [],
                  "typeProperties": {"dataset": folder_ds(P("ArchiveContainer"), "item().FolderPath"),
                                     "fieldList": ["exists"],
                                     "storeSettings": {"type": "AzureBlobStorageReadSettings", "recursive": False,
                                                       "enablePartitionDiscovery": False},
                                     "formatSettings": {"type": "BinaryReadSettings"}}},
                 ifc("IF_ItemFolderExists", f"activity('{gx}').output.exists", [delete], deps=[dep(gx)])]}},
        lookup_sp("LKP_LogExpired_Succeeded", "ret.usp_LogExpiredArchiveResult",
                  dict(TableLogId=tl, Status=("String", "SUCCEEDED"),
                       FoldersDeleted=("Int32", f"@if({is_year}, {cnt}, 0)"),
                       FilesDeleted=("Int32", f"@if({is_year}, 0, {cnt})")),
                  deps=[dep(fe)], pol=POL_LOG),
        lookup_sp("LKP_LogExpired_DeleteFailed", "ret.usp_LogExpiredArchiveResult",
                  dict(TableLogId=tl, Status=("String", "FAILED"),
                       ErrorMessage=("String", f"@concat('ERR-ARC-01: one or more expired items could not be deleted at level ', "
                                               f"{P('Level')}, ' of ', if(empty({P('FolderPath')}), '<container root>', {P('FolderPath')}), "
                                               f"'. ADF run ', pipeline().RunId)")),
                  deps=[dep(fe, "Failed")], pol=POL_LOG),
        lookup_sp("LKP_LogExpired_ListFailed", "ret.usp_LogExpiredArchiveResult",
                  dict(TableLogId=tl, Status=("String", "FAILED"),
                       ErrorMessage=("String", f"@activity('{gmd}').error.message")),
                  deps=[dep(gmd, "Failed")], pol=POL_LOG),
        lookup_sp("LKP_LogExpired_ProcFailed", "ret.usp_LogExpiredArchiveResult",
                  dict(TableLogId=tl, Status=("String", "FAILED"),
                       ErrorMessage=("String", f"@activity('{lkp}').error.message")),
                  deps=[dep(lkp, "Failed")], pol=POL_LOG),
    ]
    return pipeline(PL04A,
        "FSD 4.13 / 5.4 one level (YEAR or FILE): list the items, let ret.usp_GetExpiredArchiveFolders decide, delete the "
        "expired year folders of this table or the expired files, record the result (ERR-ARC-01 on failure; the next "
        "Daily Routine completes).",
        {"TableLogId": sp(), "ArchiveContainer": sp(), "FolderPath": sp("string", ""), "Level": sp(),
         "CutoffYear": sp("int")},
        {}, acts)

def pl04():
    y = f"substring({P('ArchiveCutoffDate')}, 0, 4)"
    common = lambda lvl, path: {"TableLogId": f"@{P('TableLogId')}", "ArchiveContainer": f"@{P('ArchiveContainer')}",
                                "FolderPath": path, "Level": lvl, "CutoffYear": f"@int({y})"}
    acts = [
        execp("EXEC_Level_Year", PL04A, common("YEAR", ""),
              desc="Container root: folders <yyyy>/<BlobPath> of years before the archive cut-off year are deleted whole."),
        execp("EXEC_Level_File", PL04A, common("FILE", f"@concat({y}, '/', {P('BlobPath')})"),
              deps=[dep("EXEC_Level_Year", "Completed")],
              desc="Folder <archive cut-off year>/<BlobPath>: files dated before the archive cut-off are deleted."),
    ]
    return pipeline(PL04,
        "FSD 4.13 / 5.4 / DR-05: delete archive data with business date before the archive cut-off, layout MD-07 "
        "<container>/<yyyy>/<BlobPath>/<BlobPath>_<yyyyMMdd>.parquet: level YEAR on the container root, then level FILE "
        "in the cut-off year. A missing folder is a no-op.",
        {"TableLogId": sp(), "ArchiveContainer": sp(), "BlobPath": sp(), "ArchiveCutoffDate": sp()},
        {}, acts)

# ------------------------------------------------------------------ PL-03 per table
def pl03():
    bt = FR("LKP_BeginTable")
    combined = (f"concat({V('vErrDataSteps')}, if(and(not(empty({V('vErrDataSteps')})), not(empty({V('vErrArchiveExpiry')}))), "
                f"' | ', ''), {V('vErrArchiveExpiry')})")
    end_q = (f"@concat('EXEC ret.usp_EndTable @TableLogId = ', string({bt}.TableLogId), ', @ErrorMessage = ', "
             f"{sql_nstr_or_null(combined)}, ';')")
    acts = [
        lookup_sp("LKP_BeginTable", "ret.usp_BeginTable",
                  dict(RunId=("Int64", f"@{P('RunId')}"), TableConfigId=("Int32", f"@{P('TableConfigId')}")),
                  qt=QT_SCAN, pol=POL_SCAN,
                  desc="FR-002 / FR-016 / FR-017 / FR-023: table log, lock, checks V-01..V-11, gates DBR-18/DBR-19, "
                       "pending resume. BeginResult PROCEED / SKIPPED / FAILED; CanRunArchiveExpiry."),
        ifc("IF_Proceed",
            f"and(equals({bt}.BeginResult, 'PROCEED'), not(equals({P('ProcessType')}, 'VALIDATION')))",
            [execp("EXEC_DataSteps", PL03A, {
                "RunId": f"@{P('RunId')}", "TableConfigId": f"@{P('TableConfigId')}",
                "TableLogId": f"@string({bt}.TableLogId)", "ProcessType": f"@{P('ProcessType')}",
                "InitialCutoffMethod": f"@{P('InitialCutoffMethod')}", "ArchiveContainer": f"@{P('ArchiveContainer')}",
                "BlobPath": f"@{P('BlobPath')}", "SchemaName": f"@{P('SchemaName')}", "TableName": f"@{P('TableName')}",
                "PendingResumeTableLogId": f"@string(coalesce({bt}?.PendingResumeTableLogId, ''))"}),
             setvar("SET_ErrDataSteps", "vErrDataSteps", "@activity('EXEC_DataSteps').error.message",
                    deps=[dep("EXEC_DataSteps", "Failed")])],
            deps=[dep("LKP_BeginTable")],
            desc="Dry validation (PL_RET_01 with ValidateOnly = true, process type VALIDATION, decision D-3) stops after "
                 "the checks of usp_BeginTable; nothing is exported or deleted."),
        ifc("IF_ArchiveExpiry",
            f"and(equals({P('ProcessType')}, 'DAILY_ROUTINE'), bool({bt}.CanRunArchiveExpiry))",
            [execp("EXEC_ArchiveExpiry", PL04, {
                "TableLogId": f"@string({bt}.TableLogId)", "ArchiveContainer": f"@{P('ArchiveContainer')}",
                "BlobPath": f"@{P('BlobPath')}", "ArchiveCutoffDate": f"@{bt}.ArchiveCutoffDate"}),
             setvar("SET_ErrArchiveExpiry", "vErrArchiveExpiry", "@activity('EXEC_ArchiveExpiry').error.message",
                    deps=[dep("EXEC_ArchiveExpiry", "Failed")])],
            deps=[dep("IF_Proceed", "Completed")],
            desc="DR-05 runs whenever V-05 and V-06 passed, whatever happened earlier (BR-14, PRC-03 E1-E4), "
                 "also when the header table was skipped by DBR-19."),
        lookup_query("LKP_EndTable", end_q, deps=[dep("IF_ArchiveExpiry", "Completed")], pol=POL_LOG,
                     desc="IC-05 / DR-06 / FR-014: always called; final status, IC status on failure/stop, lock release. "
                          "An ADF-level error message (if any) is passed as @ErrorMessage, otherwise NULL."),
        ifc("IF_TableFailed", f"contains(createArray('FAILED', 'STOPPED'), {FR('LKP_EndTable')}.FinalStatus)",
            [fail("FAIL_Table",
                  f"concat({P('SchemaName')}, '.', {P('TableName')}, ' ended ', {FR('LKP_EndTable')}.FinalStatus, "
                  f"' (', string(coalesce({FR('LKP_EndTable')}?.ErrorCode, 'no code')), '). See ret.RetentionTableLog TableLogId ', "
                  f"string({bt}.TableLogId), '.')",
                  "RET-TABLE-FAILED")],
            deps=[dep("LKP_EndTable")],
            desc="Makes a failed table visible in ADF monitoring; the master continues with the next table."),
    ]
    return pipeline(PL03,
        "PL-03 per table (IC-01..IC-05, DR-01..DR-06): usp_BeginTable -> data steps (PL_RET_03A) -> "
        "expired archive deletion (PL-04, Daily Routine) -> usp_EndTable (always).",
        {"RunId": sp(), "TableConfigId": sp(), "ProcessType": sp(), "InitialCutoffMethod": sp(),
         "ArchiveContainer": sp(), "BlobPath": sp(), "SchemaName": sp(), "TableName": sp()},
        {"vErrDataSteps": "", "vErrArchiveExpiry": ""}, acts)

# ------------------------------------------------------------------ masters
def master(name, process_type, desc, params, with_list, with_downtime, with_validate=False):
    trig = "if(equals(pipeline().TriggerType, 'ScheduleTrigger'), 'SCHEDULE', 'MANUAL')"
    rd = P("RunDate")
    run_date = (f"if(empty(trim({rd})), 'NULL', concat('''', formatDateTime(if(empty(trim({rd})), '1900-01-01', "
                f"trim({rd})), 'yyyy-MM-dd'), ''''))")
    tb = (f"if(empty(trim({P('TriggeredBy')})), concat(pipeline().TriggerType, ': ', pipeline().TriggerName), "
          f"trim({P('TriggeredBy')}))")
    downtime = sql_nstr_or_null(P("DowntimeReference")) if with_downtime else "'NULL'"
    if with_validate:
        # Decision D-3 (option A): dry validation through the same master pipeline
        validate = f"bool({P('ValidateOnly')})"
        pt_expr = f"if({validate}, 'VALIDATION', '{process_type}')"
        downtime = f"if({validate}, 'NULL', {downtime})"
    else:
        pt_expr = f"'{process_type}'"
    start_q = (f"@concat('EXEC ret.usp_StartRun @ProcessType = ''', {pt_expr}, ''', @TriggerType = ''', {trig}, "
               f"''', @AdfPipelineRunId = ''', pipeline().RunId, ''', @RunDate = ', {run_date}, "
               f"', @TriggeredBy = ', {sql_nstr(tb)}, ', @DowntimeReference = ', {downtime}, ';')")
    gt_params = dict(RunId=("Int64", f"@{V('vRunId')}"))
    if with_list:
        gt_params["TableConfigIdList"] = ("String", f"@{P('TableConfigIdList')}")
    err_expr = "concat('Table selection failed: ', activity('LKP_GetTablesToProcess').error.message)"
    endrun_err_q = (f"@concat('EXEC ret.usp_EndRun @RunId = ', {V('vRunId')}, ', @ErrorMessage = ', "
                    f"{sql_nstr(err_expr)}, ', @FailPipelineOnError = 1;')")
    acts = [
        lookup_query("LKP_StartRun", start_q, pol=POL_CTRL,
                     desc="FR-003 / FR-014: run record, run date fixed in UTC+7 (override may only be earlier, DBR-15); "
                          "idempotent per ADF pipeline run ID. Optional values are passed as NULL when empty."),
        setvar("SET_RunId", "vRunId", f"@string({FR('LKP_StartRun')}.RunId)", deps=[dep("LKP_StartRun")]),
        setvar("SET_ProcessType", "vProcessType", f"@{FR('LKP_StartRun')}.ProcessType", deps=[dep("SET_RunId")],
               desc="Process type as recorded by usp_StartRun (VALIDATION when ValidateOnly = true)."),
        lookup_sp("LKP_GetTablesToProcess", "ret.usp_GetTablesToProcess", gt_params,
                  deps=[dep("SET_ProcessType")], first_row=False, pol=POL_CTRL,
                  desc="FR-004: table selection per process type; ordered by ProcessingOrder (child tables first, DBR-19 / DBR-18)."),
        {"name": "FE_Tables", "type": "ForEach", "dependsOn": [dep("LKP_GetTablesToProcess")], "userProperties": [],
         "description": "Sequential (DEC-07). A failed table never blocks the next one.",
         "typeProperties": {
             "items": E("activity('LKP_GetTablesToProcess').output.value"), "isSequential": True,
             "activities": [execp("EXEC_TableProcess", PL03, {
                 "RunId": f"@{V('vRunId')}", "TableConfigId": "@string(item().TableConfigId)",
                 "ProcessType": f"@{V('vProcessType')}", "InitialCutoffMethod": "@item().InitialCutoffMethod",
                 "ArchiveContainer": "@item().ArchiveContainer", "BlobPath": "@item().BlobPath",
                 "SchemaName": "@item().SchemaName", "TableName": "@item().TableName"})]}},
        lookup_sp("LKP_EndRun", "ret.usp_EndRun",
                  dict(RunId=("Int64", f"@{V('vRunId')}"), FailPipelineOnError=("Boolean", True)),
                  deps=[dep("FE_Tables", "Completed")], pol=POL_ENDRUN,
                  desc="FR-014: closes the run; raises an error (pipeline FAILED) when the run is not SUCCEEDED [REC 8.3]."),
        lookup_query("LKP_EndRun_SelectionFailed", endrun_err_q,
                     deps=[dep("LKP_GetTablesToProcess", "Failed")], pol=POL_ENDRUN),
    ]
    return pipeline(name, desc, params, {"vRunId": "", "vProcessType": ""}, acts, concurrency=1, folder=FOLDER_RUN)

def pl01():
    return master(PL01, "INITIAL_CUTOFF",
        "PL-01 / PRC-02 / FR-011: Initial Cut-off Run, triggered manually inside 21:00-05:00 UTC+7 (BR-17). "
        "TableConfigIdList EMPTY = automatic mode (CR-01, SQL v0.5): all active tables not yet COMPLETED, SMALL/MEDIUM "
        "before LARGE, child tables first; run again until every table is COMPLETED. TableConfigIdList given = explicit "
        "ordered list. LARGE or TABLE_REBUILD tables require DowntimeReference (BR-16, D-07). Concurrency 1. "
        "ValidateOnly = true: dry validation (process type VALIDATION, decision D-3, FSD 4.2 / 4.11): checks V-01..V-11 "
        "only, nothing exported or deleted, DowntimeReference ignored; empty TableConfigIdList = all active tables not "
        "COMPLETED.",
        {"TableConfigIdList": sp("string", ""), "RunDate": sp("string", ""), "DowntimeReference": sp("string", ""),
         "TriggeredBy": sp("string", ""), "ValidateOnly": sp("bool", False)}, True, True, with_validate=True)

def pl02():
    return master(PL02, "DAILY_ROUTINE",
        "PL-02 / PRC-03 / FR-012: Daily Routine, scheduled every day 21:00 UTC+7 (BR-18). Selects active tables whose "
        "Initial Cut-off Run completed before the run date, from DailyRoutineStartDate (FR-020). RunDate empty = today "
        "UTC+7; manual rerun may pass an earlier date (DBR-15). Concurrency 1.",
        {"RunDate": sp("string", ""), "TriggeredBy": sp("string", "")}, False, False)

def pl05():
    return master(PL05, "VALIDATION",
        "PL-05 [REC, PRC-01 step 5]: dry validation of listed tables - usp_BeginTable checks V-01..V-11 only, no data "
        "change, recorded with process type VALIDATION. Concurrency 1.",
        {"TableConfigIdList": sp("string"), "RunDate": sp("string", ""), "TriggeredBy": sp("string", "")}, True, False)

def trigger(arm=False):
    return {"name": TR02, "properties": {
        "description": "BR-18: Daily Routine every day at 21:00 UTC+7 (SE Asia Standard Time). Deployed STOPPED: start it "
                       "only after ret.usp_ActivateDailyRoutine (FSD 16.2, FR-020).",
        "annotations": ANN, "runtimeState": "Stopped",
        "pipelines": [{"pipelineReference": {"referenceName": PL02, "type": "PipelineReference"}, "parameters": {}}],
        "type": "ScheduleTrigger",
        "typeProperties": {"recurrence": {
            "frequency": "Day", "interval": 1,
            "startTime": "[parameters('dailyRoutineTriggerStartTime')]" if arm else "2026-12-01T21:00:00",
            "timeZone": "SE Asia Standard Time",
            "schedule": {"minutes": [0], "hours": [21]}}}}}

# ------------------------------------------------------------------ write
def all_pipelines():
    return [pl03f(), pl03e(), pl03c(), pl03d(), pl03b(), pl03a(), pl04a(), pl04(), pl03(), pl01(), pl02()]

def write(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=4, ensure_ascii=False)
        f.write("\n")

def refs(obj, key):
    out = set()
    if isinstance(obj, dict):
        if obj.get("type") == key and "referenceName" in obj:
            out.add(obj["referenceName"])
        for v in obj.values(): out |= refs(v, key)
    elif isinstance(obj, list):
        for v in obj: out |= refs(v, key)
    return out

def arm_escape(obj):
    if isinstance(obj, dict): return {k: arm_escape(v) for k, v in obj.items()}
    if isinstance(obj, list): return [arm_escape(v) for v in obj]
    if isinstance(obj, str) and obj.startswith("[") and not obj.startswith("[parameters(") and not obj.startswith("[concat("):
        return "[" + obj
    return obj

def main():
    base = os.path.join(OUT, "adf")
    for ds in datasets(): write(os.path.join(base, "dataset", ds["name"] + ".json"), ds)
    pls = all_pipelines()
    for p in pls: write(os.path.join(base, "pipeline", p["name"] + ".json"), p)
    write(os.path.join(base, "trigger", TR02 + ".json"), trigger())

    # ARM template
    fid = "[concat('Microsoft.DataFactory/factories/', parameters('factoryName'))]"
    res = []
    def rid(kind, name): return f"[concat(variables('factoryId'), '/{kind}/{name}')]"
    for ds in datasets():
        res.append({"name": f"[concat(parameters('factoryName'), '/{ds['name']}')]",
                    "type": "Microsoft.DataFactory/factories/datasets", "apiVersion": "2018-06-01",
                    "properties": arm_escape(ds["properties"]),
                    "dependsOn": [rid("linkedServices", n) for n in sorted(refs(ds, "LinkedServiceReference")) if n not in EXTERNAL_LS]})
    for p in pls:
        d = [rid("datasets", n) for n in sorted(refs(p, "DatasetReference"))] + \
            [rid("pipelines", n) for n in sorted(refs(p, "PipelineReference"))]
        res.append({"name": f"[concat(parameters('factoryName'), '/{p['name']}')]",
                    "type": "Microsoft.DataFactory/factories/pipelines", "apiVersion": "2018-06-01",
                    "properties": arm_escape(p["properties"]), "dependsOn": d})
    t = trigger(arm=True)
    res.append({"name": f"[concat(parameters('factoryName'), '/{TR02}')]",
                "type": "Microsoft.DataFactory/factories/triggers", "apiVersion": "2018-06-01",
                "properties": t["properties"], "dependsOn": [rid("pipelines", PL02)]})
    tmpl = {
        "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
        "contentVersion": "1.0.0.0",
        "parameters": {
            "factoryName": {"type": "string", "metadata": {"description": "Target data factory name"}},
            "dailyRoutineTriggerStartTime": {"type": "string", "defaultValue": "2026-12-01T21:00:00",
                                             "metadata": {"description": "Local time (SE Asia Standard Time). Set to DailyRoutineStartDate 21:00 (FSD 16.2)"}}},
        "variables": {"factoryId": fid},
        "resources": res}
    write(os.path.join(OUT, "arm", "ARMTemplateForFactory.json"), tmpl)
    write(os.path.join(OUT, "arm", "ARMTemplateParametersForFactory.json"), {
        "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
        "contentVersion": "1.0.0.0",
        "parameters": {"factoryName": {"value": "<data-factory-name>"},
                       "dailyRoutineTriggerStartTime": {"value": "2026-12-01T21:00:00"}}})
    print("pipelines:", len(pls), "resources:", len(res))

if __name__ == "__main__":
    main()
