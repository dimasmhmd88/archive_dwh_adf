/* =====================================================================================
   DWH Data Retention and Archiving - default values of all configuration tables
   -------------------------------------------------------------------------------------
   Script        : config/00_insert_default_config.sql
   Version       : 0.1 (DRAFT - not reviewed, not executed against any database)
   Date          : 13 November 2026
   Requires      : DWH_Retention_DB_Objects_v0.6.sql (deploy/01..05) in the DWH database.
   Run order     : 00_insert_default_config.sql  ->  10_insert_retention_config.sql (31 phase-1 tables)
   Note          : deploy/02_triggers_seed.sql already inserts the parameter row and the error codes; this
                   script makes the defaults explicit, sets the archive container and can reset the parameters.

   WHAT THIS SCRIPT FILLS
     ret.RetentionParameter    single row (ParameterSetId = 1) with the explicit default values below
     ret.RetentionErrorCode    all 30 error / warning codes of FSD 13.1 (same list as deploy/02)
     ret.RetentionTableStatus  missing status rows (PENDING) for rows of ret.RetentionConfig
   NOT FILLED HERE
     ret.RetentionConfig       table list -> config/10_insert_retention_config.sql
                               (column defaults: DwhRetentionYears 3, BlobRetentionYears 5, LogRetentionYears 3,
                               IsActive 1)
     ret.RetentionParentKey    join keys of child tables: table-specific, no default (child tables are
                               out of go-live phase 1, MD-05)
     Log / lock / run tables   written by the procedures only

   DEFAULT VALUES (schema defaults of v0.6; values not decided in FSD v1.1 are marked "confirm")
     BatchSize               10000        BRQ-08                         confirm with DBA
     BatchPauseSeconds       3            BRQ-08                         confirm with DBA
     IcWindowStart / End     21:00 / 05:00 UTC+7 (BR-17, FR-019)
     DailyRoutineStartDate   NULL         set by ret.usp_ActivateDailyRoutine after the Initial Cut-off (AC-15);
                                          never changed by this script
     DeleteRetryCount        NULL         NULL = no retry of a failed delete batch (deadlock, lock timeout)  confirm
     DeleteLockTimeoutMs     NULL         NULL = wait without timeout                                       confirm
     DailyNullCheckMode      FULL         OQ-14 (FULL = scan the date column every day; METADATA = cheaper)
     ArchiveContainer        dwh-archive  MD-07 / D-02, storage account stormsfsax01loc10dev

   BEHAVIOUR (re-runnable, one transaction)
     @ResetToDefault = 0 (default): only missing rows and NULL ArchiveContainer are filled; values already
                                    tuned by the DBA stay unchanged.
     @ResetToDefault = 1          : the tunable parameters above are set back to the defaults, except
                                    DailyRoutineStartDate. Refused while a run is RUNNING.
   ===================================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID(N'ret.RetentionParameter', N'U') IS NULL OR OBJECT_ID(N'ret.RetentionErrorCode', N'U') IS NULL
   OR OBJECT_ID(N'ret.RetentionTableStatus', N'U') IS NULL OR COL_LENGTH(N'ret.RetentionConfig', N'LogRetentionYears') IS NULL
BEGIN
    ;THROW 50901, N'Schema ret v0.6 not found. Deploy DWH_Retention_DB_Objects_v0.6.sql (deploy/01..05) first.', 1;
END;

/* -------------------------------------------------------------------------------------
   Settings - change here only
   ------------------------------------------------------------------------------------- */
DECLARE @ResetToDefault         BIT             = 0;
DECLARE @BatchSize              INT             = 10000;
DECLARE @BatchPauseSeconds      INT             = 3;
DECLARE @IcWindowStart          TIME(0)         = '21:00';
DECLARE @IcWindowEnd            TIME(0)         = '05:00';
DECLARE @DeleteRetryCount       TINYINT         = NULL;
DECLARE @DeleteLockTimeoutMs    INT             = NULL;
DECLARE @DailyNullCheckMode     VARCHAR(10)     = 'FULL';
DECLARE @ArchiveContainer       NVARCHAR(63)    = N'dwh-archive';

DECLARE @Now DATETIME2(3) = DATEADD(HOUR, 7, SYSUTCDATETIME());

IF @ResetToDefault = 1 AND EXISTS (SELECT 1 FROM ret.RetentionRunLog WHERE Status = 'RUNNING')
BEGIN
    ;THROW 50902, N'A retention run is RUNNING. Parameters cannot be reset now.', 1;
END;

BEGIN TRANSACTION;

-- 1. ret.RetentionParameter (single row)
IF NOT EXISTS (SELECT 1 FROM ret.RetentionParameter WHERE ParameterSetId = 1)
BEGIN
    INSERT INTO ret.RetentionParameter
        (ParameterSetId, BatchSize, BatchPauseSeconds, IcWindowStart, IcWindowEnd, DailyRoutineStartDate,
         DeleteRetryCount, DeleteLockTimeoutMs, DailyNullCheckMode, ArchiveContainer, ModifiedBy, ModifiedAt)
    VALUES
        (1, @BatchSize, @BatchPauseSeconds, @IcWindowStart, @IcWindowEnd, NULL,
         @DeleteRetryCount, @DeleteLockTimeoutMs, @DailyNullCheckMode, @ArchiveContainer, ORIGINAL_LOGIN(), @Now);
END
ELSE IF @ResetToDefault = 1
BEGIN
    UPDATE ret.RetentionParameter
       SET BatchSize           = @BatchSize,
           BatchPauseSeconds   = @BatchPauseSeconds,
           IcWindowStart       = @IcWindowStart,
           IcWindowEnd         = @IcWindowEnd,
           DeleteRetryCount    = @DeleteRetryCount,
           DeleteLockTimeoutMs = @DeleteLockTimeoutMs,
           DailyNullCheckMode  = @DailyNullCheckMode,
           ArchiveContainer    = @ArchiveContainer,
           ModifiedBy          = ORIGINAL_LOGIN(),
           ModifiedAt          = @Now
     WHERE ParameterSetId = 1;
END
ELSE
BEGIN
    UPDATE ret.RetentionParameter
       SET ArchiveContainer = @ArchiveContainer, ModifiedBy = ORIGINAL_LOGIN(), ModifiedAt = @Now
     WHERE ParameterSetId = 1 AND ArchiveContainer IS NULL;
END;

-- 2. ret.RetentionErrorCode (insert missing codes, align changed texts)
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

-- 3. ret.RetentionTableStatus (rows normally created by trg_RetentionConfig_AfterInsert)
INSERT INTO ret.RetentionTableStatus (TableConfigId)
SELECT c.TableConfigId
FROM ret.RetentionConfig AS c
WHERE NOT EXISTS (SELECT 1 FROM ret.RetentionTableStatus AS s WHERE s.TableConfigId = c.TableConfigId);

COMMIT TRANSACTION;
GO

-- 4. Result
SELECT ParameterSetId, BatchSize, BatchPauseSeconds,
       CONVERT(CHAR(5), IcWindowStart, 108) AS IcWindowStart, CONVERT(CHAR(5), IcWindowEnd, 108) AS IcWindowEnd,
       DailyRoutineStartDate, DeleteRetryCount, DeleteLockTimeoutMs, DailyNullCheckMode, ArchiveContainer, ModifiedBy, ModifiedAt
FROM ret.RetentionParameter;

SELECT COUNT(*) AS ErrorCodes, SUM(CAST(IsWarning AS INT)) AS Warnings FROM ret.RetentionErrorCode;   -- expected 30 / 2

SELECT (SELECT COUNT(*) FROM ret.RetentionConfig) AS ConfigRows,
       (SELECT COUNT(*) FROM ret.RetentionTableStatus) AS StatusRows;                                -- expected equal
GO
