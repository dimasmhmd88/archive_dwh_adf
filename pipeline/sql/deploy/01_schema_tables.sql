/* =====================================================================================
   DWH Data Retention and Archiving - schema ret - 01_schema_tables.sql
   Part of DWH_Retention_DB_Objects_v0.6.sql (DRAFT - not reviewed, not executed against any database).
   Schema, tables, indexes, migration from v0.2/v0.3/v0.5 (sections 0-1)
   Deploy order: see pipeline/sql/README.md. Run connected to the DWH database.
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
