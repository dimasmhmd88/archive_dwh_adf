/* =====================================================================================
   DWH Data Retention and Archiving - Database Objects (schema ret)
   -------------------------------------------------------------------------------------
   Script        : DWH_Retention_DB_Objects_v0.6.sql (consolidated; replaces v0.5.1 and the v0.5 patch)
   Script ver.   : 0.6 (DRAFT - not reviewed, not executed against any database)
   Date          : 11 November 2026 (v0.4: 30 Oct 2026; v0.5: 31 Oct 2026; v0.5.1: 1 Nov 2026)
   Sources       : FSD_DWH_Data_Retention_v1.1 (FSD-DWH-RET v1.1, 10 Nov 2026, Draft for Review - NOT approved)
                   Decisions D-1..D-4 of the review "pipeline-agus vs FSD v1.1" (11 Nov 2026, given by the user)
                   Earlier: FSD-DWH-RET-001 v0.2, design table v0.2, BRD-DWH-RET-001 v0.1
   Target        : Azure SQL Database, DWH database, schema ret (FSD MD-01, MD-02).
                   Requires database compatibility level >= 130 (CREATE OR ALTER, STRING_AGG,
                   STRING_SPLIT with ordinal, OPENJSON).
   NOTE          : Requirement references in older comments (FR-0nn, BRQ-nn, DBR-nn, PRC-nn) use the
                   numbering of FSD v0.2. FSD v1.1 references are given as section numbers (4.x).

   CHANGES IN v0.6 (11 November 2026) - alignment with FSD v1.1
   - MD-07 archive layout (FSD 3.4, 4.7, 8): <container>/<yyyy>/<BlobPath>/<BlobPath>_<yyyyMMdd>.parquet,
     BlobPath = <schema>.<table> in lower case (no slash), container dwh-archive. fn_ArchiveFolderPath and
     fn_ArchiveFileName have the FSD signatures (@BlobPath, @BusinessDate); the RunId is no longer part of
     the file name (it stays in ret.RetentionArchiveDate). Check CK_RetentionConfig_BlobPath and V-06 reject
     a slash; migration (h) converts slash paths of tables without any archive file.
   - Decision D-1 (FSD 4.17): usp_IdentifyEligibleData refuses a business date for which an archive file of an
     earlier run of the same table may still exist (ExportStatus SUCCEEDED, FAILED or STOPPED in
     ret.RetentionArchiveDate): ERR-EXP-02, table FAILED, nothing exported or deleted; manual handling.
   - FSD 4.18: new procedure usp_GetRunArchiveFiles (files of one table log to delete after a failure);
     PL_RET_03F deletes exactly these files.
   - FSD 4.13: usp_GetExpiredArchiveFolders works on level YEAR (container root: folders <yyyy>/<BlobPath> of
     years before the archive cut-off year) and FILE (folder <cut-off year>/<BlobPath>: files dated before the
     archive cut-off). Parameters @Level ('YEAR' | 'FILE') and @Year; result FolderPath, FileName, Action.
   - MD-08 / FSD 4.24: column ret.RetentionConfig.LogRetentionYears (default 3, >= 1, V-05). usp_EndTable (Daily
     Routine) deletes log records of the table older than RunDate - LogRetentionYears; usp_EndRun deletes old
     run-level records no longer referenced. Rows still needed are kept: validated ranges not fully deleted,
     runs referenced by ret.RetentionTableStatus and [v0.6 addition, FSD update needed] archive inventory rows
     of files that are not yet expired (needed by the D-1 check).
   - FSD 4.15: monitoring views ret.vw_MQ01_LatestRuns .. ret.vw_MQ06_LocksAndRebuildTables (section 9b).
   - Decision D-3 (dry validation, option A): VALIDATION with an EMPTY table list = all active tables not
     COMPLETED; a VALIDATION run never drops leftover rebuild tables (reported as a warning only).

   CHANGES IN v0.5.1 (1 November 2026) - collation fix, no functional change
   - Error "Cannot resolve collation conflict for string_agg operation" on Azure SQL Database when the
     database collation differs from the catalog collation (names in sys.* views use the catalog
     collation; definition columns use the database collation).
   - Every string column read from sys.* views (name, collation_name, definition, filter_definition,
     type_desc, state_desc, permission_name, *_desc) and the first argument of every STRING_AGG now
     carry COLLATE DATABASE_DEFAULT. Also covers comparisons with temp-table columns (tempdb collation).

   CHANGES FROM v0.4 (v0.5, consolidated from DWH_Retention_DB_Objects_v0.5_patch.sql)
   - CR-01 (proposed, requires approval - changes FSD FR-004 "Input"):
     ret.usp_GetTablesToProcess for process type INITIAL_CUTOFF accepts an EMPTY
     @TableConfigIdList ("automatic mode"). It then selects every active table whose Initial
     Cut-off status is not COMPLETED, in this order:
        1. SMALL and MEDIUM before LARGE (BR-16, DBR-05)
        2. within a size group, child tables before other tables (DBR-18)
        3. ascending TableConfigId
     All gates of v0.4 are unchanged and are applied to the automatic list exactly as to an
     explicit list: inactive / RUNNING / header-before-child / LARGE without downtime reference /
     LARGE while SMALL or MEDIUM tables are not COMPLETED / TABLE_REBUILD without downtime
     reference -> SKIPPED with ERR-CFG-07. The operator runs the Initial Cut-off master pipeline
     again until every table is COMPLETED; each run takes only the tables not yet completed.
   - An explicit list keeps the v0.4 behaviour (operator order).
   - VALIDATION runs still require an explicit list.
   - Output columns unchanged (ADF contract unchanged).

   KNOWN LIMITATION (design finding F-12, not changed by this patch)
   - A LARGE child table whose header table is SMALL or MEDIUM can never be selected:
     the header waits for the child (DBR-18) and the child waits for all SMALL/MEDIUM tables
     (DBR-05). This applies to v0.4 as well. Decision required (OQ-26 / BR-16).

   CHANGES FROM v0.3
   - MD-05 / FSD FR-023 parent-dated retention of child tables:
       * ret.RetentionConfig: RetentionColumn nullable, new ParentTableConfigId (exactly one of
         the two is filled), new table ret.RetentionParentKey (join keys), new trigger
         ret.trg_RetentionParentKey_Protect.
       * Checks V-10 (header configuration) and V-11 (join key unique in header), header lock
         check, codes ERR-CFG-11, ERR-CFG-12, ERR-PAR-01 (warning, orphan child rows).
       * All data access goes through ret.usp_GetTableSqlParts, which returns the SQL fragments
         for own-dated and child tables (business date of a child row = date of its header row).
       * DBR-18 (IC of a header refused until its active child tables are COMPLETED),
         DBR-19 (Daily Routine: child tables first; header DWH removal skipped when a child did
         not end SUCCEEDED/NODATA), DBR-21 (orphan child rows kept, counted, never removed).
   - MD-06 / FSD 8.4 table rebuild: the v0.3 "stage, truncate and reload" procedure is replaced by
       ret.usp_TableRebuildPrepare (RB-01..RB-05: new table, retained rows, keys, indexes, count),
       ADF export from the original table (RB-06),
       ret.usp_ValidateArchive (RB-07),
       ret.usp_TableRebuildSwap (RB-07 recount, RB-08 truncate + drop + rename in one transaction,
       RB-09 identity reseed and view refresh, RB-10 definition check),
       ret.usp_TableRebuildAbort (drop the new table, revoke validation, request file cleanup).
       Parameter KeepRebuildStagingTable removed.
   - [v0.4, superseded in v0.6] MD-07 archive layout: <container>/<BlobPath>/year=YYYY/month=MM/day=DD/<file>; BlobPath lower
       case; ArchiveContainer = container name only (check constraint, no default);
       ret.usp_GetExpiredArchiveFolders works per level YEAR / MONTH / DAY (v0.6: YEAR / FILE).
   - Design table alignment: DatabaseName column removed (design table, MD-02, FSD DV-01);
       parameters TableParallelism and ExportDateParallelism removed (not in design table,
       FSD DEC-07 sequential processing); new column ret.RetentionTableLog.OrphanRows;
       ERR-CFG-10 no longer used.
   - Section 1.10 migrates a database where v0.3 (or v0.2) objects were deployed.

   POINTS WHERE THIS SCRIPT DETAILS OR DEVIATES FROM FSD v0.2 (FSD update or approval needed)
   D4-01 FSD 10.7 names one procedure usp_TableRebuild; the script splits it into
         usp_TableRebuildPrepare, usp_TableRebuildSwap and usp_TableRebuildAbort so that the export
         (RB-06) runs between them as ADF activities.
   D4-02 RB-10 definition check runs in usp_TableRebuildSwap (FSD: usp_PostCheck); usp_PostCheck
         still checks the row counts. A definition difference gives ERR-RBD-03 and the integrity flag.
   D4-03 Child eligibility uses LEFT JOIN to the header instead of the EXISTS form of FR-023; both
         give the same rows because V-11 guarantees a unique join key.
   D4-04 New procedure usp_GetPendingResume (next resume range); usp_GetExpiredArchiveFolders has new
         parameters @Level, @Year, @Month and returns Action DELETE / DESCEND (MD-07).
   D4-05 Skips by DBR-18 / DBR-19 use ERR-CFG-07 (no separate code in FSD 13.1). In the Daily Routine a
         header table is also skipped when an active child table was not selected in the run (for
         example its Initial Cut-off Run is not completed).
   D4-06 An unfinished table rebuild is never resumed: the next usp_BeginTable, usp_EndTable,
         usp_EndRun or usp_AdminCloseStaleRun drops the new table, revokes the validation and sets the
         orphan-file flag for the files of that run.

   MARKERS: [FSD] specified in FSD v0.2  [DER] derived detail, needs review  [REC] recommendation
   Physical names follow the design table v0.2; procedure names are proposals (FSD 10.7).

   ===================================================================================
   ADF CALL SEQUENCE PER TABLE (contract between pipelines and procedures)
   ===================================================================================
     Run   : usp_StartRun -> usp_GetTablesToProcess -> [per table, in ProcessingOrder] -> usp_EndRun
             (ProcessType VALIDATION = dry validation: step 1 and 11 only, nothing is changed - D-3)
     Table : 1 usp_BeginTable           BeginResult PROCEED / SKIPPED / FAILED; CanRunArchiveExpiry
             2 while PendingResumeTableLogId is not NULL: usp_BatchDelete(@TableLogId = that id),
                        then usp_BeginTable result is re-read with usp_GetPendingResume
             3 usp_IdentifyEligibleData NextAction EXPORT / VALIDATE / NONE
             BATCH_DELETE (DR always; IC with method BATCH_DELETE):
             4 EXPORT : usp_GetExportPlan -> per date: (IC) usp_CheckExecutionWindow,
                        Copy (source usp_ExportSourceRows) -> usp_LogExportResult
             5 usp_ValidateArchive  6 usp_BatchDelete  7 usp_PostCheck
             TABLE_REBUILD (IC only):
             4 usp_TableRebuildPrepare (RB-01..RB-05)
             5 EXPORT loop as above from the original table (RB-06)
             6 usp_ValidateArchive (RB-07)  7 usp_TableRebuildSwap (RB-07..RB-10)
             8 on any failure before step 7 commits: usp_TableRebuildAbort
             BOTH:
             9 DR only, when CanRunArchiveExpiry = 1 (also when BeginResult = SKIPPED by DBR-19), v0.6:
                        level YEAR: Get Metadata childItems of the container root ->
                        usp_GetExpiredArchiveFolders(@Level = 'YEAR') -> per item: folder exists? -> Delete
                        folder <yyyy>/<BlobPath> -> usp_LogExpiredArchiveResult;
                        level FILE: Get Metadata of <cut-off year>/<BlobPath> ->
                        usp_GetExpiredArchiveFolders(@Level = 'FILE', @Year) -> Delete each file ->
                        usp_LogExpiredArchiveResult
            10 if any result returns CleanupRequired = 1 (v0.6): usp_GetRunArchiveFiles -> per file:
                        exists? -> Delete <FolderPath>/<FileName> -> usp_LogCleanupResult
            11 usp_EndTable (always, also on ADF failure paths with the activity error; DR: log retention)

   DEPLOYMENT NOTES
   - Run the whole script connected to the DWH database. Re-runnable: tables are created when
     missing, migration blocks run only when needed, code objects use CREATE OR ALTER.
   - Sections 10-14 (examples, monitoring, security, optional temporal history) are commented out.
   - The script has NOT been executed against SQL Server or Azure SQL Database. Deploy first to a
     development database, run the unit tests of FSD section 17 and review with the DBA.
   ===================================================================================== */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

/* -------------------------------------------------------------------------------------
   0. Schema (BRD C-05: separated from the DWH tables only by the schema name ret)
   ------------------------------------------------------------------------------------- */
IF SCHEMA_ID(N'ret') IS NULL
    EXEC (N'CREATE SCHEMA [ret] AUTHORIZATION [dbo];');
GO

/* =====================================================================================
   1. TABLES
   ===================================================================================== */

/* 1.1 ret.RetentionErrorCode - reference list of error and warning codes (FSD 13.1) */
IF OBJECT_ID(N'ret.RetentionErrorCode', N'U') IS NULL
BEGIN
    CREATE TABLE ret.RetentionErrorCode
    (
        ErrorCode       VARCHAR(12)     NOT NULL,
        Category        NVARCHAR(50)    NOT NULL,
        Description     NVARCHAR(400)   NOT NULL,
        IsWarning       BIT             NOT NULL CONSTRAINT DF_RetentionErrorCode_IsWarning DEFAULT (0),
        CONSTRAINT PK_RetentionErrorCode PRIMARY KEY CLUSTERED (ErrorCode),
        CONSTRAINT CK_RetentionErrorCode_Format CHECK (ErrorCode LIKE 'ERR-[A-Z][A-Z][A-Z]-[0-9][0-9]')
    );
END;
GO

/* 1.2 ret.RetentionParameter - single-row global parameters (design table v0.2) */
IF OBJECT_ID(N'ret.RetentionParameter', N'U') IS NULL
BEGIN
    CREATE TABLE ret.RetentionParameter
    (
        ParameterSetId          TINYINT         NOT NULL,
        BatchSize               INT             NOT NULL CONSTRAINT DF_RetentionParameter_BatchSize     DEFAULT (10000),    -- BRQ-08
        BatchPauseSeconds       INT             NOT NULL CONSTRAINT DF_RetentionParameter_BatchPause    DEFAULT (3),        -- BRQ-08
        IcWindowStart           TIME(0)         NOT NULL CONSTRAINT DF_RetentionParameter_IcWindowStart DEFAULT ('21:00'),  -- BR-17
        IcWindowEnd             TIME(0)         NOT NULL CONSTRAINT DF_RetentionParameter_IcWindowEnd   DEFAULT ('05:00'),  -- BR-17
        DailyRoutineStartDate   DATE            NULL,                                                                       -- FR-020
        DeleteRetryCount        TINYINT         NULL,                                                                       -- NULL = no retry
        DeleteLockTimeoutMs     INT             NULL,                                                                       -- NULL = wait
        DailyNullCheckMode      VARCHAR(10)     NOT NULL CONSTRAINT DF_RetentionParameter_NullCheck     DEFAULT ('FULL'),   -- OQ-14
        ArchiveContainer        NVARCHAR(63)    NULL,                                                                       -- MD-07, D-02
        ModifiedBy              NVARCHAR(128)   NOT NULL CONSTRAINT DF_RetentionParameter_ModifiedBy    DEFAULT (ORIGINAL_LOGIN()),
        ModifiedAt              DATETIME2(3)    NOT NULL CONSTRAINT DF_RetentionParameter_ModifiedAt    DEFAULT (DATEADD(HOUR, 7, SYSUTCDATETIME())),
        CONSTRAINT PK_RetentionParameter PRIMARY KEY CLUSTERED (ParameterSetId),
        CONSTRAINT CK_RetentionParameter_SingleRow   CHECK (ParameterSetId = 1),
        CONSTRAINT CK_RetentionParameter_BatchSize   CHECK (BatchSize > 0),
        CONSTRAINT CK_RetentionParameter_BatchPause  CHECK (BatchPauseSeconds >= 0 AND BatchPauseSeconds < 86400),
        CONSTRAINT CK_RetentionParameter_LockTimeout CHECK (DeleteLockTimeoutMs IS NULL OR DeleteLockTimeoutMs >= 0),
        CONSTRAINT CK_RetentionParameter_NullCheck   CHECK (DailyNullCheckMode IN ('FULL', 'METADATA')),
        -- Container name only: 3-63 characters, lower-case letters, digits, single hyphens (MD-07)
        CONSTRAINT CK_RetentionParameter_Container   CHECK (ArchiveContainer IS NULL OR (
                   LEN(ArchiveContainer) BETWEEN 3 AND 63
               AND ArchiveContainer COLLATE Latin1_General_100_BIN2 NOT LIKE N'%[^a-z0-9-]%'
               AND ArchiveContainer NOT LIKE N'-%' AND ArchiveContainer NOT LIKE N'%-'
               AND ArchiveContainer NOT LIKE N'%--%'))
    );
END;
GO

/* 1.3 ret.RetentionConfig - central configuration (BRQ-03, design table v0.2).
       Own-dated table: RetentionColumn filled. Child table: ParentTableConfigId filled (FR-023). */
IF OBJECT_ID(N'ret.RetentionConfig', N'U') IS NULL
BEGIN
    CREATE TABLE ret.RetentionConfig
    (
        TableConfigId           INT IDENTITY(1,1) NOT NULL,
        SchemaName              SYSNAME         NOT NULL,
        TableName               SYSNAME         NOT NULL,
        RetentionColumn         SYSNAME         NULL,
        ParentTableConfigId     INT             NULL,
        DwhRetentionYears       SMALLINT        NOT NULL CONSTRAINT DF_RetentionConfig_DwhYears   DEFAULT (3),
        BlobRetentionYears      SMALLINT        NOT NULL CONSTRAINT DF_RetentionConfig_BlobYears  DEFAULT (5),
        LogRetentionYears       SMALLINT        NOT NULL CONSTRAINT DF_RetentionConfig_LogYears   DEFAULT (3),   -- MD-08
        BlobPath                NVARCHAR(400)   NOT NULL,
        InitialCutoffMethod     VARCHAR(20)     NOT NULL,
        IsActive                BIT             NOT NULL CONSTRAINT DF_RetentionConfig_IsActive   DEFAULT (1),
        SizeCategory            VARCHAR(10)     NOT NULL,
        CreatedBy               NVARCHAR(128)   NOT NULL CONSTRAINT DF_RetentionConfig_CreatedBy  DEFAULT (ORIGINAL_LOGIN()),
        CreatedAt               DATETIME2(3)    NOT NULL CONSTRAINT DF_RetentionConfig_CreatedAt  DEFAULT (DATEADD(HOUR, 7, SYSUTCDATETIME())),
        ModifiedBy              NVARCHAR(128)   NULL,
        ModifiedAt              DATETIME2(3)    NULL,
        CONSTRAINT PK_RetentionConfig PRIMARY KEY CLUSTERED (TableConfigId),
        CONSTRAINT UQ_RetentionConfig_Table    UNIQUE (SchemaName, TableName),
        CONSTRAINT UQ_RetentionConfig_BlobPath UNIQUE (BlobPath),
        CONSTRAINT FK_RetentionConfig_Parent   FOREIGN KEY (ParentTableConfigId) REFERENCES ret.RetentionConfig (TableConfigId),
        CONSTRAINT CK_RetentionConfig_DwhYears   CHECK (DwhRetentionYears >= 1),
        CONSTRAINT CK_RetentionConfig_BlobYears  CHECK (BlobRetentionYears >= 1),
        CONSTRAINT CK_RetentionConfig_LogYears   CHECK (LogRetentionYears >= 1),
        CONSTRAINT CK_RetentionConfig_Method     CHECK (InitialCutoffMethod IN ('BATCH_DELETE', 'TABLE_REBUILD')),
        CONSTRAINT CK_RetentionConfig_Size       CHECK (SizeCategory IN ('SMALL', 'MEDIUM', 'LARGE')),
        CONSTRAINT CK_RetentionConfig_DateSource CHECK ((RetentionColumn IS NOT NULL AND ParentTableConfigId IS NULL)
                                                     OR (RetentionColumn IS NULL AND ParentTableConfigId IS NOT NULL)),
        CONSTRAINT CK_RetentionConfig_NotSelf    CHECK (ParentTableConfigId IS NULL OR ParentTableConfigId <> TableConfigId),
        CONSTRAINT CK_RetentionConfig_Names      CHECK (LEN(SchemaName) > 0 AND LEN(TableName) > 0 AND (RetentionColumn IS NULL OR LEN(RetentionColumn) > 0)),
        -- <schema>.<table> in lower case, no slash or backslash (MD-07, FSD 7.2)
        CONSTRAINT CK_RetentionConfig_BlobPath   CHECK (LEN(BlobPath) > 0 AND BlobPath NOT LIKE N'%/%' AND BlobPath NOT LIKE N'%\%'
                                                     AND BlobPath COLLATE Latin1_General_100_BIN2 = LOWER(BlobPath) COLLATE Latin1_General_100_BIN2)
    );

    CREATE NONCLUSTERED INDEX IX_RetentionConfig_Parent ON ret.RetentionConfig (ParentTableConfigId) WHERE ParentTableConfigId IS NOT NULL;
END;
GO

/* 1.4 ret.RetentionParentKey - join keys between a child table and its header table (FR-023) */
IF OBJECT_ID(N'ret.RetentionParentKey', N'U') IS NULL
BEGIN
    CREATE TABLE ret.RetentionParentKey
    (
        TableConfigId   INT             NOT NULL,
        KeyOrdinal      TINYINT         NOT NULL,
        ChildColumn     SYSNAME         NOT NULL,
        ParentColumn    SYSNAME         NOT NULL,
        CreatedBy       NVARCHAR(128)   NOT NULL CONSTRAINT DF_RetentionParentKey_CreatedBy DEFAULT (ORIGINAL_LOGIN()),
        CreatedAt       DATETIME2(3)    NOT NULL CONSTRAINT DF_RetentionParentKey_CreatedAt DEFAULT (DATEADD(HOUR, 7, SYSUTCDATETIME())),
        CONSTRAINT PK_RetentionParentKey PRIMARY KEY CLUSTERED (TableConfigId, KeyOrdinal),
        CONSTRAINT UQ_RetentionParentKey_Child UNIQUE (TableConfigId, ChildColumn),
        CONSTRAINT FK_RetentionParentKey_Config FOREIGN KEY (TableConfigId) REFERENCES ret.RetentionConfig (TableConfigId) ON DELETE CASCADE,
        CONSTRAINT CK_RetentionParentKey_Ordinal CHECK (KeyOrdinal >= 1),
        CONSTRAINT CK_RetentionParentKey_Names   CHECK (LEN(ChildColumn) > 0 AND LEN(ParentColumn) > 0)
    );
END;
GO

/* 1.5 ret.RetentionRunLog - one row per execution (BRQ-12) */
IF OBJECT_ID(N'ret.RetentionRunLog', N'U') IS NULL
BEGIN
    CREATE TABLE ret.RetentionRunLog
    (
        RunId                   BIGINT IDENTITY(1,1) NOT NULL,
        AdfPipelineRunId        UNIQUEIDENTIFIER NULL,
        ProcessType             VARCHAR(20)     NOT NULL,
        RunDate                 DATE            NOT NULL,
        IsRunDateOverride       BIT             NOT NULL CONSTRAINT DF_RetentionRunLog_Override DEFAULT (0),
        TriggerType             VARCHAR(10)     NOT NULL,
        TriggeredBy             NVARCHAR(256)   NULL,
        DowntimeReference       NVARCHAR(100)   NULL,
        StartTime               DATETIME2(3)    NOT NULL CONSTRAINT DF_RetentionRunLog_StartTime DEFAULT (DATEADD(HOUR, 7, SYSUTCDATETIME())),
        EndTime                 DATETIME2(3)    NULL,
        Status                  VARCHAR(25)     NOT NULL CONSTRAINT DF_RetentionRunLog_Status DEFAULT ('RUNNING'),
        TablesSelected          INT             NULL,
        TablesSucceeded         INT             NULL,
        TablesFailed            INT             NULL,
        TablesSkipped           INT             NULL,
        ErrorCode               VARCHAR(12)     NULL,
        ErrorMessage            NVARCHAR(MAX)   NULL,
        IsClosedManually        BIT             NOT NULL CONSTRAINT DF_RetentionRunLog_ClosedManually DEFAULT (0),
        ClosedBy                NVARCHAR(128)   NULL,
        CloseComment            NVARCHAR(400)   NULL,
        CONSTRAINT PK_RetentionRunLog PRIMARY KEY CLUSTERED (RunId),
        CONSTRAINT FK_RetentionRunLog_ErrorCode FOREIGN KEY (ErrorCode) REFERENCES ret.RetentionErrorCode (ErrorCode),
        CONSTRAINT CK_RetentionRunLog_ProcessType CHECK (ProcessType IN ('INITIAL_CUTOFF', 'DAILY_ROUTINE', 'VALIDATION')),
        CONSTRAINT CK_RetentionRunLog_TriggerType CHECK (TriggerType IN ('SCHEDULE', 'MANUAL')),
        CONSTRAINT CK_RetentionRunLog_Status      CHECK (Status IN ('RUNNING', 'SUCCEEDED', 'COMPLETED_WITH_ERRORS', 'FAILED')),
        CONSTRAINT CK_RetentionRunLog_EndTime     CHECK (EndTime IS NULL OR EndTime >= StartTime),
        CONSTRAINT CK_RetentionRunLog_Closed      CHECK (Status <> 'RUNNING' OR EndTime IS NULL),
        CONSTRAINT CK_RetentionRunLog_Counters    CHECK (ISNULL(TablesSelected, 0) >= 0 AND ISNULL(TablesSucceeded, 0) >= 0
                                                         AND ISNULL(TablesFailed, 0) >= 0 AND ISNULL(TablesSkipped, 0) >= 0)
    );

    CREATE UNIQUE NONCLUSTERED INDEX UX_RetentionRunLog_AdfPipelineRunId
        ON ret.RetentionRunLog (AdfPipelineRunId) WHERE AdfPipelineRunId IS NOT NULL;

    CREATE NONCLUSTERED INDEX IX_RetentionRunLog_RunDate
        ON ret.RetentionRunLog (RunDate, ProcessType) INCLUDE (Status, StartTime, EndTime);
END;
GO

/* 1.6 ret.RetentionTableStatus - system-maintained status and blocking flags per table */
IF OBJECT_ID(N'ret.RetentionTableStatus', N'U') IS NULL
BEGIN
    CREATE TABLE ret.RetentionTableStatus
    (
        TableConfigId               INT             NOT NULL,
        InitialCutoffStatus         VARCHAR(10)     NOT NULL CONSTRAINT DF_RetentionTableStatus_Status DEFAULT ('PENDING'),
        InitialCutoffCompletionDate DATE            NULL,
        LastInitialCutoffRunId      BIGINT          NULL,
        HasOrphanFiles              BIT             NOT NULL CONSTRAINT DF_RetentionTableStatus_Orphan    DEFAULT (0),
        OrphanFilesRunId            BIGINT          NULL,
        HasIntegrityIssue           BIT             NOT NULL CONSTRAINT DF_RetentionTableStatus_Integrity DEFAULT (0),
        IntegrityIssueRunId         BIGINT          NULL,
        HasReconciliationWarning    BIT             NOT NULL CONSTRAINT DF_RetentionTableStatus_Recon     DEFAULT (0),
        ReconciliationWarningRunId  BIGINT          NULL,
        FlagComment                 NVARCHAR(400)   NULL,
        ModifiedBy                  NVARCHAR(128)   NOT NULL CONSTRAINT DF_RetentionTableStatus_ModifiedBy DEFAULT (ORIGINAL_LOGIN()),
        ModifiedAt                  DATETIME2(3)    NOT NULL CONSTRAINT DF_RetentionTableStatus_ModifiedAt DEFAULT (DATEADD(HOUR, 7, SYSUTCDATETIME())),
        CONSTRAINT PK_RetentionTableStatus PRIMARY KEY CLUSTERED (TableConfigId),
        CONSTRAINT FK_RetentionTableStatus_Config       FOREIGN KEY (TableConfigId)              REFERENCES ret.RetentionConfig (TableConfigId) ON DELETE CASCADE,
        CONSTRAINT FK_RetentionTableStatus_LastIcRun    FOREIGN KEY (LastInitialCutoffRunId)     REFERENCES ret.RetentionRunLog (RunId),
        CONSTRAINT FK_RetentionTableStatus_OrphanRun    FOREIGN KEY (OrphanFilesRunId)           REFERENCES ret.RetentionRunLog (RunId),
        CONSTRAINT FK_RetentionTableStatus_IntegrityRun FOREIGN KEY (IntegrityIssueRunId)        REFERENCES ret.RetentionRunLog (RunId),
        CONSTRAINT FK_RetentionTableStatus_ReconRun     FOREIGN KEY (ReconciliationWarningRunId) REFERENCES ret.RetentionRunLog (RunId),
        CONSTRAINT CK_RetentionTableStatus_Status CHECK (InitialCutoffStatus IN ('PENDING', 'RUNNING', 'FAILED', 'STOPPED', 'COMPLETED')),
        CONSTRAINT CK_RetentionTableStatus_Completion CHECK (
               (InitialCutoffStatus =  'COMPLETED' AND InitialCutoffCompletionDate IS NOT NULL)
            OR (InitialCutoffStatus <> 'COMPLETED' AND InitialCutoffCompletionDate IS NULL)),
        CONSTRAINT CK_RetentionTableStatus_OrphanRun    CHECK (HasOrphanFiles = 0 OR OrphanFilesRunId IS NOT NULL),
        CONSTRAINT CK_RetentionTableStatus_IntegrityRun CHECK (HasIntegrityIssue = 0 OR IntegrityIssueRunId IS NOT NULL)
    );
END;
GO

/* 1.7 ret.RetentionTableLock - table processing lock (FR-016) */
IF OBJECT_ID(N'ret.RetentionTableLock', N'U') IS NULL
BEGIN
    CREATE TABLE ret.RetentionTableLock
    (
        TableConfigId   INT             NOT NULL,
        RunId           BIGINT          NOT NULL,
        ProcessType     VARCHAR(20)     NOT NULL,
        AcquiredAt      DATETIME2(3)    NOT NULL CONSTRAINT DF_RetentionTableLock_AcquiredAt DEFAULT (DATEADD(HOUR, 7, SYSUTCDATETIME())),
        AcquiredBy      NVARCHAR(128)   NOT NULL CONSTRAINT DF_RetentionTableLock_AcquiredBy DEFAULT (ORIGINAL_LOGIN()),
        CONSTRAINT PK_RetentionTableLock PRIMARY KEY CLUSTERED (TableConfigId),
        CONSTRAINT FK_RetentionTableLock_Config FOREIGN KEY (TableConfigId) REFERENCES ret.RetentionConfig (TableConfigId),
        CONSTRAINT FK_RetentionTableLock_Run    FOREIGN KEY (RunId)         REFERENCES ret.RetentionRunLog (RunId),
        CONSTRAINT CK_RetentionTableLock_ProcessType CHECK (ProcessType IN ('INITIAL_CUTOFF', 'DAILY_ROUTINE', 'VALIDATION'))
    );
END;
GO

/* 1.8 ret.RetentionTableLog - one row per table per execution (BRD 7.4); resume control (FR-017) */
IF OBJECT_ID(N'ret.RetentionTableLog', N'U') IS NULL
BEGIN
    CREATE TABLE ret.RetentionTableLog
    (
        TableLogId              BIGINT IDENTITY(1,1) NOT NULL,
        RunId                   BIGINT          NOT NULL,
        TableConfigId           INT             NOT NULL,
        ProcessType             VARCHAR(20)     NOT NULL,
        RunDate                 DATE            NOT NULL,
        DwhCutoffDate           DATE            NULL,
        ArchiveCutoffDate       DATE            NULL,
        MethodUsed              VARCHAR(20)     NULL,
        EligibleRows            BIGINT          NULL,
        ArchivedSegmentRows     BIGINT          NULL,
        ExpiredSegmentRows      BIGINT          NULL,
        ExportDateCount         INT             NULL,
        RowsExported            BIGINT          NULL,
        PreDeleteRecount        BIGINT          NULL,
        RowsDeleted             BIGINT          NULL,
        ResumeRowsDeleted       BIGINT          NULL,
        DeleteBatchCount        INT             NULL,
        RebuildStagingTable     NVARCHAR(260)   NULL,       -- MD-06: temporary new table during the rebuild
        ArchiveFoldersDeleted   INT             NULL,
        ArchiveFilesDeleted     INT             NULL,
        RetainedRowsBefore      BIGINT          NULL,
        RetainedRowsAfter       BIGINT          NULL,
        OrphanRows              BIGINT          NULL,       -- DBR-21 child table rows without header row
        IsValidated             BIT             NOT NULL CONSTRAINT DF_RetentionTableLog_IsValidated  DEFAULT (0),
        ValidatedRangeFrom      DATE            NULL,
        ValidatedRangeTo        DATE            NULL,
        ValidatedRowCount       BIGINT          NULL,
        DeleteStatus            VARCHAR(15)     NOT NULL CONSTRAINT DF_RetentionTableLog_DeleteStatus DEFAULT ('NOT_STARTED'),
        ResumedByRunId          BIGINT          NULL,
        Status                  VARCHAR(10)     NOT NULL CONSTRAINT DF_RetentionTableLog_Status       DEFAULT ('RUNNING'),
        StartTime               DATETIME2(3)    NOT NULL CONSTRAINT DF_RetentionTableLog_StartTime    DEFAULT (DATEADD(HOUR, 7, SYSUTCDATETIME())),
        EndTime                 DATETIME2(3)    NULL,
        ErrorCode               VARCHAR(12)     NULL,
        ErrorNumber             INT             NULL,
        ErrorStep               VARCHAR(30)     NULL,
        ErrorMessage            NVARCHAR(MAX)   NULL,
        CONSTRAINT PK_RetentionTableLog PRIMARY KEY CLUSTERED (TableLogId),
        CONSTRAINT UQ_RetentionTableLog_RunTable UNIQUE (RunId, TableConfigId),
        CONSTRAINT FK_RetentionTableLog_Run       FOREIGN KEY (RunId)          REFERENCES ret.RetentionRunLog (RunId),
        CONSTRAINT FK_RetentionTableLog_Config    FOREIGN KEY (TableConfigId)  REFERENCES ret.RetentionConfig (TableConfigId),
        CONSTRAINT FK_RetentionTableLog_ResumedBy FOREIGN KEY (ResumedByRunId) REFERENCES ret.RetentionRunLog (RunId),
        CONSTRAINT FK_RetentionTableLog_ErrorCode FOREIGN KEY (ErrorCode)      REFERENCES ret.RetentionErrorCode (ErrorCode),
        CONSTRAINT CK_RetentionTableLog_ProcessType  CHECK (ProcessType IN ('INITIAL_CUTOFF', 'DAILY_ROUTINE', 'VALIDATION')),
        CONSTRAINT CK_RetentionTableLog_Method       CHECK (MethodUsed IS NULL OR MethodUsed IN ('BATCH_DELETE', 'TABLE_REBUILD')),
        CONSTRAINT CK_RetentionTableLog_Status       CHECK (Status IN ('RUNNING', 'SUCCEEDED', 'NODATA', 'FAILED', 'SKIPPED', 'STOPPED')),
        CONSTRAINT CK_RetentionTableLog_DeleteStatus CHECK (DeleteStatus IN ('NOT_STARTED', 'IN_PROGRESS', 'COMPLETED', 'FAILED', 'NOT_REQUIRED')),
        CONSTRAINT CK_RetentionTableLog_Cutoffs      CHECK (DwhCutoffDate IS NULL OR ArchiveCutoffDate IS NULL OR ArchiveCutoffDate < DwhCutoffDate),
        CONSTRAINT CK_RetentionTableLog_Range        CHECK (ValidatedRangeFrom IS NULL OR ValidatedRangeTo IS NULL OR ValidatedRangeFrom < ValidatedRangeTo),
        CONSTRAINT CK_RetentionTableLog_Validated    CHECK (IsValidated = 0 OR (ValidatedRangeTo IS NOT NULL AND ValidatedRowCount IS NOT NULL)),
        CONSTRAINT CK_RetentionTableLog_DeleteNeedsValidation CHECK (DeleteStatus IN ('NOT_STARTED', 'NOT_REQUIRED') OR IsValidated = 1),
        CONSTRAINT CK_RetentionTableLog_Counts       CHECK (
                ISNULL(EligibleRows, 0) >= 0 AND ISNULL(ArchivedSegmentRows, 0) >= 0 AND ISNULL(ExpiredSegmentRows, 0) >= 0
            AND ISNULL(RowsExported, 0) >= 0 AND ISNULL(RowsDeleted, 0) >= 0 AND ISNULL(ResumeRowsDeleted, 0) >= 0
            AND ISNULL(ValidatedRowCount, 0) >= 0 AND ISNULL(ArchiveFoldersDeleted, 0) >= 0 AND ISNULL(ArchiveFilesDeleted, 0) >= 0),
        CONSTRAINT CK_RetentionTableLog_Orphans      CHECK (OrphanRows IS NULL OR OrphanRows >= 0),
        CONSTRAINT CK_RetentionTableLog_EndTime      CHECK (EndTime IS NULL OR EndTime >= StartTime)
    );

    CREATE NONCLUSTERED INDEX IX_RetentionTableLog_Table_Latest
        ON ret.RetentionTableLog (TableConfigId, TableLogId DESC)
        INCLUDE (RunId, Status, IsValidated, DeleteStatus, ValidatedRangeFrom, ValidatedRangeTo, ValidatedRowCount, RowsDeleted);

    CREATE NONCLUSTERED INDEX IX_RetentionTableLog_PendingResume
        ON ret.RetentionTableLog (TableConfigId)
        INCLUDE (RunId, MethodUsed, ValidatedRangeFrom, ValidatedRangeTo, ValidatedRowCount, RowsDeleted)
        WHERE IsValidated = 1 AND DeleteStatus IN ('NOT_STARTED', 'IN_PROGRESS', 'FAILED');

    CREATE NONCLUSTERED INDEX IX_RetentionTableLog_RunDate
        ON ret.RetentionTableLog (RunDate, Status) INCLUDE (TableConfigId, ProcessType, ErrorCode);
END;
GO

/* 1.9 ret.RetentionArchiveDate - per business date export snapshot and result */
IF OBJECT_ID(N'ret.RetentionArchiveDate', N'U') IS NULL
BEGIN
    CREATE TABLE ret.RetentionArchiveDate
    (
        TableLogId          BIGINT          NOT NULL,
        BusinessDate        DATE            NOT NULL,
        RunId               BIGINT          NOT NULL,
        TableConfigId       INT             NOT NULL,
        ExpectedRows        BIGINT          NOT NULL,
        RowsRead            BIGINT          NULL,
        RowsWritten         BIGINT          NULL,
        FileCount           INT             NULL,
        FolderPath          NVARCHAR(1024)  NOT NULL,       -- <yyyy>/<BlobPath> (MD-07, v0.6)
        FileName            NVARCHAR(400)   NOT NULL,       -- <BlobPath>_<yyyyMMdd>.parquet (MD-07, v0.6)
        ExportStatus        VARCHAR(10)     NOT NULL CONSTRAINT DF_RetentionArchiveDate_ExportStatus DEFAULT ('PENDING'),
        ValidationResult    VARCHAR(10)     NULL,
        ExportStartTime     DATETIME2(3)    NULL,
        ExportEndTime       DATETIME2(3)    NULL,
        ErrorMessage        NVARCHAR(MAX)   NULL,
        CONSTRAINT PK_RetentionArchiveDate PRIMARY KEY CLUSTERED (TableLogId, BusinessDate),
        CONSTRAINT FK_RetentionArchiveDate_TableLog FOREIGN KEY (TableLogId)    REFERENCES ret.RetentionTableLog (TableLogId),
        CONSTRAINT FK_RetentionArchiveDate_Run      FOREIGN KEY (RunId)         REFERENCES ret.RetentionRunLog (RunId),
        CONSTRAINT FK_RetentionArchiveDate_Config   FOREIGN KEY (TableConfigId) REFERENCES ret.RetentionConfig (TableConfigId),
        CONSTRAINT CK_RetentionArchiveDate_ExportStatus CHECK (ExportStatus IN ('PENDING', 'SUCCEEDED', 'FAILED', 'STOPPED', 'REMOVED')),
        CONSTRAINT CK_RetentionArchiveDate_Validation   CHECK (ValidationResult IS NULL OR ValidationResult IN ('PASSED', 'FAILED')),
        CONSTRAINT CK_RetentionArchiveDate_Counts       CHECK (ExpectedRows >= 0 AND ISNULL(RowsRead, 0) >= 0 AND ISNULL(RowsWritten, 0) >= 0)
    );

    CREATE NONCLUSTERED INDEX IX_RetentionArchiveDate_TableDate
        ON ret.RetentionArchiveDate (TableConfigId, BusinessDate)
        INCLUDE (RunId, ExportStatus, RowsWritten, FolderPath, FileName);
END;
GO

/* 1.10 ret.RetentionStepLog - detailed step trail */
IF OBJECT_ID(N'ret.RetentionStepLog', N'U') IS NULL
BEGIN
    CREATE TABLE ret.RetentionStepLog
    (
        StepLogId               BIGINT IDENTITY(1,1) NOT NULL,
        RunId                   BIGINT          NOT NULL,
        TableLogId              BIGINT          NULL,
        TableConfigId           INT             NULL,
        StepCode                VARCHAR(30)     NOT NULL,
        ValidationCheckCode     VARCHAR(4)      NULL,
        BusinessDate            DATE            NULL,
        ExpectedRows            BIGINT          NULL,
        RowsRead                BIGINT          NULL,
        RowsWritten             BIGINT          NULL,
        FilePath                NVARCHAR(2000)  NULL,
        FileCount               INT             NULL,
        BatchCount              INT             NULL,
        RowsProcessed           BIGINT          NULL,
        ReferenceRunId          BIGINT          NULL,
        Status                  VARCHAR(10)     NOT NULL CONSTRAINT DF_RetentionStepLog_Status    DEFAULT ('RUNNING'),
        StartTime               DATETIME2(3)    NOT NULL CONSTRAINT DF_RetentionStepLog_StartTime DEFAULT (DATEADD(HOUR, 7, SYSUTCDATETIME())),
        EndTime                 DATETIME2(3)    NULL,
        Message                 NVARCHAR(4000)  NULL,
        ErrorCode               VARCHAR(12)     NULL,
        ErrorNumber             INT             NULL,
        ErrorMessage            NVARCHAR(MAX)   NULL,
        CONSTRAINT PK_RetentionStepLog PRIMARY KEY CLUSTERED (StepLogId),
        CONSTRAINT FK_RetentionStepLog_Run       FOREIGN KEY (RunId)          REFERENCES ret.RetentionRunLog (RunId),
        CONSTRAINT FK_RetentionStepLog_TableLog  FOREIGN KEY (TableLogId)     REFERENCES ret.RetentionTableLog (TableLogId),
        CONSTRAINT FK_RetentionStepLog_Config    FOREIGN KEY (TableConfigId)  REFERENCES ret.RetentionConfig (TableConfigId),
        CONSTRAINT FK_RetentionStepLog_RefRun    FOREIGN KEY (ReferenceRunId) REFERENCES ret.RetentionRunLog (RunId),
        CONSTRAINT FK_RetentionStepLog_ErrorCode FOREIGN KEY (ErrorCode)      REFERENCES ret.RetentionErrorCode (ErrorCode),
        CONSTRAINT CK_RetentionStepLog_StepCode  CHECK (StepCode IN (
            'START_RUN', 'SELECT_TABLES', 'LOCK', 'VALIDATE', 'RESUME', 'COUNT', 'EXPORT',
            'VALIDATE-ARCHIVE', 'RECOUNT', 'DELETE', 'REBUILD', 'POSTCHECK', 'CLEANUP',
            'EXPIRE', 'END_TABLE', 'END_RUN', 'ADMIN')),
        CONSTRAINT CK_RetentionStepLog_CheckCode CHECK (ValidationCheckCode IS NULL OR ValidationCheckCode LIKE 'V-[01][0-9]'),
        CONSTRAINT CK_RetentionStepLog_Status    CHECK (Status IN ('RUNNING', 'SUCCEEDED', 'FAILED', 'SKIPPED', 'STOPPED', 'WARNING')),
        CONSTRAINT CK_RetentionStepLog_EndTime   CHECK (EndTime IS NULL OR EndTime >= StartTime)
    );

    CREATE NONCLUSTERED INDEX IX_RetentionStepLog_TableLog
        ON ret.RetentionStepLog (TableLogId, StepLogId) INCLUDE (StepCode, BusinessDate, Status);

    CREATE NONCLUSTERED INDEX IX_RetentionStepLog_Run
        ON ret.RetentionStepLog (RunId, StepLogId) INCLUDE (TableConfigId, StepCode, Status);
END;
GO

/* -------------------------------------------------------------------------------------
   1.11 MIGRATION of databases where v0.2 or v0.3 objects were deployed.
        Every block runs only when the old structure is present. Review on a copy first.
   ------------------------------------------------------------------------------------- */

-- (a) v0.2: TotalRetentionYears -> BlobRetentionYears (as in v0.3)
IF COL_LENGTH(N'ret.RetentionConfig', N'TotalRetentionYears') IS NOT NULL
   AND COL_LENGTH(N'ret.RetentionConfig', N'BlobRetentionYears') IS NULL
BEGIN
    IF OBJECT_ID(N'ret.CK_RetentionConfig_TotalYears', N'C') IS NOT NULL
        ALTER TABLE ret.RetentionConfig DROP CONSTRAINT CK_RetentionConfig_TotalYears;
    IF OBJECT_ID(N'ret.DF_RetentionConfig_TotalYears', N'D') IS NOT NULL
        ALTER TABLE ret.RetentionConfig DROP CONSTRAINT DF_RetentionConfig_TotalYears;
    EXEC sp_rename N'ret.RetentionConfig.TotalRetentionYears', N'BlobRetentionYears', N'COLUMN';
    EXEC (N'UPDATE ret.RetentionConfig SET BlobRetentionYears = BlobRetentionYears - DwhRetentionYears;
            ALTER TABLE ret.RetentionConfig ADD CONSTRAINT DF_RetentionConfig_BlobYears DEFAULT (5) FOR BlobRetentionYears;
            ALTER TABLE ret.RetentionConfig ADD CONSTRAINT CK_RetentionConfig_BlobYears CHECK (BlobRetentionYears >= 1);');
END;
GO

-- (b) v0.3: drop DatabaseName (design table v0.2, FSD DV-01)
IF COL_LENGTH(N'ret.RetentionConfig', N'DatabaseName') IS NOT NULL
BEGIN
    IF OBJECT_ID(N'ret.UQ_RetentionConfig_Table', N'UQ') IS NOT NULL
        ALTER TABLE ret.RetentionConfig DROP CONSTRAINT UQ_RetentionConfig_Table;
    IF OBJECT_ID(N'ret.DF_RetentionConfig_DatabaseName', N'D') IS NOT NULL
        ALTER TABLE ret.RetentionConfig DROP CONSTRAINT DF_RetentionConfig_DatabaseName;
    IF OBJECT_ID(N'ret.CK_RetentionConfig_Names', N'C') IS NOT NULL
        ALTER TABLE ret.RetentionConfig DROP CONSTRAINT CK_RetentionConfig_Names;
    ALTER TABLE ret.RetentionConfig DROP COLUMN DatabaseName;
    ALTER TABLE ret.RetentionConfig ADD CONSTRAINT UQ_RetentionConfig_Table UNIQUE (SchemaName, TableName);
END;
GO

-- (c) v0.3: parent-dated retention columns and constraints (MD-05)
IF COL_LENGTH(N'ret.RetentionConfig', N'ParentTableConfigId') IS NULL
BEGIN
    IF OBJECT_ID(N'ret.CK_RetentionConfig_Names', N'C') IS NOT NULL
        ALTER TABLE ret.RetentionConfig DROP CONSTRAINT CK_RetentionConfig_Names;
    ALTER TABLE ret.RetentionConfig ALTER COLUMN RetentionColumn SYSNAME NULL;
    ALTER TABLE ret.RetentionConfig ADD ParentTableConfigId INT NULL;
END;
GO
IF OBJECT_ID(N'ret.FK_RetentionConfig_Parent', N'F') IS NULL
    ALTER TABLE ret.RetentionConfig ADD CONSTRAINT FK_RetentionConfig_Parent FOREIGN KEY (ParentTableConfigId) REFERENCES ret.RetentionConfig (TableConfigId);
IF OBJECT_ID(N'ret.CK_RetentionConfig_DateSource', N'C') IS NULL
    ALTER TABLE ret.RetentionConfig ADD CONSTRAINT CK_RetentionConfig_DateSource CHECK ((RetentionColumn IS NOT NULL AND ParentTableConfigId IS NULL) OR (RetentionColumn IS NULL AND ParentTableConfigId IS NOT NULL));
IF OBJECT_ID(N'ret.CK_RetentionConfig_NotSelf', N'C') IS NULL
    ALTER TABLE ret.RetentionConfig ADD CONSTRAINT CK_RetentionConfig_NotSelf CHECK (ParentTableConfigId IS NULL OR ParentTableConfigId <> TableConfigId);
IF OBJECT_ID(N'ret.CK_RetentionConfig_Names', N'C') IS NULL
    ALTER TABLE ret.RetentionConfig ADD CONSTRAINT CK_RetentionConfig_Names CHECK (LEN(SchemaName) > 0 AND LEN(TableName) > 0 AND (RetentionColumn IS NULL OR LEN(RetentionColumn) > 0));
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID(N'ret.RetentionConfig') AND name = N'IX_RetentionConfig_Parent')
    CREATE NONCLUSTERED INDEX IX_RetentionConfig_Parent ON ret.RetentionConfig (ParentTableConfigId) WHERE ParentTableConfigId IS NOT NULL;
GO

-- (d) BlobPath = <schema>.<table> in lower case without slash (MD-07 as decided 10 Nov 2026, FSD 7.2).
--     Paths of tables without any archive file and with Initial Cut-off status PENDING are converted
--     automatically ('/' -> '.', lower case). Other non-conforming paths are reported and the block stops:
--     they must be corrected manually together with their archive folders.
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE parent_object_id = OBJECT_ID(N'ret.RetentionConfig')
               AND name = N'CK_RetentionConfig_BlobPath' AND definition LIKE N'%LOWER%' AND definition LIKE N'%[%]/[%]%')
BEGIN
    UPDATE c
       SET BlobPath = LOWER(REPLACE(c.BlobPath, N'/', N'.'))
      FROM ret.RetentionConfig AS c
      LEFT JOIN ret.RetentionTableStatus AS s ON s.TableConfigId = c.TableConfigId
     WHERE (CHARINDEX(N'/', c.BlobPath) > 0
            OR c.BlobPath COLLATE Latin1_General_100_BIN2 <> LOWER(c.BlobPath) COLLATE Latin1_General_100_BIN2)
       AND ISNULL(s.InitialCutoffStatus, 'PENDING') = 'PENDING'
       AND NOT EXISTS (SELECT 1 FROM ret.RetentionArchiveDate AS a WHERE a.TableConfigId = c.TableConfigId)
       AND NOT EXISTS (SELECT 1 FROM ret.RetentionTableLog AS l WHERE l.TableConfigId = c.TableConfigId AND l.IsValidated = 1);

    IF EXISTS (SELECT 1 FROM ret.RetentionConfig
               WHERE CHARINDEX(N'/', BlobPath) > 0 OR CHARINDEX(N'\', BlobPath) > 0
                  OR BlobPath COLLATE Latin1_General_100_BIN2 <> LOWER(BlobPath) COLLATE Latin1_General_100_BIN2)
    BEGIN
        SELECT TableConfigId, SchemaName, TableName, BlobPath FROM ret.RetentionConfig
        WHERE CHARINDEX(N'/', BlobPath) > 0 OR CHARINDEX(N'\', BlobPath) > 0
           OR BlobPath COLLATE Latin1_General_100_BIN2 <> LOWER(BlobPath) COLLATE Latin1_General_100_BIN2;
        RAISERROR (N'Migration stopped: BlobPath values with a slash or upper-case letters exist for tables with archive files (MD-07). Correct them and their archive folders first.', 16, 1);
    END
    ELSE
    BEGIN
        IF OBJECT_ID(N'ret.CK_RetentionConfig_BlobPath', N'C') IS NOT NULL
            ALTER TABLE ret.RetentionConfig DROP CONSTRAINT CK_RetentionConfig_BlobPath;
        ALTER TABLE ret.RetentionConfig ADD CONSTRAINT CK_RetentionConfig_BlobPath CHECK (LEN(BlobPath) > 0 AND BlobPath NOT LIKE N'%/%' AND BlobPath NOT LIKE N'%\%'
            AND BlobPath COLLATE Latin1_General_100_BIN2 = LOWER(BlobPath) COLLATE Latin1_General_100_BIN2);
    END;
END;
GO

-- (e) v0.3 parameters not in the design table v0.2
IF COL_LENGTH(N'ret.RetentionParameter', N'TableParallelism') IS NOT NULL
BEGIN
    IF OBJECT_ID(N'ret.CK_RetentionParameter_TableParallel', N'C') IS NOT NULL ALTER TABLE ret.RetentionParameter DROP CONSTRAINT CK_RetentionParameter_TableParallel;
    IF OBJECT_ID(N'ret.DF_RetentionParameter_TableParallel', N'D') IS NOT NULL ALTER TABLE ret.RetentionParameter DROP CONSTRAINT DF_RetentionParameter_TableParallel;
    ALTER TABLE ret.RetentionParameter DROP COLUMN TableParallelism;
END;
IF COL_LENGTH(N'ret.RetentionParameter', N'ExportDateParallelism') IS NOT NULL
BEGIN
    IF OBJECT_ID(N'ret.CK_RetentionParameter_ExportParallel', N'C') IS NOT NULL ALTER TABLE ret.RetentionParameter DROP CONSTRAINT CK_RetentionParameter_ExportParallel;
    ALTER TABLE ret.RetentionParameter DROP COLUMN ExportDateParallelism;
END;
IF COL_LENGTH(N'ret.RetentionParameter', N'KeepRebuildStagingTable') IS NOT NULL
BEGIN
    IF OBJECT_ID(N'ret.DF_RetentionParameter_KeepStaging', N'D') IS NOT NULL ALTER TABLE ret.RetentionParameter DROP CONSTRAINT DF_RetentionParameter_KeepStaging;
    ALTER TABLE ret.RetentionParameter DROP COLUMN KeepRebuildStagingTable;
END;
IF OBJECT_ID(N'ret.CK_RetentionParameter_Container', N'C') IS NULL
    ALTER TABLE ret.RetentionParameter ADD CONSTRAINT CK_RetentionParameter_Container CHECK (ArchiveContainer IS NULL OR (
        LEN(ArchiveContainer) BETWEEN 3 AND 63
        AND ArchiveContainer COLLATE Latin1_General_100_BIN2 NOT LIKE N'%[^a-z0-9-]%'
        AND ArchiveContainer NOT LIKE N'-%' AND ArchiveContainer NOT LIKE N'%-' AND ArchiveContainer NOT LIKE N'%--%'));
GO

-- (f) new log column and wider validation-check code
IF COL_LENGTH(N'ret.RetentionTableLog', N'OrphanRows') IS NULL
    ALTER TABLE ret.RetentionTableLog ADD OrphanRows BIGINT NULL CONSTRAINT CK_RetentionTableLog_Orphans CHECK (OrphanRows IS NULL OR OrphanRows >= 0);
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_RetentionStepLog_CheckCode' AND definition LIKE N'%V-0[[]1-9]%')
BEGIN
    ALTER TABLE ret.RetentionStepLog DROP CONSTRAINT CK_RetentionStepLog_CheckCode;
    ALTER TABLE ret.RetentionStepLog ADD CONSTRAINT CK_RetentionStepLog_CheckCode CHECK (ValidationCheckCode IS NULL OR ValidationCheckCode LIKE 'V-[01][0-9]');
END;
GO

-- (g) v0.3 procedure replaced by usp_TableRebuildPrepare / Swap / Abort
IF OBJECT_ID(N'ret.usp_TableRebuild', N'P') IS NOT NULL
    DROP PROCEDURE ret.usp_TableRebuild;
GO

-- (h) v0.5 -> v0.6: log retention per table (MD-08, FSD 4.24)
IF COL_LENGTH(N'ret.RetentionConfig', N'LogRetentionYears') IS NULL
    ALTER TABLE ret.RetentionConfig ADD LogRetentionYears SMALLINT NOT NULL CONSTRAINT DF_RetentionConfig_LogYears DEFAULT (3);
GO
IF OBJECT_ID(N'ret.CK_RetentionConfig_LogYears', N'C') IS NULL
    ALTER TABLE ret.RetentionConfig ADD CONSTRAINT CK_RetentionConfig_LogYears CHECK (LogRetentionYears >= 1);
GO

/* =====================================================================================
   2. TRIGGERS
   ===================================================================================== */

-- 2a. New configuration row => status row PENDING (FR-001)
CREATE OR ALTER TRIGGER ret.trg_RetentionConfig_AfterInsert
ON ret.RetentionConfig
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO ret.RetentionTableStatus (TableConfigId)
    SELECT i.TableConfigId
    FROM inserted AS i
    WHERE NOT EXISTS (SELECT 1 FROM ret.RetentionTableStatus AS s WHERE s.TableConfigId = i.TableConfigId);
END;
GO

-- 2b. Audit columns and protection of identifying attributes once archiving has started (PRC-06)
CREATE OR ALTER TRIGGER ret.trg_RetentionConfig_AfterUpdate
ON ret.RetentionConfig
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF TRIGGER_NESTLEVEL(@@PROCID) > 1
        RETURN;

    IF EXISTS
    (
        SELECT 1
        FROM inserted AS i
        JOIN deleted  AS d ON d.TableConfigId = i.TableConfigId
        JOIN ret.RetentionTableStatus AS s ON s.TableConfigId = i.TableConfigId
        WHERE (   i.SchemaName <> d.SchemaName
               OR i.TableName  <> d.TableName
               OR ISNULL(i.RetentionColumn, N'') <> ISNULL(d.RetentionColumn, N'')
               OR ISNULL(i.ParentTableConfigId, -1) <> ISNULL(d.ParentTableConfigId, -1)
               OR i.BlobPath COLLATE Latin1_General_100_BIN2 <> d.BlobPath COLLATE Latin1_General_100_BIN2)
          AND (   s.InitialCutoffStatus IN ('RUNNING', 'COMPLETED')
               OR EXISTS (SELECT 1 FROM ret.RetentionTableLog AS l
                          WHERE l.TableConfigId = i.TableConfigId AND l.IsValidated = 1))
    )
    BEGIN
        ;THROW 50001, N'Schema, table, retention column, ParentTableConfigId and blob path cannot be changed after archiving has started for this table (FSD PRC-06 / OQ-22).', 1;
    END;

    UPDATE c
       SET ModifiedBy = ORIGINAL_LOGIN(),
           ModifiedAt = DATEADD(HOUR, 7, SYSUTCDATETIME())
      FROM ret.RetentionConfig AS c
      JOIN inserted AS i ON i.TableConfigId = c.TableConfigId;
END;
GO

-- 2c. Join keys of a child table cannot change once archiving has started (FR-023)
CREATE OR ALTER TRIGGER ret.trg_RetentionParentKey_Protect
ON ret.RetentionParentKey
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS
    (
        SELECT 1
        FROM (SELECT TableConfigId FROM inserted UNION SELECT TableConfigId FROM deleted) AS k
        JOIN ret.RetentionTableStatus AS s ON s.TableConfigId = k.TableConfigId
        WHERE s.InitialCutoffStatus IN ('RUNNING', 'COMPLETED')
           OR EXISTS (SELECT 1 FROM ret.RetentionTableLog AS l WHERE l.TableConfigId = k.TableConfigId AND l.IsValidated = 1)
    )
    BEGIN
        ;THROW 50002, N'Join keys of a child table cannot be changed after archiving has started for the table (FSD FR-023 / OQ-22).', 1;
    END;
END;
GO

/* =====================================================================================
   3. SEED DATA
   ===================================================================================== */
IF NOT EXISTS (SELECT 1 FROM ret.RetentionParameter WHERE ParameterSetId = 1)
    INSERT INTO ret.RetentionParameter (ParameterSetId) VALUES (1);
GO

MERGE ret.RetentionErrorCode AS t
USING (VALUES
    ('ERR-CFG-01', N'Configuration / metadata', N'V-01: configured schema or table does not exist in the current database', 0),
    ('ERR-CFG-02', N'Configuration / metadata', N'V-02: retention column does not exist', 0),
    ('ERR-CFG-03', N'Configuration / metadata', N'V-03: retention column is not date, datetime, datetime2 or smalldatetime', 0),
    ('ERR-CFG-04', N'Configuration / metadata', N'V-04: retention column contains NULL values', 0),
    ('ERR-CFG-05', N'Configuration / metadata', N'V-05: invalid retention periods (DWH, archive or log retention years < 1)', 0),
    ('ERR-CFG-06', N'Configuration / metadata', N'V-06: blob path or archive container missing or invalid', 0),
    ('ERR-CFG-07', N'Configuration / metadata', N'V-07: table not eligible for this run (inactive, completed, gates DBR-05, DBR-18, DBR-19)', 0),
    ('ERR-CFG-08', N'Configuration / metadata', N'V-08: column type or column name not supported by the Parquet format', 0),
    ('ERR-CFG-09', N'Configuration / metadata', N'V-09: orphan-file or integrity flag outstanding', 0),
    ('ERR-CFG-11', N'Configuration / child table', N'V-10: header table configuration invalid', 0),
    ('ERR-CFG-12', N'Configuration / child table', N'V-11: join key not unique in the header table', 0),
    ('ERR-PAR-01', N'Child table',              N'Orphan child rows found (no header row); rows kept (DBR-21)', 1),
    ('ERR-LCK-01', N'Concurrency',              N'Table or its header table locked by another run', 0),
    ('ERR-SYS-01', N'Database / connectivity',  N'Query, procedure or connection failure', 0),
    ('ERR-SYS-02', N'Run date',                 N'Run date later than the current UTC+7 date', 0),
    ('ERR-EXP-01', N'Export',                   N'Copy activity failed after retries', 0),
    ('ERR-EXP-02', N'Export',                   N'Archive file for this table and business date may already exist from an earlier run (decision D-1): date refused, table FAILED, manual handling', 0),
    ('ERR-EXP-03', N'Export cleanup',           N'Files written by the failed run could not be removed (orphan files)', 0),
    ('ERR-VAL-01', N'Validation',               N'Per-date or total row-count mismatch between DWH and Parquet', 0),
    ('ERR-VAL-02', N'Validation',               N'Recount differs from the validated total', 0),
    ('ERR-VAL-03', N'Integrity',                N'Resume: remaining rows in validated range exceed the expected count', 0),
    ('ERR-DEL-01', N'Deletion',                 N'Batch delete failed after retries', 0),
    ('ERR-DEL-02', N'Post-check',               N'Rows older than the DWH cut-off remain, or retained rows were lost', 0),
    ('ERR-DEL-03', N'Reconciliation',           N'Deleted total differs from validated total', 1),
    ('ERR-RBD-01', N'Table rebuild',            N'Failure before truncation (RB-01..RB-05); new table dropped, original unchanged', 0),
    ('ERR-RBD-02', N'Table rebuild',            N'Failure inside the truncate, drop and rename transaction (RB-08); rolled back', 0),
    ('ERR-RBD-03', N'Table rebuild',            N'Failure after commit (RB-09, RB-10); DBA procedure required', 0),
    ('ERR-RBD-04', N'Table rebuild',            N'Table not supported for rebuild (RB-01)', 0),
    ('ERR-ARC-01', N'Expired archive deletion', N'Listing or deletion of expired archive folders failed', 0),
    ('ERR-WIN-01', N'Window',                   N'Initial Cut-off Run window end reached; processing stopped', 0)
) AS s (ErrorCode, Category, Description, IsWarning)
ON t.ErrorCode = s.ErrorCode
WHEN MATCHED AND (t.Category <> s.Category OR t.Description <> s.Description OR t.IsWarning <> s.IsWarning)
    THEN UPDATE SET Category = s.Category, Description = s.Description, IsWarning = s.IsWarning
WHEN NOT MATCHED BY TARGET
    THEN INSERT (ErrorCode, Category, Description, IsWarning) VALUES (s.ErrorCode, s.Category, s.Description, s.IsWarning);
GO

-- ERR-CFG-10 (v0.3, database mismatch) is obsolete without the DatabaseName column
DELETE e FROM ret.RetentionErrorCode AS e
WHERE e.ErrorCode = 'ERR-CFG-10'
  AND NOT EXISTS (SELECT 1 FROM ret.RetentionTableLog WHERE ErrorCode = e.ErrorCode)
  AND NOT EXISTS (SELECT 1 FROM ret.RetentionStepLog  WHERE ErrorCode = e.ErrorCode)
  AND NOT EXISTS (SELECT 1 FROM ret.RetentionRunLog   WHERE ErrorCode = e.ErrorCode);
GO

/* =====================================================================================
   4. FUNCTIONS (design table v0.2)
   ===================================================================================== */

-- Current date-time in UTC+7 (BR-04). Azure SQL Database runs in UTC; WIB has no DST.
CREATE OR ALTER FUNCTION ret.fn_NowUtc7 ()
RETURNS DATETIME2(3)
AS
BEGIN
    RETURN CONVERT(DATETIME2(3), DATEADD(HOUR, 7, SYSUTCDATETIME()));
END;
GO

CREATE OR ALTER FUNCTION ret.fn_TodayUtc7 ()
RETURNS DATE
AS
BEGIN
    RETURN CONVERT(DATE, DATEADD(HOUR, 7, SYSUTCDATETIME()));
END;
GO

-- Cut-off dates (BR-03): total = DWH + Blob years; e.g. 2026-10-27, 3 + 5 -> 2023-10-27 / 2018-10-27
CREATE OR ALTER FUNCTION ret.fn_GetCutoffDates
(
    @RunDate                DATE,
    @DwhRetentionYears      SMALLINT,
    @BlobRetentionYears     SMALLINT
)
RETURNS TABLE
AS
RETURN
    SELECT CONVERT(SMALLINT, @DwhRetentionYears + @BlobRetentionYears)              AS TotalRetentionYears,
           DATEADD(YEAR, -@DwhRetentionYears, @RunDate)                              AS DwhCutoffDate,
           DATEADD(YEAR, -(@DwhRetentionYears + @BlobRetentionYears), @RunDate)      AS ArchiveCutoffDate;
GO

-- Window that may cross midnight (BR-17: 21:00 - 05:00)
CREATE OR ALTER FUNCTION ret.fn_IsWithinWindow
(
    @Time           TIME(0),
    @WindowStart    TIME(0),
    @WindowEnd      TIME(0)
)
RETURNS BIT
AS
BEGIN
    RETURN CASE
        WHEN @Time IS NULL OR @WindowStart IS NULL OR @WindowEnd IS NULL THEN CAST(0 AS BIT)
        WHEN @WindowStart = @WindowEnd THEN CAST(1 AS BIT)
        WHEN @WindowStart < @WindowEnd
            THEN CASE WHEN @Time >= @WindowStart AND @Time < @WindowEnd THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END
        ELSE CASE WHEN @Time >= @WindowStart OR @Time < @WindowEnd THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END
    END;
END;
GO

-- Archive folder <yyyy>/<BlobPath> (MD-07, FSD 4.7): one folder per year of the business date, then one per table
CREATE OR ALTER FUNCTION ret.fn_ArchiveFolderPath
(
    @BlobPath       NVARCHAR(400),
    @BusinessDate   DATE
)
RETURNS NVARCHAR(1024)
AS
BEGIN
    RETURN CONVERT(NCHAR(4), YEAR(@BusinessDate)) + N'/' + @BlobPath;
END;
GO

-- Archive file name <BlobPath>_<yyyyMMdd>.parquet (MD-07, FSD 4.7). The RunId is recorded in
-- ret.RetentionArchiveDate; an existing file of an earlier run is never overwritten (decision D-1).
CREATE OR ALTER FUNCTION ret.fn_ArchiveFileName
(
    @BlobPath       NVARCHAR(400),
    @BusinessDate   DATE
)
RETURNS NVARCHAR(400)
AS
BEGIN
    RETURN @BlobPath + N'_' + CONVERT(NCHAR(8), @BusinessDate, 112) + N'.parquet';
END;
GO

-- Seconds -> 'hh:mm:ss' for WAITFOR DELAY
CREATE OR ALTER FUNCTION ret.fn_DelayString (@Seconds INT)
RETURNS CHAR(8)
AS
BEGIN
    RETURN CONVERT(CHAR(8), DATEADD(SECOND, ISNULL(@Seconds, 0), CAST('00:00:00' AS TIME(0))), 108);
END;
GO

-- Column data type as T-SQL text (used to script the new table of a rebuild, RB-02)
CREATE OR ALTER FUNCTION ret.fn_ColumnTypeSql
(
    @UserTypeId INT,
    @MaxLength  SMALLINT,
    @Precision  TINYINT,
    @Scale      TINYINT
)
RETURNS NVARCHAR(300)
AS
BEGIN
    DECLARE @Name SYSNAME, @SchemaName SYSNAME, @IsUserDefined BIT;

    SELECT @Name = t.name COLLATE DATABASE_DEFAULT, @SchemaName = SCHEMA_NAME(t.schema_id), @IsUserDefined = t.is_user_defined
    FROM sys.types AS t
    WHERE t.user_type_id = @UserTypeId;

    IF @IsUserDefined = 1
        RETURN QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@Name);

    RETURN @Name + CASE
        WHEN @Name IN (N'varchar', N'char', N'varbinary', N'binary')
            THEN N'(' + CASE WHEN @MaxLength = -1 THEN N'MAX' ELSE CONVERT(NVARCHAR(10), @MaxLength) END + N')'
        WHEN @Name IN (N'nvarchar', N'nchar')
            THEN N'(' + CASE WHEN @MaxLength = -1 THEN N'MAX' ELSE CONVERT(NVARCHAR(10), @MaxLength / 2) END + N')'
        WHEN @Name IN (N'decimal', N'numeric') THEN CONCAT(N'(', @Precision, N', ', @Scale, N')')
        WHEN @Name IN (N'datetime2', N'time', N'datetimeoffset') THEN CONCAT(N'(', @Scale, N')')
        WHEN @Name = N'float' THEN CONCAT(N'(', @Precision, N')')
        ELSE N''
    END;
END;
GO

-- Text description of a table definition (columns, indexes, constraints, triggers, permissions).
-- Compared before and after the rebuild (RB-10). Object IDs are not part of the text.
CREATE OR ALTER FUNCTION ret.fn_TableDefinitionText (@ObjectId INT)
RETURNS NVARCHAR(MAX)
AS
BEGIN
    DECLARE @Cols NVARCHAR(MAX), @Idx NVARCHAR(MAX), @Chk NVARCHAR(MAX), @Def NVARCHAR(MAX),
            @Fk NVARCHAR(MAX), @Trg NVARCHAR(MAX), @Perm NVARCHAR(MAX);

    SELECT @Cols = STRING_AGG(CONVERT(NVARCHAR(MAX), CONCAT(c.name COLLATE DATABASE_DEFAULT, N'|', TYPE_NAME(c.user_type_id), N'|', c.max_length, N'|',
                   c.precision, N'|', c.scale, N'|', c.is_nullable, N'|', c.collation_name COLLATE DATABASE_DEFAULT, N'|', c.is_identity, N'|',
                   cc.definition COLLATE DATABASE_DEFAULT, N'|', cc.is_persisted)) COLLATE DATABASE_DEFAULT, N';') WITHIN GROUP (ORDER BY c.column_id)
    FROM sys.columns AS c
    LEFT JOIN sys.computed_columns AS cc ON cc.object_id = c.object_id AND cc.column_id = c.column_id
    WHERE c.object_id = @ObjectId;

    SELECT @Idx = STRING_AGG(CONVERT(NVARCHAR(MAX), CONCAT(i.name COLLATE DATABASE_DEFAULT, N'|', i.type, N'|', i.is_unique, N'|', i.is_primary_key, N'|',
                  i.is_unique_constraint, N'|', i.filter_definition COLLATE DATABASE_DEFAULT, N'|', i.is_disabled, N'|', i.fill_factor, N'|',
                  i.ignore_dup_key, N'|', k.Cols, N'|', pz.Compression)) COLLATE DATABASE_DEFAULT, N';') WITHIN GROUP (ORDER BY i.type, i.name COLLATE DATABASE_DEFAULT)
    FROM sys.indexes AS i
    OUTER APPLY (SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), CONCAT(c.name COLLATE DATABASE_DEFAULT, CASE WHEN ic.is_descending_key = 1 THEN N' DESC' END,
                        CASE WHEN ic.is_included_column = 1 THEN N' INCLUDE' END)) COLLATE DATABASE_DEFAULT, N',') WITHIN GROUP (ORDER BY ic.key_ordinal, ic.index_column_id) AS Cols
                 FROM sys.index_columns AS ic
                 JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                 WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id) AS k
    OUTER APPLY (SELECT MIN(p.data_compression_desc COLLATE DATABASE_DEFAULT) AS Compression
                 FROM sys.partitions AS p WHERE p.object_id = i.object_id AND p.index_id = i.index_id) AS pz
    WHERE i.object_id = @ObjectId;

    SELECT @Chk = STRING_AGG(CONVERT(NVARCHAR(MAX), CONCAT(ck.name COLLATE DATABASE_DEFAULT, N'|', ck.definition COLLATE DATABASE_DEFAULT, N'|', ck.is_disabled, N'|', ck.is_not_trusted)) COLLATE DATABASE_DEFAULT, N';')
                  WITHIN GROUP (ORDER BY ck.name COLLATE DATABASE_DEFAULT)
    FROM sys.check_constraints AS ck
    WHERE ck.parent_object_id = @ObjectId;

    SELECT @Def = STRING_AGG(CONVERT(NVARCHAR(MAX), CONCAT(dc.name COLLATE DATABASE_DEFAULT, N'|', c.name COLLATE DATABASE_DEFAULT, N'|', dc.definition COLLATE DATABASE_DEFAULT)), N';') WITHIN GROUP (ORDER BY dc.name COLLATE DATABASE_DEFAULT)
    FROM sys.default_constraints AS dc
    JOIN sys.columns AS c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id
    WHERE dc.parent_object_id = @ObjectId;

    SELECT @Fk = STRING_AGG(CONVERT(NVARCHAR(MAX), CONCAT(fk.name COLLATE DATABASE_DEFAULT, N'|', OBJECT_SCHEMA_NAME(fk.referenced_object_id), N'.',
                 OBJECT_NAME(fk.referenced_object_id), N'|', fk.delete_referential_action, N'|', fk.update_referential_action, N'|',
                 fk.is_disabled, N'|', fk.is_not_trusted, N'|', fc.Cols)) COLLATE DATABASE_DEFAULT, N';') WITHIN GROUP (ORDER BY fk.name COLLATE DATABASE_DEFAULT)
    FROM sys.foreign_keys AS fk
    OUTER APPLY (SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), CONCAT(COL_NAME(x.parent_object_id, x.parent_column_id), N'>',
                        COL_NAME(x.referenced_object_id, x.referenced_column_id))) COLLATE DATABASE_DEFAULT, N',') WITHIN GROUP (ORDER BY x.constraint_column_id) AS Cols
                 FROM sys.foreign_key_columns AS x WHERE x.constraint_object_id = fk.object_id) AS fc
    WHERE fk.parent_object_id = @ObjectId;

    SELECT @Trg = STRING_AGG(CONVERT(NVARCHAR(MAX), CONCAT(tr.name COLLATE DATABASE_DEFAULT, N'|', tr.is_disabled, N'|', tr.is_instead_of_trigger)) COLLATE DATABASE_DEFAULT, N';')
                  WITHIN GROUP (ORDER BY tr.name COLLATE DATABASE_DEFAULT)
    FROM sys.triggers AS tr
    WHERE tr.parent_id = @ObjectId;

    SELECT @Perm = STRING_AGG(CONVERT(NVARCHAR(MAX), CONCAT(dp.state_desc COLLATE DATABASE_DEFAULT, N'|', dp.permission_name COLLATE DATABASE_DEFAULT, N'|', USER_NAME(dp.grantee_principal_id),
                   N'|', COL_NAME(dp.major_id, NULLIF(dp.minor_id, 0)))) COLLATE DATABASE_DEFAULT, N';')
                   WITHIN GROUP (ORDER BY dp.state_desc COLLATE DATABASE_DEFAULT, dp.permission_name COLLATE DATABASE_DEFAULT, dp.grantee_principal_id, dp.minor_id)
    FROM sys.database_permissions AS dp
    WHERE dp.class = 1 AND dp.major_id = @ObjectId;

    RETURN CONCAT(N'COLUMNS:', @Cols, N'#INDEXES:', @Idx, N'#CHECKS:', @Chk, N'#DEFAULTS:', @Def,
                  N'#FK:', @Fk, N'#TRIGGERS:', @Trg, N'#PERMISSIONS:', @Perm);
END;
GO

/* =====================================================================================
   5. INTERNAL HELPER PROCEDURES (not granted to the ADF identity)
   ===================================================================================== */

-- 5.1 Write one step-log record (completed step unless @Status = 'RUNNING')
CREATE OR ALTER PROCEDURE ret.usp_WriteStepLog
    @RunId                  BIGINT,
    @StepCode               VARCHAR(30),
    @Status                 VARCHAR(10),
    @TableLogId             BIGINT          = NULL,
    @TableConfigId          INT             = NULL,
    @StartTime              DATETIME2(3)    = NULL,
    @Message                NVARCHAR(4000)  = NULL,
    @ValidationCheckCode    VARCHAR(4)      = NULL,
    @BusinessDate           DATE            = NULL,
    @ExpectedRows           BIGINT          = NULL,
    @RowsRead               BIGINT          = NULL,
    @RowsWritten            BIGINT          = NULL,
    @FilePath               NVARCHAR(2000)  = NULL,
    @FileCount              INT             = NULL,
    @BatchCount             INT             = NULL,
    @RowsProcessed          BIGINT          = NULL,
    @ReferenceRunId         BIGINT          = NULL,
    @ErrorCode              VARCHAR(12)     = NULL,
    @ErrorNumber            INT             = NULL,
    @ErrorMessage           NVARCHAR(MAX)   = NULL,
    @StepLogId              BIGINT          = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Now DATETIME2(3) = ret.fn_NowUtc7();
    DECLARE @StepStart DATETIME2(3) = CASE WHEN @StartTime IS NULL OR @StartTime > @Now THEN @Now ELSE @StartTime END;

    INSERT INTO ret.RetentionStepLog
        (RunId, TableLogId, TableConfigId, StepCode, ValidationCheckCode, BusinessDate,
         ExpectedRows, RowsRead, RowsWritten, FilePath, FileCount, BatchCount, RowsProcessed,
         ReferenceRunId, Status, StartTime, EndTime, Message, ErrorCode, ErrorNumber, ErrorMessage)
    VALUES
        (@RunId, @TableLogId, @TableConfigId, @StepCode, @ValidationCheckCode, @BusinessDate,
         @ExpectedRows, @RowsRead, @RowsWritten, @FilePath, @FileCount, @BatchCount, @RowsProcessed,
         @ReferenceRunId, @Status, @StepStart, CASE WHEN @Status = 'RUNNING' THEN NULL ELSE @Now END,
         @Message, @ErrorCode, @ErrorNumber, @ErrorMessage);

    SET @StepLogId = SCOPE_IDENTITY();
END;
GO

-- 5.2 Record an error or warning on a table log. The first non-warning code is kept; messages
--     are appended. @NewStatus NULL = status unchanged (warnings).
CREATE OR ALTER PROCEDURE ret.usp_SetTableError
    @TableLogId     BIGINT,
    @ErrorCode      VARCHAR(12),
    @ErrorStep      VARCHAR(30)     = NULL,
    @ErrorMessage   NVARCHAR(MAX)   = NULL,
    @ErrorNumber    INT             = NULL,
    @NewStatus      VARCHAR(10)     = 'FAILED'
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @NewIsWarning BIT = ISNULL((SELECT IsWarning FROM ret.RetentionErrorCode WHERE ErrorCode = @ErrorCode), 0);
    DECLARE @CurrentCode VARCHAR(12), @CurrentIsWarning BIT, @Replace BIT;

    SELECT @CurrentCode = l.ErrorCode, @CurrentIsWarning = ISNULL(e.IsWarning, 0)
    FROM ret.RetentionTableLog AS l
    LEFT JOIN ret.RetentionErrorCode AS e ON e.ErrorCode = l.ErrorCode
    WHERE l.TableLogId = @TableLogId;

    SET @Replace = CASE WHEN @CurrentCode IS NULL THEN 1
                        WHEN @CurrentIsWarning = 1 AND @NewIsWarning = 0 THEN 1
                        ELSE 0 END;

    UPDATE ret.RetentionTableLog
       SET Status = CASE
                        WHEN @NewStatus IS NULL THEN Status
                        WHEN Status IN ('FAILED', 'SKIPPED') THEN Status
                        WHEN Status = 'STOPPED' AND @NewStatus <> 'FAILED' THEN Status
                        ELSE @NewStatus
                    END,
           ErrorCode    = CASE WHEN @Replace = 1 THEN @ErrorCode   ELSE ErrorCode   END,
           ErrorNumber  = CASE WHEN @Replace = 1 THEN @ErrorNumber ELSE ErrorNumber END,
           ErrorStep    = CASE WHEN @Replace = 1 THEN @ErrorStep   ELSE ErrorStep   END,
           ErrorMessage = CASE WHEN ErrorMessage IS NULL
                               THEN CONCAT(N'[', @ErrorCode, N'] ', @ErrorMessage)
                               ELSE CONCAT(ErrorMessage, N' | [', @ErrorCode, N'] ', @ErrorMessage) END
     WHERE TableLogId = @TableLogId;
END;
GO

/* 5.3 ret.usp_GetTableSqlParts - SQL fragments for one configured table (FR-023, MD-05).
       Own-dated table : date expression t.<RetentionColumn>, FROM <table> AS t.
       Child table     : date expression p.<header RetentionColumn>,
                         FROM <child> AS t LEFT JOIN <header> AS p ON p.<ParentColumn> = t.<ChildColumn> AND ...
       With V-11 (unique join key in the header) the join never multiplies child rows. Predicates
       built by the callers:
         eligible : <DateExpr> < @Upper [AND <DateExpr> >= @Lower]
         retained : (<DateExpr> >= @Upper OR <DateExpr> IS NULL)   -- NULL = orphan child row (DBR-21)
       Also checks V-01 (table exists), V-10 (header configuration) and V-11 (@CheckUniqueness:
       0 = no check, 1 = unique index covering the join key or duplicate count, 2 = duplicate count always).
       Runs in the caller's security context (callers use EXECUTE AS OWNER). */
CREATE OR ALTER PROCEDURE ret.usp_GetTableSqlParts
    @TableConfigId          INT,
    @CheckUniqueness        TINYINT         = 0,
    @IsChild                BIT             = NULL OUTPUT,
    @FullName               NVARCHAR(300)   = NULL OUTPUT,
    @ObjectId               INT             = NULL OUTPUT,
    @DateTableFullName      NVARCHAR(300)   = NULL OUTPUT,
    @DateTableObjectId      INT             = NULL OUTPUT,
    @DateColumn             SYSNAME         = NULL OUTPUT,
    @DateExpr               NVARCHAR(400)   = NULL OUTPUT,
    @JoinSql                NVARCHAR(MAX)   = NULL OUTPUT,
    @FromSql                NVARCHAR(MAX)   = NULL OUTPUT,
    @OrphanExpr             NVARCHAR(400)   = NULL OUTPUT,
    @ParentTableConfigId    INT             = NULL OUTPUT,
    @ErrorCode              VARCHAR(12)     = NULL OUTPUT,
    @CheckCode              VARCHAR(4)      = NULL OUTPUT,
    @ErrorMessage           NVARCHAR(4000)  = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @SchemaName SYSNAME, @TableName SYSNAME, @Col SYSNAME, @DwhYears SMALLINT, @BlobYears SMALLINT,
            @PSchema SYSNAME, @PTable SYSNAME, @PCol SYSNAME, @PParent INT, @PActive BIT, @PDwh SMALLINT, @PBlob SMALLINT,
            @KeyCount INT, @On NVARCHAR(MAX), @FirstPCol SYSNAME, @Bad NVARCHAR(MAX), @KeyList NVARCHAR(MAX),
            @Dup BIGINT, @sql NVARCHAR(MAX);

    SELECT @IsChild = NULL, @FullName = NULL, @ObjectId = NULL, @DateTableFullName = NULL, @DateTableObjectId = NULL,
           @DateColumn = NULL, @DateExpr = NULL, @JoinSql = NULL, @FromSql = NULL, @OrphanExpr = NULL,
           @ErrorCode = NULL, @CheckCode = NULL, @ErrorMessage = NULL;

    SELECT @SchemaName = SchemaName, @TableName = TableName, @Col = RetentionColumn, @ParentTableConfigId = ParentTableConfigId,
           @DwhYears = DwhRetentionYears, @BlobYears = BlobRetentionYears
    FROM ret.RetentionConfig
    WHERE TableConfigId = @TableConfigId;

    IF @SchemaName IS NULL
    BEGIN
        ;THROW 50401, N'TableConfigId not found.', 1;
    END;

    SET @IsChild  = CASE WHEN @ParentTableConfigId IS NULL THEN 0 ELSE 1 END;
    SET @FullName = QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@TableName);
    SET @ObjectId = OBJECT_ID(@FullName, N'U');

    IF @ObjectId IS NULL
    BEGIN
        SELECT @ErrorCode = 'ERR-CFG-01', @CheckCode = 'V-01',
               @ErrorMessage = CONCAT(N'Table ', @FullName, N' does not exist in the current database.');
        RETURN;
    END;

    IF @IsChild = 0
    BEGIN
        SELECT @DateTableFullName = @FullName, @DateTableObjectId = @ObjectId, @DateColumn = @Col,
               @DateExpr = N't.' + QUOTENAME(@Col), @JoinSql = N'',
               @FromSql = N' FROM ' + @FullName + N' AS t', @OrphanExpr = N'1 = 0';
        RETURN;
    END;

    /* ---- V-10 header configuration (DBR-20) ---- */
    SELECT @PSchema = SchemaName, @PTable = TableName, @PCol = RetentionColumn, @PParent = ParentTableConfigId,
           @PActive = IsActive, @PDwh = DwhRetentionYears, @PBlob = BlobRetentionYears
    FROM ret.RetentionConfig
    WHERE TableConfigId = @ParentTableConfigId;

    SELECT @KeyCount = COUNT(*) FROM ret.RetentionParentKey WHERE TableConfigId = @TableConfigId;

    SET @ErrorMessage = CASE
        WHEN @PSchema IS NULL THEN N'Header table configuration not found.'
        WHEN @PParent IS NOT NULL OR @PCol IS NULL
            THEN N'Header table must have its own retention column; only one level is supported (DBR-20).'
        WHEN EXISTS (SELECT 1 FROM ret.RetentionConfig WHERE ParentTableConfigId = @TableConfigId)
            THEN N'Table is the header of another table and cannot be a child table itself (DBR-20).'
        WHEN @PActive = 0 THEN N'Header table configuration is inactive.'
        WHEN @PDwh <> @DwhYears OR @PBlob <> @BlobYears
            THEN CONCAT(N'Retention years (', @DwhYears, N' + ', @BlobYears, N') differ from the header table (', @PDwh, N' + ', @PBlob, N') (DBR-20).')
        WHEN @KeyCount = 0 THEN N'No join keys in ret.RetentionParentKey.'
    END;

    IF @ErrorMessage IS NULL
    BEGIN
        SET @DateTableFullName = QUOTENAME(@PSchema) + N'.' + QUOTENAME(@PTable);
        SET @DateTableObjectId = OBJECT_ID(@DateTableFullName, N'U');
        SET @DateColumn        = @PCol;

        IF @DateTableObjectId IS NULL
            SET @ErrorMessage = CONCAT(N'Header table ', @DateTableFullName, N' does not exist in the current database.');
        ELSE IF @DateTableObjectId = @ObjectId
            SET @ErrorMessage = N'Header table and child table are the same table.';
    END;

    IF @ErrorMessage IS NULL
    BEGIN
        SELECT @Bad = STRING_AGG(CONVERT(NVARCHAR(MAX), CONCAT(k.ChildColumn, N' = ', k.ParentColumn, N' (', x.Problem, N')')) COLLATE DATABASE_DEFAULT, N'; ')
        FROM ret.RetentionParentKey AS k
        LEFT JOIN sys.columns AS cc ON cc.object_id = @ObjectId          AND cc.name COLLATE DATABASE_DEFAULT = k.ChildColumn
        LEFT JOIN sys.columns AS pc ON pc.object_id = @DateTableObjectId AND pc.name COLLATE DATABASE_DEFAULT = k.ParentColumn
        CROSS APPLY (SELECT CASE
            WHEN cc.column_id IS NULL THEN N'child column not found'
            WHEN pc.column_id IS NULL THEN N'header column not found'
            WHEN CASE WHEN TYPE_NAME(cc.system_type_id) IN ('char', 'varchar', 'nchar', 'nvarchar') THEN 'STRING'
                      WHEN TYPE_NAME(cc.system_type_id) IN ('tinyint', 'smallint', 'int', 'bigint') THEN 'INTEGER'
                      WHEN TYPE_NAME(cc.system_type_id) IN ('decimal', 'numeric') THEN 'DECIMAL'
                      ELSE TYPE_NAME(cc.system_type_id) END
              <> CASE WHEN TYPE_NAME(pc.system_type_id) IN ('char', 'varchar', 'nchar', 'nvarchar') THEN 'STRING'
                      WHEN TYPE_NAME(pc.system_type_id) IN ('tinyint', 'smallint', 'int', 'bigint') THEN 'INTEGER'
                      WHEN TYPE_NAME(pc.system_type_id) IN ('decimal', 'numeric') THEN 'DECIMAL'
                      ELSE TYPE_NAME(pc.system_type_id) END
                THEN CONCAT(N'incompatible types ', TYPE_NAME(cc.system_type_id), N' / ', TYPE_NAME(pc.system_type_id))
            WHEN ISNULL(cc.collation_name COLLATE DATABASE_DEFAULT, N'') <> ISNULL(pc.collation_name COLLATE DATABASE_DEFAULT, N'')
                THEN CONCAT(N'different collations ', cc.collation_name COLLATE DATABASE_DEFAULT, N' / ', pc.collation_name COLLATE DATABASE_DEFAULT)
            END AS Problem) AS x
        WHERE k.TableConfigId = @TableConfigId
          AND x.Problem IS NOT NULL;

        IF @Bad IS NOT NULL
            SET @ErrorMessage = LEFT(CONCAT(N'Invalid join keys: ', @Bad), 4000);
    END;

    IF @ErrorMessage IS NOT NULL
    BEGIN
        SELECT @ErrorCode = 'ERR-CFG-11', @CheckCode = 'V-10';
        RETURN;
    END;

    SELECT @On = STRING_AGG(CONVERT(NVARCHAR(MAX), N'p.' + QUOTENAME(ParentColumn) + N' = t.' + QUOTENAME(ChildColumn)) COLLATE DATABASE_DEFAULT, N' AND ')
                 WITHIN GROUP (ORDER BY KeyOrdinal),
           @KeyList = STRING_AGG(CONVERT(NVARCHAR(MAX), QUOTENAME(ParentColumn)) COLLATE DATABASE_DEFAULT, N', ') WITHIN GROUP (ORDER BY KeyOrdinal)
    FROM ret.RetentionParentKey
    WHERE TableConfigId = @TableConfigId;

    SELECT TOP (1) @FirstPCol = ParentColumn
    FROM ret.RetentionParentKey
    WHERE TableConfigId = @TableConfigId
    ORDER BY KeyOrdinal;

    SELECT @DateExpr   = N'p.' + QUOTENAME(@PCol),
           @JoinSql    = N' LEFT JOIN ' + @DateTableFullName + N' AS p ON ' + @On,
           @OrphanExpr = N'p.' + QUOTENAME(@FirstPCol) + N' IS NULL';
    SET @FromSql = N' FROM ' + @FullName + N' AS t' + @JoinSql;

    /* ---- V-11 join key unique in the header table ---- */
    IF @CheckUniqueness = 2
       OR (@CheckUniqueness = 1
       AND NOT EXISTS (SELECT 1
                       FROM sys.indexes AS i
                       WHERE i.object_id = @DateTableObjectId AND i.is_unique = 1 AND i.has_filter = 0
                         AND i.is_disabled = 0 AND i.is_hypothetical = 0
                         AND NOT EXISTS (SELECT 1
                                         FROM sys.index_columns AS ic
                                         JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                                         WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.key_ordinal > 0
                                           AND NOT EXISTS (SELECT 1 FROM ret.RetentionParentKey AS k
                                                           WHERE k.TableConfigId = @TableConfigId
                                                             AND k.ParentColumn = c.name COLLATE DATABASE_DEFAULT))))
    BEGIN
        -- Duplicate count on the join key (full scan of the header table)
        SET @sql = N'SELECT @d = COUNT_BIG(*) FROM (SELECT TOP (1) 1 AS x FROM ' + @DateTableFullName
                 + N' GROUP BY ' + @KeyList + N' HAVING COUNT_BIG(*) > 1) AS q;';
        EXEC sp_executesql @sql, N'@d BIGINT OUTPUT', @d = @Dup OUTPUT;

        IF @Dup > 0
            SELECT @ErrorCode = 'ERR-CFG-12', @CheckCode = 'V-11',
                   @ErrorMessage = CONCAT(N'Join key (', @KeyList, N') is not unique in header table ', @DateTableFullName,
                                          N'; child rows would be counted more than once.');
    END;
END;
GO

/* =====================================================================================
   6. MAIN STORED PROCEDURES
   ===================================================================================== */

/* 6.1 ret.usp_StartRun - create the run record and fix the run date (FR-003, DBR-02).
       @RunDate NULL = today UTC+7; a later date is rejected (ERR-SYS-02). Idempotent per ADF run ID. */
CREATE OR ALTER PROCEDURE ret.usp_StartRun
    @ProcessType        VARCHAR(20),
    @TriggerType        VARCHAR(10)         = 'SCHEDULE',
    @AdfPipelineRunId   UNIQUEIDENTIFIER    = NULL,
    @RunDate            DATE                = NULL,
    @TriggeredBy        NVARCHAR(256)       = NULL,
    @DowntimeReference  NVARCHAR(100)       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Now DATETIME2(3) = ret.fn_NowUtc7();
    DECLARE @Today DATE = CONVERT(DATE, @Now);
    DECLARE @RunId BIGINT, @Msg NVARCHAR(2048);

    IF @ProcessType IS NULL OR @ProcessType NOT IN ('INITIAL_CUTOFF', 'DAILY_ROUTINE', 'VALIDATION')
    BEGIN
        ;THROW 50101, N'Invalid @ProcessType. Allowed values: INITIAL_CUTOFF, DAILY_ROUTINE, VALIDATION.', 1;
    END;

    IF @TriggerType IS NULL OR @TriggerType NOT IN ('SCHEDULE', 'MANUAL')
    BEGIN
        ;THROW 50102, N'Invalid @TriggerType. Allowed values: SCHEDULE, MANUAL.', 1;
    END;

    IF @AdfPipelineRunId IS NOT NULL
    BEGIN
        SELECT @RunId = RunId FROM ret.RetentionRunLog WHERE AdfPipelineRunId = @AdfPipelineRunId;

        IF @RunId IS NOT NULL
        BEGIN
            SELECT r.RunId, r.ProcessType, CONVERT(CHAR(10), r.RunDate, 23) AS RunDate, r.Status, CAST(1 AS BIT) AS IsExistingRun
            FROM ret.RetentionRunLog AS r
            WHERE r.RunId = @RunId;
            RETURN;
        END;
    END;

    SET @RunDate = ISNULL(@RunDate, @Today);

    IF @RunDate > @Today
    BEGIN
        SET @Msg = CONCAT(N'Run date ', CONVERT(CHAR(10), @RunDate, 23), N' is later than the current UTC+7 date ',
                          CONVERT(CHAR(10), @Today, 23), N' (DBR-15).');

        INSERT INTO ret.RetentionRunLog
            (AdfPipelineRunId, ProcessType, RunDate, IsRunDateOverride, TriggerType, TriggeredBy,
             DowntimeReference, StartTime, EndTime, Status, ErrorCode, ErrorMessage)
        VALUES
            (@AdfPipelineRunId, @ProcessType, @RunDate, 1, @TriggerType, @TriggeredBy,
             @DowntimeReference, @Now, @Now, 'FAILED', 'ERR-SYS-02', @Msg);

        ;THROW 50103, @Msg, 1;
    END;

    INSERT INTO ret.RetentionRunLog
        (AdfPipelineRunId, ProcessType, RunDate, IsRunDateOverride, TriggerType, TriggeredBy, DowntimeReference, StartTime, Status)
    VALUES
        (@AdfPipelineRunId, @ProcessType, @RunDate, CASE WHEN @RunDate <> @Today THEN 1 ELSE 0 END,
         @TriggerType, @TriggeredBy, @DowntimeReference, @Now, 'RUNNING');

    SET @RunId = SCOPE_IDENTITY();

    SET @Msg = CONCAT(N'Run started. Process type ', @ProcessType, N', run date ', CONVERT(CHAR(10), @RunDate, 23), N' (UTC+7).');
    EXEC ret.usp_WriteStepLog @RunId = @RunId, @StepCode = 'START_RUN', @Status = 'SUCCEEDED', @StartTime = @Now, @Message = @Msg;

    SELECT @RunId AS RunId, @ProcessType AS ProcessType, CONVERT(CHAR(10), @RunDate, 23) AS RunDate,
           'RUNNING' AS Status, CAST(0 AS BIT) AS IsExistingRun;
END;
GO

/* 6.2 ret.usp_GetTablesToProcess - table selection (FR-004) - v0.5 (CR-01, proposed, not approved)
       DAILY_ROUTINE : active tables whose Initial Cut-off completed before the run date (DBR-04),
                       from DailyRoutineStartDate onwards; child tables first (DBR-19).
       INITIAL_CUTOFF: explicit @TableConfigIdList in the given order, or EMPTY list = automatic mode:
                       every active table not COMPLETED, SMALL/MEDIUM before LARGE, child first,
                       then TableConfigId. Gates as in v0.4 (inactive, completed, running, DBR-05,
                       DBR-18, downtime reference); not eligible tables are logged SKIPPED (ERR-CFG-07).
       VALIDATION    : listed tables, any status; EMPTY list = all active tables not COMPLETED, in the
                       automatic order (v0.6, decision D-3). */
CREATE OR ALTER PROCEDURE ret.usp_GetTablesToProcess
    @RunId              BIGINT,
    @TableConfigIdList  NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Now DATETIME2(3) = ret.fn_NowUtc7();
    DECLARE @ProcessType VARCHAR(20), @RunDate DATE, @RunStatus VARCHAR(25), @Downtime NVARCHAR(100),
            @DrStartDate DATE, @Container NVARCHAR(63), @Msg NVARCHAR(4000), @Selected INT, @Skipped INT,
            @Unknown NVARCHAR(4000), @StepStatus VARCHAR(10), @IsAutoMode BIT = 0;

    SELECT @ProcessType = ProcessType, @RunDate = RunDate, @RunStatus = Status, @Downtime = DowntimeReference
    FROM ret.RetentionRunLog
    WHERE RunId = @RunId;

    IF @ProcessType IS NULL
    BEGIN
        ;THROW 50111, N'RunId not found.', 1;
    END;
    IF @RunStatus <> 'RUNNING'
    BEGIN
        ;THROW 50112, N'Run is not in status RUNNING.', 1;
    END;

    SELECT @DrStartDate = DailyRoutineStartDate, @Container = ArchiveContainer
    FROM ret.RetentionParameter
    WHERE ParameterSetId = 1;

    CREATE TABLE #Candidate
    (
        TableConfigId   INT             NOT NULL PRIMARY KEY,
        ProcessingOrder INT             NOT NULL,
        IsKnown         BIT             NOT NULL,
        SkipReason      NVARCHAR(400)   NULL
    );

    -- List to evaluate for INITIAL_CUTOFF / VALIDATION (explicit or automatic)
    CREATE TABLE #List
    (
        TableConfigId   INT     NOT NULL PRIMARY KEY,
        Ord             INT     NOT NULL
    );

    IF @ProcessType = 'DAILY_ROUTINE'
    BEGIN
        IF @DrStartDate IS NULL OR @RunDate < @DrStartDate
        BEGIN
            SET @Msg = CONCAT(N'Daily Routine not active for run date ', CONVERT(CHAR(10), @RunDate, 23),
                              N'. DailyRoutineStartDate = ', ISNULL(CONVERT(CHAR(10), @DrStartDate, 23), N'not set'),
                              N' (usp_ActivateDailyRoutine). No table selected.');
        END
        ELSE
        BEGIN
            INSERT INTO #Candidate (TableConfigId, ProcessingOrder, IsKnown, SkipReason)
            SELECT c.TableConfigId,
                   ROW_NUMBER() OVER (ORDER BY CASE WHEN c.ParentTableConfigId IS NOT NULL THEN 0 ELSE 1 END, c.TableConfigId),
                   1, NULL
            FROM ret.RetentionConfig AS c
            JOIN ret.RetentionTableStatus AS s ON s.TableConfigId = c.TableConfigId
            WHERE c.IsActive = 1
              AND s.InitialCutoffStatus = 'COMPLETED'
              AND s.InitialCutoffCompletionDate < @RunDate;
        END;
    END
    ELSE
    BEGIN
        IF NULLIF(LTRIM(RTRIM(@TableConfigIdList)), N'') IS NULL
        BEGIN
            /* ---- CR-01 automatic mode (INITIAL_CUTOFF) and dry validation (VALIDATION, D-3):
                    all active tables not yet COMPLETED ---- */
            SET @IsAutoMode = 1;

            INSERT INTO #List (TableConfigId, Ord)
            SELECT c.TableConfigId,
                   ROW_NUMBER() OVER (ORDER BY CASE WHEN c.SizeCategory = 'LARGE' THEN 1 ELSE 0 END,
                                               CASE WHEN c.ParentTableConfigId IS NOT NULL THEN 0 ELSE 1 END,
                                               c.TableConfigId)
            FROM ret.RetentionConfig AS c
            LEFT JOIN ret.RetentionTableStatus AS s ON s.TableConfigId = c.TableConfigId
            WHERE c.IsActive = 1
              AND ISNULL(s.InitialCutoffStatus, 'PENDING') <> 'COMPLETED';
        END
        ELSE
        BEGIN
            IF EXISTS (SELECT 1 FROM STRING_SPLIT(@TableConfigIdList, N',') AS x
                       WHERE LTRIM(RTRIM(x.value)) <> N'' AND TRY_CONVERT(INT, LTRIM(RTRIM(x.value))) IS NULL)
            BEGIN
                ;THROW 50114, N'@TableConfigIdList must contain comma-separated integer TableConfigId values only.', 1;
            END;

            INSERT INTO #List (TableConfigId, Ord)
            SELECT TRY_CONVERT(INT, LTRIM(RTRIM(x.value))), CONVERT(INT, MIN(x.ordinal))
            FROM STRING_SPLIT(@TableConfigIdList, N',', 1) AS x
            WHERE LTRIM(RTRIM(x.value)) <> N''
            GROUP BY TRY_CONVERT(INT, LTRIM(RTRIM(x.value)));
        END;

        /* ---- Gates of v0.4, unchanged, applied to the explicit or automatic list ---- */
        INSERT INTO #Candidate (TableConfigId, ProcessingOrder, IsKnown, SkipReason)
        SELECT li.TableConfigId,
               li.Ord,
               CASE WHEN c.TableConfigId IS NULL THEN 0 ELSE 1 END,
               CASE
                   WHEN c.TableConfigId IS NULL THEN N'Unknown TableConfigId.'
                   WHEN @ProcessType = 'VALIDATION' THEN NULL
                   WHEN c.IsActive = 0 THEN N'Table is inactive (DBR-11).'
                   WHEN s.InitialCutoffStatus = 'COMPLETED' THEN N'Initial Cut-off Run already completed (BR-12).'
                   WHEN s.InitialCutoffStatus = 'RUNNING' THEN N'Initial Cut-off status is RUNNING (another run or an aborted run; see usp_AdminCloseStaleRun).'
                   WHEN EXISTS (SELECT 1
                                FROM ret.RetentionConfig AS ch
                                JOIN ret.RetentionTableStatus AS chs ON chs.TableConfigId = ch.TableConfigId
                                WHERE ch.ParentTableConfigId = c.TableConfigId AND ch.IsActive = 1
                                  AND chs.InitialCutoffStatus <> 'COMPLETED'
                                  AND NOT EXISTS (SELECT 1 FROM #List AS li2 WHERE li2.TableConfigId = ch.TableConfigId AND li2.Ord < li.Ord))
                       THEN N'Header table: active child tables must complete their Initial Cut-off Run first or be listed before the header (DBR-18).'
                   WHEN c.SizeCategory = 'LARGE' AND @Downtime IS NULL
                       THEN N'LARGE table requires a downtime reference on the run (BR-16, D-07).'
                   WHEN c.SizeCategory = 'LARGE'
                        AND EXISTS (SELECT 1
                                    FROM ret.RetentionConfig AS c2
                                    JOIN ret.RetentionTableStatus AS s2 ON s2.TableConfigId = c2.TableConfigId
                                    WHERE c2.IsActive = 1 AND c2.SizeCategory IN ('SMALL', 'MEDIUM')
                                      AND s2.InitialCutoffStatus <> 'COMPLETED')
                       THEN N'SMALL and MEDIUM tables must complete their Initial Cut-off Run first (BR-16, DBR-05, OQ-26).'
                   WHEN c.InitialCutoffMethod = 'TABLE_REBUILD' AND @Downtime IS NULL
                       THEN N'Method TABLE_REBUILD requires a downtime reference on the run (BR-16, D-07).'
                   ELSE NULL
               END
        FROM #List AS li
        LEFT JOIN ret.RetentionConfig      AS c ON c.TableConfigId = li.TableConfigId
        LEFT JOIN ret.RetentionTableStatus AS s ON s.TableConfigId = li.TableConfigId;

        INSERT INTO ret.RetentionTableLog
            (RunId, TableConfigId, ProcessType, RunDate, Status, StartTime, EndTime, ErrorCode, ErrorStep, ErrorMessage)
        SELECT @RunId, k.TableConfigId, @ProcessType, @RunDate, 'SKIPPED', @Now, @Now, 'ERR-CFG-07', 'SELECT_TABLES',
               CONCAT(N'[ERR-CFG-07] ', k.SkipReason)
        FROM #Candidate AS k
        WHERE k.IsKnown = 1 AND k.SkipReason IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM ret.RetentionTableLog AS t WHERE t.RunId = @RunId AND t.TableConfigId = k.TableConfigId);

        SELECT @Unknown = STRING_AGG(CONVERT(NVARCHAR(20), TableConfigId) COLLATE DATABASE_DEFAULT, N', ')
        FROM #Candidate WHERE IsKnown = 0;

        IF @IsAutoMode = 1
            SET @Msg = N'Automatic table selection (CR-01): all active tables not COMPLETED, SMALL/MEDIUM before LARGE, child tables first.';
    END;

    SELECT @Selected = COUNT(*) FROM #Candidate WHERE IsKnown = 1 AND SkipReason IS NULL;
    SELECT @Skipped  = COUNT(*) FROM #Candidate WHERE SkipReason IS NOT NULL;

    UPDATE ret.RetentionRunLog
       SET TablesSelected = @Selected,
           TablesSkipped  = @Skipped
     WHERE RunId = @RunId;

    SET @Msg = CONCAT(ISNULL(@Msg + N' ', N''), N'Tables selected: ', @Selected, N'; skipped: ', @Skipped,
                      CASE WHEN @Unknown IS NOT NULL THEN CONCAT(N'; unknown TableConfigId: ', @Unknown) ELSE N'' END, N'.');
    SET @StepStatus = CASE WHEN @Unknown IS NULL THEN 'SUCCEEDED' ELSE 'WARNING' END;
    EXEC ret.usp_WriteStepLog @RunId = @RunId, @StepCode = 'SELECT_TABLES', @Status = @StepStatus, @StartTime = @Now, @Message = @Msg;

    SELECT c.TableConfigId, c.SchemaName, c.TableName, c.RetentionColumn, c.ParentTableConfigId,
           CAST(CASE WHEN c.ParentTableConfigId IS NULL THEN 0 ELSE 1 END AS BIT) AS IsChild,
           c.DwhRetentionYears, c.BlobRetentionYears, cd.TotalRetentionYears,
           CONVERT(CHAR(10), cd.DwhCutoffDate, 23)     AS DwhCutoffDate,
           CONVERT(CHAR(10), cd.ArchiveCutoffDate, 23) AS ArchiveCutoffDate,
           c.BlobPath, @Container AS ArchiveContainer,
           c.InitialCutoffMethod, c.SizeCategory, k.ProcessingOrder
    FROM #Candidate AS k
    JOIN ret.RetentionConfig AS c ON c.TableConfigId = k.TableConfigId
    CROSS APPLY ret.fn_GetCutoffDates(@RunDate, c.DwhRetentionYears, c.BlobRetentionYears) AS cd
    WHERE k.IsKnown = 1 AND k.SkipReason IS NULL
    ORDER BY k.ProcessingOrder;
END;
GO

/* 6.3 ret.usp_BeginTable - table log, lock (FR-016), checks V-01..V-11 (FR-002), gates DBR-18 and
       DBR-19, clean-up of an interrupted table rebuild, pending resume (FR-017).
       CanRunArchiveExpiry = 1 (Daily Routine) when V-05 and V-06 passed: DR-05 runs even when later
       checks fail or the table is skipped by DBR-19 (BR-14). */
CREATE OR ALTER PROCEDURE ret.usp_BeginTable
    @RunId          BIGINT,
    @TableConfigId  INT
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Now DATETIME2(3) = ret.fn_NowUtc7();
    DECLARE @ProcessType VARCHAR(20), @RunDate DATE, @RunStatus VARCHAR(25),
            @SchemaName SYSNAME, @TableName SYSNAME, @ParentId INT,
            @DwhYears SMALLINT, @BlobYears SMALLINT, @BlobPath NVARCHAR(400), @Container NVARCHAR(63),
            @DwhCutoff DATE, @ArchiveCutoff DATE, @TableLogId BIGINT,
            @IsChild BIT, @FullName NVARCHAR(300), @ObjectId INT, @DateTable NVARCHAR(300), @DateObjectId INT, @DateCol SYSNAME,
            @DateExpr NVARCHAR(400), @JoinSql NVARCHAR(MAX), @FromSql NVARCHAR(MAX), @OrphanExpr NVARCHAR(400),
            @ColTypeName SYSNAME, @ColNullable BIT,
            @ErrCode VARCHAR(12), @ErrMsg NVARCHAR(4000), @CheckCode VARCHAR(4), @Holder BIGINT,
            @CanExpiry BIT = 0, @NullCount BIGINT = 0, @NullMode VARCHAR(10), @NullCheckNote NVARCHAR(400),
            @sql NVARCHAR(MAX), @BadList NVARCHAR(MAX), @Gate NVARCHAR(400), @StaleLogId BIGINT, @ErrNo INT,
            @ResumeLogId BIGINT, @ResumeRunId BIGINT, @ResumeCount INT = 0, @Uniq TINYINT, @LogYears SMALLINT,
            @StaleNote NVARCHAR(400);

    SELECT @ProcessType = ProcessType, @RunDate = RunDate, @RunStatus = Status
    FROM ret.RetentionRunLog WHERE RunId = @RunId;

    IF @ProcessType IS NULL OR @RunStatus <> 'RUNNING'
    BEGIN
        ;THROW 50121, N'RunId not found or run is not in status RUNNING.', 1;
    END;

    SELECT @SchemaName = SchemaName, @TableName = TableName, @ParentId = ParentTableConfigId,
           @DwhYears = DwhRetentionYears, @BlobYears = BlobRetentionYears, @BlobPath = BlobPath,
           @LogYears = LogRetentionYears
    FROM ret.RetentionConfig WHERE TableConfigId = @TableConfigId;

    IF @SchemaName IS NULL
    BEGIN
        ;THROW 50122, N'TableConfigId not found.', 1;
    END;

    SELECT @Container = ArchiveContainer FROM ret.RetentionParameter WHERE ParameterSetId = 1;

    SELECT @DwhCutoff = DwhCutoffDate, @ArchiveCutoff = ArchiveCutoffDate
    FROM ret.fn_GetCutoffDates(@RunDate, @DwhYears, @BlobYears);

    -- Re-entry in the same run (e.g. ADF activity retry): nothing is started twice
    IF EXISTS (SELECT 1 FROM ret.RetentionTableLog WHERE RunId = @RunId AND TableConfigId = @TableConfigId)
    BEGIN
        SELECT l.TableLogId, 'SKIPPED' AS BeginResult, CAST(0 AS BIT) AS CanRunArchiveExpiry,
               CAST(NULL AS BIGINT) AS PendingResumeTableLogId, CAST(NULL AS BIGINT) AS PendingResumeRunId,
               CAST(NULL AS VARCHAR(20)) AS PendingResumeMethod, CAST(CASE WHEN @ParentId IS NULL THEN 0 ELSE 1 END AS BIT) AS IsChild,
               CONVERT(CHAR(10), l.DwhCutoffDate, 23) AS DwhCutoffDate, CONVERT(CHAR(10), l.ArchiveCutoffDate, 23) AS ArchiveCutoffDate,
               l.ErrorCode, N'Table already started in this run; not started again.' AS Message
        FROM ret.RetentionTableLog AS l
        WHERE l.RunId = @RunId AND l.TableConfigId = @TableConfigId;
        RETURN;
    END;

    INSERT INTO ret.RetentionTableLog (RunId, TableConfigId, ProcessType, RunDate, DwhCutoffDate, ArchiveCutoffDate, StartTime)
    VALUES (@RunId, @TableConfigId, @ProcessType, @RunDate, @DwhCutoff, @ArchiveCutoff, @Now);

    SET @TableLogId = SCOPE_IDENTITY();

    BEGIN TRY
        /* ---- Lock (FR-016) ---- */
        BEGIN TRY
            INSERT INTO ret.RetentionTableLock (TableConfigId, RunId, ProcessType)
            VALUES (@TableConfigId, @RunId, @ProcessType);
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() IN (2627, 2601)
            BEGIN
                SELECT @Holder = RunId FROM ret.RetentionTableLock WHERE TableConfigId = @TableConfigId;
                SET @ErrMsg = CONCAT(N'Table is locked by RunId ', @Holder, N'.');

                UPDATE ret.RetentionTableLog
                   SET Status = 'SKIPPED', EndTime = ret.fn_NowUtc7(), ErrorCode = 'ERR-LCK-01',
                       ErrorStep = 'LOCK', ErrorMessage = CONCAT(N'[ERR-LCK-01] ', @ErrMsg)
                 WHERE TableLogId = @TableLogId;

                EXEC ret.usp_WriteStepLog @RunId = @RunId, @StepCode = 'LOCK', @Status = 'SKIPPED',
                     @TableLogId = @TableLogId, @TableConfigId = @TableConfigId, @StartTime = @Now,
                     @ErrorCode = 'ERR-LCK-01', @ErrorMessage = @ErrMsg;

                SELECT @TableLogId AS TableLogId, 'SKIPPED' AS BeginResult, CAST(0 AS BIT) AS CanRunArchiveExpiry,
                       CAST(NULL AS BIGINT) AS PendingResumeTableLogId, CAST(NULL AS BIGINT) AS PendingResumeRunId,
                       CAST(NULL AS VARCHAR(20)) AS PendingResumeMethod, CAST(CASE WHEN @ParentId IS NULL THEN 0 ELSE 1 END AS BIT) AS IsChild,
                       CONVERT(CHAR(10), @DwhCutoff, 23) AS DwhCutoffDate, CONVERT(CHAR(10), @ArchiveCutoff, 23) AS ArchiveCutoffDate,
                       'ERR-LCK-01' AS ErrorCode, @ErrMsg AS Message;
                RETURN;
            END;
            THROW;
        END CATCH;

        /* ---- Header table locked by another run (child table, FR-023) ---- */
        IF @ParentId IS NOT NULL
        BEGIN
            SELECT @Holder = RunId FROM ret.RetentionTableLock WHERE TableConfigId = @ParentId AND RunId <> @RunId;

            IF @Holder IS NOT NULL
            BEGIN
                SET @ErrMsg = CONCAT(N'Header table (TableConfigId ', @ParentId, N') is locked by RunId ', @Holder, N'.');
                EXEC ret.usp_SetTableError @TableLogId = @TableLogId, @ErrorCode = 'ERR-LCK-01', @ErrorStep = 'LOCK',
                     @ErrorMessage = @ErrMsg, @NewStatus = 'SKIPPED';
                EXEC ret.usp_WriteStepLog @RunId = @RunId, @StepCode = 'LOCK', @Status = 'SKIPPED',
                     @TableLogId = @TableLogId, @TableConfigId = @TableConfigId, @StartTime = @Now,
                     @ErrorCode = 'ERR-LCK-01', @ErrorMessage = @ErrMsg;

                SELECT @TableLogId AS TableLogId, 'SKIPPED' AS BeginResult, CAST(0 AS BIT) AS CanRunArchiveExpiry,
                       CAST(NULL AS BIGINT) AS PendingResumeTableLogId, CAST(NULL AS BIGINT) AS PendingResumeRunId,
                       CAST(NULL AS VARCHAR(20)) AS PendingResumeMethod, CAST(1 AS BIT) AS IsChild,
                       CONVERT(CHAR(10), @DwhCutoff, 23) AS DwhCutoffDate, CONVERT(CHAR(10), @ArchiveCutoff, 23) AS ArchiveCutoffDate,
                       'ERR-LCK-01' AS ErrorCode, @ErrMsg AS Message;
                RETURN;
            END;
        END;

        /* ---- Initial Cut-off status RUNNING ---- */
        IF NOT EXISTS (SELECT 1 FROM ret.RetentionTableStatus WHERE TableConfigId = @TableConfigId)
            INSERT INTO ret.RetentionTableStatus (TableConfigId) VALUES (@TableConfigId);

        IF @ProcessType = 'INITIAL_CUTOFF'
            UPDATE ret.RetentionTableStatus
               SET InitialCutoffStatus = 'RUNNING', LastInitialCutoffRunId = @RunId,
                   ModifiedBy = ORIGINAL_LOGIN(), ModifiedAt = ret.fn_NowUtc7()
             WHERE TableConfigId = @TableConfigId;

        /* ---- V-05 retention periods ---- */
        IF NOT (@DwhYears >= 1 AND @BlobYears >= 1 AND @LogYears >= 1)
            SELECT @ErrCode = 'ERR-CFG-05', @CheckCode = 'V-05',
                   @ErrMsg = N'DWH, archive and log retention must each be >= 1 year (FSD 4.1, V-05).';

        /* ---- V-06 blob path and archive container (MD-07) ---- */
        IF @ErrCode IS NULL
           AND (   NULLIF(@BlobPath, N'') IS NULL
                OR CHARINDEX(N'/', @BlobPath) > 0 OR CHARINDEX(N'\', @BlobPath) > 0
                OR @BlobPath COLLATE Latin1_General_100_BIN2 <> LOWER(@BlobPath) COLLATE Latin1_General_100_BIN2
                OR EXISTS (SELECT 1 FROM ret.RetentionConfig WHERE BlobPath = @BlobPath AND TableConfigId <> @TableConfigId))
            SELECT @ErrCode = 'ERR-CFG-06', @CheckCode = 'V-06',
                   @ErrMsg = N'BlobPath missing, not <schema>.<table> in lower case without slash, or not unique (MD-07).';

        IF @ErrCode IS NULL AND NULLIF(@Container, N'') IS NULL
            SELECT @ErrCode = 'ERR-CFG-06', @CheckCode = 'V-06',
                   @ErrMsg = N'ArchiveContainer is not set in ret.RetentionParameter (D-02).';

        IF @ErrCode IS NULL AND @ProcessType = 'DAILY_ROUTINE'
            SET @CanExpiry = 1;

        /* ---- V-01 table, V-10 header configuration, V-11 unique join key ---- */
        SET @Uniq = CASE WHEN @ProcessType IN ('INITIAL_CUTOFF', 'VALIDATION') THEN 2 ELSE 1 END;   -- FSD V-11: IC always counted

        IF @ErrCode IS NULL
            EXEC ret.usp_GetTableSqlParts @TableConfigId = @TableConfigId, @CheckUniqueness = @Uniq,
                 @IsChild = @IsChild OUTPUT, @FullName = @FullName OUTPUT, @ObjectId = @ObjectId OUTPUT,
                 @DateTableFullName = @DateTable OUTPUT, @DateTableObjectId = @DateObjectId OUTPUT, @DateColumn = @DateCol OUTPUT,
                 @DateExpr = @DateExpr OUTPUT, @JoinSql = @JoinSql OUTPUT, @FromSql = @FromSql OUTPUT, @OrphanExpr = @OrphanExpr OUTPUT,
                 @ErrorCode = @ErrCode OUTPUT, @CheckCode = @CheckCode OUTPUT, @ErrorMessage = @ErrMsg OUTPUT;

        /* ---- V-02 / V-03 retention column (header column for a child table) ---- */
        IF @ErrCode IS NULL
        BEGIN
            SELECT @ColTypeName = TYPE_NAME(c.system_type_id), @ColNullable = c.is_nullable
            FROM sys.columns AS c
            WHERE c.object_id = @DateObjectId AND c.name COLLATE DATABASE_DEFAULT = @DateCol;

            IF @ColTypeName IS NULL
                SELECT @ErrCode = 'ERR-CFG-02', @CheckCode = 'V-02',
                       @ErrMsg = CONCAT(N'Retention column ', QUOTENAME(@DateCol), N' does not exist in ', @DateTable, N'.');
            ELSE IF @ColTypeName NOT IN ('date', 'datetime', 'datetime2', 'smalldatetime')
                SELECT @ErrCode = 'ERR-CFG-03', @CheckCode = 'V-03',
                       @ErrMsg = CONCAT(N'Retention column ', QUOTENAME(@DateCol), N' of ', @DateTable, N' has type ', @ColTypeName, N' (BR-06).');
        END;

        /* ---- V-04 no NULL values in the retention column (BR-06) ---- */
        IF @ErrCode IS NULL
        BEGIN
            SELECT @NullMode = DailyNullCheckMode FROM ret.RetentionParameter WHERE ParameterSetId = 1;

            IF @ColNullable = 0
                SET @NullCheckNote = N'Retention column is NOT NULL (metadata).';
            ELSE IF @ProcessType IN ('INITIAL_CUTOFF', 'VALIDATION') OR ISNULL(@NullMode, 'FULL') = 'FULL'
            BEGIN
                SET @sql = N'SELECT @n = COUNT_BIG(*) FROM ' + @DateTable + N' WHERE ' + QUOTENAME(@DateCol) + N' IS NULL;';
                EXEC sp_executesql @sql, N'@n BIGINT OUTPUT', @n = @NullCount OUTPUT;
                SET @NullCheckNote = N'Full NULL count performed.';
            END
            ELSE
                SET @NullCheckNote = N'Retention column is nullable; data check skipped (DailyNullCheckMode = METADATA, OQ-14).';

            IF @NullCount > 0
                SELECT @ErrCode = 'ERR-CFG-04', @CheckCode = 'V-04',
                       @ErrMsg = CONCAT(N'Retention column ', QUOTENAME(@DateCol), N' of ', @DateTable, N' contains ', @NullCount, N' NULL values (BR-06).');
        END;

        /* ---- V-08 Parquet compatibility of the exported table ---- */
        IF @ErrCode IS NULL
        BEGIN
            SELECT @BadList = STRING_AGG(CONVERT(NVARCHAR(MAX), CONCAT(QUOTENAME(c.name COLLATE DATABASE_DEFAULT), N' (', t.name COLLATE DATABASE_DEFAULT, N')')) COLLATE DATABASE_DEFAULT, N', ')
            FROM sys.columns AS c
            JOIN sys.types AS t ON t.user_type_id = c.user_type_id
            WHERE c.object_id = @ObjectId
              AND (   TYPE_NAME(c.system_type_id) = 'sql_variant'
                   OR t.is_assembly_type = 1
                   OR c.name COLLATE DATABASE_DEFAULT LIKE N'%[ ,;{}()=]%'
                   OR CHARINDEX(NCHAR(9), c.name COLLATE DATABASE_DEFAULT) > 0 OR CHARINDEX(NCHAR(10), c.name COLLATE DATABASE_DEFAULT) > 0 OR CHARINDEX(NCHAR(13), c.name COLLATE DATABASE_DEFAULT) > 0);

            IF @BadList IS NOT NULL
                SELECT @ErrCode = 'ERR-CFG-08', @CheckCode = 'V-08',
                       @ErrMsg = LEFT(CONCAT(N'Columns not supported for Parquet export: ', @BadList), 4000);
        END;

        /* ---- Interrupted table rebuild of an earlier run (MD-06): drop the new table, revoke the
                validation; the files of that run remain and are flagged as orphan files.
                VALIDATION run (decision D-3): nothing is changed, the leftover is only reported. ---- */
        IF @ErrCode IS NULL AND @ProcessType = 'VALIDATION'
           AND EXISTS (SELECT 1 FROM ret.RetentionTableLog AS l
                       WHERE l.TableConfigId = @TableConfigId AND l.TableLogId <> @TableLogId
                         AND l.MethodUsed = 'TABLE_REBUILD' AND l.DeleteStatus <> 'COMPLETED'
                         AND (l.RebuildStagingTable IS NOT NULL OR l.IsValidated = 1))
        BEGIN
            SET @StaleNote = N'Unfinished table rebuild of an earlier run found; the next Initial Cut-off Run of this table drops the leftover new table and flags its archive files as orphan files (not changed by this VALIDATION run).';
            EXEC ret.usp_WriteStepLog @RunId = @RunId, @StepCode = 'VALIDATE', @Status = 'WARNING',
                 @TableLogId = @TableLogId, @TableConfigId = @TableConfigId, @StartTime = @Now, @Message = @StaleNote;
        END;

        IF @ErrCode IS NULL AND @ProcessType <> 'VALIDATION'
        BEGIN
            SELECT TOP (1) @StaleLogId = l.TableLogId
            FROM ret.RetentionTableLog AS l
            WHERE l.TableConfigId = @TableConfigId AND l.TableLogId <> @TableLogId
              AND l.MethodUsed = 'TABLE_REBUILD' AND l.DeleteStatus <> 'COMPLETED'
              AND (l.RebuildStagingTable IS NOT NULL OR l.IsValidated = 1)
            ORDER BY l.TableLogId;

            WHILE @StaleLogId IS NOT NULL
            BEGIN
                EXEC ret.usp_TableRebuildAbort @RunId = @RunId, @TableLogId = @StaleLogId, @MarkOrphanFiles = 1, @Silent = 1;

                SET @StaleLogId = NULL;
                SELECT TOP (1) @StaleLogId = l.TableLogId
                FROM ret.RetentionTableLog AS l
                WHERE l.TableConfigId = @TableConfigId AND l.TableLogId <> @TableLogId
                  AND l.MethodUsed = 'TABLE_REBUILD' AND l.DeleteStatus <> 'COMPLETED'
                  AND (l.RebuildStagingTable IS NOT NULL OR l.IsValidated = 1)
                ORDER BY l.TableLogId;
            END;
        END;

        /* ---- V-09 blocking flags ---- */
        IF @ErrCode IS NULL
           AND EXISTS (SELECT 1 FROM ret.RetentionTableStatus
                       WHERE TableConfigId = @TableConfigId AND (HasOrphanFiles = 1 OR HasIntegrityIssue = 1))
            SELECT @ErrCode = 'ERR-CFG-09', @CheckCode = 'V-09',
                   @ErrMsg = N'Orphan-file or integrity flag outstanding; investigate and clear with usp_AdminClearTableFlag.';

        /* ---- Validation result ---- */
        IF @ErrCode IS NOT NULL
        BEGIN
            EXEC ret.usp_SetTableError @TableLogId = @TableLogId, @ErrorCode = @ErrCode, @ErrorStep = 'VALIDATE', @ErrorMessage = @ErrMsg;
            EXEC ret.usp_WriteStepLog @RunId = @RunId, @StepCode = 'VALIDATE', @Status = 'FAILED',
                 @TableLogId = @TableLogId, @TableConfigId = @TableConfigId, @StartTime = @Now,
                 @ValidationCheckCode = @CheckCode, @ErrorCode = @ErrCode, @ErrorMessage = @ErrMsg;

            SELECT @TableLogId AS TableLogId, 'FAILED' AS BeginResult, @CanExpiry AS CanRunArchiveExpiry,
                   CAST(NULL AS BIGINT) AS PendingResumeTableLogId, CAST(NULL AS BIGINT) AS PendingResumeRunId,
                   CAST(NULL AS VARCHAR(20)) AS PendingResumeMethod, CAST(CASE WHEN @ParentId IS NULL THEN 0 ELSE 1 END AS BIT) AS IsChild,
                   CONVERT(CHAR(10), @DwhCutoff, 23) AS DwhCutoffDate, CONVERT(CHAR(10), @ArchiveCutoff, 23) AS ArchiveCutoffDate,
                   @ErrCode AS ErrorCode, @ErrMsg AS Message;
            RETURN;
        END;

        EXEC ret.usp_WriteStepLog @RunId = @RunId, @StepCode = 'VALIDATE', @Status = 'SUCCEEDED',
             @TableLogId = @TableLogId, @TableConfigId = @TableConfigId, @StartTime = @Now, @Message = @NullCheckNote;

        /* ---- Header table gates: DBR-18 (IC) and DBR-19 (DR) ---- */
        IF @ProcessType = 'INITIAL_CUTOFF'
           AND EXISTS (SELECT 1
                       FROM ret.RetentionConfig AS ch
                       JOIN ret.RetentionTableStatus AS chs ON chs.TableConfigId = ch.TableConfigId
                       WHERE ch.ParentTableConfigId = @TableConfigId AND ch.IsActive = 1 AND chs.InitialCutoffStatus <> 'COMPLETED')
            SET @Gate = N'Header table: the Initial Cut-off Run of every active child table must be COMPLETED first (DBR-18).';

        IF @ProcessType = 'DAILY_ROUTINE'
           AND EXISTS (SELECT 1
                       FROM ret.RetentionConfig AS ch
                       WHERE ch.ParentTableConfigId = @TableConfigId AND ch.IsActive = 1
                         AND NOT EXISTS (SELECT 1 FROM ret.RetentionTableLog AS cl
                                         WHERE cl.RunId = @RunId AND cl.TableConfigId = ch.TableConfigId
                                           AND cl.Status IN ('SUCCEEDED', 'NODATA')))
            SET @Gate = N'Header table: DWH removal skipped because an active child table did not end SUCCEEDED or NODATA in this run (DBR-19). Archive expiry still runs.';

        IF @Gate IS NOT NULL
        BEGIN
            EXEC ret.usp_SetTableError @TableLogId = @TableLogId, @ErrorCode = 'ERR-CFG-07', @ErrorStep = 'VALIDATE',
                 @ErrorMessage = @Gate, @NewStatus = 'SKIPPED';
            EXEC ret.usp_WriteStepLog @RunId = @RunId, @StepCode = 'VALIDATE', @Status = 'SKIPPED',
                 @TableLogId = @TableLogId, @TableConfigId = @TableConfigId, @StartTime = @Now,
                 @ErrorCode = 'ERR-CFG-07', @ErrorMessage = @Gate;

            SELECT @TableLogId AS TableLogId, 'SKIPPED' AS BeginResult, @CanExpiry AS CanRunArchiveExpiry,
                   CAST(NULL AS BIGINT) AS PendingResumeTableLogId, CAST(NULL AS BIGINT) AS PendingResumeRunId,
                   CAST(NULL AS VARCHAR(20)) AS PendingResumeMethod, @IsChild AS IsChild,
                   CONVERT(CHAR(10), @DwhCutoff, 23) AS DwhCutoffDate, CONVERT(CHAR(10), @ArchiveCutoff, 23) AS ArchiveCutoffDate,
                   'ERR-CFG-07' AS ErrorCode, @Gate AS Message;
            RETURN;
        END;

        /* ---- Pending resume (FR-017): validated batch-delete range of an earlier run ---- */
        IF @ProcessType IN ('INITIAL_CUTOFF', 'DAILY_ROUTINE')
        BEGIN
            SELECT @ResumeCount = COUNT(*)
            FROM ret.RetentionTableLog
            WHERE TableConfigId = @TableConfigId AND TableLogId <> @TableLogId
              AND IsValidated = 1 AND DeleteStatus IN ('NOT_STARTED', 'IN_PROGRESS', 'FAILED')
              AND ISNULL(MethodUsed, 'BATCH_DELETE') = 'BATCH_DELETE';

            SELECT TOP (1) @ResumeLogId = l.TableLogId, @ResumeRunId = l.RunId
            FROM ret.RetentionTableLog AS l
            WHERE l.TableConfigId = @TableConfigId AND l.TableLogId <> @TableLogId
              AND l.IsValidated = 1 AND l.DeleteStatus IN ('NOT_STARTED', 'IN_PROGRESS', 'FAILED')
              AND ISNULL(l.MethodUsed, 'BATCH_DELETE') = 'BATCH_DELETE'
            ORDER BY l.TableLogId ASC;
        END;

        SELECT @TableLogId AS TableLogId, 'PROCEED' AS BeginResult, @CanExpiry AS CanRunArchiveExpiry,
               @ResumeLogId AS PendingResumeTableLogId, @ResumeRunId AS PendingResumeRunId,
               CASE WHEN @ResumeLogId IS NOT NULL THEN CAST('BATCH_DELETE' AS VARCHAR(20)) END AS PendingResumeMethod,
               @IsChild AS IsChild,
               CONVERT(CHAR(10), @DwhCutoff, 23) AS DwhCutoffDate, CONVERT(CHAR(10), @ArchiveCutoff, 23) AS ArchiveCutoffDate,
               CAST(NULL AS VARCHAR(12)) AS ErrorCode,
               CASE WHEN @ResumeCount > 1 THEN CONCAT(@ResumeCount, N' pending resume ranges; resume the oldest first (usp_GetPendingResume).')
                    ELSE CAST(NULL AS NVARCHAR(400)) END AS Message;
    END TRY
    BEGIN CATCH
        SELECT @ErrMsg = LEFT(ERROR_MESSAGE(), 4000), @ErrNo = ERROR_NUMBER();

        EXEC ret.usp_SetTableError @TableLogId = @TableLogId, @ErrorCode = 'ERR-SYS-01', @ErrorStep = 'VALIDATE',
             @ErrorMessage = @ErrMsg, @ErrorNumber = @ErrNo;
        EXEC ret.usp_WriteStepLog @RunId = @RunId, @StepCode = 'VALIDATE', @Status = 'FAILED',
             @TableLogId = @TableLogId, @TableConfigId = @TableConfigId, @StartTime = @Now,
             @ErrorCode = 'ERR-SYS-01', @ErrorNumber = @ErrNo, @ErrorMessage = @ErrMsg;

        SELECT @TableLogId AS TableLogId, 'FAILED' AS BeginResult, @CanExpiry AS CanRunArchiveExpiry,
               CAST(NULL AS BIGINT) AS PendingResumeTableLogId, CAST(NULL AS BIGINT) AS PendingResumeRunId,
               CAST(NULL AS VARCHAR(20)) AS PendingResumeMethod, CAST(CASE WHEN @ParentId IS NULL THEN 0 ELSE 1 END AS BIT) AS IsChild,
               CONVERT(CHAR(10), @DwhCutoff, 23) AS DwhCutoffDate, CONVERT(CHAR(10), @ArchiveCutoff, 23) AS ArchiveCutoffDate,
               'ERR-SYS-01' AS ErrorCode, @ErrMsg AS Message;
    END CATCH;
END;
GO

/* 6.4 ret.usp_GetPendingResume - next validated batch-delete range of an earlier run still to be
       deleted for the table (FR-017). ADF calls it after each resume until it returns no row. */
CREATE OR ALTER PROCEDURE ret.usp_GetPendingResume
    @RunId          BIGINT,
    @TableConfigId  INT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP (1) l.TableLogId AS PendingResumeTableLogId, l.RunId AS PendingResumeRunId,
           CAST('BATCH_DELETE' AS VARCHAR(20)) AS PendingResumeMethod,
           l.ValidatedRowCount, ISNULL(l.RowsDeleted, 0) AS RowsDeleted, l.DeleteStatus
    FROM ret.RetentionTableLog AS l
    WHERE l.TableConfigId = @TableConfigId AND l.RunId <> @RunId
      AND l.IsValidated = 1 AND l.DeleteStatus IN ('NOT_STARTED', 'IN_PROGRESS', 'FAILED')
      AND ISNULL(l.MethodUsed, 'BATCH_DELETE') = 'BATCH_DELETE'
    ORDER BY l.TableLogId ASC;
END;
GO

/* 6.5 ret.usp_IdentifyEligibleData - per business date snapshot (FR-005).
       IC: archived segment [archive cut-off, DWH cut-off) per date + expired, retained and orphan counts.
       DR: every row before the DWH cut-off per date (OQ-10); orphan count for child tables when
           DailyNullCheckMode = FULL.
       Child table: business date = date of the header row (FR-023). Orphan child rows are never
       eligible; they are counted and reported with warning ERR-PAR-01 (DBR-21).
       NextAction: EXPORT, VALIDATE (IC: expired rows only, DBR-03) or NONE.
       v0.6 decision D-1 (FSD 4.17): a business date on or after the archive cut-off for which an archive
       file of an earlier run of the same table may exist (ExportStatus SUCCEEDED, FAILED or STOPPED, i.e.
       not REMOVED) is refused: ERR-EXP-02, table FAILED, snapshot removed, nothing exported or deleted.
       Dates before the archive cut-off are not checked: their files are expired and removed by DR-05. */
CREATE OR ALTER PROCEDURE ret.usp_IdentifyEligibleData
    @TableLogId BIGINT
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Now DATETIME2(3) = ret.fn_NowUtc7();
    DECLARE @RunId BIGINT, @TableConfigId INT, @ProcessType VARCHAR(20), @Status VARCHAR(10),
            @DwhCutoff DATE, @ArchiveCutoff DATE, @SchemaName SYSNAME, @TableName SYSNAME, @BlobPath NVARCHAR(400),
            @IsChild BIT, @DateExpr NVARCHAR(400), @FromSql NVARCHAR(MAX), @OrphanExpr NVARCHAR(400),
            @ErrCode VARCHAR(12), @CheckCode VARCHAR(4), @sql NVARCHAR(MAX), @NullMode VARCHAR(10),
            @ToExport BIGINT = 0, @Expired BIGINT = 0, @Retained BIGINT = NULL, @Orphans BIGINT = NULL, @Eligible BIGINT = 0,
            @DateCount INT = 0, @MinDate DATE, @MaxDate DATE, @NextAction VARCHAR(10), @Msg NVARCHAR(4000), @ErrNo INT,
            @ExistCount INT, @ExistDates NVARCHAR(4000);

    SELECT @RunId = l.RunId, @TableConfigId = l.TableConfigId, @ProcessType = l.ProcessType, @Status = l.Status,
           @DwhCutoff = l.DwhCutoffDate, @ArchiveCutoff = l.ArchiveCutoffDate,
           @SchemaName = c.SchemaName, @TableName = c.TableName, @BlobPath = c.BlobPath
    FROM ret.RetentionTableLog AS l
    JOIN ret.RetentionConfig AS c ON c.TableConfigId = l.TableConfigId
    WHERE l.TableLogId = @TableLogId;

    IF @RunId IS NULL
    BEGIN
        ;THROW 50131, N'TableLogId not found.', 1;
    END;

    IF @Status <> 'RUNNING' OR @ProcessType NOT IN ('INITIAL_CUTOFF', 'DAILY_ROUTINE')
       OR EXISTS (SELECT 1 FROM ret.RetentionArchiveDate WHERE TableLogId = @TableLogId AND ExportStatus <> 'PENDING')
       OR EXISTS (SELECT 1 FROM ret.RetentionTableLog WHERE TableLogId = @TableLogId AND (IsValidated = 1 OR RebuildStagingTable IS NOT NULL))
    BEGIN
        SELECT @TableLogId AS TableLogId, 'FAILED' AS Result, 'NONE' AS NextAction,
               CAST(NULL AS BIGINT) AS EligibleRows, CAST(NULL AS BIGINT) AS RowsToExport, CAST(NULL AS BIGINT) AS ExpiredRows,
               CAST(NULL AS BIGINT) AS RetainedRows, CAST(NULL AS BIGINT) AS OrphanRows, CAST(NULL AS INT) AS ExportDateCount,
               CAST(NULL AS CHAR(10)) AS MinBusinessDate, CAST(NULL AS CHAR(10)) AS MaxBusinessDate,
               N'Table log is not RUNNING, process type not supported, or export / rebuild already started.' AS Message;
        RETURN;
    END;

    BEGIN TRY
        EXEC ret.usp_GetTableSqlParts @TableConfigId = @TableConfigId, @CheckUniqueness = 0,
             @IsChild = @IsChild OUTPUT, @DateExpr = @DateExpr OUTPUT, @FromSql = @FromSql OUTPUT, @OrphanExpr = @OrphanExpr OUTPUT,
             @ErrorCode = @ErrCode OUTPUT, @CheckCode = @CheckCode OUTPUT, @ErrorMessage = @Msg OUTPUT;

        IF @ErrCode IS NOT NULL
        BEGIN
            ;THROW 50132, @Msg, 1;
        END;

        DELETE FROM ret.RetentionArchiveDate WHERE TableLogId = @TableLogId;   -- re-call before export: rebuild snapshot

        SET @sql = N'INSERT INTO ret.RetentionArchiveDate (TableLogId, BusinessDate, RunId, TableConfigId, ExpectedRows, FolderPath, FileName)
SELECT @TableLogId, d.BusinessDate, @RunId, @TableConfigId, d.RowCnt,
       ret.fn_ArchiveFolderPath(@BlobPath, d.BusinessDate),
       ret.fn_ArchiveFileName(@BlobPath, d.BusinessDate)
FROM (SELECT CAST(' + @DateExpr + N' AS DATE) AS BusinessDate, COUNT_BIG(*) AS RowCnt' + @FromSql + N'
      WHERE ' + @DateExpr + N' < @DwhCutoff'
            + CASE WHEN @ProcessType = 'INITIAL_CUTOFF' THEN N' AND ' + @DateExpr + N' >= @ArchiveCutoff' ELSE N'' END + N'
      GROUP BY CAST(' + @DateExpr + N' AS DATE)) AS d;';

        EXEC sp_executesql @sql,
             N'@TableLogId BIGINT, @RunId BIGINT, @TableConfigId INT, @BlobPath NVARCHAR(400), @SchemaName SYSNAME, @TableName SYSNAME, @DwhCutoff DATE, @ArchiveCutoff DATE',
             @TableLogId = @TableLogId, @RunId = @RunId, @TableConfigId = @TableConfigId, @BlobPath = @BlobPath,
             @SchemaName = @SchemaName, @TableName = @TableName, @DwhCutoff = @DwhCutoff, @ArchiveCutoff = @ArchiveCutoff;

        /* ---- Decision D-1: never overwrite an archive file of an earlier run (FSD 4.17, ERR-EXP-02) ---- */
        SELECT @ExistCount = COUNT(*)
        FROM ret.RetentionArchiveDate AS a
        WHERE a.TableLogId = @TableLogId AND a.BusinessDate >= @ArchiveCutoff
          AND EXISTS (SELECT 1 FROM ret.RetentionArchiveDate AS e
                      WHERE e.TableConfigId = a.TableConfigId AND e.BusinessDate = a.BusinessDate
                        AND e.TableLogId <> a.TableLogId AND e.ExportStatus IN ('SUCCEEDED', 'FAILED', 'STOPPED'));

        IF @ExistCount > 0
        BEGIN
            SELECT @ExistDates = STRING_AGG(CONVERT(NVARCHAR(MAX), x.Info) COLLATE DATABASE_DEFAULT, N', ')
            FROM (SELECT TOP (20) CONCAT(CONVERT(CHAR(10), a.BusinessDate, 23), N' (RunId ', MAX(e.RunId), N')') AS Info
                  FROM ret.RetentionArchiveDate AS a
                  JOIN ret.RetentionArchiveDate AS e
                    ON e.TableConfigId = a.TableConfigId AND e.BusinessDate = a.BusinessDate
                   AND e.TableLogId <> a.TableLogId AND e.ExportStatus IN ('SUCCEEDED', 'FAILED', 'STOPPED')
                  WHERE a.TableLogId = @TableLogId AND a.BusinessDate >= @ArchiveCutoff
                  GROUP BY a.BusinessDate
                  ORDER BY a.BusinessDate) AS x;

            DELETE FROM ret.RetentionArchiveDate WHERE TableLogId = @TableLogId;

            SET @Msg = LEFT(CONCAT(N'Archive file already exists from an earlier run for ', @ExistCount,
                                   N' business date(s) with rows still in the DWH (back-dated rows?): ', @ExistDates,
                                   CASE WHEN @ExistCount > 20 THEN N', ...' ELSE N'' END,
                                   N'. Nothing exported or deleted; manual handling required (decision D-1).'), 4000);
            EXEC ret.usp_SetTableError @TableLogId = @TableLogId, @ErrorCode = 'ERR-EXP-02', @ErrorStep = 'COUNT', @ErrorMessage = @Msg;
            EXEC ret.usp_WriteStepLog @RunId = @RunId, @StepCode = 'COUNT', @Status = 'FAILED',
                 @TableLogId = @TableLogId, @TableConfigId = @TableConfigId, @StartTime = @Now,
                 @ErrorCode = 'ERR-EXP-02', @ErrorMessage = @Msg;

            SELECT @TableLogId AS TableLogId, 'FAILED' AS Result, 'NONE' AS NextAction,
                   CAST(NULL AS BIGINT) AS EligibleRows, CAST(NULL AS BIGINT) AS RowsToExport, CAST(NULL AS BIGINT) AS ExpiredRows,
                   CAST(NULL AS BIGINT) AS RetainedRows, CAST(NULL AS BIGINT) AS OrphanRows, CAST(NULL AS INT) AS ExportDateCount,
                   CAST(NULL AS CHAR(10)) AS MinBusinessDate, CAST(NULL AS CHAR(10)) AS MaxBusinessDate, @Msg AS Message;
            RETURN;
        END;

        SELECT @ToExport = ISNULL(SUM(ExpectedRows), 0), @DateCount = COUNT(*),
               @MinDate = MIN(BusinessDate), @MaxDate = MAX(BusinessDate)
        FROM ret.RetentionArchiveDate
        WHERE TableLogId = @TableLogId;

        SELECT @NullMode = DailyNullCheckMode FROM ret.RetentionParameter WHERE ParameterSetId = 1;

        IF @ProcessType = 'INITIAL_CUTOFF'
        BEGIN
            SET @sql = N'SELECT @Expired  = COUNT_BIG(CASE WHEN ' + @DateExpr + N' <  @ArchiveCutoff THEN 1 END),
       @Retained = COUNT_BIG(CASE WHEN ' + @DateExpr + N' >= @DwhCutoff OR ' + @DateExpr + N' IS NULL THEN 1 END),
       @Orphans  = COUNT_BIG(CASE WHEN ' + @OrphanExpr + N' THEN 1 END)' + @FromSql + N';';
            EXEC sp_executesql @sql,
                 N'@ArchiveCutoff DATE, @DwhCutoff DATE, @Expired BIGINT OUTPUT, @Retained BIGINT OUTPUT, @Orphans BIGINT OUTPUT',
                 @ArchiveCutoff = @ArchiveCutoff, @DwhCutoff = @DwhCutoff,
                 @Expired = @Expired OUTPUT, @Retained = @Retained OUTPUT, @Orphans = @Orphans OUTPUT;
        END
        ELSE IF @IsChild = 1 AND ISNULL(@NullMode, 'FULL') = 'FULL'
        BEGIN
            SET @sql = N'SELECT @Orphans = COUNT_BIG(*)' + @FromSql + N' WHERE ' + @OrphanExpr + N';';
            EXEC sp_executesql @sql, N'@Orphans BIGINT OUTPUT', @Orphans = @Orphans OUTPUT;
        END;

        SET @Eligible   = @ToExport + @Expired;
        SET @NextAction = CASE WHEN @ToExport > 0 THEN 'EXPORT' WHEN @Expired > 0 THEN 'VALIDATE' ELSE 'NONE' END;

        UPDATE ret.RetentionTableLog
           SET EligibleRows        = @Eligible,
               ArchivedSegmentRows = CASE WHEN @ProcessType = 'INITIAL_CUTOFF' THEN @ToExport END,
               ExpiredSegmentRows  = CASE WHEN @ProcessType = 'INITIAL_CUTOFF' THEN @Expired END,
               RetainedRowsBefore  = @Retained,
               OrphanRows          = CASE WHEN @IsChild = 1 THEN @Orphans END,
               ExportDateCount     = @DateCount,
               RowsExported        = 0,
               DeleteStatus        = CASE WHEN @Eligible = 0 THEN 'NOT_REQUIRED' ELSE DeleteStatus END
         WHERE TableLogId = @TableLogId;

        SET @Msg = CONCAT(N'Rows to export: ', @ToExport, N' in ', @DateCount, N' business dates',
                          CASE WHEN @ProcessType = 'INITIAL_CUTOFF'
                               THEN CONCAT(N'; expired: ', @Expired, N'; retained: ', @Retained) ELSE N'' END,
                          CASE WHEN @IsChild = 1 THEN CONCAT(N'; orphan child rows: ', ISNULL(CONVERT(NVARCHAR(20), @Orphans), N'not counted')) ELSE N'' END,
                          N'; next action: ', @NextAction, N'.');
        EXEC ret.usp_WriteStepLog @RunId = @RunId, @StepCode = 'COUNT', @Status = 'SUCCEEDED',
             @TableLogId = @TableLogId, @TableConfigId = @TableConfigId, @StartTime = @Now,
             @ExpectedRows = @Eligible, @Message = @Msg;

        IF @Orphans > 0
        BEGIN
            DECLARE @OrphanMsg NVARCHAR(4000) = CONCAT(@Orphans, N' child rows have no header row; they are kept in the DWH and not archived (DBR-21).');
            EXEC ret.usp_SetTableError @TableLogId = @TableLogId, @ErrorCode = 'ERR-PAR-01', @ErrorStep = 'COUNT',
                 @ErrorMessage = @OrphanMsg, @NewStatus = NULL;
            EXEC ret.usp_WriteStepLog @RunId = @RunId, @StepCode = 'COUNT', @Status = 'WARNING',
                 @TableLogId = @TableLogId, @TableConfigId = @TableConfigId, @StartTime = @Now,
                 @RowsProcessed = @Orphans, @ErrorCode = 'ERR-PAR-01', @Message = @OrphanMsg;
        END;

        SELECT @TableLogId AS TableLogId, 'SUCCEEDED' AS Result, @NextAction AS NextAction,
               @Eligible AS EligibleRows, @ToExport AS RowsToExport, @Expired AS ExpiredRows, @Retained AS RetainedRows,
               @Orphans AS OrphanRows, @DateCount AS ExportDateCount,
               CONVERT(CHAR(10), @MinDate, 23) AS MinBusinessDate, CONVERT(CHAR(10), @MaxDate, 23) AS MaxBusinessDate,
               @Msg AS Message;
    END TRY
    BEGIN CATCH
        SELECT @Msg = LEFT(ERROR_MESSAGE(), 4000), @ErrNo = ERROR_NUMBER();

        EXEC ret.usp_SetTableError @TableLogId = @TableLogId, @ErrorCode = 'ERR-SYS-01', @ErrorStep = 'COUNT',
             @ErrorMessage = @Msg, @ErrorNumber = @ErrNo;
        EXEC ret.usp_WriteStepLog @RunId = @RunId, @StepCode = 'COUNT', @Status = 'FAILED',
             @TableLogId = @TableLogId, @TableConfigId = @TableConfigId, @StartTime = @Now,
             @ErrorCode = 'ERR-SYS-01', @ErrorNumber = @ErrNo, @ErrorMessage = @Msg;

        SELECT @TableLogId AS TableLogId, 'FAILED' AS Result, 'NONE' AS NextAction,
               CAST(NULL AS BIGINT) AS EligibleRows, CAST(NULL AS BIGINT) AS RowsToExport, CAST(NULL AS BIGINT) AS ExpiredRows,
               CAST(NULL AS BIGINT) AS RetainedRows, CAST(NULL AS BIGINT) AS OrphanRows, CAST(NULL AS INT) AS ExportDateCount,
               CAST(NULL AS CHAR(10)) AS MinBusinessDate, CAST(NULL AS CHAR(10)) AS MaxBusinessDate, @Msg AS Message;
    END CATCH;
END;
GO

/* 6.6 ret.usp_GetExportPlan - business dates still to export (paged for the ADF Lookup limit) */
CREATE OR ALTER PROCEDURE ret.usp_GetExportPlan
    @TableLogId BIGINT,
    @MaxRows    INT = 5000
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP (@MaxRows)
           a.TableLogId,
           CONVERT(CHAR(10), a.BusinessDate, 23) AS BusinessDate,
           a.FolderPath,
           a.FileName,
           a.ExpectedRows
    FROM ret.RetentionArchiveDate AS a
    WHERE a.TableLogId = @TableLogId
      AND a.ExportStatus = 'PENDING'
    ORDER BY a.BusinessDate;
END;
GO

/* 6.7 ret.usp_ExportSourceRows - source of the ADF Copy activity for one business date.
       All columns of the configured table in ordinal order, no transformation. For a child table
       the rows are selected through the header date; only child columns are exported. */
CREATE OR ALTER PROCEDURE ret.usp_ExportSourceRows
    @TableLogId     BIGINT,
    @BusinessDate   DATE
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @TableConfigId INT, @ObjectId INT, @DateExpr NVARCHAR(400), @FromSql NVARCHAR(MAX),
            @ErrCode VARCHAR(12), @CheckCode VARCHAR(4), @Msg NVARCHAR(4000), @ColList NVARCHAR(MAX), @sql NVARCHAR(MAX);

    SELECT @TableConfigId = a.TableConfigId
    FROM ret.RetentionArchiveDate AS a
    WHERE a.TableLogId = @TableLogId
      AND a.BusinessDate = @BusinessDate;

    IF @TableConfigId IS NULL
    BEGIN
        ;THROW 50161, N'Business date is not part of the export plan of this table log.', 1;
    END;

    EXEC ret.usp_GetTableSqlParts @TableConfigId = @TableConfigId, @CheckUniqueness = 0,
         @ObjectId = @ObjectId OUTPUT, @DateExpr = @DateExpr OUTPUT, @FromSql = @FromSql OUTPUT,
         @ErrorCode = @ErrCode OUTPUT, @CheckCode = @CheckCode OUTPUT, @ErrorMessage = @Msg OUTPUT;

    IF @ErrCode IS NOT NULL
    BEGIN
        ;THROW 50162, @Msg, 1;
    END;

    SELECT @ColList = STRING_AGG(CONVERT(NVARCHAR(MAX), N't.' + QUOTENAME(c.name COLLATE DATABASE_DEFAULT)), N', ') WITHIN GROUP (ORDER BY c.column_id)
    FROM sys.columns AS c
    WHERE c.object_id = @ObjectId;

    SET @sql = N'SELECT ' + @ColList + @FromSql
             + N' WHERE ' + @DateExpr + N' >= @d AND ' + @DateExpr + N' < DATEADD(DAY, 1, @d);';

    EXEC sp_executesql @sql, N'@d DATE', @d = @BusinessDate;
END;
GO

/* 6.8 ret.usp_CheckExecutionWindow - IC window control (BR-17, FR-019). Always 1 for DR. */
CREATE OR ALTER PROCEDURE ret.usp_CheckExecutionWindow
    @RunId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Now DATETIME2(3) = ret.fn_NowUtc7(), @ProcessType VARCHAR(20), @WinStart TIME(0), @WinEnd TIME(0);

    SELECT @ProcessType = ProcessType FROM ret.RetentionRunLog WHERE RunId = @RunId;
    SELECT @WinStart = IcWindowStart, @WinEnd = IcWindowEnd FROM ret.RetentionParameter WHERE ParameterSetId = 1;

    SELECT CASE WHEN @ProcessType = 'INITIAL_CUTOFF'
                THEN ret.fn_IsWithinWindow(CAST(@Now AS TIME(0)), @WinStart, @WinEnd)
                ELSE CAST(1 AS BIT) END AS IsWithinWindow,
           CONVERT(CHAR(19), @Now, 120) AS NowUtc7,
           CONVERT(CHAR(5), @WinStart, 108) AS WindowStart,
           CONVERT(CHAR(5), @WinEnd, 108) AS WindowEnd;
END;
GO

/* 6.9 ret.usp_LogExportResult - result of one Copy activity.
       ContinueExport = 0 stops the loop; CleanupRequired = 1: delete this run's files of the table,
       then usp_LogCleanupResult (FR-018). For a table rebuild call usp_TableRebuildAbort first. */
CREATE OR ALTER PROCEDURE ret.usp_LogExportResult
    @TableLogId         BIGINT,
    @BusinessDate       DATE,
    @ExportStatus       VARCHAR(10),
    @RowsRead           BIGINT          = NULL,
    @RowsWritten        BIGINT          = NULL,
    @FilesWritten       INT             = NULL,
    @ExportStartTime    DATETIME2(3)    = NULL,
    @ErrorMessage       NVARCHAR(MAX)   = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Now DATETIME2(3) = ret.fn_NowUtc7();
    DECLARE @RunId BIGINT, @TableConfigId INT, @ProcessType VARCHAR(20), @FilePath NVARCHAR(2000), @Expected BIGINT,
            @WinStart TIME(0), @WinEnd TIME(0), @Continue BIT = 1, @Cleanup BIT = 0, @Remaining INT, @Msg NVARCHAR(4000),
            @StepErrCode VARCHAR(12);

    IF @ExportStatus IS NULL OR @ExportStatus NOT IN ('SUCCEEDED', 'FAILED', 'STOPPED')
    BEGIN
        ;THROW 50181, N'Invalid @ExportStatus. Allowed values: SUCCEEDED, FAILED, STOPPED.', 1;
    END;

    SELECT @RunId = a.RunId, @TableConfigId = a.TableConfigId, @ProcessType = l.ProcessType,
           @FilePath = a.FolderPath + N'/' + a.FileName, @Expected = a.ExpectedRows
    FROM ret.RetentionArchiveDate AS a
    JOIN ret.RetentionTableLog AS l ON l.TableLogId = a.TableLogId
    WHERE a.TableLogId = @TableLogId AND a.BusinessDate = @BusinessDate;

    IF @RunId IS NULL
    BEGIN
        ;THROW 50182, N'Business date is not part of the export plan of this table log.', 1;
    END;

    UPDATE ret.RetentionArchiveDate
       SET ExportStatus    = @ExportStatus,
           RowsRead        = @RowsRead,
           RowsWritten     = @RowsWritten,
           FileCount       = @FilesWritten,
           ExportStartTime = COALESCE(@ExportStartTime, ExportStartTime),
           ExportEndTime   = @Now,
           ErrorMessage    = @ErrorMessage
     WHERE TableLogId = @TableLogId AND BusinessDate = @BusinessDate;

    UPDATE ret.RetentionTableLog
       SET RowsExported = (SELECT ISNULL(SUM(RowsWritten), 0) FROM ret.RetentionArchiveDate
                           WHERE TableLogId = @TableLogId AND ExportStatus = 'SUCCEEDED')
     WHERE TableLogId = @TableLogId;

    SET @StepErrCode = CASE @ExportStatus WHEN 'FAILED' THEN 'ERR-EXP-01' WHEN 'STOPPED' THEN 'ERR-WIN-01' END;
    EXEC ret.usp_WriteStepLog @RunId = @RunId, @StepCode = 'EXPORT', @Status = @ExportStatus,
         @TableLogId = @TableLogId, @TableConfigId = @TableConfigId, @StartTime = @ExportStartTime,
         @BusinessDate = @BusinessDate, @ExpectedRows = @Expected, @RowsRead = @RowsRead, @RowsWritten = @RowsWritten,
         @FilePath = @FilePath, @FileCount = @FilesWritten, @ErrorCode = @StepErrCode, @ErrorMessage = @ErrorMessage;

    IF @ExportStatus = 'FAILED'
    BEGIN
        SET @Msg = CONCAT(N'Export failed for business date ', CONVERT(CHAR(10), @BusinessDate, 23), N'. ', @ErrorMessage);
        EXEC ret.usp_SetTableError @TableLogId = @TableLogId, @ErrorCode = 'ERR-EXP-01', @ErrorStep = 'EXPORT', @ErrorMessage = @Msg;
        SELECT @Continue = 0, @Cleanup = 1;
    END
    ELSE IF @ExportStatus = 'STOPPED'
    BEGIN
        EXEC ret.usp_SetTableError @TableLogId = @TableLogId, @ErrorCode = 'ERR-WIN-01', @ErrorStep = 'EXPORT',
             @ErrorMessage = N'Initial Cut-off window end reached during export.', @NewStatus = 'STOPPED';
        SELECT @Continue = 0, @Cleanup = 1;
    END
    ELSE IF @ProcessType = 'INITIAL_CUTOFF'
    BEGIN
        SELECT @WinStart = IcWindowStart, @WinEnd = IcWindowEnd FROM ret.RetentionParameter WHERE ParameterSetId = 1;
        SELECT @Remaining = COUNT(*) FROM ret.RetentionArchiveDate WHERE TableLogId = @TableLogId AND ExportStatus = 'PENDING';

        IF @Remaining > 0 AND ret.fn_IsWithinWindow(CAST(@Now AS TIME(0)), @WinStart, @WinEnd) = 0
        BEGIN
            EXEC ret.usp_SetTableError @TableLogId = @TableLogId, @ErrorCode = 'ERR-WIN-01', @ErrorStep = 'EXPORT',
                 @ErrorMessage = N'Initial Cut-off window end reached during export (FR-019).', @NewStatus = 'STOPPED';
            SELECT @Continue = 0, @Cleanup = 1;
        END;
    END;

    SELECT @Continue AS ContinueExport,
           @Cleanup  AS CleanupRequired,
           (SELECT COUNT(*) FROM ret.RetentionArchiveDate WHERE TableLogId = @TableLogId AND ExportStatus = 'PENDING') AS RemainingDates,
           (SELECT Status FROM ret.RetentionTableLog WHERE TableLogId = @TableLogId) AS TableStatus;
END;
GO

/* 6.10 ret.usp_ValidateArchive - row-count validation (BRQ-07, BR-08).
        Per date ExpectedRows = RowsRead = RowsWritten and export SUCCEEDED; total = rows to export.
        On success the delete range [NULL, DWH cut-off) and ValidatedRowCount = eligible rows are recorded.
        DeleteMethod: DR = BATCH_DELETE; IC = configured method (BATCH_DELETE or TABLE_REBUILD). */
CREATE OR ALTER PROCEDURE ret.usp_ValidateArchive
    @TableLogId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Now DATETIME2(3) = ret.fn_NowUtc7();
    DECLARE @RunId BIGINT, @TableConfigId INT, @ProcessType VARCHAR(20), @Status VARCHAR(10), @IsValidated BIT,
            @Eligible BIGINT, @ToExport BIGINT, @DwhCutoff DATE, @ConfigMethod VARCHAR(20), @DeleteMethod VARCHAR(20),
            @Dates INT, @FailedDates INT, @Expected BIGINT, @Written BIGINT, @Pass BIT, @Msg NVARCHAR(4000);

    SELECT @RunId = l.RunId, @TableConfigId = l.TableConfigId, @ProcessType = l.ProcessType, @Status = l.Status,
           @IsValidated = l.IsValidated, @Eligible = l.EligibleRows, @DwhCutoff = l.DwhCutoffDate,
           @ToExport = CASE WHEN l.ProcessType = 'INITIAL_CUTOFF' THEN l.ArchivedSegmentRows ELSE l.EligibleRows END,
           @ConfigMethod = c.InitialCutoffMethod
    FROM ret.RetentionTableLog AS l
    JOIN ret.RetentionConfig AS c ON c.TableConfigId = l.TableConfigId
    WHERE l.TableLogId = @TableLogId;

    IF @RunId IS NULL
    BEGIN
        ;THROW 50191, N'TableLogId not found.', 1;
    END;

    SET @DeleteMethod = CASE WHEN @ProcessType = 'INITIAL_CUTOFF' THEN @ConfigMethod ELSE 'BATCH_DELETE' END;

    IF @IsValidated = 1
    BEGIN
        SELECT 'PASSED' AS ValidationResult, ValidatedRowCount, @DeleteMethod AS DeleteMethod,
               CAST(0 AS BIT) AS CleanupRequired, N'Already validated.' AS Message
        FROM ret.RetentionTableLog WHERE TableLogId = @TableLogId;
        RETURN;
    END;

    IF @Status <> 'RUNNING' OR @Eligible IS NULL
    BEGIN
        SELECT 'FAILED' AS ValidationResult, CAST(NULL AS BIGINT) AS ValidatedRowCount, @DeleteMethod AS DeleteMethod,
               CAST(CASE WHEN EXISTS (SELECT 1 FROM ret.RetentionArchiveDate WHERE TableLogId = @TableLogId AND ExportStatus = 'SUCCEEDED')
                         THEN 1 ELSE 0 END AS BIT) AS CleanupRequired,
               N'Table log is not RUNNING or eligible data was not identified.' AS Message;
        RETURN;
    END;

    IF @Eligible = 0
    BEGIN
        SELECT 'NOT_REQUIRED' AS ValidationResult, CAST(0 AS BIGINT) AS ValidatedRowCount, @DeleteMethod AS DeleteMethod,
               CAST(0 AS BIT) AS CleanupRequired, N'No eligible rows.' AS Message;
        RETURN;
    END;

    UPDATE ret.RetentionArchiveDate
       SET ValidationResult = CASE WHEN ExportStatus = 'SUCCEEDED' AND RowsRead = ExpectedRows AND RowsWritten = ExpectedRows
                                   THEN 'PASSED' ELSE 'FAILED' END
     WHERE TableLogId = @TableLogId;

    SELECT @Dates       = COUNT(*),
           @FailedDates = ISNULL(SUM(CASE WHEN ValidationResult = 'FAILED' THEN 1 ELSE 0 END), 0),
           @Expected    = ISNULL(SUM(ExpectedRows), 0),
           @Written     = ISNULL(SUM(CASE WHEN ExportStatus = 'SUCCEEDED' THEN RowsWritten END), 0)
    FROM ret.RetentionArchiveDate
    WHERE TableLogId = @TableLogId;

    SET @Pass = CASE WHEN @FailedDates = 0 AND @Written = @Expected AND @Expected = ISNULL(@ToExport, 0) THEN 1 ELSE 0 END;

    IF @Pass = 1
    BEGIN
        UPDATE ret.RetentionTableLog
           SET IsValidated        = 1,
               ValidatedRangeFrom = NULL,
               ValidatedRangeTo   = @DwhCutoff,
               ValidatedRowCount  = @Eligible,
               DeleteStatus       = 'NOT_STARTED',
               MethodUsed         = @DeleteMethod
         WHERE TableLogId = @TableLogId;

        SET @Msg = CONCAT(N'Validation passed: ', @Dates, N' dates, ', @Written, N' rows exported; rows to remove from the DWH: ', @Eligible, N'.');
        EXEC ret.usp_WriteStepLog @RunId = @RunId, @StepCode = 'VALIDATE-ARCHIVE', @Status = 'SUCCEEDED',
             @TableLogId = @TableLogId, @TableConfigId = @TableConfigId, @StartTime = @Now,
             @ExpectedRows = @Expected, @RowsWritten = @Written, @Message = @Msg;

        SELECT 'PASSED' AS ValidationResult, @Eligible AS ValidatedRowCount, @DeleteMethod AS DeleteMethod,
               CAST(0 AS BIT) AS CleanupRequired, @Msg AS Message;
    END
    ELSE
    BEGIN
        SET @Msg = CONCAT(N'Validation failed: ', @FailedDates, N' of ', @Dates, N' dates mismatched; expected ', @Expected,
                          N', written ', @Written, N', snapshot ', @ToExport, N'. No data removed (BR-08).');
        EXEC ret.usp_SetTableError @TableLogId = @TableLogId, @ErrorCode = 'ERR-VAL-01', @ErrorStep = 'VALIDATE-ARCHIVE', @ErrorMessage = @Msg;
        EXEC ret.usp_WriteStepLog @RunId = @RunId, @StepCode = 'VALIDATE-ARCHIVE', @Status = 'FAILED',
             @TableLogId = @TableLogId, @TableConfigId = @TableConfigId, @StartTime = @Now,
             @ExpectedRows = @Expected, @RowsWritten = @Written, @ErrorCode = 'ERR-VAL-01', @ErrorMessage = @Msg;

        SELECT 'FAILED' AS ValidationResult, CAST(NULL AS BIGINT) AS ValidatedRowCount, @DeleteMethod AS DeleteMethod,
               CAST(1 AS BIT) AS CleanupRequired, @Msg AS Message;
    END;
END;
GO

/* 6.11 ret.usp_BatchDelete - batch delete of a validated range (BRQ-08, BR-08, FR-017).
        @TableLogId = log owning the validated range (current run, or an earlier run for a resume).
        Each batch: at most BatchSize rows plus the progress update in one short transaction, then
        a pause of BatchPauseSeconds. IC: stops at the window end and is resumed by the next run.
        Child table: rows are selected through the header date (FR-023); orphan rows never match. */
CREATE OR ALTER PROCEDURE ret.usp_BatchDelete
    @RunId      BIGINT,
    @TableLogId BIGINT
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Now DATETIME2(3) = ret.fn_NowUtc7();
    DECLARE @OwnerRunId BIGINT, @TableConfigId INT, @IsValidated BIT, @DeleteStatus VARCHAR(15), @OwnerMethod VARCHAR(20),
            @RangeFrom DATE, @RangeTo DATE, @ValidatedCount BIGINT, @DeletedSoFar BIGINT,
            @CurProcessType VARCHAR(20), @CurTableLogId BIGINT, @IsResume BIT,
            @DateExpr NVARCHAR(400), @FromSql NVARCHAR(MAX), @PartErr VARCHAR(12), @PartCheck VARCHAR(4), @PartMsg NVARCHAR(4000),
            @Pred NVARCHAR(1000), @BatchSize INT, @Pause INT, @RetryMax INT, @LockTimeoutMs INT, @WinStart TIME(0), @WinEnd TIME(0),
            @Delay CHAR(8), @sql NVARCHAR(MAX), @sqlCount NVARCHAR(MAX), @Remaining BIGINT, @Expected BIGINT, @rc INT, @Retry INT,
            @BatchDone BIT, @Batches INT = 0, @DeletedThisCall BIGINT = 0, @TotalDeleted BIGINT,
            @Result VARCHAR(10), @ErrCode VARCHAR(12), @ErrNum INT, @Msg NVARCHAR(4000), @Cleanup BIT = 0, @LogTarget BIGINT,
            @StepCode VARCHAR(30), @StepStatus VARCHAR(10), @RefRunId BIGINT, @StepErrCode VARCHAR(12);

    SELECT @OwnerRunId = l.RunId, @TableConfigId = l.TableConfigId,
           @IsValidated = l.IsValidated, @DeleteStatus = l.DeleteStatus, @OwnerMethod = l.MethodUsed,
           @RangeFrom = l.ValidatedRangeFrom, @RangeTo = l.ValidatedRangeTo, @ValidatedCount = l.ValidatedRowCount,
           @DeletedSoFar = ISNULL(l.RowsDeleted, 0)
    FROM ret.RetentionTableLog AS l
    WHERE l.TableLogId = @TableLogId;

    IF @OwnerRunId IS NULL
    BEGIN
        ;THROW 50201, N'TableLogId not found.', 1;
    END;

    SELECT @CurProcessType = ProcessType FROM ret.RetentionRunLog WHERE RunId = @RunId AND Status = 'RUNNING';
    SELECT @CurTableLogId  = TableLogId  FROM ret.RetentionTableLog WHERE RunId = @RunId AND TableConfigId = @TableConfigId;
    SET @IsResume  = CASE WHEN @OwnerRunId <> @RunId THEN 1 ELSE 0 END;
    SET @LogTarget = ISNULL(@CurTableLogId, @TableLogId);

    /* ---- Preconditions ---- */
    IF @CurProcessType IS NULL OR @CurProcessType NOT IN ('INITIAL_CUTOFF', 'DAILY_ROUTINE')
        SELECT @Result = 'FAILED', @ErrCode = 'ERR-SYS-01', @Msg = N'Current run not found, not RUNNING, or not IC/DR.';
    ELSE IF @CurTableLogId IS NULL
        SELECT @Result = 'FAILED', @ErrCode = 'ERR-SYS-01', @Msg = N'Table was not started in the current run (usp_BeginTable).';
    ELSE IF NOT EXISTS (SELECT 1 FROM ret.RetentionTableLock WHERE TableConfigId = @TableConfigId AND RunId = @RunId)
        SELECT @Result = 'FAILED', @ErrCode = 'ERR-LCK-01', @Msg = N'Table lock is not held by the current run.';
    ELSE IF @DeleteStatus IN ('COMPLETED', 'NOT_REQUIRED')
        SELECT @Result = 'COMPLETED', @Msg = N'Deletion already completed or not required.';
    ELSE IF @IsValidated = 0
        SELECT @Result = 'FAILED', @ErrCode = 'ERR-VAL-01', @Msg = N'Range is not validated; nothing deleted (BR-08).';
    ELSE IF @OwnerMethod = 'TABLE_REBUILD'
        SELECT @Result = 'FAILED', @ErrCode = 'ERR-SYS-01', @Msg = N'Range belongs to a table rebuild; use usp_TableRebuildSwap (BR-11, MD-06).';

    IF @Result IS NOT NULL
        GOTO Finish;

    EXEC ret.usp_GetTableSqlParts @TableConfigId = @TableConfigId, @CheckUniqueness = 0,
         @DateExpr = @DateExpr OUTPUT, @FromSql = @FromSql OUTPUT,
         @ErrorCode = @PartErr OUTPUT, @CheckCode = @PartCheck OUTPUT, @ErrorMessage = @PartMsg OUTPUT;

    IF @PartErr IS NOT NULL
    BEGIN
        SELECT @Result = 'FAILED', @ErrCode = @PartErr, @Msg = @PartMsg;
        GOTO Finish;
    END;

    SELECT @BatchSize = BatchSize, @Pause = BatchPauseSeconds, @RetryMax = ISNULL(DeleteRetryCount, 0),
           @LockTimeoutMs = ISNULL(DeleteLockTimeoutMs, -1), @WinStart = IcWindowStart, @WinEnd = IcWindowEnd
    FROM ret.RetentionParameter WHERE ParameterSetId = 1;

    SET @Delay    = ret.fn_DelayString(@Pause);
    SET @Pred     = @DateExpr + N' < @Upper' + CASE WHEN @RangeFrom IS NOT NULL THEN N' AND ' + @DateExpr + N' >= @Lower' ELSE N'' END;
    SET @sqlCount = N'SELECT @n = COUNT_BIG(*)' + @FromSql + N' WHERE ' + @Pred + N';';
    SET @sql      = N'SET LOCK_TIMEOUT ' + CONVERT(NVARCHAR(12), @LockTimeoutMs) + N';
DELETE TOP (@BatchSize) t' + @FromSql + N' WHERE ' + @Pred + N';
SET @rc = @@ROWCOUNT;';

    BEGIN TRY
        /* ---- Recount (DBR-06) / resume integrity check (FR-017) ---- */
        EXEC sp_executesql @sqlCount, N'@Upper DATE, @Lower DATE, @n BIGINT OUTPUT',
             @Upper = @RangeTo, @Lower = @RangeFrom, @n = @Remaining OUTPUT;

        SET @Expected = @ValidatedCount - @DeletedSoFar;

        IF @DeleteStatus = 'NOT_STARTED' AND @IsResume = 0
        BEGIN
            UPDATE ret.RetentionTableLog SET PreDeleteRecount = @Remaining WHERE TableLogId = @TableLogId;

            IF @Remaining <> @ValidatedCount
            BEGIN
                UPDATE ret.RetentionTableLog SET IsValidated = 0 WHERE TableLogId = @TableLogId;
                SELECT @Result = 'FAILED', @ErrCode = 'ERR-VAL-02', @Cleanup = 1,
                       @Msg = CONCAT(N'Pre-delete recount ', @Remaining, N' differs from validated total ', @ValidatedCount,
                                     N'. Nothing deleted; archive files of this run must be removed (FR-018).');
                GOTO Finish;
            END;
        END
        ELSE IF @Remaining > @Expected
        BEGIN
            UPDATE ret.RetentionTableStatus
               SET HasIntegrityIssue = 1, IntegrityIssueRunId = @RunId, ModifiedBy = ORIGINAL_LOGIN(), ModifiedAt = ret.fn_NowUtc7(),
                   FlagComment = CONCAT(N'ERR-VAL-03 on TableLogId ', @TableLogId)
             WHERE TableConfigId = @TableConfigId;
            SELECT @Result = 'FAILED', @ErrCode = 'ERR-VAL-03',
                   @Msg = CONCAT(N'Remaining rows ', @Remaining, N' exceed expected ', @Expected, N' for the validated range. Nothing deleted.');
            GOTO Finish;
        END;

        UPDATE ret.RetentionTableLog SET DeleteStatus = 'IN_PROGRESS', MethodUsed = 'BATCH_DELETE' WHERE TableLogId = @TableLogId;

        /* ---- Batch loop ---- */
        WHILE 1 = 1
        BEGIN
            IF @CurProcessType = 'INITIAL_CUTOFF'
               AND ret.fn_IsWithinWindow(CAST(ret.fn_NowUtc7() AS TIME(0)), @WinStart, @WinEnd) = 0
            BEGIN
                SELECT @Result = 'STOPPED', @ErrCode = 'ERR-WIN-01',
                       @Msg = N'Initial Cut-off window end reached during deletion; the next run resumes the range (FR-017, FR-019).';
                BREAK;
            END;

            SELECT @Retry = 0, @BatchDone = 0, @rc = 0;

            WHILE @BatchDone = 0
            BEGIN
                BEGIN TRY
                    BEGIN TRANSACTION;
                        EXEC sp_executesql @sql, N'@BatchSize INT, @Upper DATE, @Lower DATE, @rc INT OUTPUT',
                             @BatchSize = @BatchSize, @Upper = @RangeTo, @Lower = @RangeFrom, @rc = @rc OUTPUT;

                        UPDATE ret.RetentionTableLog
                           SET RowsDeleted      = ISNULL(RowsDeleted, 0) + @rc,
                               DeleteBatchCount = ISNULL(DeleteBatchCount, 0) + 1
                         WHERE TableLogId = @TableLogId;
                    COMMIT TRANSACTION;
                    SET @BatchDone = 1;
                END TRY
                BEGIN CATCH
                    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
                    SELECT @ErrNum = ERROR_NUMBER(), @Msg = LEFT(ERROR_MESSAGE(), 4000);

                    IF @ErrNum IN (1205, 1222) AND @Retry < @RetryMax
                    BEGIN
                        SET @Retry += 1;
                        WAITFOR DELAY @Delay;
                    END
                    ELSE
                        BREAK;
                END CATCH;
            END;

            IF @BatchDone = 0
            BEGIN
                SELECT @Result = 'FAILED', @ErrCode = 'ERR-DEL-01';
                BREAK;
            END;

            SELECT @Batches += 1, @DeletedThisCall += @rc;

            IF @rc < @BatchSize
                BREAK;

            WAITFOR DELAY @Delay;
        END;

        /* ---- Completion ---- */
        IF @Result IS NULL
        BEGIN
            EXEC sp_executesql @sqlCount, N'@Upper DATE, @Lower DATE, @n BIGINT OUTPUT',
                 @Upper = @RangeTo, @Lower = @RangeFrom, @n = @Remaining OUTPUT;

            IF @Remaining > 0
                SELECT @Result = 'FAILED', @ErrCode = 'ERR-DEL-02',
                       @Msg = CONCAT(@Remaining, N' rows remain in the validated range after deletion (A-03).');
            ELSE
            BEGIN
                UPDATE ret.RetentionTableLog
                   SET DeleteStatus   = 'COMPLETED',
                       ResumedByRunId = CASE WHEN @IsResume = 1 THEN @RunId ELSE ResumedByRunId END
                 WHERE TableLogId = @TableLogId;

                SELECT @TotalDeleted = RowsDeleted FROM ret.RetentionTableLog WHERE TableLogId = @TableLogId;

                IF @TotalDeleted <> @ValidatedCount
                BEGIN
                    SET @Msg = CONCAT(N'Deleted total ', @TotalDeleted, N' differs from validated total ', @ValidatedCount, N'.');
                    EXEC ret.usp_SetTableError @TableLogId = @LogTarget, @ErrorCode = 'ERR-DEL-03', @ErrorStep = 'DELETE',
                         @ErrorMessage = @Msg, @NewStatus = NULL;
                    UPDATE ret.RetentionTableStatus
                       SET HasReconciliationWarning = 1, ReconciliationWarningRunId = @RunId,
                           ModifiedBy = ORIGINAL_LOGIN(), ModifiedAt = ret.fn_NowUtc7()
                     WHERE TableConfigId = @TableConfigId;
                END
                ELSE
                    SET @Msg = CONCAT(N'Deleted ', @DeletedThisCall, N' rows in ', @Batches, N' batches.');

                SET @Result = 'COMPLETED';
            END;
        END;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SELECT @Result = 'FAILED', @ErrCode = 'ERR-SYS-01', @ErrNum = ERROR_NUMBER(), @Msg = LEFT(ERROR_MESSAGE(), 4000);
    END CATCH;

    /* ---- State after failure / stop ---- */
    IF @Result = 'FAILED' AND @ErrCode IN ('ERR-DEL-01', 'ERR-DEL-02', 'ERR-SYS-01')
       AND EXISTS (SELECT 1 FROM ret.RetentionTableLog WHERE TableLogId = @TableLogId AND DeleteStatus = 'IN_PROGRESS')
        UPDATE ret.RetentionTableLog SET DeleteStatus = 'FAILED' WHERE TableLogId = @TableLogId;

    IF @ErrCode = 'ERR-DEL-02'
        UPDATE ret.RetentionTableStatus
           SET HasIntegrityIssue = 1, IntegrityIssueRunId = @RunId, ModifiedBy = ORIGINAL_LOGIN(), ModifiedAt = ret.fn_NowUtc7(),
               FlagComment = CONCAT(N'ERR-DEL-02 on TableLogId ', @TableLogId)
         WHERE TableConfigId = @TableConfigId;

    IF @IsResume = 1 AND @DeletedThisCall > 0 AND @CurTableLogId IS NOT NULL
        UPDATE ret.RetentionTableLog SET ResumeRowsDeleted = ISNULL(ResumeRowsDeleted, 0) + @DeletedThisCall
         WHERE TableLogId = @CurTableLogId;

Finish:
    SELECT @StepCode    = CASE WHEN @IsResume = 1 THEN 'RESUME' ELSE 'DELETE' END,
           @StepStatus  = CASE @Result WHEN 'COMPLETED' THEN 'SUCCEEDED' WHEN 'STOPPED' THEN 'STOPPED' ELSE 'FAILED' END,
           @RefRunId    = CASE WHEN @IsResume = 1 THEN @OwnerRunId END,
           @StepErrCode = CASE WHEN @Result <> 'COMPLETED' THEN @ErrCode END;

    IF @Result IN ('FAILED', 'STOPPED') AND @ErrCode IS NOT NULL
        EXEC ret.usp_SetTableError @TableLogId = @LogTarget, @ErrorCode = @ErrCode, @ErrorStep = @StepCode,
             @ErrorMessage = @Msg, @ErrorNumber = @ErrNum, @NewStatus = @Result;

    EXEC ret.usp_WriteStepLog @RunId = @RunId, @StepCode = @StepCode, @Status = @StepStatus,
         @TableLogId = @CurTableLogId, @TableConfigId = @TableConfigId, @StartTime = @Now,
         @BatchCount = @Batches, @RowsProcessed = @DeletedThisCall, @ReferenceRunId = @RefRunId,
         @ErrorCode = @StepErrCode, @ErrorNumber = @ErrNum, @Message = @Msg;

    SELECT @Result AS DeleteResult, @DeletedThisCall AS RowsDeleted, @Batches AS BatchCount, @IsResume AS IsResume,
           @Cleanup AS CleanupRequired, @ErrCode AS ErrorCode, @Msg AS Message;
END;
GO

/* =====================================================================================
   7. TABLE REBUILD - Initial Cut-off Run only (BRQ-09, BR-10, BR-11, MD-04, MD-06, FSD 8.4)
      Sequence (FSD RB-01..RB-10, MD-04 steps 1-5):
        usp_TableRebuildPrepare  RB-01 checks, RB-02 script definition, RB-03 new table
                                 <table>__RBD_<RunId> with the retained rows (step 1),
                                 RB-04 keys, constraints, indexes (step 2), RB-05 count check
        ADF export loop          RB-06 archive rows between 3 and 8 years from the ORIGINAL table (step 3)
        usp_ValidateArchive      RB-07 row-count validation
        usp_TableRebuildSwap     RB-07 recount, RB-08 one transaction: truncate original (step 4),
                                 drop original, rename new table, constraints and indexes (step 5),
                                 re-create triggers, permissions, extended properties;
                                 RB-09 identity reseed, view refresh; RB-10 definition check
        usp_TableRebuildAbort    any failure before RB-08 commits: drop the new table, revoke the
                                 validation, request removal of this run's files
      Preconditions: approved downtime (run DowntimeReference), ETL writes stopped, valid backup or
      point-in-time restore point confirmed (R-02), database space for the new table (checked) and
      transaction log capacity agreed with the DBA (R-06). Rebuild is never resumed across runs.
   ===================================================================================== */

/* 7.1 ret.usp_TableRebuildAbort - undo an unfinished rebuild (also used by usp_BeginTable,
       usp_EndTable, usp_EndRun and usp_AdminCloseStaleRun). Never touches the original table.
       @MarkOrphanFiles = 1: archive files of that run stay in Blob Storage and the table gets the
       orphan-file flag (used when ADF will not run the file cleanup). */
CREATE OR ALTER PROCEDURE ret.usp_TableRebuildAbort
    @RunId              BIGINT,
    @TableLogId         BIGINT,
    @MarkOrphanFiles    BIT = 0,
    @Silent             BIT = 0,
    @CleanupRequired    BIT = NULL OUTPUT
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Now DATETIME2(3) = ret.fn_NowUtc7();
    DECLARE @LogRunId BIGINT, @TableConfigId INT, @MethodUsed VARCHAR(20), @DeleteStatus VARCHAR(15), @IsValidated BIT,
            @NewFull NVARCHAR(260), @SchemaName SYSNAME, @TableName SYSNAME, @Expected NVARCHAR(300), @HasFiles BIT,
            @Result VARCHAR(15), @Msg NVARCHAR(4000), @sql NVARCHAR(MAX), @StepStatus VARCHAR(10), @StepErrCode VARCHAR(12), @ErrNo INT;

    SELECT @LogRunId = l.RunId, @TableConfigId = l.TableConfigId, @MethodUsed = l.MethodUsed, @DeleteStatus = l.DeleteStatus,
           @IsValidated = l.IsValidated, @NewFull = l.RebuildStagingTable, @SchemaName = c.SchemaName, @TableName = c.TableName
    FROM ret.RetentionTableLog AS l
    JOIN ret.RetentionConfig AS c ON c.TableConfigId = l.TableConfigId
    WHERE l.TableLogId = @TableLogId;

    IF @LogRunId IS NULL
    BEGIN
        ;THROW 50431, N'TableLogId not found.', 1;
    END;

    SET @CleanupRequired = 0;

    IF ISNULL(@MethodUsed, '') <> 'TABLE_REBUILD' OR @DeleteStatus = 'COMPLETED' OR (@NewFull IS NULL AND @IsValidated = 0)
    BEGIN
        SELECT @Result = 'NOT_REQUIRED', @Msg = N'No unfinished table rebuild for this table log.';
    END
    ELSE
    BEGIN
        BEGIN TRY
            -- Only the new table of this run may be dropped
            SET @Expected = QUOTENAME(@SchemaName) + N'.' + QUOTENAME(CONCAT(@TableName, N'__RBD_', @LogRunId));

            IF @NewFull IS NOT NULL AND @NewFull <> @Expected
            BEGIN
                ;THROW 50432, N'RebuildStagingTable does not match the expected rebuild table name; nothing dropped.', 1;
            END;

            IF OBJECT_ID(@Expected, N'U') IS NOT NULL
            BEGIN
                SET @sql = N'DROP TABLE ' + @Expected + N';';
                EXEC sp_executesql @sql;
            END;

            UPDATE ret.RetentionTableLog
               SET IsValidated = 0, DeleteStatus = 'NOT_STARTED', RebuildStagingTable = NULL
             WHERE TableLogId = @TableLogId;

            SET @HasFiles = CASE WHEN EXISTS (SELECT 1 FROM ret.RetentionArchiveDate
                                              WHERE TableLogId = @TableLogId AND ExportStatus IN ('SUCCEEDED', 'FAILED', 'STOPPED'))
                                 THEN 1 ELSE 0 END;

            IF @HasFiles = 1 AND @MarkOrphanFiles = 1
            BEGIN
                UPDATE ret.RetentionTableStatus
                   SET HasOrphanFiles = 1, OrphanFilesRunId = @LogRunId, ModifiedBy = ORIGINAL_LOGIN(), ModifiedAt = ret.fn_NowUtc7(),
                       FlagComment = CONCAT(N'Unfinished table rebuild of RunId ', @LogRunId, N': remove the files of that run listed in ret.RetentionArchiveDate')
                 WHERE TableConfigId = @TableConfigId;
                SET @Msg = CONCAT(N'Unfinished rebuild of RunId ', @LogRunId, N' undone: new table dropped, validation revoked, original table unchanged. ',
                                  N'Archive files of RunId ', @LogRunId, N' flagged as orphan files.');
            END
            ELSE
            BEGIN
                SET @CleanupRequired = @HasFiles;
                SET @Msg = CONCAT(N'Unfinished rebuild undone: new table dropped, validation revoked, original table unchanged.',
                                  CASE WHEN @HasFiles = 1 THEN N' Remove the archive files of this run (CleanupRequired).' ELSE N'' END);
            END;

            SET @Result = 'ABORTED';
        END TRY
        BEGIN CATCH
            SELECT @Result = 'FAILED', @Msg = LEFT(ERROR_MESSAGE(), 4000), @ErrNo = ERROR_NUMBER();
        END CATCH;
    END;

    IF @Result <> 'NOT_REQUIRED'
    BEGIN
        SELECT @StepStatus  = CASE WHEN @Result = 'ABORTED' THEN 'SUCCEEDED' ELSE 'FAILED' END,
               @StepErrCode = CASE WHEN @Result = 'FAILED' THEN 'ERR-RBD-01' END;
        EXEC ret.usp_WriteStepLog @RunId = @RunId, @StepCode = 'REBUILD', @Status = @StepStatus,
             @TableLogId = @TableLogId, @TableConfigId = @TableConfigId, @StartTime = @Now, @ReferenceRunId = @LogRunId,
             @Message = @Msg, @ErrorCode = @StepErrCode, @ErrorNumber = @ErrNo;
    END;

    IF @Silent = 0
        SELECT @Result AS AbortResult, @CleanupRequired AS CleanupRequired, @Msg AS Message;
END;
GO

/* 7.2 ret.usp_TableRebuildPrepare - RB-01..RB-05. The original table is not changed.
       Retained rows (business date >= DWH cut-off, plus orphan child rows) are copied per year
       into <schema>.<table>__RBD_<RunId>; keys, constraints and indexes are added afterwards
       under temporary names RBD<RunId>_C<object_id> / RBD<RunId>_I<index_id>. */
CREATE OR ALTER PROCEDURE ret.usp_TableRebuildPrepare
    @RunId      BIGINT,
    @TableLogId BIGINT
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Now DATETIME2(3) = ret.fn_NowUtc7();
    DECLARE @LogRunId BIGINT, @TableConfigId INT, @Status VARCHAR(10), @IsValidated BIT, @Eligible BIGINT, @Retained BIGINT,
            @DwhCutoff DATE, @StagingNow NVARCHAR(260), @ConfigMethod VARCHAR(20), @SchemaName SYSNAME, @TableName SYSNAME,
            @CurProcessType VARCHAR(20), @Downtime NVARCHAR(100), @WinStart TIME(0), @WinEnd TIME(0),
            @FullName NVARCHAR(300), @ObjectId INT, @DateExpr NVARCHAR(400), @FromSql NVARCHAR(MAX),
            @PartErr VARCHAR(12), @PartCheck VARCHAR(4), @PartMsg NVARCHAR(4000),
            @Unsupported NVARCHAR(MAX), @NewName NVARCHAR(400), @NewFull NVARCHAR(300), @Prefix NVARCHAR(40),
            @ColDefs NVARCHAR(MAX), @ColList NVARCHAR(MAX), @SelList NVARCHAR(MAX), @HasIdentity BIT, @sql NVARCHAR(MAX), @InsSql NVARCHAR(MAX),
            @Year INT, @From DATE, @To DATE, @n BIGINT, @Inserted BIGINT = 0, @Recount BIGINT, @NewCount BIGINT,
            @MaxBytes BIGINT, @UsedBytes BIGINT, @TableBytes BIGINT, @NeedBytes BIGINT,
            @DdlOrd INT, @DdlSql NVARCHAR(MAX), @Created BIT = 0,
            @Result VARCHAR(15), @ErrCode VARCHAR(12), @ErrNum INT, @Msg NVARCHAR(4000), @StepStatus VARCHAR(10), @StepErrCode VARCHAR(12);

    SELECT @LogRunId = l.RunId, @TableConfigId = l.TableConfigId, @Status = l.Status, @IsValidated = l.IsValidated,
           @Eligible = l.EligibleRows, @Retained = l.RetainedRowsBefore, @DwhCutoff = l.DwhCutoffDate, @StagingNow = l.RebuildStagingTable,
           @ConfigMethod = c.InitialCutoffMethod, @SchemaName = c.SchemaName, @TableName = c.TableName
    FROM ret.RetentionTableLog AS l
    JOIN ret.RetentionConfig AS c ON c.TableConfigId = l.TableConfigId
    WHERE l.TableLogId = @TableLogId;

    IF @LogRunId IS NULL
    BEGIN
        ;THROW 50411, N'TableLogId not found.', 1;
    END;

    SELECT @CurProcessType = ProcessType, @Downtime = DowntimeReference FROM ret.RetentionRunLog WHERE RunId = @RunId AND Status = 'RUNNING';
    SELECT @WinStart = IcWindowStart, @WinEnd = IcWindowEnd FROM ret.RetentionParameter WHERE ParameterSetId = 1;

    SET @NewName = CONCAT(@TableName, N'__RBD_', @RunId);
    SET @NewFull = QUOTENAME(@SchemaName) + N'.' + QUOTENAME(LEFT(@NewName, 128));
    SET @Prefix  = CONCAT(N'RBD', @RunId);

    /* ---- Preconditions ---- */
    IF ISNULL(@CurProcessType, '') <> 'INITIAL_CUTOFF'
        SELECT @Result = 'FAILED', @ErrCode = 'ERR-SYS-01', @Msg = N'Table rebuild is allowed only in a RUNNING Initial Cut-off Run (BR-10).';
    ELSE IF @LogRunId <> @RunId
        SELECT @Result = 'FAILED', @ErrCode = 'ERR-SYS-01', @Msg = N'A table rebuild is never resumed; the table log must belong to the current run.';
    ELSE IF @Downtime IS NULL
        SELECT @Result = 'FAILED', @ErrCode = 'ERR-RBD-01', @Msg = N'Run has no downtime reference (BR-16, D-07).';
    ELSE IF @ConfigMethod <> 'TABLE_REBUILD'
        SELECT @Result = 'FAILED', @ErrCode = 'ERR-SYS-01', @Msg = N'Configured IC method is not TABLE_REBUILD (BR-11).';
    ELSE IF NOT EXISTS (SELECT 1 FROM ret.RetentionTableLock WHERE TableConfigId = @TableConfigId AND RunId = @RunId)
        SELECT @Result = 'FAILED', @ErrCode = 'ERR-LCK-01', @Msg = N'Table lock is not held by the current run.';
    ELSE IF @Status <> 'RUNNING' OR @Eligible IS NULL
        SELECT @Result = 'FAILED', @ErrCode = 'ERR-SYS-01', @Msg = N'Table log is not RUNNING or eligible data was not identified.';
    ELSE IF @Eligible = 0
        SELECT @Result = 'NOT_REQUIRED', @Msg = N'No eligible rows; no rebuild required.';
    ELSE IF @IsValidated = 1
        SELECT @Result = 'FAILED', @ErrCode = 'ERR-SYS-01', @Msg = N'Range already validated; the new table must be prepared before the export (RB-03 before RB-06).';
    ELSE IF @StagingNow = @NewFull AND OBJECT_ID(@NewFull, N'U') IS NOT NULL
        SELECT @Result = 'COMPLETED', @Msg = N'New table already prepared in this run.';
    ELSE IF LEN(@NewName) > 128
        SELECT @Result = 'FAILED', @ErrCode = 'ERR-RBD-04', @Msg = N'Name of the new table would exceed 128 characters.';
    ELSE IF ret.fn_IsWithinWindow(CAST(@Now AS TIME(0)), @WinStart, @WinEnd) = 0
        SELECT @Result = 'STOPPED', @ErrCode = 'ERR-WIN-01', @Msg = N'Outside the Initial Cut-off window; rebuild not started.';

    IF @Result IS NOT NULL
        GOTO Finish;

    EXEC ret.usp_GetTableSqlParts @TableConfigId = @TableConfigId, @CheckUniqueness = 0,
         @FullName = @FullName OUTPUT, @ObjectId = @ObjectId OUTPUT, @DateExpr = @DateExpr OUTPUT, @FromSql = @FromSql OUTPUT,
         @ErrorCode = @PartErr OUTPUT, @CheckCode = @PartCheck OUTPUT, @ErrorMessage = @PartMsg OUTPUT;

    IF @PartErr IS NOT NULL
    BEGIN
        SELECT @Result = 'FAILED', @ErrCode = @PartErr, @Msg = @PartMsg;
        GOTO Finish;
    END;

    /* ---- RB-01 unsupported features ---- */
    SELECT @Unsupported = STRING_AGG(CONVERT(NVARCHAR(MAX), x.Reason) COLLATE DATABASE_DEFAULT, N'; ')
    FROM (
        SELECT CONCAT(N'referenced by foreign key ', QUOTENAME(fk.name COLLATE DATABASE_DEFAULT), N' of ', QUOTENAME(OBJECT_SCHEMA_NAME(fk.parent_object_id)), N'.',
                      QUOTENAME(OBJECT_NAME(fk.parent_object_id))) AS Reason
        FROM sys.foreign_keys AS fk WHERE fk.referenced_object_id = @ObjectId
        UNION ALL
        SELECT CONCAT(N'referenced by schema-bound module ', QUOTENAME(OBJECT_SCHEMA_NAME(m.object_id)), N'.', QUOTENAME(OBJECT_NAME(m.object_id)))
        FROM sys.sql_expression_dependencies AS d
        JOIN sys.sql_modules AS m ON m.object_id = d.referencing_id
        WHERE d.referenced_id = @ObjectId AND m.is_schema_bound = 1
        UNION ALL
        SELECT N'system-versioned temporal or history table' FROM sys.tables AS t WHERE t.object_id = @ObjectId AND t.temporal_type <> 0
        UNION ALL
        SELECT N'memory-optimized table' FROM sys.tables AS t WHERE t.object_id = @ObjectId AND t.is_memory_optimized = 1
        UNION ALL
        SELECT N'graph table' FROM sys.tables AS t WHERE t.object_id = @ObjectId AND (t.is_node = 1 OR t.is_edge = 1)
        UNION ALL
        SELECT N'ledger table' FROM sys.tables AS t WHERE t.object_id = @ObjectId AND t.ledger_type <> 0
        UNION ALL
        SELECT N'tracked by change data capture' FROM sys.tables AS t WHERE t.object_id = @ObjectId AND t.is_tracked_by_cdc = 1
        UNION ALL
        SELECT N'change tracking enabled' FROM sys.change_tracking_tables AS ct WHERE ct.object_id = @ObjectId
        UNION ALL
        SELECT N'replicated table' FROM sys.tables AS t WHERE t.object_id = @ObjectId AND (t.is_replicated = 1 OR t.is_merge_published = 1)
        UNION ALL
        SELECT DISTINCT N'partitioned table' FROM sys.indexes AS i JOIN sys.data_spaces AS ds ON ds.data_space_id = i.data_space_id
        WHERE i.object_id = @ObjectId AND ds.type = 'PS'
        UNION ALL
        SELECT CONCAT(N'rowversion column ', QUOTENAME(c.name COLLATE DATABASE_DEFAULT)) FROM sys.columns AS c WHERE c.object_id = @ObjectId AND TYPE_NAME(c.system_type_id) = 'timestamp'
        UNION ALL
        SELECT CONCAT(N'GENERATED ALWAYS column ', QUOTENAME(c.name COLLATE DATABASE_DEFAULT)) FROM sys.columns AS c WHERE c.object_id = @ObjectId AND c.generated_always_type <> 0
        UNION ALL
        SELECT CONCAT(N'sparse column or column set ', QUOTENAME(c.name COLLATE DATABASE_DEFAULT)) FROM sys.columns AS c WHERE c.object_id = @ObjectId AND (c.is_sparse = 1 OR c.is_column_set = 1)
        UNION ALL
        SELECT CONCAT(N'masked column ', QUOTENAME(c.name COLLATE DATABASE_DEFAULT)) FROM sys.columns AS c WHERE c.object_id = @ObjectId AND c.is_masked = 1
        UNION ALL
        SELECT CONCAT(N'encrypted column ', QUOTENAME(c.name COLLATE DATABASE_DEFAULT)) FROM sys.columns AS c WHERE c.object_id = @ObjectId AND c.encryption_type IS NOT NULL
        UNION ALL
        SELECT CONCAT(N'typed xml column ', QUOTENAME(c.name COLLATE DATABASE_DEFAULT)) FROM sys.columns AS c WHERE c.object_id = @ObjectId AND c.xml_collection_id <> 0
        UNION ALL
        SELECT CONCAT(N'index type ', i.type_desc COLLATE DATABASE_DEFAULT, N' ', QUOTENAME(i.name COLLATE DATABASE_DEFAULT)) FROM sys.indexes AS i WHERE i.object_id = @ObjectId AND i.type NOT IN (0, 1, 2)
        UNION ALL
        SELECT N'full-text index' FROM sys.fulltext_indexes AS f WHERE f.object_id = @ObjectId
        UNION ALL
        SELECT CONCAT(N'trigger without readable definition ', QUOTENAME(tr.name COLLATE DATABASE_DEFAULT))
        FROM sys.triggers AS tr LEFT JOIN sys.sql_modules AS m ON m.object_id = tr.object_id
        WHERE tr.parent_id = @ObjectId AND m.definition COLLATE DATABASE_DEFAULT IS NULL
        UNION ALL
        SELECT CONCAT(N'NOT FOR REPLICATION constraint ', QUOTENAME(ck.name COLLATE DATABASE_DEFAULT)) FROM sys.check_constraints AS ck
        WHERE ck.parent_object_id = @ObjectId AND ck.is_not_for_replication = 1
        UNION ALL
        SELECT CONCAT(N'NOT FOR REPLICATION constraint ', QUOTENAME(fk.name COLLATE DATABASE_DEFAULT)) FROM sys.foreign_keys AS fk
        WHERE fk.parent_object_id = @ObjectId AND fk.is_not_for_replication = 1
    ) AS x;

    IF @Unsupported IS NOT NULL
    BEGIN
        SELECT @Result = 'FAILED', @ErrCode = 'ERR-RBD-04',
               @Msg = LEFT(CONCAT(N'Rebuild not supported (RB-01): ', @Unsupported, N'. Use BATCH_DELETE or an approved table-specific procedure (OQ-11).'), 4000);
        GOTO Finish;
    END;

    /* ---- RB-01 database space for the new table (estimate: retained share of the table size) ---- */
    SELECT @MaxBytes = CONVERT(BIGINT, DATABASEPROPERTYEX(DB_NAME(), 'MaxSizeInBytes'));
    SELECT @UsedBytes  = SUM(CONVERT(BIGINT, reserved_page_count)) * 8192 FROM sys.dm_db_partition_stats;
    SELECT @TableBytes = SUM(CONVERT(BIGINT, reserved_page_count)) * 8192 FROM sys.dm_db_partition_stats WHERE object_id = @ObjectId;
    SET @NeedBytes = CONVERT(BIGINT, ISNULL(@TableBytes, 0) * (CONVERT(FLOAT, ISNULL(@Retained, 0)) / NULLIF(ISNULL(@Retained, 0) + @Eligible, 0)));

    IF @MaxBytes > 0 AND @UsedBytes + @NeedBytes > @MaxBytes * 0.95
    BEGIN
        SELECT @Result = 'FAILED', @ErrCode = 'ERR-RBD-01',
               @Msg = CONCAT(N'Insufficient database space for the new table: used ', @UsedBytes / 1048576, N' MB + estimated ',
                             @NeedBytes / 1048576, N' MB exceeds 95% of the maximum size ', @MaxBytes / 1048576, N' MB (R-06).');
        GOTO Finish;
    END;

    /* ---- RB-02 script the column definitions ---- */
    SELECT @ColDefs = STRING_AGG(CONVERT(NVARCHAR(MAX), d.ColDef) COLLATE DATABASE_DEFAULT, N',' + NCHAR(10) + N'    ') WITHIN GROUP (ORDER BY d.column_id)
    FROM (
        SELECT c.column_id,
               QUOTENAME(c.name COLLATE DATABASE_DEFAULT) + N' ' +
               CASE WHEN cc.column_id IS NOT NULL
                    THEN N'AS ' + cc.definition COLLATE DATABASE_DEFAULT
                         + CASE WHEN cc.is_persisted = 1 THEN N' PERSISTED' + CASE WHEN c.is_nullable = 0 THEN N' NOT NULL' ELSE N'' END ELSE N'' END
                    ELSE ret.fn_ColumnTypeSql(c.user_type_id, c.max_length, c.precision, c.scale)
                         + CASE WHEN c.collation_name COLLATE DATABASE_DEFAULT IS NOT NULL AND ty.is_user_defined = 0 THEN N' COLLATE ' + c.collation_name COLLATE DATABASE_DEFAULT ELSE N'' END
                         + CASE WHEN ic.column_id IS NOT NULL
                                THEN N' IDENTITY(' + CONVERT(NVARCHAR(40), ic.seed_value) + N', ' + CONVERT(NVARCHAR(40), ic.increment_value) + N')'
                                ELSE N'' END
                         + CASE WHEN c.is_nullable = 1 THEN N' NULL' ELSE N' NOT NULL' END
               END AS ColDef
        FROM sys.columns AS c
        JOIN sys.types AS ty ON ty.user_type_id = c.user_type_id
        LEFT JOIN sys.computed_columns AS cc ON cc.object_id = c.object_id AND cc.column_id = c.column_id
        LEFT JOIN sys.identity_columns AS ic ON ic.object_id = c.object_id AND ic.column_id = c.column_id
        WHERE c.object_id = @ObjectId
    ) AS d;

    SELECT @ColList = STRING_AGG(CONVERT(NVARCHAR(MAX), QUOTENAME(c.name COLLATE DATABASE_DEFAULT)), N', ') WITHIN GROUP (ORDER BY c.column_id),
           @SelList = STRING_AGG(CONVERT(NVARCHAR(MAX), N't.' + QUOTENAME(c.name COLLATE DATABASE_DEFAULT)), N', ') WITHIN GROUP (ORDER BY c.column_id)
    FROM sys.columns AS c
    WHERE c.object_id = @ObjectId AND c.is_computed = 0;

    SET @HasIdentity = CASE WHEN EXISTS (SELECT 1 FROM sys.identity_columns WHERE object_id = @ObjectId) THEN 1 ELSE 0 END;

    /* ---- RB-04 statements (executed after the data load), temporary names ---- */
    CREATE TABLE #Ddl (Ord INT IDENTITY(1, 1) PRIMARY KEY, Phase TINYINT NOT NULL, Sql NVARCHAR(MAX) NOT NULL, Done BIT NOT NULL DEFAULT (0));

    -- Indexes and PRIMARY KEY / UNIQUE constraints (clustered first)
    INSERT INTO #Ddl (Phase, Sql)
    SELECT CASE WHEN i.type = 1 THEN 1 ELSE 2 END,
           CASE WHEN i.is_primary_key = 1 OR i.is_unique_constraint = 1
                THEN N'ALTER TABLE ' + @NewFull + N' ADD CONSTRAINT ' + QUOTENAME(CONCAT(@Prefix, N'_C', kc.object_id))
                     + CASE WHEN i.is_primary_key = 1 THEN N' PRIMARY KEY ' ELSE N' UNIQUE ' END + i.type_desc COLLATE DATABASE_DEFAULT
                     + N' (' + k.KeyCols + N')' + ISNULL(w.WithSql, N'') + N';'
                ELSE N'CREATE ' + CASE WHEN i.is_unique = 1 THEN N'UNIQUE ' ELSE N'' END + i.type_desc COLLATE DATABASE_DEFAULT + N' INDEX '
                     + QUOTENAME(CONCAT(@Prefix, N'_I', i.index_id)) + N' ON ' + @NewFull + N' (' + k.KeyCols + N')'
                     + ISNULL(N' INCLUDE (' + k.IncCols + N')', N'') + ISNULL(N' WHERE ' + i.filter_definition COLLATE DATABASE_DEFAULT, N'')
                     + ISNULL(w.WithSql, N'') + N';'
           END
           + CASE WHEN i.is_disabled = 1
                  THEN NCHAR(10) + N'ALTER INDEX ' + QUOTENAME(CASE WHEN kc.object_id IS NOT NULL THEN CONCAT(@Prefix, N'_C', kc.object_id)
                                                                     ELSE CONCAT(@Prefix, N'_I', i.index_id) END)
                       + N' ON ' + @NewFull + N' DISABLE;'
                  ELSE N'' END
    FROM sys.indexes AS i
    LEFT JOIN sys.key_constraints AS kc ON kc.parent_object_id = i.object_id AND kc.unique_index_id = i.index_id
    OUTER APPLY (SELECT STRING_AGG(CASE WHEN ic.key_ordinal > 0
                                        THEN CONVERT(NVARCHAR(MAX), QUOTENAME(c.name COLLATE DATABASE_DEFAULT) + CASE WHEN ic.is_descending_key = 1 THEN N' DESC' ELSE N' ASC' END) END COLLATE DATABASE_DEFAULT, N', ')
                               WITHIN GROUP (ORDER BY ic.key_ordinal, ic.index_column_id) AS KeyCols,
                        STRING_AGG(CASE WHEN ic.is_included_column = 1 THEN CONVERT(NVARCHAR(MAX), QUOTENAME(c.name COLLATE DATABASE_DEFAULT)) END, N', ')
                               WITHIN GROUP (ORDER BY ic.key_ordinal, ic.index_column_id) AS IncCols
                 FROM sys.index_columns AS ic
                 JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                 WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id) AS k
    OUTER APPLY (SELECT MIN(p.data_compression_desc COLLATE DATABASE_DEFAULT) AS Compression
                 FROM sys.partitions AS p WHERE p.object_id = i.object_id AND p.index_id = i.index_id) AS pz
    OUTER APPLY (SELECT N' WITH (' + STRING_AGG(o.Opt COLLATE DATABASE_DEFAULT, N', ') + N')' AS WithSql
                 FROM (VALUES (CASE WHEN i.fill_factor > 0 THEN CONCAT(N'FILLFACTOR = ', i.fill_factor) END),
                              (CASE WHEN i.is_padded = 1 THEN N'PAD_INDEX = ON' END),
                              (CASE WHEN i.ignore_dup_key = 1 THEN N'IGNORE_DUP_KEY = ON' END),
                              (CASE WHEN i.allow_row_locks = 0 THEN N'ALLOW_ROW_LOCKS = OFF' END),
                              (CASE WHEN i.allow_page_locks = 0 THEN N'ALLOW_PAGE_LOCKS = OFF' END),
                              (CASE WHEN pz.Compression <> N'NONE' THEN N'DATA_COMPRESSION = ' + pz.Compression END)) AS o (Opt)) AS w
    WHERE i.object_id = @ObjectId AND i.index_id > 0
    ORDER BY CASE WHEN i.type = 1 THEN 0 ELSE 1 END, i.index_id;

    -- Heap compression
    INSERT INTO #Ddl (Phase, Sql)
    SELECT 1, N'ALTER TABLE ' + @NewFull + N' REBUILD WITH (DATA_COMPRESSION = ' + p.data_compression_desc COLLATE DATABASE_DEFAULT + N');'
    FROM sys.partitions AS p
    WHERE p.object_id = @ObjectId AND p.index_id = 0 AND p.partition_number = 1 AND p.data_compression_desc COLLATE DATABASE_DEFAULT <> N'NONE';

    -- Default constraints
    INSERT INTO #Ddl (Phase, Sql)
    SELECT 3, N'ALTER TABLE ' + @NewFull + N' ADD CONSTRAINT ' + QUOTENAME(CONCAT(@Prefix, N'_C', dc.object_id))
              + N' DEFAULT ' + dc.definition COLLATE DATABASE_DEFAULT + N' FOR ' + QUOTENAME(c.name COLLATE DATABASE_DEFAULT) + N';'
    FROM sys.default_constraints AS dc
    JOIN sys.columns AS c ON c.object_id = dc.parent_object_id AND c.column_id = dc.parent_column_id
    WHERE dc.parent_object_id = @ObjectId;

    -- Check constraints (trusted / not trusted / disabled as in the original)
    INSERT INTO #Ddl (Phase, Sql)
    SELECT 4, N'ALTER TABLE ' + @NewFull + CASE WHEN ck.is_not_trusted = 1 THEN N' WITH NOCHECK' ELSE N' WITH CHECK' END
              + N' ADD CONSTRAINT ' + QUOTENAME(CONCAT(@Prefix, N'_C', ck.object_id)) + N' CHECK ' + ck.definition COLLATE DATABASE_DEFAULT + N';'
              + CASE WHEN ck.is_disabled = 1
                     THEN NCHAR(10) + N'ALTER TABLE ' + @NewFull + N' NOCHECK CONSTRAINT ' + QUOTENAME(CONCAT(@Prefix, N'_C', ck.object_id)) + N';'
                     ELSE N'' END
    FROM sys.check_constraints AS ck
    WHERE ck.parent_object_id = @ObjectId;

    -- Outgoing foreign keys
    INSERT INTO #Ddl (Phase, Sql)
    SELECT 5, N'ALTER TABLE ' + @NewFull + CASE WHEN fk.is_not_trusted = 1 THEN N' WITH NOCHECK' ELSE N' WITH CHECK' END
              + N' ADD CONSTRAINT ' + QUOTENAME(CONCAT(@Prefix, N'_C', fk.object_id))
              + N' FOREIGN KEY (' + fc.ParentCols + N') REFERENCES '
              + QUOTENAME(OBJECT_SCHEMA_NAME(fk.referenced_object_id)) + N'.' + QUOTENAME(OBJECT_NAME(fk.referenced_object_id))
              + N' (' + fc.RefCols + N') ON DELETE ' + REPLACE(fk.delete_referential_action_desc COLLATE DATABASE_DEFAULT, N'_', N' ')
              + N' ON UPDATE ' + REPLACE(fk.update_referential_action_desc COLLATE DATABASE_DEFAULT, N'_', N' ') + N';'
              + CASE WHEN fk.is_disabled = 1
                     THEN NCHAR(10) + N'ALTER TABLE ' + @NewFull + N' NOCHECK CONSTRAINT ' + QUOTENAME(CONCAT(@Prefix, N'_C', fk.object_id)) + N';'
                     ELSE N'' END
    FROM sys.foreign_keys AS fk
    OUTER APPLY (SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), QUOTENAME(COL_NAME(x.parent_object_id, x.parent_column_id))) COLLATE DATABASE_DEFAULT, N', ')
                               WITHIN GROUP (ORDER BY x.constraint_column_id) AS ParentCols,
                        STRING_AGG(CONVERT(NVARCHAR(MAX), QUOTENAME(COL_NAME(x.referenced_object_id, x.referenced_column_id))) COLLATE DATABASE_DEFAULT, N', ')
                               WITHIN GROUP (ORDER BY x.constraint_column_id) AS RefCols
                 FROM sys.foreign_key_columns AS x WHERE x.constraint_object_id = fk.object_id) AS fc
    WHERE fk.parent_object_id = @ObjectId;

    BEGIN TRY
        /* ---- RB-03 create the new table and copy the retained rows per year ---- */
        UPDATE ret.RetentionTableLog SET MethodUsed = 'TABLE_REBUILD', RebuildStagingTable = @NewFull WHERE TableLogId = @TableLogId;

        IF OBJECT_ID(@NewFull, N'U') IS NOT NULL
        BEGIN
            SET @sql = N'DROP TABLE ' + @NewFull + N';';
            EXEC sp_executesql @sql;
        END;

        SET @sql = N'CREATE TABLE ' + @NewFull + N'
(
    ' + @ColDefs + N'
);';
        EXEC sp_executesql @sql;
        SET @Created = 1;

        SET @InsSql = CASE WHEN @HasIdentity = 1 THEN N'SET IDENTITY_INSERT ' + @NewFull + N' ON;' + NCHAR(10) ELSE N'' END
                    + N'INSERT INTO ' + @NewFull + N' WITH (TABLOCK) (' + @ColList + N')' + NCHAR(10)
                    + N'SELECT ' + @SelList + @FromSql + NCHAR(10)
                    + N'WHERE <PRED>;' + NCHAR(10)
                    + N'SET @n = ROWCOUNT_BIG();'
                    + CASE WHEN @HasIdentity = 1 THEN NCHAR(10) + N'SET IDENTITY_INSERT ' + @NewFull + N' OFF;' ELSE N'' END;

        CREATE TABLE #Years (Yr INT NOT NULL PRIMARY KEY);
        SET @sql = N'INSERT INTO #Years (Yr) SELECT DISTINCT YEAR(' + @DateExpr + N')' + @FromSql + N' WHERE ' + @DateExpr + N' >= @Cutoff;';
        EXEC sp_executesql @sql, N'@Cutoff DATE', @Cutoff = @DwhCutoff;

        SET @Year = (SELECT MIN(Yr) FROM #Years);
        WHILE @Year IS NOT NULL
        BEGIN
            SET @From = CASE WHEN DATEFROMPARTS(@Year, 1, 1) < @DwhCutoff THEN @DwhCutoff ELSE DATEFROMPARTS(@Year, 1, 1) END;
            SET @To   = CASE WHEN @Year < 9999 THEN DATEFROMPARTS(@Year + 1, 1, 1) END;
            SET @sql  = REPLACE(@InsSql, N'<PRED>', @DateExpr + N' >= @From AND (@To IS NULL OR ' + @DateExpr + N' < @To)');
            EXEC sp_executesql @sql, N'@From DATE, @To DATE, @n BIGINT OUTPUT', @From = @From, @To = @To, @n = @n OUTPUT;
            SET @Inserted += @n;
            SET @Year = (SELECT MIN(Yr) FROM #Years WHERE Yr > @Year);
        END;

        -- Rows without business date: orphan child rows (DBR-21); none for own-dated tables (V-04)
        SET @sql = REPLACE(@InsSql, N'<PRED>', @DateExpr + N' IS NULL');
        EXEC sp_executesql @sql, N'@n BIGINT OUTPUT', @n = @n OUTPUT;
        SET @Inserted += @n;

        /* ---- RB-04 keys, constraints, indexes ---- */
        WHILE 1 = 1
        BEGIN
            SET @DdlOrd = NULL;
            SELECT TOP (1) @DdlOrd = Ord, @DdlSql = Sql FROM #Ddl WHERE Done = 0 ORDER BY Phase, Ord;
            IF @DdlOrd IS NULL BREAK;
            EXEC sp_executesql @DdlSql;
            UPDATE #Ddl SET Done = 1 WHERE Ord = @DdlOrd;
        END;

        /* ---- RB-05 count check ---- */
        SET @sql = N'SELECT @n = COUNT_BIG(*)' + @FromSql + N' WHERE ' + @DateExpr + N' >= @Cutoff OR ' + @DateExpr + N' IS NULL;';
        EXEC sp_executesql @sql, N'@Cutoff DATE, @n BIGINT OUTPUT', @Cutoff = @DwhCutoff, @n = @Recount OUTPUT;
        SET @sql = N'SELECT @n = COUNT_BIG(*) FROM ' + @NewFull + N';';
        EXEC sp_executesql @sql, N'@n BIGINT OUTPUT', @n = @NewCount OUTPUT;

        IF @NewCount <> @Inserted OR @NewCount <> @Recount
        BEGIN
            SET @Msg = CONCAT(N'Retained row count mismatch: original ', @Recount, N', inserted ', @Inserted, N', new table ', @NewCount,
                              N' (ETL writes not stopped?).');
            THROW 50412, @Msg, 1;
        END;

        SELECT @Result = 'COMPLETED',
               @Msg = CONCAT(N'New table ', @NewFull, N' prepared with ', @NewCount, N' retained rows and ', (SELECT COUNT(*) FROM #Ddl),
                             N' key, constraint and index statements. Original table unchanged.');
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SELECT @Result = 'FAILED', @ErrCode = 'ERR-RBD-01', @ErrNum = ERROR_NUMBER(), @Msg = LEFT(ERROR_MESSAGE(), 4000);

        BEGIN TRY
            IF @Created = 1 AND OBJECT_ID(@NewFull, N'U') IS NOT NULL
            BEGIN
                SET @sql = N'DROP TABLE ' + @NewFull + N';';
                EXEC sp_executesql @sql;
            END;
            UPDATE ret.RetentionTableLog SET RebuildStagingTable = NULL WHERE TableLogId = @TableLogId;
        END TRY
        BEGIN CATCH
            SET @Msg = LEFT(CONCAT(@Msg, N' | new table not dropped: ', ERROR_MESSAGE()), 4000);
        END CATCH;
    END CATCH;

Finish:
    SELECT @StepStatus  = CASE @Result WHEN 'COMPLETED' THEN 'SUCCEEDED' WHEN 'NOT_REQUIRED' THEN 'SUCCEEDED' WHEN 'STOPPED' THEN 'STOPPED' ELSE 'FAILED' END,
           @StepErrCode = CASE WHEN @Result IN ('FAILED', 'STOPPED') THEN @ErrCode END;

    IF @Result IN ('FAILED', 'STOPPED') AND @ErrCode IS NOT NULL
        EXEC ret.usp_SetTableError @TableLogId = @TableLogId, @ErrorCode = @ErrCode, @ErrorStep = 'REBUILD',
             @ErrorMessage = @Msg, @ErrorNumber = @ErrNum, @NewStatus = @Result;

    EXEC ret.usp_WriteStepLog @RunId = @RunId, @StepCode = 'REBUILD', @Status = @StepStatus,
         @TableLogId = @TableLogId, @TableConfigId = @TableConfigId, @StartTime = @Now,
         @RowsProcessed = @Inserted, @ErrorCode = @StepErrCode, @ErrorNumber = @ErrNum,
         @Message = @Msg;

    SELECT @Result AS PrepareResult, CASE WHEN @Result = 'COMPLETED' THEN @NewFull END AS NewTableName,
           @Inserted AS RowsRetained, @ErrCode AS ErrorCode, @Msg AS Message;
END;
GO

/* 7.3 ret.usp_TableRebuildSwap - RB-07..RB-10, after usp_ValidateArchive PASSED.
       One transaction under an exclusive lock: recount, TRUNCATE original, DROP original, rename the
       new table and its constraints / indexes to the original names, re-create triggers (with first/
       last order), permissions and extended properties, mark the deletion COMPLETED.
       After commit: identity reseed, refresh of dependent views, definition comparison.
       Result <> COMPLETED and DeleteStatus <> COMPLETED: ADF calls usp_TableRebuildAbort. */
CREATE OR ALTER PROCEDURE ret.usp_TableRebuildSwap
    @RunId      BIGINT,
    @TableLogId BIGINT
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Now DATETIME2(3) = ret.fn_NowUtc7();
    DECLARE @LogRunId BIGINT, @TableConfigId INT, @Status VARCHAR(10), @IsValidated BIT, @DeleteStatus VARCHAR(15), @MethodUsed VARCHAR(20),
            @ValidatedCount BIGINT, @RangeTo DATE, @NewFull NVARCHAR(260), @SchemaName SYSNAME, @TableName SYSNAME,
            @CurProcessType VARCHAR(20), @WinStart TIME(0), @WinEnd TIME(0), @Prefix NVARCHAR(40), @NewObjectId INT,
            @FullName NVARCHAR(300), @ObjectId INT, @DateExpr NVARCHAR(400), @JoinSql NVARCHAR(MAX),
            @PartErr VARCHAR(12), @PartCheck VARCHAR(4), @PartMsg NVARCHAR(4000),
            @DefBefore NVARCHAR(MAX), @DefAfter NVARCHAR(MAX), @HasIdentity BIT, @IdentBefore NUMERIC(38, 0), @IdentAfter NUMERIC(38, 0),
            @Missing NVARCHAR(MAX), @sql NVARCHAR(MAX), @Elig BIGINT, @KeepOrig BIGINT, @KeepNew BIGINT,
            @Id INT, @Kind VARCHAR(10), @TempName SYSNAME, @OrigName SYSNAME, @Def NVARCHAR(MAX), @IsDisabled BIT,
            @OrderType VARCHAR(10), @EventType NVARCHAR(60), @XpName SYSNAME, @XpValue SQL_VARIANT, @XpCol SYSNAME,
            @ViewName NVARCHAR(300), @ViewErrors NVARCHAR(MAX), @Phase TINYINT = 0,
            @Result VARCHAR(10), @ErrCode VARCHAR(12), @ErrNum INT, @Msg NVARCHAR(4000), @StepStatus VARCHAR(10), @StepErrCode VARCHAR(12);

    SELECT @LogRunId = l.RunId, @TableConfigId = l.TableConfigId, @Status = l.Status, @IsValidated = l.IsValidated,
           @DeleteStatus = l.DeleteStatus, @MethodUsed = l.MethodUsed, @ValidatedCount = l.ValidatedRowCount,
           @RangeTo = l.ValidatedRangeTo, @NewFull = l.RebuildStagingTable, @SchemaName = c.SchemaName, @TableName = c.TableName
    FROM ret.RetentionTableLog AS l
    JOIN ret.RetentionConfig AS c ON c.TableConfigId = l.TableConfigId
    WHERE l.TableLogId = @TableLogId;

    IF @LogRunId IS NULL
    BEGIN
        ;THROW 50421, N'TableLogId not found.', 1;
    END;

    SELECT @CurProcessType = ProcessType FROM ret.RetentionRunLog WHERE RunId = @RunId AND Status = 'RUNNING';
    SELECT @WinStart = IcWindowStart, @WinEnd = IcWindowEnd FROM ret.RetentionParameter WHERE ParameterSetId = 1;
    SET @Prefix = CONCAT(N'RBD', @RunId);
    SET @NewObjectId = OBJECT_ID(@NewFull, N'U');

    /* ---- Preconditions ---- */
    IF ISNULL(@CurProcessType, '') <> 'INITIAL_CUTOFF' OR @LogRunId <> @RunId
        SELECT @Result = 'FAILED', @ErrCode = 'ERR-SYS-01', @Msg = N'Swap allowed only for a table log of the current RUNNING Initial Cut-off Run.';
    ELSE IF NOT EXISTS (SELECT 1 FROM ret.RetentionTableLock WHERE TableConfigId = @TableConfigId AND RunId = @RunId)
        SELECT @Result = 'FAILED', @ErrCode = 'ERR-LCK-01', @Msg = N'Table lock is not held by the current run.';
    ELSE IF @DeleteStatus = 'COMPLETED'
        SELECT @Result = 'COMPLETED', @Msg = N'Rebuild already completed.';
    ELSE IF ISNULL(@MethodUsed, '') <> 'TABLE_REBUILD' OR @Status <> 'RUNNING'
        SELECT @Result = 'FAILED', @ErrCode = 'ERR-SYS-01', @Msg = N'Table log is not RUNNING or method is not TABLE_REBUILD.';
    ELSE IF @IsValidated = 0
        SELECT @Result = 'FAILED', @ErrCode = 'ERR-VAL-01', @Msg = N'Archive not validated; original table unchanged (BR-08).';
    ELSE IF @NewObjectId IS NULL
        SELECT @Result = 'FAILED', @ErrCode = 'ERR-RBD-01', @Msg = N'New table not found; run usp_TableRebuildPrepare first.';
    ELSE IF ret.fn_IsWithinWindow(CAST(@Now AS TIME(0)), @WinStart, @WinEnd) = 0
        SELECT @Result = 'STOPPED', @ErrCode = 'ERR-WIN-01', @Msg = N'Outside the Initial Cut-off window; swap not started.';

    IF @Result IS NOT NULL
        GOTO Finish;

    EXEC ret.usp_GetTableSqlParts @TableConfigId = @TableConfigId, @CheckUniqueness = 0,
         @FullName = @FullName OUTPUT, @ObjectId = @ObjectId OUTPUT, @DateExpr = @DateExpr OUTPUT, @JoinSql = @JoinSql OUTPUT,
         @ErrorCode = @PartErr OUTPUT, @CheckCode = @PartCheck OUTPUT, @ErrorMessage = @PartMsg OUTPUT;

    IF @PartErr IS NOT NULL
    BEGIN
        SELECT @Result = 'FAILED', @ErrCode = @PartErr, @Msg = @PartMsg;
        GOTO Finish;
    END;

    /* ---- Capture the original definition (unchanged during the downtime) ---- */
    SET @DefBefore   = ret.fn_TableDefinitionText(@ObjectId);
    SET @HasIdentity = CASE WHEN EXISTS (SELECT 1 FROM sys.identity_columns WHERE object_id = @ObjectId) THEN 1 ELSE 0 END;
    SET @IdentBefore = CASE WHEN @HasIdentity = 1 THEN CONVERT(NUMERIC(38, 0), IDENT_CURRENT(@FullName)) END;

    CREATE TABLE #Ren (Id INT IDENTITY(1, 1) PRIMARY KEY, Kind VARCHAR(10) NOT NULL, TempName SYSNAME NOT NULL, OrigName SYSNAME NOT NULL);
    INSERT INTO #Ren (Kind, TempName, OrigName)
    SELECT 'OBJECT', CONCAT(@Prefix, N'_C', o.object_id), o.name COLLATE DATABASE_DEFAULT
    FROM sys.objects AS o
    WHERE o.parent_object_id = @ObjectId AND o.type IN ('PK', 'UQ', 'D', 'C', 'F');
    INSERT INTO #Ren (Kind, TempName, OrigName)
    SELECT 'INDEX', CONCAT(@Prefix, N'_I', i.index_id), i.name COLLATE DATABASE_DEFAULT
    FROM sys.indexes AS i
    WHERE i.object_id = @ObjectId AND i.index_id > 0 AND i.is_primary_key = 0 AND i.is_unique_constraint = 0;

    SELECT @Missing = STRING_AGG(CONVERT(NVARCHAR(MAX), r.TempName) COLLATE DATABASE_DEFAULT, N', ')
    FROM #Ren AS r
    WHERE (r.Kind = 'OBJECT' AND NOT EXISTS (SELECT 1 FROM sys.objects AS o WHERE o.parent_object_id = @NewObjectId AND o.name COLLATE DATABASE_DEFAULT = r.TempName))
       OR (r.Kind = 'INDEX'  AND NOT EXISTS (SELECT 1 FROM sys.indexes AS i WHERE i.object_id = @NewObjectId AND i.name COLLATE DATABASE_DEFAULT = r.TempName));

    IF @Missing IS NOT NULL
    BEGIN
        SELECT @Result = 'FAILED', @ErrCode = 'ERR-RBD-01',
               @Msg = LEFT(CONCAT(N'New table is incomplete; missing objects: ', @Missing, N'. Original table unchanged.'), 4000);
        GOTO Finish;
    END;

    CREATE TABLE #Trg (Id INT IDENTITY(1, 1) PRIMARY KEY, Name SYSNAME NOT NULL, Def NVARCHAR(MAX) NOT NULL, IsDisabled BIT NOT NULL);
    INSERT INTO #Trg (Name, Def, IsDisabled)
    SELECT tr.name COLLATE DATABASE_DEFAULT, m.definition COLLATE DATABASE_DEFAULT, tr.is_disabled
    FROM sys.triggers AS tr JOIN sys.sql_modules AS m ON m.object_id = tr.object_id
    WHERE tr.parent_id = @ObjectId;

    CREATE TABLE #TrgOrder (Id INT IDENTITY(1, 1) PRIMARY KEY, Name SYSNAME NOT NULL, OrderType VARCHAR(10) NOT NULL, EventType NVARCHAR(60) NOT NULL);
    INSERT INTO #TrgOrder (Name, OrderType, EventType)
    SELECT tr.name COLLATE DATABASE_DEFAULT, CASE WHEN te.is_first = 1 THEN 'First' ELSE 'Last' END, te.type_desc COLLATE DATABASE_DEFAULT
    FROM sys.trigger_events AS te JOIN sys.triggers AS tr ON tr.object_id = te.object_id
    WHERE tr.parent_id = @ObjectId AND (te.is_first = 1 OR te.is_last = 1);

    CREATE TABLE #Perm (Id INT IDENTITY(1, 1) PRIMARY KEY, Sql NVARCHAR(MAX) NOT NULL);
    INSERT INTO #Perm (Sql)
    SELECT CASE WHEN dp.state = 'W' THEN N'GRANT' ELSE dp.state_desc COLLATE DATABASE_DEFAULT END + N' ' + dp.permission_name COLLATE DATABASE_DEFAULT + N' ON ' + @FullName
           + ISNULL(N' (' + QUOTENAME(COL_NAME(dp.major_id, NULLIF(dp.minor_id, 0))) + N')', N'')
           + N' TO ' + QUOTENAME(USER_NAME(dp.grantee_principal_id))
           + CASE WHEN dp.state = 'W' THEN N' WITH GRANT OPTION' ELSE N'' END + N';'
    FROM sys.database_permissions AS dp
    WHERE dp.class = 1 AND dp.major_id = @ObjectId;

    CREATE TABLE #Xp (Id INT IDENTITY(1, 1) PRIMARY KEY, Name SYSNAME NOT NULL, Value SQL_VARIANT NULL, ColName SYSNAME NULL);
    INSERT INTO #Xp (Name, Value, ColName)
    SELECT ep.name COLLATE DATABASE_DEFAULT, ep.value, COL_NAME(ep.major_id, NULLIF(ep.minor_id, 0))
    FROM sys.extended_properties AS ep
    WHERE ep.class = 1 AND ep.major_id = @ObjectId;

    CREATE TABLE #Views (Id INT IDENTITY(1, 1) PRIMARY KEY, Name NVARCHAR(300) NOT NULL);
    INSERT INTO #Views (Name)
    SELECT DISTINCT QUOTENAME(OBJECT_SCHEMA_NAME(v.object_id)) + N'.' + QUOTENAME(v.name COLLATE DATABASE_DEFAULT)
    FROM sys.sql_expression_dependencies AS d JOIN sys.views AS v ON v.object_id = d.referencing_id
    WHERE d.referenced_id = @ObjectId;

    BEGIN TRY
        SET @Phase = 2;
        BEGIN TRANSACTION;

            /* RB-07 recount under an exclusive table lock */
            SET @sql = N'SELECT @e = COUNT_BIG(CASE WHEN ' + @DateExpr + N' < @Upper THEN 1 END),
       @k = COUNT_BIG(CASE WHEN ' + @DateExpr + N' >= @Upper OR ' + @DateExpr + N' IS NULL THEN 1 END)
FROM ' + @FullName + N' AS t WITH (TABLOCKX, HOLDLOCK)' + @JoinSql + N';';
            EXEC sp_executesql @sql, N'@Upper DATE, @e BIGINT OUTPUT, @k BIGINT OUTPUT', @Upper = @RangeTo, @e = @Elig OUTPUT, @k = @KeepOrig OUTPUT;

            SET @sql = N'SELECT @n = COUNT_BIG(*) FROM ' + @NewFull + N' WITH (TABLOCKX, HOLDLOCK);';
            EXEC sp_executesql @sql, N'@n BIGINT OUTPUT', @n = @KeepNew OUTPUT;

            UPDATE ret.RetentionTableLog SET PreDeleteRecount = @Elig WHERE TableLogId = @TableLogId;

            IF @Elig <> @ValidatedCount
            BEGIN
                SET @ErrCode = 'ERR-VAL-02';
                SET @Msg = CONCAT(N'Recount ', @Elig, N' differs from validated total ', @ValidatedCount, N'. Swap rolled back; original table unchanged.');
                THROW 50422, @Msg, 1;
            END;

            IF @KeepOrig <> @KeepNew
            BEGIN
                SET @Msg = CONCAT(N'Retained rows in the original table (', @KeepOrig, N') differ from the new table (', @KeepNew,
                                  N'). Swap rolled back; original table unchanged.');
                THROW 50423, @Msg, 1;
            END;

            /* RB-08 MD-04 step 4: truncate the original table, then drop it */
            SET @sql = N'TRUNCATE TABLE ' + @FullName + N';';
            EXEC sp_executesql @sql;
            SET @sql = N'DROP TABLE ' + @FullName + N';';
            EXEC sp_executesql @sql;

            /* RB-08 MD-04 step 5: rename the new table and its objects to the original names */
            EXEC sp_rename @objname = @NewFull, @newname = @TableName, @objtype = 'OBJECT';

            SET @Id = (SELECT MIN(Id) FROM #Ren);
            WHILE @Id IS NOT NULL
            BEGIN
                SELECT @Kind = Kind, @TempName = TempName, @OrigName = OrigName FROM #Ren WHERE Id = @Id;
                IF @Kind = 'OBJECT'
                BEGIN
                    SET @sql = QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@TempName);
                    EXEC sp_rename @objname = @sql, @newname = @OrigName, @objtype = 'OBJECT';
                END
                ELSE
                BEGIN
                    SET @sql = @FullName + N'.' + QUOTENAME(@TempName);
                    EXEC sp_rename @objname = @sql, @newname = @OrigName, @objtype = 'INDEX';
                END;
                SET @Id = (SELECT MIN(Id) FROM #Ren WHERE Id > @Id);
            END;

            /* Triggers, trigger order, permissions, extended properties */
            SET @Id = (SELECT MIN(Id) FROM #Trg);
            WHILE @Id IS NOT NULL
            BEGIN
                SELECT @OrigName = Name, @Def = Def, @IsDisabled = IsDisabled FROM #Trg WHERE Id = @Id;
                EXEC sp_executesql @Def;
                IF @IsDisabled = 1
                BEGIN
                    SET @sql = N'DISABLE TRIGGER ' + QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@OrigName) + N' ON ' + @FullName + N';';
                    EXEC sp_executesql @sql;
                END;
                SET @Id = (SELECT MIN(Id) FROM #Trg WHERE Id > @Id);
            END;

            SET @Id = (SELECT MIN(Id) FROM #TrgOrder);
            WHILE @Id IS NOT NULL
            BEGIN
                SELECT @OrigName = Name, @OrderType = OrderType, @EventType = EventType FROM #TrgOrder WHERE Id = @Id;
                SET @sql = QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@OrigName);
                EXEC sp_settriggerorder @triggername = @sql, @order = @OrderType, @stmttype = @EventType;
                SET @Id = (SELECT MIN(Id) FROM #TrgOrder WHERE Id > @Id);
            END;

            SET @Id = (SELECT MIN(Id) FROM #Perm);
            WHILE @Id IS NOT NULL
            BEGIN
                SELECT @sql = Sql FROM #Perm WHERE Id = @Id;
                EXEC sp_executesql @sql;
                SET @Id = (SELECT MIN(Id) FROM #Perm WHERE Id > @Id);
            END;

            SET @Id = (SELECT MIN(Id) FROM #Xp);
            WHILE @Id IS NOT NULL
            BEGIN
                SELECT @XpName = Name, @XpValue = Value, @XpCol = ColName FROM #Xp WHERE Id = @Id;
                IF @XpCol IS NULL
                    EXEC sys.sp_addextendedproperty @name = @XpName, @value = @XpValue,
                         @level0type = N'SCHEMA', @level0name = @SchemaName, @level1type = N'TABLE', @level1name = @TableName;
                ELSE
                    EXEC sys.sp_addextendedproperty @name = @XpName, @value = @XpValue,
                         @level0type = N'SCHEMA', @level0name = @SchemaName, @level1type = N'TABLE', @level1name = @TableName,
                         @level2type = N'COLUMN', @level2name = @XpCol;
                SET @Id = (SELECT MIN(Id) FROM #Xp WHERE Id > @Id);
            END;

            UPDATE ret.RetentionTableLog
               SET DeleteStatus = 'COMPLETED', RowsDeleted = @Elig, DeleteBatchCount = 0, RebuildStagingTable = NULL
             WHERE TableLogId = @TableLogId;

        COMMIT TRANSACTION;

        /* ---- RB-09 identity reseed and dependent views (after commit) ---- */
        SET @Phase = 3;
        IF @HasIdentity = 1 AND @IdentBefore IS NOT NULL
        BEGIN
            SET @IdentAfter = CONVERT(NUMERIC(38, 0), IDENT_CURRENT(@FullName));
            IF @IdentAfter IS NULL OR @IdentAfter < @IdentBefore
            BEGIN
                SET @sql = N'DBCC CHECKIDENT (''' + REPLACE(@FullName, N'''', N'''''') + N''', RESEED, '
                         + CONVERT(NVARCHAR(40), @IdentBefore) + N') WITH NO_INFOMSGS;';
                EXEC sp_executesql @sql;
            END;
        END;

        SET @Id = (SELECT MIN(Id) FROM #Views);
        WHILE @Id IS NOT NULL
        BEGIN
            SELECT @ViewName = Name FROM #Views WHERE Id = @Id;
            BEGIN TRY
                EXEC sys.sp_refreshview @viewname = @ViewName;
            END TRY
            BEGIN CATCH
                SET @ViewErrors = CONCAT(@ViewErrors, CASE WHEN @ViewErrors IS NULL THEN N'' ELSE N'; ' END, @ViewName, N': ', ERROR_MESSAGE());
            END CATCH;
            SET @Id = (SELECT MIN(Id) FROM #Views WHERE Id > @Id);
        END;

        /* ---- RB-10 definition check ---- */
        SET @DefAfter = ret.fn_TableDefinitionText(OBJECT_ID(@FullName, N'U'));

        IF HASHBYTES('SHA2_256', @DefAfter) <> HASHBYTES('SHA2_256', @DefBefore) OR @ViewErrors IS NOT NULL
            SELECT @Result = 'FAILED', @ErrCode = 'ERR-RBD-03',
                   @Msg = LEFT(CONCAT(N'Data swap committed (', @Elig, N' rows removed, ', @KeepNew, N' retained) but ',
                                      CASE WHEN HASHBYTES('SHA2_256', @DefAfter) <> HASHBYTES('SHA2_256', @DefBefore)
                                           THEN N'the table definition differs from the original (compare ret.fn_TableDefinitionText with the logged definition). ' ELSE N'' END,
                                      CASE WHEN @ViewErrors IS NOT NULL THEN CONCAT(N'View refresh failed: ', @ViewErrors, N'. ') ELSE N'' END,
                                      N'DBA procedure required.'), 4000);
        ELSE
            SELECT @Result = 'COMPLETED',
                   @Msg = CONCAT(N'Rebuild completed: ', @Elig, N' rows removed, ', @KeepNew, N' rows retained; original table truncated and dropped, ',
                                 N'new table renamed; definition verified.');
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        SELECT @Result = 'FAILED', @ErrNum = ERROR_NUMBER(), @Msg = LEFT(ERROR_MESSAGE(), 4000),
               @ErrCode = CASE WHEN @ErrCode = 'ERR-VAL-02' THEN @ErrCode WHEN @Phase = 2 THEN 'ERR-RBD-02' WHEN @Phase = 3 THEN 'ERR-RBD-03' ELSE 'ERR-SYS-01' END;
    END CATCH;

Finish:
    SELECT @StepStatus  = CASE @Result WHEN 'COMPLETED' THEN 'SUCCEEDED' WHEN 'STOPPED' THEN 'STOPPED' ELSE 'FAILED' END,
           @StepErrCode = CASE WHEN @Result <> 'COMPLETED' THEN @ErrCode END;

    IF @Result IN ('FAILED', 'STOPPED') AND @ErrCode IS NOT NULL
        EXEC ret.usp_SetTableError @TableLogId = @TableLogId, @ErrorCode = @ErrCode, @ErrorStep = 'REBUILD',
             @ErrorMessage = @Msg, @ErrorNumber = @ErrNum, @NewStatus = @Result;

    IF @ErrCode = 'ERR-RBD-03'
        UPDATE ret.RetentionTableStatus
           SET HasIntegrityIssue = 1, IntegrityIssueRunId = @RunId, ModifiedBy = ORIGINAL_LOGIN(), ModifiedAt = ret.fn_NowUtc7(),
               FlagComment = CONCAT(N'ERR-RBD-03 on TableLogId ', @TableLogId)
         WHERE TableConfigId = @TableConfigId;

    EXEC ret.usp_WriteStepLog @RunId = @RunId, @StepCode = 'REBUILD', @Status = @StepStatus,
         @TableLogId = @TableLogId, @TableConfigId = @TableConfigId, @StartTime = @Now,
         @RowsProcessed = @Elig, @ErrorCode = @StepErrCode, @ErrorNumber = @ErrNum, @Message = @Msg;

    SELECT @Result AS SwapResult,
           (SELECT DeleteStatus FROM ret.RetentionTableLog WHERE TableLogId = @TableLogId) AS DeleteStatus,
           CASE WHEN @Result = 'COMPLETED' OR @ErrCode = 'ERR-RBD-03' THEN @Elig ELSE 0 END AS RowsDeleted,
           @KeepNew AS RowsRetained, @ErrCode AS ErrorCode, @Msg AS Message;
END;
GO

/* =====================================================================================
   8. POST-CHECK, ARCHIVE EXPIRY, CLEANUP, END OF TABLE AND RUN, ADMINISTRATION
   ===================================================================================== */

/* 8.1 ret.usp_PostCheck - post-check after deletion (AC-03, AC-07, FR-020).
       No rows with business date before the DWH cut-off may remain. IC: retained rows (including
       orphan child rows) must not decrease. IC success: status COMPLETED, completion date = today UTC+7. */
CREATE OR ALTER PROCEDURE ret.usp_PostCheck
    @TableLogId BIGINT
WITH EXECUTE AS OWNER
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Now DATETIME2(3) = ret.fn_NowUtc7();
    DECLARE @RunId BIGINT, @TableConfigId INT, @ProcessType VARCHAR(20), @Status VARCHAR(10), @DwhCutoff DATE, @RetainedBefore BIGINT,
            @DateExpr NVARCHAR(400), @FromSql NVARCHAR(MAX), @PartErr VARCHAR(12), @PartCheck VARCHAR(4),
            @sql NVARCHAR(MAX), @Below BIGINT, @RetainedNow BIGINT, @Pass BIT, @Msg NVARCHAR(4000), @ErrNo INT;

    SELECT @RunId = l.RunId, @TableConfigId = l.TableConfigId, @ProcessType = l.ProcessType, @Status = l.Status,
           @DwhCutoff = l.DwhCutoffDate, @RetainedBefore = l.RetainedRowsBefore
    FROM ret.RetentionTableLog AS l
    WHERE l.TableLogId = @TableLogId;

    IF @RunId IS NULL
    BEGIN
        ;THROW 50221, N'TableLogId not found.', 1;
    END;

    IF @Status <> 'RUNNING' OR @ProcessType NOT IN ('INITIAL_CUTOFF', 'DAILY_ROUTINE')
    BEGIN
        SELECT 'FAILED' AS PostCheckResult, CAST(NULL AS BIGINT) AS RowsBelowCutoff, @RetainedBefore AS RetainedRowsBefore,
               CAST(NULL AS BIGINT) AS RetainedRowsAfter, N'Table log is not RUNNING or process type not supported.' AS Message;
        RETURN;
    END;

    BEGIN TRY
        EXEC ret.usp_GetTableSqlParts @TableConfigId = @TableConfigId, @CheckUniqueness = 0,
             @DateExpr = @DateExpr OUTPUT, @FromSql = @FromSql OUTPUT,
             @ErrorCode = @PartErr OUTPUT, @CheckCode = @PartCheck OUTPUT, @ErrorMessage = @Msg OUTPUT;

        IF @PartErr IS NOT NULL
        BEGIN
            ;THROW 50222, @Msg, 1;
        END;

        SET @sql = N'SELECT @Below = COUNT_BIG(CASE WHEN ' + @DateExpr + N' < @Cutoff THEN 1 END),
       @Kept  = COUNT_BIG(CASE WHEN ' + @DateExpr + N' >= @Cutoff OR ' + @DateExpr + N' IS NULL THEN 1 END)' + @FromSql + N';';
        EXEC sp_executesql @sql, N'@Cutoff DATE, @Below BIGINT OUTPUT, @Kept BIGINT OUTPUT',
             @Cutoff = @DwhCutoff, @Below = @Below OUTPUT, @Kept = @RetainedNow OUTPUT;

        SET @Pass = CASE WHEN @Below = 0 AND (@ProcessType <> 'INITIAL_CUTOFF' OR @RetainedNow >= ISNULL(@RetainedBefore, 0)) THEN 1 ELSE 0 END;

        UPDATE ret.RetentionTableLog
           SET RetainedRowsAfter = CASE WHEN @ProcessType = 'INITIAL_CUTOFF' THEN @RetainedNow ELSE RetainedRowsAfter END
         WHERE TableLogId = @TableLogId;

        IF @Pass = 1
        BEGIN
            IF @ProcessType = 'INITIAL_CUTOFF'
                UPDATE ret.RetentionTableStatus
                   SET InitialCutoffStatus = 'COMPLETED', InitialCutoffCompletionDate = ret.fn_TodayUtc7(),
                       LastInitialCutoffRunId = @RunId, ModifiedBy = ORIGINAL_LOGIN(), ModifiedAt = ret.fn_NowUtc7()
                 WHERE TableConfigId = @TableConfigId;

            SET @Msg = CONCAT(N'Post-check passed. Rows below cut-off: 0',
                              CASE WHEN @ProcessType = 'INITIAL_CUTOFF'
                                   THEN CONCAT(N'; retained before ', @RetainedBefore, N', after ', @RetainedNow,
                                               CASE WHEN @RetainedNow > @RetainedBefore THEN N' (rows loaded during the run)' ELSE N'' END)
                                   ELSE N'' END, N'.');
            EXEC ret.usp_WriteStepLog @RunId = @RunId, @StepCode = 'POSTCHECK', @Status = 'SUCCEEDED',
                 @TableLogId = @TableLogId, @TableConfigId = @TableConfigId, @StartTime = @Now, @Message = @Msg;
        END
        ELSE
        BEGIN
            SET @Msg = CONCAT(N'Post-check failed. Rows below cut-off: ', @Below,
                              N'; retained before ', ISNULL(CONVERT(NVARCHAR(20), @RetainedBefore), N'n/a'), N', after ', @RetainedNow, N'.');
            EXEC ret.usp_SetTableError @TableLogId = @TableLogId, @ErrorCode = 'ERR-DEL-02', @ErrorStep = 'POSTCHECK', @ErrorMessage = @Msg;
            UPDATE ret.RetentionTableStatus
               SET HasIntegrityIssue = 1, IntegrityIssueRunId = @RunId, ModifiedBy = ORIGINAL_LOGIN(), ModifiedAt = ret.fn_NowUtc7(),
                   FlagComment = CONCAT(N'ERR-DEL-02 on TableLogId ', @TableLogId)
             WHERE TableConfigId = @TableConfigId;
            EXEC ret.usp_WriteStepLog @RunId = @RunId, @StepCode = 'POSTCHECK', @Status = 'FAILED',
                 @TableLogId = @TableLogId, @TableConfigId = @TableConfigId, @StartTime = @Now,
                 @ErrorCode = 'ERR-DEL-02', @ErrorMessage = @Msg;
        END;

        SELECT CASE WHEN @Pass = 1 THEN 'PASSED' ELSE 'FAILED' END AS PostCheckResult,
               @Below AS RowsBelowCutoff, @RetainedBefore AS RetainedRowsBefore, @RetainedNow AS RetainedRowsAfter, @Msg AS Message;
    END TRY
    BEGIN CATCH
        SELECT @Msg = LEFT(ERROR_MESSAGE(), 4000), @ErrNo = ERROR_NUMBER();
        EXEC ret.usp_SetTableError @TableLogId = @TableLogId, @ErrorCode = 'ERR-SYS-01', @ErrorStep = 'POSTCHECK',
             @ErrorMessage = @Msg, @ErrorNumber = @ErrNo;
        EXEC ret.usp_WriteStepLog @RunId = @RunId, @StepCode = 'POSTCHECK', @Status = 'FAILED',
             @TableLogId = @TableLogId, @TableConfigId = @TableConfigId, @StartTime = @Now,
             @ErrorCode = 'ERR-SYS-01', @ErrorNumber = @ErrNo, @ErrorMessage = @Msg;
        SELECT 'FAILED' AS PostCheckResult, CAST(NULL AS BIGINT) AS RowsBelowCutoff, @RetainedBefore AS RetainedRowsBefore,
               CAST(NULL AS BIGINT) AS RetainedRowsAfter, @Msg AS Message;
    END CATCH;
END;
GO

/* 8.2 ret.usp_GetExpiredArchiveFolders - expired archive deletion (FSD 4.13, 5.4, DR-05), layout MD-07
       <container>/<yyyy>/<BlobPath>/<BlobPath>_<yyyyMMdd>.parquet. Called with the ADF Get Metadata childItems:
         @Level = 'YEAR' : container root, items <yyyy> (folders). Every year before the archive cut-off year
                           returns folder <yyyy>/<BlobPath> with Action DELETE (recursive delete; ADF first
                           checks that the folder exists - the year folder is shared by all tables).
         @Level = 'FILE' : folder <@Year>/<BlobPath> (@Year = archive cut-off year), items
                           <BlobPath>_<yyyyMMdd>.parquet (files). Every file dated before the archive cut-off
                           returns Action DELETE with FolderPath and FileName.
       Items not matching the pattern are never deleted and are logged as a warning.
       Result: ItemName, FolderPath, FileName ('' for a folder), Action. */
CREATE OR ALTER PROCEDURE ret.usp_GetExpiredArchiveFolders
    @TableLogId     BIGINT,
    @ChildItemsJson NVARCHAR(MAX),
    @Level          VARCHAR(5)  = 'YEAR',
    @Year           SMALLINT    = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Now DATETIME2(3) = ret.fn_NowUtc7();
    DECLARE @RunId BIGINT, @TableConfigId INT, @ProcessType VARCHAR(20), @ArchiveCutoff DATE, @BlobPath NVARCHAR(400),
            @ParentPath NVARCHAR(1024), @CutYear INT, @Ignored NVARCHAR(MAX), @ToDelete INT, @Msg NVARCHAR(4000),
            @StepStatus VARCHAR(10), @Prefix NVARCHAR(410);

    SELECT @RunId = l.RunId, @TableConfigId = l.TableConfigId, @ProcessType = l.ProcessType,
           @ArchiveCutoff = l.ArchiveCutoffDate, @BlobPath = c.BlobPath
    FROM ret.RetentionTableLog AS l
    JOIN ret.RetentionConfig AS c ON c.TableConfigId = l.TableConfigId
    WHERE l.TableLogId = @TableLogId;

    IF @RunId IS NULL
    BEGIN
        ;THROW 50231, N'TableLogId not found.', 1;
    END;
    IF @ProcessType <> 'DAILY_ROUTINE'
    BEGIN
        ;THROW 50232, N'Expired archive deletion runs only in the Daily Routine (DR-05).', 1;
    END;
    IF @Level IS NULL OR @Level NOT IN ('YEAR', 'FILE') OR (@Level = 'FILE' AND @Year IS NULL)
    BEGIN
        ;THROW 50233, N'Invalid @Level / @Year combination (YEAR; FILE with @Year).', 1;
    END;

    SET @CutYear    = YEAR(@ArchiveCutoff);
    SET @Prefix     = @BlobPath + N'_';
    SET @ParentPath = CASE WHEN @Level = 'YEAR' THEN N'' ELSE CONCAT(RIGHT(CONCAT(N'000', @Year), 4), N'/', @BlobPath) END;

    CREATE TABLE #Item (ItemName NVARCHAR(400) NULL, ItemType NVARCHAR(20) NULL, ItemYear INT NULL, ItemDate DATE NULL,
                        IsValid BIT NOT NULL DEFAULT (0), Action VARCHAR(10) NULL);

    IF NULLIF(LTRIM(RTRIM(@ChildItemsJson)), N'') IS NOT NULL
    BEGIN
        IF ISJSON(@ChildItemsJson) = 0
        BEGIN
            SET @Msg = N'Get Metadata output is not valid JSON; nothing deleted.';
            EXEC ret.usp_SetTableError @TableLogId = @TableLogId, @ErrorCode = 'ERR-ARC-01', @ErrorStep = 'EXPIRE', @ErrorMessage = @Msg;
            EXEC ret.usp_WriteStepLog @RunId = @RunId, @StepCode = 'EXPIRE', @Status = 'FAILED', @TableLogId = @TableLogId,
                 @TableConfigId = @TableConfigId, @StartTime = @Now, @ErrorCode = 'ERR-ARC-01', @ErrorMessage = @Msg;
            SELECT CAST(NULL AS NVARCHAR(400)) AS ItemName, CAST(NULL AS NVARCHAR(1024)) AS FolderPath,
                   CAST(NULL AS NVARCHAR(400)) AS FileName, CAST(NULL AS VARCHAR(10)) AS Action
            WHERE 1 = 0;
            RETURN;
        END;

        INSERT INTO #Item (ItemName, ItemType)
        SELECT j.ItemName, j.ItemType
        FROM OPENJSON(@ChildItemsJson) WITH (ItemName NVARCHAR(400) '$.name', ItemType NVARCHAR(20) '$.type') AS j;

        IF @Level = 'YEAR'
            UPDATE #Item
               SET ItemYear = TRY_CONVERT(INT, ItemName),
                   IsValid  = CASE WHEN ItemType = N'Folder' AND LEN(ItemName) = 4 AND ItemName LIKE N'[12][0-9][0-9][0-9]' THEN 1 ELSE 0 END;
        ELSE
            UPDATE #Item
               SET ItemDate = CASE WHEN ItemType = N'File' AND LEN(ItemName) = LEN(@Prefix) + 16
                                    AND LEFT(ItemName, LEN(@Prefix)) COLLATE Latin1_General_100_BIN2 = @Prefix COLLATE Latin1_General_100_BIN2
                                    AND RIGHT(ItemName, 8) COLLATE Latin1_General_100_BIN2 = N'.parquet'
                                    AND SUBSTRING(ItemName, LEN(@Prefix) + 1, 8) NOT LIKE N'%[^0-9]%'
                                   THEN TRY_CONVERT(DATE, SUBSTRING(ItemName, LEN(@Prefix) + 1, 8), 112) END;

        IF @Level = 'FILE'
            UPDATE #Item SET IsValid = CASE WHEN ItemDate IS NOT NULL AND YEAR(ItemDate) = @Year THEN 1 ELSE 0 END;

        UPDATE #Item
           SET Action = CASE WHEN IsValid = 0 THEN NULL
                             WHEN @Level = 'YEAR' AND ItemYear < @CutYear THEN 'DELETE'
                             WHEN @Level = 'FILE' AND ItemDate < @ArchiveCutoff THEN 'DELETE' END;
    END;

    SELECT @Ignored  = STRING_AGG(CONVERT(NVARCHAR(MAX), LEFT(ItemName, 200)) COLLATE DATABASE_DEFAULT, N', ') FROM #Item WHERE IsValid = 0;
    SELECT @ToDelete = COUNT(*) FROM #Item WHERE Action = 'DELETE';

    SET @Msg = LEFT(CONCAT(N'Level ', @Level, N' of ', CASE WHEN @ParentPath = N'' THEN N'<container root>' ELSE @ParentPath END,
                           N' (archive cut-off ', CONVERT(CHAR(10), @ArchiveCutoff, 23), N'): ', @ToDelete,
                           CASE WHEN @Level = 'YEAR' THEN N' year folders of this table to delete' ELSE N' files to delete' END,
                           CASE WHEN @Ignored IS NOT NULL THEN CONCAT(N'. Items not matching the pattern, not deleted: ', @Ignored) ELSE N'' END,
                           N'.'), 4000);
    SET @StepStatus = CASE WHEN @Ignored IS NULL THEN 'SUCCEEDED' ELSE 'WARNING' END;
    EXEC ret.usp_WriteStepLog @RunId = @RunId, @StepCode = 'EXPIRE', @Status = @StepStatus,
         @TableLogId = @TableLogId, @TableConfigId = @TableConfigId, @StartTime = @Now, @Message = @Msg;

    SELECT i.ItemName,
           CASE WHEN @Level = 'YEAR' THEN i.ItemName + N'/' + @BlobPath ELSE @ParentPath END AS FolderPath,
           CASE WHEN @Level = 'YEAR' THEN N'' ELSE i.ItemName END AS FileName,
           i.Action
    FROM #Item AS i
    WHERE i.Action = 'DELETE'
    ORDER BY i.ItemName;
END;
GO

/* 8.3 ret.usp_LogExpiredArchiveResult - result of the ADF Delete activities (DR-05) */
CREATE OR ALTER PROCEDURE ret.usp_LogExpiredArchiveResult
    @TableLogId     BIGINT,
    @Status         VARCHAR(10),
    @FoldersDeleted INT             = 0,
    @FilesDeleted   INT             = 0,
    @ErrorMessage   NVARCHAR(MAX)   = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Now DATETIME2(3) = ret.fn_NowUtc7(), @RunId BIGINT, @TableConfigId INT, @Msg NVARCHAR(4000), @StepErrCode VARCHAR(12);

    IF @Status IS NULL OR @Status NOT IN ('SUCCEEDED', 'FAILED')
    BEGIN
        ;THROW 50241, N'Invalid @Status. Allowed values: SUCCEEDED, FAILED.', 1;
    END;

    SELECT @RunId = RunId, @TableConfigId = TableConfigId FROM ret.RetentionTableLog WHERE TableLogId = @TableLogId;
    IF @RunId IS NULL
    BEGIN
        ;THROW 50242, N'TableLogId not found.', 1;
    END;

    UPDATE ret.RetentionTableLog
       SET ArchiveFoldersDeleted = ISNULL(ArchiveFoldersDeleted, 0) + ISNULL(@FoldersDeleted, 0),
           ArchiveFilesDeleted   = ISNULL(ArchiveFilesDeleted, 0)   + ISNULL(@FilesDeleted, 0)
     WHERE TableLogId = @TableLogId;

    IF @Status = 'FAILED'
        EXEC ret.usp_SetTableError @TableLogId = @TableLogId, @ErrorCode = 'ERR-ARC-01', @ErrorStep = 'EXPIRE', @ErrorMessage = @ErrorMessage;

    SELECT @Msg = CONCAT(N'Folders deleted: ', ISNULL(@FoldersDeleted, 0), N'; files deleted: ', ISNULL(@FilesDeleted, 0), N'.'),
           @StepErrCode = CASE WHEN @Status = 'FAILED' THEN 'ERR-ARC-01' END;
    EXEC ret.usp_WriteStepLog @RunId = @RunId, @StepCode = 'EXPIRE', @Status = @Status,
         @TableLogId = @TableLogId, @TableConfigId = @TableConfigId, @StartTime = @Now,
         @FileCount = @FilesDeleted, @RowsProcessed = @FoldersDeleted,
         @Message = @Msg, @ErrorCode = @StepErrCode, @ErrorMessage = @ErrorMessage;

    SELECT ArchiveFoldersDeleted, ArchiveFilesDeleted FROM ret.RetentionTableLog WHERE TableLogId = @TableLogId;
END;
GO

/* 8.4 ret.usp_LogCleanupResult - result of removing this run's archive files (FR-018).
       Files removed for a range whose deletion had started: integrity flag. Cleanup failure: orphan flag. */
CREATE OR ALTER PROCEDURE ret.usp_LogCleanupResult
    @TableLogId     BIGINT,
    @Status         VARCHAR(10),
    @FilesRemoved   INT             = NULL,
    @ErrorMessage   NVARCHAR(MAX)   = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Now DATETIME2(3) = ret.fn_NowUtc7(), @RunId BIGINT, @TableConfigId INT, @IsValidated BIT,
            @DeleteStatus VARCHAR(15), @RowsDeleted BIGINT, @Msg NVARCHAR(4000), @StepErrCode VARCHAR(12);

    IF @Status IS NULL OR @Status NOT IN ('SUCCEEDED', 'FAILED')
    BEGIN
        ;THROW 50251, N'Invalid @Status. Allowed values: SUCCEEDED, FAILED.', 1;
    END;

    SELECT @RunId = RunId, @TableConfigId = TableConfigId, @IsValidated = IsValidated,
           @DeleteStatus = DeleteStatus, @RowsDeleted = ISNULL(RowsDeleted, 0)
    FROM ret.RetentionTableLog WHERE TableLogId = @TableLogId;

    IF @RunId IS NULL
    BEGIN
        ;THROW 50252, N'TableLogId not found.', 1;
    END;

    IF @Status = 'SUCCEEDED'
    BEGIN
        UPDATE ret.RetentionArchiveDate SET ExportStatus = 'REMOVED'
         WHERE TableLogId = @TableLogId AND ExportStatus IN ('SUCCEEDED', 'FAILED', 'STOPPED');
        UPDATE ret.RetentionTableLog SET RowsExported = 0 WHERE TableLogId = @TableLogId;

        IF @IsValidated = 1
        BEGIN
            IF @DeleteStatus = 'NOT_STARTED' AND @RowsDeleted = 0
            BEGIN
                UPDATE ret.RetentionTableLog SET IsValidated = 0 WHERE TableLogId = @TableLogId;
                SET @Msg = N'Archive files removed after validation; validation revoked, DWH unchanged.';
            END
            ELSE
            BEGIN
                UPDATE ret.RetentionTableStatus
                   SET HasIntegrityIssue = 1, IntegrityIssueRunId = @RunId, ModifiedBy = ORIGINAL_LOGIN(), ModifiedAt = ret.fn_NowUtc7(),
                       FlagComment = CONCAT(N'Archive files removed after deletion started; TableLogId ', @TableLogId)
                 WHERE TableConfigId = @TableConfigId;
                SET @Msg = N'Archive files removed although deletion had started: archived data may be lost. Integrity flag set.';
                EXEC ret.usp_SetTableError @TableLogId = @TableLogId, @ErrorCode = 'ERR-VAL-03', @ErrorStep = 'CLEANUP', @ErrorMessage = @Msg;
            END;
        END
        ELSE
            SET @Msg = N'Archive files of this run removed; DWH unchanged.';
    END
    ELSE
    BEGIN
        UPDATE ret.RetentionTableStatus
           SET HasOrphanFiles = 1, OrphanFilesRunId = @RunId, ModifiedBy = ORIGINAL_LOGIN(), ModifiedAt = ret.fn_NowUtc7(),
               FlagComment = CONCAT(N'Orphan files of RunId ', @RunId)
         WHERE TableConfigId = @TableConfigId;
        SET @Msg = CONCAT(N'Cleanup of files of RunId ', @RunId, N' failed. ', @ErrorMessage);
        EXEC ret.usp_SetTableError @TableLogId = @TableLogId, @ErrorCode = 'ERR-EXP-03', @ErrorStep = 'CLEANUP', @ErrorMessage = @Msg;
    END;

    SET @StepErrCode = CASE WHEN @Status = 'FAILED' THEN 'ERR-EXP-03' END;
    EXEC ret.usp_WriteStepLog @RunId = @RunId, @StepCode = 'CLEANUP', @Status = @Status,
         @TableLogId = @TableLogId, @TableConfigId = @TableConfigId, @StartTime = @Now, @FileCount = @FilesRemoved,
         @Message = @Msg, @ErrorCode = @StepErrCode, @ErrorMessage = @ErrorMessage;

    SELECT @Status AS CleanupStatus, @Msg AS Message;
END;
GO

/* 8.4a ret.usp_GetRunArchiveFiles - archive files that one table log (run) may have written (FSD 4.18, 6.1).
        Used by PL_RET_03F after an export, validation, recount or rebuild failure: ADF deletes exactly these
        files (no wildcard), then calls usp_LogCleanupResult. Dates still PENDING were never written;
        dates already REMOVED were cleaned before. At most 5,000 rows (ADF Lookup limit); a table log has at
        most one row per business date of about five years. */
CREATE OR ALTER PROCEDURE ret.usp_GetRunArchiveFiles
    @TableLogId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM ret.RetentionTableLog WHERE TableLogId = @TableLogId)
    BEGIN
        ;THROW 50255, N'TableLogId not found.', 1;
    END;

    SELECT TOP (5000)
           CONVERT(CHAR(10), a.BusinessDate, 23) AS BusinessDate,
           a.FolderPath,
           a.FileName,
           a.ExportStatus
    FROM ret.RetentionArchiveDate AS a
    WHERE a.TableLogId = @TableLogId
      AND a.ExportStatus IN ('SUCCEEDED', 'FAILED', 'STOPPED')
    ORDER BY a.BusinessDate;
END;
GO

/* 8.5 ret.usp_AbortRunRebuilds - internal: undo unfinished rebuilds of one run when the run is
       closed without the ADF failure path (usp_EndRun, usp_AdminCloseStaleRun). */
CREATE OR ALTER PROCEDURE ret.usp_AbortRunRebuilds
    @RunId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @LogId BIGINT;

    SELECT TOP (1) @LogId = TableLogId
    FROM ret.RetentionTableLog
    WHERE RunId = @RunId AND MethodUsed = 'TABLE_REBUILD' AND DeleteStatus <> 'COMPLETED'
      AND (RebuildStagingTable IS NOT NULL OR IsValidated = 1)
    ORDER BY TableLogId;

    WHILE @LogId IS NOT NULL
    BEGIN
        EXEC ret.usp_TableRebuildAbort @RunId = @RunId, @TableLogId = @LogId, @MarkOrphanFiles = 1, @Silent = 1;

        SET @LogId = (SELECT MIN(TableLogId) FROM ret.RetentionTableLog
                      WHERE RunId = @RunId AND TableLogId > @LogId AND MethodUsed = 'TABLE_REBUILD' AND DeleteStatus <> 'COMPLETED'
                        AND (RebuildStagingTable IS NOT NULL OR IsValidated = 1));
    END;
END;
GO

/* 8.5a ret.usp_PurgeTableLogs - internal: log retention of one table (MD-08, FSD 4.24), called by usp_EndTable
        in the Daily Routine. Deletes step, archive-date and table log rows of the table whose run date is before
        RunDate - LogRetentionYears. Kept: the current table log, open table logs, validated ranges not fully
        deleted, runs referenced by ret.RetentionTableStatus and [v0.6] table logs whose archive inventory still
        lists files that are not expired (business date >= archive cut-off), because decision D-1 needs them. */
CREATE OR ALTER PROCEDURE ret.usp_PurgeTableLogs
    @TableLogId     BIGINT,
    @RowsDeleted    INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @TableConfigId INT, @ProcessType VARCHAR(20), @RunDate DATE, @ArchiveCutoff DATE, @LogYears SMALLINT,
            @LogCutoff DATE, @n INT = 0;

    SET @RowsDeleted = 0;

    SELECT @TableConfigId = l.TableConfigId, @ProcessType = l.ProcessType, @RunDate = l.RunDate,
           @ArchiveCutoff = l.ArchiveCutoffDate, @LogYears = c.LogRetentionYears
    FROM ret.RetentionTableLog AS l
    JOIN ret.RetentionConfig AS c ON c.TableConfigId = l.TableConfigId
    WHERE l.TableLogId = @TableLogId;

    IF @TableConfigId IS NULL OR @ProcessType <> 'DAILY_ROUTINE' OR @LogYears IS NULL OR @LogYears < 1
        RETURN;

    SET @LogCutoff = DATEADD(YEAR, -@LogYears, @RunDate);

    CREATE TABLE #Del (TableLogId BIGINT NOT NULL PRIMARY KEY);

    INSERT INTO #Del (TableLogId)
    SELECT l.TableLogId
    FROM ret.RetentionTableLog AS l
    WHERE l.TableConfigId = @TableConfigId
      AND l.TableLogId <> @TableLogId
      AND l.RunDate < @LogCutoff
      AND l.EndTime IS NOT NULL
      AND NOT (l.IsValidated = 1 AND l.DeleteStatus IN ('NOT_STARTED', 'IN_PROGRESS', 'FAILED'))
      AND NOT EXISTS (SELECT 1 FROM ret.RetentionTableStatus AS s
                      WHERE s.TableConfigId = l.TableConfigId
                        AND l.RunId IN (ISNULL(s.LastInitialCutoffRunId, -1), ISNULL(s.OrphanFilesRunId, -1),
                                        ISNULL(s.IntegrityIssueRunId, -1), ISNULL(s.ReconciliationWarningRunId, -1)))
      AND NOT EXISTS (SELECT 1 FROM ret.RetentionArchiveDate AS a
                      WHERE a.TableLogId = l.TableLogId AND a.ExportStatus = 'SUCCEEDED'
                        AND (@ArchiveCutoff IS NULL OR a.BusinessDate >= @ArchiveCutoff));

    BEGIN TRY
        BEGIN TRANSACTION;

            DELETE sl FROM ret.RetentionStepLog AS sl JOIN #Del AS d ON d.TableLogId = sl.TableLogId;
            SET @n += @@ROWCOUNT;

            DELETE sl FROM ret.RetentionStepLog AS sl
            WHERE sl.TableConfigId = @TableConfigId AND sl.TableLogId IS NULL AND sl.StartTime < @LogCutoff;
            SET @n += @@ROWCOUNT;

            DELETE a FROM ret.RetentionArchiveDate AS a JOIN #Del AS d ON d.TableLogId = a.TableLogId;
            SET @n += @@ROWCOUNT;

            DELETE l FROM ret.RetentionTableLog AS l JOIN #Del AS d ON d.TableLogId = l.TableLogId;
            SET @n += @@ROWCOUNT;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    SET @RowsDeleted = @n;
END;
GO

/* 8.5b ret.usp_PurgeRunLogs - internal: run-level log retention (FSD 4.24), called by usp_EndRun of a Daily
        Routine. Deletes run log rows (and their run-level step rows) older than RunDate - the largest
        LogRetentionYears of the configuration, when no table log, archive inventory, status flag, lock or
        later step still refers to the run. */
CREATE OR ALTER PROCEDURE ret.usp_PurgeRunLogs
    @RunId          BIGINT,
    @RowsDeleted    INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ProcessType VARCHAR(20), @RunDate DATE, @MaxYears SMALLINT, @RunCutoff DATE, @n INT = 0;

    SET @RowsDeleted = 0;

    SELECT @ProcessType = ProcessType, @RunDate = RunDate FROM ret.RetentionRunLog WHERE RunId = @RunId;
    IF @ProcessType IS NULL OR @ProcessType <> 'DAILY_ROUTINE'
        RETURN;

    SELECT @MaxYears = ISNULL(MAX(LogRetentionYears), 3) FROM ret.RetentionConfig;
    SET @RunCutoff = DATEADD(YEAR, -@MaxYears, @RunDate);

    CREATE TABLE #DelRun (RunId BIGINT NOT NULL PRIMARY KEY);

    INSERT INTO #DelRun (RunId)
    SELECT r.RunId
    FROM ret.RetentionRunLog AS r
    WHERE r.RunId <> @RunId
      AND r.RunDate < @RunCutoff
      AND r.Status <> 'RUNNING'
      AND NOT EXISTS (SELECT 1 FROM ret.RetentionTableLog AS l WHERE l.RunId = r.RunId OR l.ResumedByRunId = r.RunId)
      AND NOT EXISTS (SELECT 1 FROM ret.RetentionArchiveDate AS a WHERE a.RunId = r.RunId)
      AND NOT EXISTS (SELECT 1 FROM ret.RetentionTableLock AS k WHERE k.RunId = r.RunId)
      AND NOT EXISTS (SELECT 1 FROM ret.RetentionTableStatus AS s
                      WHERE r.RunId IN (ISNULL(s.LastInitialCutoffRunId, -1), ISNULL(s.OrphanFilesRunId, -1),
                                        ISNULL(s.IntegrityIssueRunId, -1), ISNULL(s.ReconciliationWarningRunId, -1)))
      AND NOT EXISTS (SELECT 1 FROM ret.RetentionStepLog AS sl WHERE sl.ReferenceRunId = r.RunId AND sl.RunId <> r.RunId);

    BEGIN TRY
        BEGIN TRANSACTION;

            DELETE sl FROM ret.RetentionStepLog AS sl JOIN #DelRun AS d ON d.RunId = sl.RunId;
            SET @n += @@ROWCOUNT;

            DELETE r FROM ret.RetentionRunLog AS r JOIN #DelRun AS d ON d.RunId = r.RunId;
            SET @n += @@ROWCOUNT;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    SET @RowsDeleted = @n;
END;
GO

/* 8.6 ret.usp_EndTable - close the table log, final status, Initial Cut-off status on failure/stop,
       release the lock. Always called, also from ADF failure paths. Idempotent. An unfinished rebuild
       still open here is undone and its files are flagged as orphan files.
       v0.6 (MD-08, FSD 4.24): in the Daily Routine log records of the table older than LogRetentionYears are
       deleted (usp_PurgeTableLogs); a failure is logged as a warning and does not change the table result. */
CREATE OR ALTER PROCEDURE ret.usp_EndTable
    @TableLogId     BIGINT,
    @ErrorCode      VARCHAR(12)     = NULL,
    @ErrorStep      VARCHAR(30)     = NULL,
    @ErrorMessage   NVARCHAR(MAX)   = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Now DATETIME2(3) = ret.fn_NowUtc7();
    DECLARE @RunId BIGINT, @TableConfigId INT, @ProcessType VARCHAR(20), @Status VARCHAR(10), @EndTime DATETIME2(3),
            @Eligible BIGINT, @DeleteStatus VARCHAR(15), @IcStatus VARCHAR(10), @IcRunId BIGINT, @Final VARCHAR(10), @Msg NVARCHAR(4000),
            @StepStatus VARCHAR(10), @Purged INT, @PurgeMsg NVARCHAR(4000), @PurgeErr NVARCHAR(4000);

    SELECT @RunId = l.RunId, @TableConfigId = l.TableConfigId, @ProcessType = l.ProcessType, @EndTime = l.EndTime
    FROM ret.RetentionTableLog AS l WHERE l.TableLogId = @TableLogId;

    IF @RunId IS NULL
    BEGIN
        ;THROW 50261, N'TableLogId not found.', 1;
    END;

    IF @EndTime IS NULL
    BEGIN
        IF @ErrorCode IS NOT NULL OR @ErrorMessage IS NOT NULL
        BEGIN
            IF @ErrorCode IS NULL OR NOT EXISTS (SELECT 1 FROM ret.RetentionErrorCode WHERE ErrorCode = @ErrorCode)
                SET @ErrorCode = 'ERR-SYS-01';
            SET @ErrorStep = ISNULL(@ErrorStep, 'END_TABLE');
            EXEC ret.usp_SetTableError @TableLogId = @TableLogId, @ErrorCode = @ErrorCode, @ErrorStep = @ErrorStep, @ErrorMessage = @ErrorMessage;
        END;

        IF EXISTS (SELECT 1 FROM ret.RetentionTableLog
                   WHERE TableLogId = @TableLogId AND MethodUsed = 'TABLE_REBUILD' AND DeleteStatus <> 'COMPLETED'
                     AND (RebuildStagingTable IS NOT NULL OR IsValidated = 1))
            EXEC ret.usp_TableRebuildAbort @RunId = @RunId, @TableLogId = @TableLogId, @MarkOrphanFiles = 1, @Silent = 1;

        SELECT @Status = l.Status, @Eligible = l.EligibleRows, @DeleteStatus = l.DeleteStatus
        FROM ret.RetentionTableLog AS l WHERE l.TableLogId = @TableLogId;

        SELECT @IcStatus = InitialCutoffStatus, @IcRunId = LastInitialCutoffRunId
        FROM ret.RetentionTableStatus WHERE TableConfigId = @TableConfigId;

        /* Safety nets: a table cannot end SUCCEEDED when a mandatory step was skipped */
        IF @Status = 'RUNNING' AND @ProcessType IN ('INITIAL_CUTOFF', 'DAILY_ROUTINE')
        BEGIN
            IF @Eligible IS NULL
                SET @Msg = N'Eligible data was not identified (usp_IdentifyEligibleData not executed).';
            ELSE IF @ProcessType = 'INITIAL_CUTOFF' AND ISNULL(@IcStatus, '') <> 'COMPLETED'
                SET @Msg = N'Initial Cut-off post-check not passed (usp_PostCheck not executed or failed).';
            ELSE IF @ProcessType = 'DAILY_ROUTINE' AND @Eligible > 0 AND @DeleteStatus <> 'COMPLETED'
                SET @Msg = N'Eligible rows were not deleted (export, validation or deletion not completed).';

            IF @Msg IS NOT NULL
            BEGIN
                EXEC ret.usp_SetTableError @TableLogId = @TableLogId, @ErrorCode = 'ERR-SYS-01', @ErrorStep = 'END_TABLE', @ErrorMessage = @Msg;
                SET @Status = 'FAILED';
            END;
        END;

        SET @Final = CASE WHEN @Status <> 'RUNNING' THEN @Status
                          WHEN @ProcessType IN ('INITIAL_CUTOFF', 'DAILY_ROUTINE') AND ISNULL(@Eligible, 0) = 0 THEN 'NODATA'
                          ELSE 'SUCCEEDED' END;

        UPDATE ret.RetentionTableLog
           SET Status       = @Final,
               EndTime      = CASE WHEN @Now < StartTime THEN StartTime ELSE @Now END,
               DeleteStatus = CASE WHEN DeleteStatus = 'NOT_STARTED' AND ISNULL(EligibleRows, 0) = 0 THEN 'NOT_REQUIRED' ELSE DeleteStatus END
         WHERE TableLogId = @TableLogId;

        IF @ProcessType = 'INITIAL_CUTOFF' AND @IcStatus = 'RUNNING' AND @IcRunId = @RunId
            UPDATE ret.RetentionTableStatus
               SET InitialCutoffStatus = CASE WHEN @Final = 'STOPPED' THEN 'STOPPED' ELSE 'FAILED' END,
                   ModifiedBy = ORIGINAL_LOGIN(), ModifiedAt = ret.fn_NowUtc7()
             WHERE TableConfigId = @TableConfigId;

        /* ---- Log retention (MD-08, FSD 4.24): Daily Routine only; never changes the table result ---- */
        IF @ProcessType = 'DAILY_ROUTINE'
        BEGIN
            BEGIN TRY
                EXEC ret.usp_PurgeTableLogs @TableLogId = @TableLogId, @RowsDeleted = @Purged OUTPUT;
                SET @PurgeMsg = CONCAT(N' Log records older than LogRetentionYears deleted: ', ISNULL(@Purged, 0), N'.');
            END TRY
            BEGIN CATCH
                IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
                SET @PurgeErr = LEFT(ERROR_MESSAGE(), 4000);
            END CATCH;
        END;

        SELECT @StepStatus = CASE WHEN @Final IN ('SUCCEEDED', 'NODATA') THEN 'SUCCEEDED' WHEN @Final = 'STOPPED' THEN 'STOPPED'
                                  WHEN @Final = 'SKIPPED' THEN 'SKIPPED' ELSE 'FAILED' END,
               @Msg = CONCAT(N'Final status: ', @Final, N'.', @PurgeMsg);
        EXEC ret.usp_WriteStepLog @RunId = @RunId, @StepCode = 'END_TABLE', @Status = @StepStatus,
             @TableLogId = @TableLogId, @TableConfigId = @TableConfigId, @StartTime = @Now, @Message = @Msg,
             @RowsProcessed = @Purged;

        IF @PurgeErr IS NOT NULL
        BEGIN
            SET @PurgeMsg = CONCAT(N'Log retention failed; retried by the next Daily Routine (FSD 4.24): ', @PurgeErr);
            EXEC ret.usp_WriteStepLog @RunId = @RunId, @StepCode = 'END_TABLE', @Status = 'WARNING',
                 @TableLogId = @TableLogId, @TableConfigId = @TableConfigId, @StartTime = @Now, @Message = @PurgeMsg;
        END;
    END;

    DELETE FROM ret.RetentionTableLock WHERE TableConfigId = @TableConfigId AND RunId = @RunId;

    SELECT l.TableLogId, l.Status AS FinalStatus, l.EligibleRows, l.RowsExported, l.RowsDeleted, l.ResumeRowsDeleted, l.OrphanRows,
           l.ArchiveFilesDeleted, l.ErrorCode, l.ErrorMessage, s.InitialCutoffStatus
    FROM ret.RetentionTableLog AS l
    LEFT JOIN ret.RetentionTableStatus AS s ON s.TableConfigId = l.TableConfigId
    WHERE l.TableLogId = @TableLogId;
END;
GO

/* 8.7 ret.usp_EndRun - close the run. Open table logs are closed as FAILED, unfinished rebuilds
       undone, locks released. @FailPipelineOnError = 1 raises an error when the run did not succeed. */
CREATE OR ALTER PROCEDURE ret.usp_EndRun
    @RunId                  BIGINT,
    @ErrorMessage           NVARCHAR(MAX)   = NULL,
    @FailPipelineOnError    BIT             = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Now DATETIME2(3) = ret.fn_NowUtc7();
    DECLARE @RunStatus VARCHAR(25), @Succeeded INT, @Failed INT, @Skipped INT, @Final VARCHAR(25), @Msg NVARCHAR(2048),
            @StepStatus VARCHAR(10), @StepMsg NVARCHAR(4000), @Purged INT, @PurgeErr NVARCHAR(4000);

    SELECT @RunStatus = Status FROM ret.RetentionRunLog WHERE RunId = @RunId;
    IF @RunStatus IS NULL
    BEGIN
        ;THROW 50271, N'RunId not found.', 1;
    END;

    IF @RunStatus = 'RUNNING'
    BEGIN
        EXEC ret.usp_AbortRunRebuilds @RunId = @RunId;

        UPDATE ret.RetentionTableLog
           SET Status = 'FAILED',
               EndTime = CASE WHEN @Now < StartTime THEN StartTime ELSE @Now END,
               ErrorCode = ISNULL(ErrorCode, 'ERR-SYS-01'),
               ErrorStep = ISNULL(ErrorStep, 'END_RUN'),
               ErrorMessage = CONCAT(ErrorMessage, CASE WHEN ErrorMessage IS NULL THEN N'' ELSE N' | ' END,
                                     N'[ERR-SYS-01] Table log not closed before the end of the run.')
         WHERE RunId = @RunId AND EndTime IS NULL;

        UPDATE ret.RetentionTableStatus
           SET InitialCutoffStatus = 'FAILED', ModifiedBy = ORIGINAL_LOGIN(), ModifiedAt = ret.fn_NowUtc7()
         WHERE LastInitialCutoffRunId = @RunId AND InitialCutoffStatus = 'RUNNING';

        DELETE FROM ret.RetentionTableLock WHERE RunId = @RunId;

        SELECT @Succeeded = SUM(CASE WHEN Status IN ('SUCCEEDED', 'NODATA') THEN 1 ELSE 0 END),
               @Failed    = SUM(CASE WHEN Status IN ('FAILED', 'STOPPED') THEN 1 ELSE 0 END),
               @Skipped   = SUM(CASE WHEN Status = 'SKIPPED' THEN 1 ELSE 0 END)
        FROM ret.RetentionTableLog WHERE RunId = @RunId;

        SELECT @Succeeded = ISNULL(@Succeeded, 0), @Failed = ISNULL(@Failed, 0), @Skipped = ISNULL(@Skipped, 0);

        SET @Final = CASE WHEN @ErrorMessage IS NOT NULL AND @Succeeded = 0 THEN 'FAILED'
                          WHEN @ErrorMessage IS NOT NULL OR @Failed > 0 OR @Skipped > 0 THEN 'COMPLETED_WITH_ERRORS'
                          ELSE 'SUCCEEDED' END;

        UPDATE ret.RetentionRunLog
           SET Status = @Final,
               EndTime = CASE WHEN @Now < StartTime THEN StartTime ELSE @Now END,
               TablesSucceeded = @Succeeded,
               TablesFailed = @Failed,
               TablesSkipped = @Skipped,
               ErrorCode = CASE WHEN @Final <> 'SUCCEEDED' AND @ErrorMessage IS NOT NULL THEN ISNULL(ErrorCode, 'ERR-SYS-01') ELSE ErrorCode END,
               ErrorMessage = COALESCE(@ErrorMessage, ErrorMessage)
         WHERE RunId = @RunId;

        SELECT @StepStatus = CASE WHEN @Final = 'SUCCEEDED' THEN 'SUCCEEDED' WHEN @Final = 'FAILED' THEN 'FAILED' ELSE 'WARNING' END,
               @StepMsg = CONCAT(N'Run ', @Final, N'. Succeeded/NoData: ', @Succeeded, N'; failed/stopped: ', @Failed, N'; skipped: ', @Skipped, N'.');
        EXEC ret.usp_WriteStepLog @RunId = @RunId, @StepCode = 'END_RUN', @Status = @StepStatus,
             @StartTime = @Now, @Message = @StepMsg, @ErrorMessage = @ErrorMessage;

        /* ---- Run-level log retention (FSD 4.24), Daily Routine only; never changes the run result ---- */
        BEGIN TRY
            EXEC ret.usp_PurgeRunLogs @RunId = @RunId, @RowsDeleted = @Purged OUTPUT;
            IF @Purged > 0
            BEGIN
                SET @StepMsg = CONCAT(N'Run-level log records older than LogRetentionYears deleted: ', @Purged, N'.');
                EXEC ret.usp_WriteStepLog @RunId = @RunId, @StepCode = 'END_RUN', @Status = 'SUCCEEDED',
                     @StartTime = @Now, @Message = @StepMsg, @RowsProcessed = @Purged;
            END;
        END TRY
        BEGIN CATCH
            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
            SET @PurgeErr = LEFT(CONCAT(N'Run-level log retention failed; retried by the next Daily Routine: ', ERROR_MESSAGE()), 4000);
            EXEC ret.usp_WriteStepLog @RunId = @RunId, @StepCode = 'END_RUN', @Status = 'WARNING',
                 @StartTime = @Now, @Message = @PurgeErr;
        END CATCH;
    END;

    SELECT RunId, ProcessType, CONVERT(CHAR(10), RunDate, 23) AS RunDate, Status, TablesSelected, TablesSucceeded,
           TablesFailed, TablesSkipped, StartTime, EndTime
    FROM ret.RetentionRunLog WHERE RunId = @RunId;

    SELECT @Final = Status FROM ret.RetentionRunLog WHERE RunId = @RunId;
    IF @FailPipelineOnError = 1 AND @Final <> 'SUCCEEDED'
    BEGIN
        SET @Msg = CONCAT(N'Retention run ', @RunId, N' ended with status ', @Final, N'. See ret.RetentionTableLog.');
        THROW 50272, @Msg, 1;
    END;
END;
GO

/* 8.8 ret.usp_AdminCloseStaleRun - operator procedure: close a run aborted outside the handled
       failure paths. Unfinished rebuilds are undone (new table dropped, files flagged as orphan files);
       validated batch-delete ranges are resumed by the next run (FR-017).
       Confirm in ADF monitoring that the pipeline is no longer active before calling. */
CREATE OR ALTER PROCEDURE ret.usp_AdminCloseStaleRun
    @RunId      BIGINT,
    @Comment    NVARCHAR(400),
    @Confirm    BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Now DATETIME2(3) = ret.fn_NowUtc7(), @Msg NVARCHAR(4000);

    IF @Confirm <> 1 OR NULLIF(LTRIM(RTRIM(@Comment)), N'') IS NULL
    BEGIN
        ;THROW 50281, N'Set @Confirm = 1 and provide a @Comment explaining the investigation.', 1;
    END;
    IF NOT EXISTS (SELECT 1 FROM ret.RetentionRunLog WHERE RunId = @RunId AND Status = 'RUNNING')
    BEGIN
        ;THROW 50282, N'Run not found or not in status RUNNING.', 1;
    END;

    SET @Msg = CONCAT(N'Closed manually by ', ORIGINAL_LOGIN(), N': ', @Comment);

    EXEC ret.usp_AbortRunRebuilds @RunId = @RunId;

    BEGIN TRANSACTION;

        UPDATE ret.RetentionTableLog
           SET Status = 'FAILED',
               EndTime = CASE WHEN @Now < StartTime THEN StartTime ELSE @Now END,
               ErrorCode = ISNULL(ErrorCode, 'ERR-SYS-01'),
               ErrorStep = ISNULL(ErrorStep, 'ADMIN'),
               ErrorMessage = CONCAT(ErrorMessage, CASE WHEN ErrorMessage IS NULL THEN N'' ELSE N' | ' END, N'[ADMIN] ', @Msg)
         WHERE RunId = @RunId AND EndTime IS NULL;

        UPDATE ret.RetentionTableStatus
           SET InitialCutoffStatus = 'FAILED', ModifiedBy = ORIGINAL_LOGIN(), ModifiedAt = @Now
         WHERE LastInitialCutoffRunId = @RunId AND InitialCutoffStatus = 'RUNNING';

        DELETE FROM ret.RetentionTableLock WHERE RunId = @RunId;

        UPDATE ret.RetentionRunLog
           SET Status = 'FAILED',
               EndTime = CASE WHEN @Now < StartTime THEN StartTime ELSE @Now END,
               IsClosedManually = 1, ClosedBy = ORIGINAL_LOGIN(), CloseComment = @Comment,
               ErrorCode = ISNULL(ErrorCode, 'ERR-SYS-01'),
               ErrorMessage = CONCAT(ErrorMessage, CASE WHEN ErrorMessage IS NULL THEN N'' ELSE N' | ' END, @Msg)
         WHERE RunId = @RunId;

    COMMIT TRANSACTION;

    EXEC ret.usp_WriteStepLog @RunId = @RunId, @StepCode = 'ADMIN', @Status = 'SUCCEEDED', @StartTime = @Now, @Message = @Msg;

    SELECT RunId, Status, IsClosedManually, ClosedBy, CloseComment, EndTime FROM ret.RetentionRunLog WHERE RunId = @RunId;
END;
GO

/* 8.9 ret.usp_AdminClearTableFlag - clear a flag after investigation (ORPHAN_FILES, INTEGRITY, RECONCILIATION) */
CREATE OR ALTER PROCEDURE ret.usp_AdminClearTableFlag
    @TableConfigId  INT,
    @FlagType       VARCHAR(20),
    @Comment        NVARCHAR(400),
    @Confirm        BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Now DATETIME2(3) = ret.fn_NowUtc7(), @RunId BIGINT, @Msg NVARCHAR(4000);

    IF @Confirm <> 1 OR NULLIF(LTRIM(RTRIM(@Comment)), N'') IS NULL
    BEGIN
        ;THROW 50291, N'Set @Confirm = 1 and provide a @Comment explaining the investigation.', 1;
    END;
    IF @FlagType IS NULL OR @FlagType NOT IN ('ORPHAN_FILES', 'INTEGRITY', 'RECONCILIATION')
    BEGIN
        ;THROW 50292, N'Invalid @FlagType. Allowed values: ORPHAN_FILES, INTEGRITY, RECONCILIATION.', 1;
    END;

    SELECT @RunId = CASE @FlagType WHEN 'ORPHAN_FILES' THEN OrphanFilesRunId
                                   WHEN 'INTEGRITY' THEN IntegrityIssueRunId
                                   ELSE ReconciliationWarningRunId END
    FROM ret.RetentionTableStatus WHERE TableConfigId = @TableConfigId;

    UPDATE ret.RetentionTableStatus
       SET HasOrphanFiles             = CASE WHEN @FlagType = 'ORPHAN_FILES'   THEN 0 ELSE HasOrphanFiles END,
           OrphanFilesRunId           = CASE WHEN @FlagType = 'ORPHAN_FILES'   THEN NULL ELSE OrphanFilesRunId END,
           HasIntegrityIssue          = CASE WHEN @FlagType = 'INTEGRITY'      THEN 0 ELSE HasIntegrityIssue END,
           IntegrityIssueRunId        = CASE WHEN @FlagType = 'INTEGRITY'      THEN NULL ELSE IntegrityIssueRunId END,
           HasReconciliationWarning   = CASE WHEN @FlagType = 'RECONCILIATION' THEN 0 ELSE HasReconciliationWarning END,
           ReconciliationWarningRunId = CASE WHEN @FlagType = 'RECONCILIATION' THEN NULL ELSE ReconciliationWarningRunId END,
           FlagComment = LEFT(CONCAT(N'Cleared ', @FlagType, N' by ', ORIGINAL_LOGIN(), N': ', @Comment), 400),
           ModifiedBy  = ORIGINAL_LOGIN(),
           ModifiedAt  = @Now
     WHERE TableConfigId = @TableConfigId;

    IF @@ROWCOUNT = 0
    BEGIN
        ;THROW 50293, N'TableConfigId not found.', 1;
    END;

    IF @RunId IS NOT NULL
    BEGIN
        SET @Msg = CONCAT(N'Flag ', @FlagType, N' cleared for TableConfigId ', @TableConfigId, N' by ', ORIGINAL_LOGIN(), N': ', @Comment);
        EXEC ret.usp_WriteStepLog @RunId = @RunId, @StepCode = 'ADMIN', @Status = 'SUCCEEDED',
             @TableConfigId = @TableConfigId, @StartTime = @Now, @Message = @Msg;
    END;

    SELECT * FROM ret.RetentionTableStatus WHERE TableConfigId = @TableConfigId;
END;
GO

/* 8.10 ret.usp_ActivateDailyRoutine - DB-side control for AC-15: allowed when every active table has
        completed its Initial Cut-off Run; start date = day after the last completion date (BR-12). */
CREATE OR ALTER PROCEDURE ret.usp_ActivateDailyRoutine
    @StartDate  DATE = NULL,
    @Confirm    BIT  = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Earliest DATE, @Pending NVARCHAR(MAX), @Msg NVARCHAR(2048);

    IF @Confirm <> 1
    BEGIN
        ;THROW 50301, N'Set @Confirm = 1 to activate the Daily Routine.', 1;
    END;

    IF NOT EXISTS (SELECT 1 FROM ret.RetentionConfig WHERE IsActive = 1)
    BEGIN
        ;THROW 50302, N'No active table in the configuration.', 1;
    END;

    SELECT @Pending = STRING_AGG(CONVERT(NVARCHAR(MAX), CONCAT(c.SchemaName, N'.', c.TableName, N' (', s.InitialCutoffStatus, N')')) COLLATE DATABASE_DEFAULT, N', ')
    FROM ret.RetentionConfig AS c
    JOIN ret.RetentionTableStatus AS s ON s.TableConfigId = c.TableConfigId
    WHERE c.IsActive = 1 AND s.InitialCutoffStatus <> 'COMPLETED';

    IF @Pending IS NOT NULL
    BEGIN
        SET @Msg = LEFT(CONCAT(N'Initial Cut-off Run not completed for: ', @Pending, N' (AC-15).'), 2048);
        THROW 50303, @Msg, 1;
    END;

    SELECT @Earliest = DATEADD(DAY, 1, MAX(s.InitialCutoffCompletionDate))
    FROM ret.RetentionConfig AS c
    JOIN ret.RetentionTableStatus AS s ON s.TableConfigId = c.TableConfigId
    WHERE c.IsActive = 1;

    SET @StartDate = ISNULL(@StartDate, @Earliest);
    IF @StartDate < @Earliest
    BEGIN
        SET @Msg = CONCAT(N'Start date cannot be earlier than ', CONVERT(CHAR(10), @Earliest, 23), N' (AC-15).');
        THROW 50304, @Msg, 1;
    END;

    UPDATE ret.RetentionParameter
       SET DailyRoutineStartDate = @StartDate, ModifiedBy = ORIGINAL_LOGIN(), ModifiedAt = ret.fn_NowUtc7()
     WHERE ParameterSetId = 1;

    SELECT CONVERT(CHAR(10), @StartDate, 23) AS DailyRoutineStartDate,
           N'Start the ADF Daily Routine schedule trigger (21:00 UTC+7) with first execution on this date.' AS NextStep;
END;
GO

/* =====================================================================================
   9. TABLE ANALYSIS SUPPORT (FR-022) - read-only, caller permissions
   ===================================================================================== */

-- 9.1 Candidate tables: size, date columns, configuration and foreign-key status
CREATE OR ALTER PROCEDURE ret.usp_ListCandidateTables
    @SchemaName SYSNAME = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT s.name COLLATE DATABASE_DEFAULT AS SchemaName,
           t.name COLLATE DATABASE_DEFAULT AS TableName,
           ps.RowCnt,
           CAST(ps.ReservedPages * 8.0 / 1024 AS DECIMAL(18, 2)) AS ReservedMB,
           dc.DateColumns,
           CASE WHEN cfg.TableConfigId IS NOT NULL THEN 1 ELSE 0 END AS IsConfigured,
           CASE WHEN cfg.ParentTableConfigId IS NOT NULL THEN 1 ELSE 0 END AS IsConfiguredAsChild,
           CASE WHEN EXISTS (SELECT 1 FROM sys.foreign_keys AS fk WHERE fk.referenced_object_id = t.object_id AND fk.parent_object_id <> t.object_id)
                THEN 1 ELSE 0 END AS IsReferencedByForeignKey
    FROM sys.tables AS t
    JOIN sys.schemas AS s ON s.schema_id = t.schema_id
    CROSS APPLY (SELECT SUM(CASE WHEN p.index_id IN (0, 1) THEN p.row_count ELSE 0 END) AS RowCnt,
                        SUM(p.reserved_page_count) AS ReservedPages
                 FROM sys.dm_db_partition_stats AS p WHERE p.object_id = t.object_id) AS ps
    OUTER APPLY (SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), CONCAT(c.name COLLATE DATABASE_DEFAULT, N' (', TYPE_NAME(c.system_type_id),
                                   CASE WHEN c.is_nullable = 1 THEN N', nullable' ELSE N'' END, N')')) COLLATE DATABASE_DEFAULT, N', ')
                        WITHIN GROUP (ORDER BY c.column_id) AS DateColumns
                 FROM sys.columns AS c
                 WHERE c.object_id = t.object_id
                   AND TYPE_NAME(c.system_type_id) IN ('date', 'datetime', 'datetime2', 'smalldatetime', 'datetimeoffset')) AS dc
    LEFT JOIN ret.RetentionConfig AS cfg
           ON cfg.SchemaName = s.name COLLATE DATABASE_DEFAULT AND cfg.TableName = t.name COLLATE DATABASE_DEFAULT
    WHERE s.name COLLATE DATABASE_DEFAULT <> N'ret'
      AND t.is_ms_shipped = 0
      AND t.name COLLATE DATABASE_DEFAULT NOT LIKE N'%[_][_]RBD[_]%'
      AND (@SchemaName IS NULL OR s.name COLLATE DATABASE_DEFAULT = @SchemaName)
    ORDER BY ps.RowCnt DESC;
END;
GO

-- 9.2 Profile one candidate retention column: NULLs, range, rows per year, index support (full scan)
CREATE OR ALTER PROCEDURE ret.usp_ProfileRetentionColumn
    @SchemaName         SYSNAME,
    @TableName          SYSNAME,
    @RetentionColumn    SYSNAME
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @FullName NVARCHAR(300) = QUOTENAME(@SchemaName) + N'.' + QUOTENAME(@TableName);
    DECLARE @ObjectId INT = OBJECT_ID(@FullName, N'U');
    DECLARE @QCol NVARCHAR(300) = QUOTENAME(@RetentionColumn), @sql NVARCHAR(MAX);

    IF @ObjectId IS NULL OR NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = @ObjectId AND name = @RetentionColumn)
    BEGIN
        ;THROW 50311, N'Table or column not found.', 1;
    END;

    SELECT @SchemaName AS SchemaName, @TableName AS TableName, c.name COLLATE DATABASE_DEFAULT AS RetentionColumn,
           TYPE_NAME(c.system_type_id) AS DataType, c.is_nullable AS IsNullable,
           CASE WHEN EXISTS (SELECT 1 FROM sys.index_columns AS ic
                             WHERE ic.object_id = @ObjectId AND ic.column_id = c.column_id AND ic.key_ordinal = 1)
                THEN 1 ELSE 0 END AS IsLeadingIndexColumn
    FROM sys.columns AS c
    WHERE c.object_id = @ObjectId AND c.name COLLATE DATABASE_DEFAULT = @RetentionColumn;

    SET @sql = N'SELECT COUNT_BIG(*) AS TotalRows,
       COUNT_BIG(CASE WHEN ' + @QCol + N' IS NULL THEN 1 END) AS NullRows,
       MIN(' + @QCol + N') AS MinValue, MAX(' + @QCol + N') AS MaxValue
FROM ' + @FullName + N';
SELECT YEAR(' + @QCol + N') AS BusinessYear, COUNT_BIG(*) AS RowCnt
FROM ' + @FullName + N'
WHERE ' + @QCol + N' IS NOT NULL
GROUP BY YEAR(' + @QCol + N')
ORDER BY BusinessYear;';

    EXEC sp_executesql @sql;
END;
GO

/* =====================================================================================
   9b. MONITORING VIEWS (FSD 4.15, 11.3, MQ-01..MQ-06) - read-only, role ret_log_reader
       Ordering is given in the query, not in the view, e.g.
         SELECT TOP (20) * FROM ret.vw_MQ01_LatestRuns ORDER BY RunId DESC;
         SELECT * FROM ret.vw_MQ02_FailedTables ORDER BY TableLogId DESC;
         SELECT * FROM ret.vw_MQ05_Reconciliation WHERE RunDate = CAST(DATEADD(DAY, -1, ret.fn_TodayUtc7()) AS DATE);
   ===================================================================================== */

-- MQ-01 Runs with status and counters
CREATE OR ALTER VIEW ret.vw_MQ01_LatestRuns
AS
SELECT RunId, ProcessType, RunDate, TriggerType, Status, TablesSelected, TablesSucceeded,
       TablesFailed, TablesSkipped, StartTime, EndTime, ErrorMessage
FROM ret.RetentionRunLog;
GO

-- MQ-02 Failed, stopped or skipped tables of the last 7 days
CREATE OR ALTER VIEW ret.vw_MQ02_FailedTables
AS
SELECT l.TableLogId, l.RunId, l.RunDate, l.ProcessType, c.SchemaName, c.TableName,
       l.Status, l.ErrorCode, l.ErrorStep, l.ErrorMessage
FROM ret.RetentionTableLog AS l
JOIN ret.RetentionConfig AS c ON c.TableConfigId = l.TableConfigId
WHERE l.Status IN ('FAILED', 'STOPPED', 'SKIPPED')
  AND l.RunDate >= DATEADD(DAY, -7, ret.fn_TodayUtc7());
GO

-- MQ-03 Status and flags per table, with the header of child tables
CREATE OR ALTER VIEW ret.vw_MQ03_TableStatus
AS
SELECT c.TableConfigId, c.SchemaName, c.TableName, c.RetentionColumn,
       h.SchemaName + N'.' + h.TableName AS HeaderTable, c.IsActive, c.SizeCategory,
       c.InitialCutoffMethod, c.LogRetentionYears, s.InitialCutoffStatus, s.InitialCutoffCompletionDate,
       s.HasOrphanFiles, s.HasIntegrityIssue, s.HasReconciliationWarning, s.FlagComment
FROM ret.RetentionConfig AS c
JOIN ret.RetentionTableStatus AS s ON s.TableConfigId = c.TableConfigId
LEFT JOIN ret.RetentionConfig AS h ON h.TableConfigId = c.ParentTableConfigId;
GO

-- MQ-04 Validated ranges not fully deleted (pending resume)
CREATE OR ALTER VIEW ret.vw_MQ04_PendingResume
AS
SELECT l.TableLogId, l.RunId, c.SchemaName, c.TableName, l.ValidatedRangeTo,
       l.ValidatedRowCount, l.RowsDeleted, l.DeleteStatus
FROM ret.RetentionTableLog AS l
JOIN ret.RetentionConfig AS c ON c.TableConfigId = l.TableConfigId
WHERE l.IsValidated = 1 AND l.DeleteStatus IN ('NOT_STARTED', 'IN_PROGRESS', 'FAILED');
GO

-- MQ-05 Reconciliation per table run
CREATE OR ALTER VIEW ret.vw_MQ05_Reconciliation
AS
SELECT l.TableLogId, l.RunId, l.RunDate, c.SchemaName, c.TableName, l.MethodUsed, l.EligibleRows,
       l.ArchivedSegmentRows, l.ExpiredSegmentRows, l.RowsExported, l.RowsDeleted,
       l.RetainedRowsBefore, l.RetainedRowsAfter, l.OrphanRows,
       l.ArchiveFoldersDeleted, l.ArchiveFilesDeleted, l.Status
FROM ret.RetentionTableLog AS l
JOIN ret.RetentionConfig AS c ON c.TableConfigId = l.TableConfigId
WHERE l.ProcessType IN ('INITIAL_CUTOFF', 'DAILY_ROUTINE');
GO

-- MQ-06 Locks held and leftover __RBD_ tables. Catalog names are converted to the database collation
-- (UNION with configuration columns); create_date is UTC and is shown in UTC+7.
CREATE OR ALTER VIEW ret.vw_MQ06_LocksAndRebuildTables
AS
SELECT N'LOCK' AS ItemType, c.SchemaName, c.TableName, k.RunId, k.ProcessType,
       k.AcquiredAt AS SinceUtc7, k.AcquiredBy
FROM ret.RetentionTableLock AS k
JOIN ret.RetentionConfig AS c ON c.TableConfigId = k.TableConfigId
UNION ALL
SELECT N'REBUILD_TABLE', CONVERT(SYSNAME, SCHEMA_NAME(t.schema_id)) COLLATE DATABASE_DEFAULT, t.name COLLATE DATABASE_DEFAULT,
       NULL, NULL, CONVERT(DATETIME2(3), DATEADD(HOUR, 7, t.create_date)), NULL
FROM sys.tables AS t
WHERE t.name COLLATE DATABASE_DEFAULT LIKE N'%[_][_]RBD[_]%';
GO

/* =====================================================================================
   10. EXAMPLE CONFIGURATION (COMMENTED OUT)
       Values are illustrations only. Schema, table, column, method and size category come from
       the approved candidate list (FSD Appendix A, D-05); the container name from D-02.
   =====================================================================================
-- Archive container (container name only, MD-07; value to be supplied by the infrastructure team)
UPDATE ret.RetentionParameter SET ArchiveContainer = N'<container-name>' WHERE ParameterSetId = 1;

-- Own-dated table (BRD 7.3 example)
INSERT INTO ret.RetentionConfig
    (SchemaName, TableName, RetentionColumn, ParentTableConfigId, DwhRetentionYears, BlobRetentionYears,
     BlobPath, InitialCutoffMethod, IsActive, SizeCategory)
VALUES
    (N'BOS', N'JTI_SD_BrandDistDetail', N'dtmDate', NULL, 3, 5,
     N'bos.jti_sd_branddistdetail', 'BATCH_DELETE', 1, 'LARGE');            -- method TBD (rebuild candidate)

-- Header table and child table without its own date column (FR-023, MD-05)
DECLARE @HeaderId INT, @ChildId INT;

INSERT INTO ret.RetentionConfig
    (SchemaName, TableName, RetentionColumn, ParentTableConfigId, DwhRetentionYears, BlobRetentionYears,
     BlobPath, InitialCutoffMethod, IsActive, SizeCategory)
VALUES
    (N'<schema>', N'<HeaderTable>', N'<dateColumn>', NULL, 3, 5, N'<schema>.<headertable>', 'BATCH_DELETE', 1, 'MEDIUM');
SET @HeaderId = SCOPE_IDENTITY();

INSERT INTO ret.RetentionConfig
    (SchemaName, TableName, RetentionColumn, ParentTableConfigId, DwhRetentionYears, BlobRetentionYears,
     BlobPath, InitialCutoffMethod, IsActive, SizeCategory)
VALUES
    (N'<schema>', N'<ChildTable>', NULL, @HeaderId, 3, 5, N'<schema>.<childtable>', 'BATCH_DELETE', 1, 'MEDIUM');
SET @ChildId = SCOPE_IDENTITY();

INSERT INTO ret.RetentionParentKey (TableConfigId, KeyOrdinal, ChildColumn, ParentColumn)
VALUES (@ChildId, 1, N'<childKeyColumn1>', N'<headerKeyColumn1>'),
       (@ChildId, 2, N'<childKeyColumn2>', N'<headerKeyColumn2>');

-- Initial Cut-off order: child tables first or earlier in the same list (DBR-18), e.g.
--   EXEC ret.usp_GetTablesToProcess @RunId = <RunId>, @TableConfigIdList = N'<ChildId>,<HeaderId>';
*/

/* =====================================================================================
   11. EXAMPLE CALLS (COMMENTED OUT)
   =====================================================================================
-- Dry validation (V-01..V-11, no data change)
EXEC ret.usp_StartRun @ProcessType = 'VALIDATION', @TriggerType = 'MANUAL', @TriggeredBy = N'<operator>';
EXEC ret.usp_GetTablesToProcess @RunId = <RunId>, @TableConfigIdList = N'1,2';   -- or NULL: all active tables not COMPLETED (v0.6)
EXEC ret.usp_BeginTable @RunId = <RunId>, @TableConfigId = 1;
EXEC ret.usp_EndTable @TableLogId = <TableLogId>;
EXEC ret.usp_EndRun @RunId = <RunId>, @FailPipelineOnError = 0;

-- Table rebuild (IC, downtime reference required)
EXEC ret.usp_StartRun @ProcessType = 'INITIAL_CUTOFF', @TriggerType = 'MANUAL', @TriggeredBy = N'<operator>', @DowntimeReference = N'<CR-number>';
--   usp_GetTablesToProcess -> usp_BeginTable -> usp_IdentifyEligibleData -> usp_TableRebuildPrepare
--   -> export loop -> usp_ValidateArchive -> usp_TableRebuildSwap -> usp_PostCheck -> usp_EndTable
--   on failure before the swap commits: usp_TableRebuildAbort -> file cleanup -> usp_LogCleanupResult -> usp_EndTable

-- Archive expiry (DR-05), level by level
EXEC ret.usp_GetExpiredArchiveFolders @TableLogId = <TableLogId>, @Level = 'YEAR', @ChildItemsJson = N'[{"name":"2017","type":"Folder"},{"name":"2018","type":"Folder"}]';
EXEC ret.usp_GetExpiredArchiveFolders @TableLogId = <TableLogId>, @Level = 'FILE', @Year = 2018, @ChildItemsJson = N'[{"name":"bos.jti_sd_branddistdetail_20181026.parquet","type":"File"},{"name":"bos.jti_sd_branddistdetail_20181027.parquet","type":"File"}]';
-- Files written by one table log (cleanup after a failure)
EXEC ret.usp_GetRunArchiveFiles @TableLogId = <TableLogId>;

-- Activation of the Daily Routine after all Initial Cut-off Runs completed (AC-15)
EXEC ret.usp_ActivateDailyRoutine @Confirm = 1;
*/

/* =====================================================================================
   12. MONITORING QUERIES (FR-015, BRQ-13) (COMMENTED OUT)
   =====================================================================================
-- 12.1 Latest runs
SELECT TOP (20) RunId, ProcessType, RunDate, TriggerType, Status, TablesSelected, TablesSucceeded,
       TablesFailed, TablesSkipped, StartTime, EndTime, ErrorMessage
FROM ret.RetentionRunLog ORDER BY RunId DESC;

-- 12.2 Failed, stopped or skipped tables in the last 7 days
SELECT l.RunId, l.RunDate, l.ProcessType, c.SchemaName, c.TableName, l.Status, l.ErrorCode, l.ErrorStep, l.ErrorMessage
FROM ret.RetentionTableLog AS l JOIN ret.RetentionConfig AS c ON c.TableConfigId = l.TableConfigId
WHERE l.Status IN ('FAILED', 'STOPPED', 'SKIPPED') AND l.RunDate >= DATEADD(DAY, -7, ret.fn_TodayUtc7())
ORDER BY l.TableLogId DESC;

-- 12.3 Status and flags per table, with header table of child tables
SELECT c.TableConfigId, c.SchemaName, c.TableName, c.RetentionColumn, h.SchemaName + N'.' + h.TableName AS HeaderTable,
       c.IsActive, c.SizeCategory, c.InitialCutoffMethod, s.InitialCutoffStatus, s.InitialCutoffCompletionDate,
       s.HasOrphanFiles, s.HasIntegrityIssue, s.HasReconciliationWarning, s.FlagComment
FROM ret.RetentionConfig AS c
JOIN ret.RetentionTableStatus AS s ON s.TableConfigId = c.TableConfigId
LEFT JOIN ret.RetentionConfig AS h ON h.TableConfigId = c.ParentTableConfigId
ORDER BY COALESCE(c.ParentTableConfigId, c.TableConfigId), c.ParentTableConfigId, c.TableConfigId;

-- 12.4 Pending resume (validated batch-delete ranges not fully deleted)
SELECT l.TableLogId, l.RunId, c.SchemaName, c.TableName, l.ValidatedRangeTo, l.ValidatedRowCount, l.RowsDeleted, l.DeleteStatus
FROM ret.RetentionTableLog AS l JOIN ret.RetentionConfig AS c ON c.TableConfigId = l.TableConfigId
WHERE l.IsValidated = 1 AND l.DeleteStatus IN ('NOT_STARTED', 'IN_PROGRESS', 'FAILED');

-- 12.5 Reconciliation per table log (exported vs deleted, orphan child rows)
SELECT l.TableLogId, l.RunDate, c.SchemaName, c.TableName, l.MethodUsed, l.EligibleRows, l.ArchivedSegmentRows, l.ExpiredSegmentRows,
       l.RowsExported, l.RowsDeleted, l.RetainedRowsBefore, l.RetainedRowsAfter, l.OrphanRows, l.ArchiveFilesDeleted, l.Status
FROM ret.RetentionTableLog AS l JOIN ret.RetentionConfig AS c ON c.TableConfigId = l.TableConfigId
WHERE l.ProcessType IN ('INITIAL_CUTOFF', 'DAILY_ROUTINE')
ORDER BY l.TableLogId DESC;

-- 12.6 Locks held and leftover rebuild tables
SELECT k.TableConfigId, c.SchemaName, c.TableName, k.RunId, k.ProcessType, k.AcquiredAt, k.AcquiredBy
FROM ret.RetentionTableLock AS k JOIN ret.RetentionConfig AS c ON c.TableConfigId = k.TableConfigId;

SELECT SCHEMA_NAME(t.schema_id) AS SchemaName, t.name AS TableName, t.create_date
FROM sys.tables AS t WHERE t.name LIKE N'%[_][_]RBD[_]%';
*/

/* =====================================================================================
   13. SECURITY (SEC-02..SEC-05) - REVIEW WITH THE DBA BEFORE USE (COMMENTED OUT)
       Procedures that read or change DWH tables run WITH EXECUTE AS OWNER (dynamic SQL breaks
       ownership chaining). The ADF identity needs EXECUTE only, no direct rights on DWH tables.
       The owner (dbo) needs the rights used by the rebuild: CREATE TABLE, ALTER, DROP, sp_rename,
       DBCC CHECKIDENT, GRANT on the rebuilt table (dbo has them).
       Internal procedures (usp_WriteStepLog, usp_SetTableError, usp_GetTableSqlParts,
       usp_AbortRunRebuilds, usp_PurgeTableLogs, usp_PurgeRunLogs) are not granted to anyone.
       Database user of the ADF connection: FSD SEC-01 uses the factory managed identity (FROM EXTERNAL
       PROVIDER). If the linked service (e.g. Agus_SqlServer_dwh, type SQL Server) signs in with an SQL
       login instead, create that user with FOR LOGIN (or as a contained user) and add it to
       ret_adf_executor - deviation from SEC-01 to be recorded (review decision D-2).
   =====================================================================================
CREATE USER [<adf-managed-identity-name>] FROM EXTERNAL PROVIDER;

CREATE ROLE ret_adf_executor;
GRANT EXECUTE ON ret.usp_StartRun                   TO ret_adf_executor;
GRANT EXECUTE ON ret.usp_GetTablesToProcess         TO ret_adf_executor;
GRANT EXECUTE ON ret.usp_BeginTable                 TO ret_adf_executor;
GRANT EXECUTE ON ret.usp_GetPendingResume           TO ret_adf_executor;
GRANT EXECUTE ON ret.usp_IdentifyEligibleData       TO ret_adf_executor;
GRANT EXECUTE ON ret.usp_GetExportPlan              TO ret_adf_executor;
GRANT EXECUTE ON ret.usp_ExportSourceRows           TO ret_adf_executor;
GRANT EXECUTE ON ret.usp_CheckExecutionWindow       TO ret_adf_executor;
GRANT EXECUTE ON ret.usp_LogExportResult            TO ret_adf_executor;
GRANT EXECUTE ON ret.usp_ValidateArchive            TO ret_adf_executor;
GRANT EXECUTE ON ret.usp_BatchDelete                TO ret_adf_executor;
GRANT EXECUTE ON ret.usp_TableRebuildPrepare        TO ret_adf_executor;
GRANT EXECUTE ON ret.usp_TableRebuildSwap           TO ret_adf_executor;
GRANT EXECUTE ON ret.usp_TableRebuildAbort          TO ret_adf_executor;
GRANT EXECUTE ON ret.usp_PostCheck                  TO ret_adf_executor;
GRANT EXECUTE ON ret.usp_GetExpiredArchiveFolders   TO ret_adf_executor;
GRANT EXECUTE ON ret.usp_LogExpiredArchiveResult    TO ret_adf_executor;
GRANT EXECUTE ON ret.usp_LogCleanupResult           TO ret_adf_executor;
GRANT EXECUTE ON ret.usp_GetRunArchiveFiles         TO ret_adf_executor;
GRANT EXECUTE ON ret.usp_EndTable                   TO ret_adf_executor;
GRANT EXECUTE ON ret.usp_EndRun                     TO ret_adf_executor;
ALTER ROLE ret_adf_executor ADD MEMBER [<adf-managed-identity-name>];

CREATE ROLE ret_config_editor;                                  -- Customer users (SEC-03)
GRANT SELECT, INSERT ON ret.RetentionConfig TO ret_config_editor;
GRANT UPDATE ON ret.RetentionConfig (SchemaName, TableName, RetentionColumn, ParentTableConfigId, DwhRetentionYears,
      BlobRetentionYears, BlobPath, InitialCutoffMethod, IsActive, SizeCategory) TO ret_config_editor;
GRANT SELECT, INSERT, UPDATE, DELETE ON ret.RetentionParentKey TO ret_config_editor;   -- protected by trigger after archiving starts
GRANT SELECT ON ret.RetentionTableStatus TO ret_config_editor;

CREATE ROLE ret_log_reader;                                     -- Operations team (SEC-04)
GRANT SELECT ON SCHEMA::ret TO ret_log_reader;

CREATE ROLE ret_operator_admin;                                 -- operator procedures (TBC who)
GRANT EXECUTE ON ret.usp_AdminCloseStaleRun     TO ret_operator_admin;
GRANT EXECUTE ON ret.usp_AdminClearTableFlag    TO ret_operator_admin;
GRANT EXECUTE ON ret.usp_ActivateDailyRoutine   TO ret_operator_admin;
GRANT EXECUTE ON ret.usp_ListCandidateTables    TO ret_operator_admin;
GRANT EXECUTE ON ret.usp_ProfileRetentionColumn TO ret_operator_admin;
*/

/* =====================================================================================
   14. OPTIONAL - change history of the configuration tables (SEC-08) (COMMENTED OUT)
       Period columns are in UTC (engine behaviour). Note: usp_TableRebuildPrepare rejects temporal
       tables only for DWH tables being rebuilt; ret tables are never rebuilt.
   =====================================================================================
ALTER TABLE ret.RetentionConfig ADD
    ValidFromUtc DATETIME2(3) GENERATED ALWAYS AS ROW START HIDDEN NOT NULL
        CONSTRAINT DF_RetentionConfig_ValidFrom DEFAULT (SYSUTCDATETIME()),
    ValidToUtc   DATETIME2(3) GENERATED ALWAYS AS ROW END   HIDDEN NOT NULL
        CONSTRAINT DF_RetentionConfig_ValidTo   DEFAULT (CONVERT(DATETIME2(3), '9999-12-31 23:59:59.999')),
    PERIOD FOR SYSTEM_TIME (ValidFromUtc, ValidToUtc);
GO
ALTER TABLE ret.RetentionConfig
    SET (SYSTEM_VERSIONING = ON (HISTORY_TABLE = ret.RetentionConfigHistory));
GO
*/
