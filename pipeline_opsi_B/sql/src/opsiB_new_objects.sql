/* =====================================================================================
   A. COLUMNS - export parallelism (option B: N business dates exported in parallel per chunk)
      Effective N = ISNULL(RetentionConfig.ExportParallelism, RetentionParameter.ExportParallelism), 1..16.
      16 = ForEach batchCount of PL_RET_03G_Export_Chunk (upper bound; change both together).
   ===================================================================================== */
IF COL_LENGTH(N'ret.RetentionParameter', N'ExportParallelism') IS NULL
BEGIN
    ALTER TABLE ret.RetentionParameter
        ADD ExportParallelism TINYINT NOT NULL
            CONSTRAINT DF_RetentionParameter_ExportParallelism DEFAULT (4) WITH VALUES;
END;
GO
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_RetentionParameter_ExportParallelism')
    ALTER TABLE ret.RetentionParameter
        ADD CONSTRAINT CK_RetentionParameter_ExportParallelism CHECK (ExportParallelism BETWEEN 1 AND 16);
GO
IF COL_LENGTH(N'ret.RetentionConfig', N'ExportParallelism') IS NULL
BEGIN
    ALTER TABLE ret.RetentionConfig ADD ExportParallelism TINYINT NULL;    -- NULL = global value
END;
GO
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_RetentionConfig_ExportParallelism')
    ALTER TABLE ret.RetentionConfig
        ADD CONSTRAINT CK_RetentionConfig_ExportParallelism CHECK (ExportParallelism IS NULL OR ExportParallelism BETWEEN 1 AND 16);
GO

-- @@PROCEDURES@@
/* =====================================================================================
   C. NEW PROCEDURES (option B)
   Each wrapper calls the v0.6 procedures unchanged and in the v0.6 order; it only removes ADF round trips.
   The called procedures write their result into #RetOut_<procedure> (section B), never INSERT ... EXEC.
   ===================================================================================== */

/* C.1 ret.usp_StartRunAndGetTables - usp_StartRun + usp_GetTablesToProcess in one Lookup (masters PL_RET_01 / 02).
       Result: one row per selected table (run columns repeated); one row with TableConfigId NULL when no table
       is selected. A selection error closes the run with usp_EndRun (FAILED) and is raised again. */
CREATE OR ALTER PROCEDURE ret.usp_StartRunAndGetTables
    @ProcessType        VARCHAR(20),
    @TriggerType        VARCHAR(10)         = 'SCHEDULE',
    @AdfPipelineRunId   UNIQUEIDENTIFIER    = NULL,
    @RunDate            DATE                = NULL,
    @TriggeredBy        NVARCHAR(256)       = NULL,
    @DowntimeReference  NVARCHAR(100)       = NULL,
    @TableConfigIdList  NVARCHAR(MAX)       = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @RunId BIGINT, @Err NVARCHAR(4000);

    CREATE TABLE #RetOut_usp_StartRun
    (RunId BIGINT, ProcessType VARCHAR(20), RunDate CHAR(10), Status VARCHAR(25), IsExistingRun BIT);

    -- usp_StartRun raises ERR-SYS-02 itself (run logged FAILED) when the run date is in the future
    EXEC ret.usp_StartRun @ProcessType = @ProcessType, @TriggerType = @TriggerType, @AdfPipelineRunId = @AdfPipelineRunId,
         @RunDate = @RunDate, @TriggeredBy = @TriggeredBy, @DowntimeReference = @DowntimeReference;

    SELECT TOP (1) @RunId = RunId FROM #RetOut_usp_StartRun;
    IF @RunId IS NULL
    BEGIN
        ;THROW 50801, N'usp_StartRun returned no run.', 1;
    END;

    CREATE TABLE #RetOut_usp_GetTablesToProcess
    (TableConfigId INT, SchemaName SYSNAME, TableName SYSNAME, RetentionColumn SYSNAME NULL, ParentTableConfigId INT NULL,
     IsChild BIT, DwhRetentionYears SMALLINT, BlobRetentionYears SMALLINT, TotalRetentionYears SMALLINT,
     DwhCutoffDate CHAR(10), ArchiveCutoffDate CHAR(10), BlobPath NVARCHAR(400), ArchiveContainer NVARCHAR(63),
     InitialCutoffMethod VARCHAR(20), SizeCategory VARCHAR(10), ProcessingOrder BIGINT);

    BEGIN TRY
        EXEC ret.usp_GetTablesToProcess @RunId = @RunId, @TableConfigIdList = @TableConfigIdList;
    END TRY
    BEGIN CATCH
        SET @Err = LEFT(CONCAT(N'Table selection failed: ', ERROR_MESSAGE()), 4000);
        CREATE TABLE #RetOut_usp_EndRun
        (RunId BIGINT, ProcessType VARCHAR(20), RunDate CHAR(10), Status VARCHAR(25), TablesSelected INT, TablesSucceeded INT,
         TablesFailed INT, TablesSkipped INT, StartTime DATETIME2(3), EndTime DATETIME2(3));
        EXEC ret.usp_EndRun @RunId = @RunId, @ErrorMessage = @Err, @FailPipelineOnError = 0;
        THROW;
    END CATCH;

    SELECT r.RunId, r.ProcessType, r.RunDate, r.Status AS RunStatus, r.IsExistingRun,
           t.TableConfigId, t.SchemaName, t.TableName, t.RetentionColumn, t.ParentTableConfigId, t.IsChild,
           t.DwhRetentionYears, t.BlobRetentionYears, t.TotalRetentionYears, t.DwhCutoffDate, t.ArchiveCutoffDate,
           t.BlobPath, t.ArchiveContainer, t.InitialCutoffMethod, t.SizeCategory, t.ProcessingOrder
    FROM #RetOut_usp_StartRun AS r
    LEFT JOIN #RetOut_usp_GetTablesToProcess AS t ON 1 = 1
    ORDER BY t.ProcessingOrder;
END;
GO

/* C.2 ret.usp_BeginTableAndIdentify - usp_BeginTable + usp_IdentifyEligibleData in one Lookup (PL_RET_03).
       Identify runs only when BeginResult = PROCEED, the run is not VALIDATION and no validated range of an
       earlier run is pending (FSD 4.17: the resume comes first; PL_RET_03A then calls usp_IdentifyEligibleData
       itself after PL_RET_03B). An unexpected identify error is recorded (ERR-SYS-01) and returned as
       IdentifyResult FAILED, so PL_RET_03 still closes the table with usp_EndTable. */
CREATE OR ALTER PROCEDURE ret.usp_BeginTableAndIdentify
    @RunId          BIGINT,
    @TableConfigId  INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @TableLogId BIGINT, @BeginResult VARCHAR(10), @Pending BIGINT, @ProcessType VARCHAR(20),
            @IdentifyExecuted BIT = 0, @Msg NVARCHAR(4000);

    CREATE TABLE #RetOut_usp_BeginTable
    (TableLogId BIGINT, BeginResult VARCHAR(10), CanRunArchiveExpiry BIT, PendingResumeTableLogId BIGINT NULL,
     PendingResumeRunId BIGINT NULL, PendingResumeMethod VARCHAR(20) NULL, IsChild BIT, DwhCutoffDate CHAR(10) NULL,
     ArchiveCutoffDate CHAR(10) NULL, ErrorCode VARCHAR(12) NULL, Message NVARCHAR(MAX) NULL);

    CREATE TABLE #RetOut_usp_IdentifyEligibleData
    (TableLogId BIGINT, Result VARCHAR(10), NextAction VARCHAR(10), EligibleRows BIGINT NULL, RowsToExport BIGINT NULL,
     ExpiredRows BIGINT NULL, RetainedRows BIGINT NULL, OrphanRows BIGINT NULL, ExportDateCount INT NULL,
     MinBusinessDate CHAR(10) NULL, MaxBusinessDate CHAR(10) NULL, Message NVARCHAR(MAX) NULL);

    EXEC ret.usp_BeginTable @RunId = @RunId, @TableConfigId = @TableConfigId;

    SELECT TOP (1) @TableLogId = TableLogId, @BeginResult = BeginResult, @Pending = PendingResumeTableLogId
    FROM #RetOut_usp_BeginTable;
    SELECT @ProcessType = ProcessType FROM ret.RetentionRunLog WHERE RunId = @RunId;

    IF @BeginResult = 'PROCEED' AND @ProcessType <> 'VALIDATION' AND @Pending IS NULL
    BEGIN
        SET @IdentifyExecuted = 1;
        BEGIN TRY
            EXEC ret.usp_IdentifyEligibleData @TableLogId = @TableLogId;
        END TRY
        BEGIN CATCH
            SET @Msg = LEFT(CONCAT(N'usp_IdentifyEligibleData failed: ', ERROR_MESSAGE()), 4000);
            EXEC ret.usp_SetTableError @TableLogId = @TableLogId, @ErrorCode = 'ERR-SYS-01', @ErrorStep = 'COUNT',
                 @ErrorMessage = @Msg, @ErrorNumber = NULL;
            DELETE FROM #RetOut_usp_IdentifyEligibleData;
            INSERT INTO #RetOut_usp_IdentifyEligibleData (TableLogId, Result, NextAction, Message)
            VALUES (@TableLogId, 'FAILED', 'NONE', @Msg);
        END CATCH;
    END;

    SELECT b.TableLogId, b.BeginResult, b.CanRunArchiveExpiry, b.PendingResumeTableLogId, b.PendingResumeRunId,
           b.PendingResumeMethod, b.IsChild, b.DwhCutoffDate, b.ArchiveCutoffDate, b.ErrorCode, b.Message,
           @IdentifyExecuted AS IdentifyExecuted,
           i.Result AS IdentifyResult, i.NextAction, i.EligibleRows, i.RowsToExport, i.ExpiredRows, i.RetainedRows,
           i.OrphanRows, i.ExportDateCount, i.MinBusinessDate, i.MaxBusinessDate, i.Message AS IdentifyMessage
    FROM #RetOut_usp_BeginTable AS b
    LEFT JOIN #RetOut_usp_IdentifyEligibleData AS i ON i.TableLogId = b.TableLogId;
END;
GO

/* C.3 ret.usp_GetExportChunk - next chunk of business dates to export (PL_RET_03E, option B).
       Called once per chunk, sequentially; replaces usp_CheckExecutionWindow + usp_GetExportPlan.
       ContinueExport = 1: up to N PENDING dates are returned (one row each), exported in parallel by
       PL_RET_03G; RemainingAfterChunk = 0 ends the loop after this chunk.
       ContinueExport = 0: one row with BusinessDate NULL; CleanupRequired = 1 when the export failed or
       stopped (this run's files are removed by PL_RET_03F; ValidateArchive would fail anyway). */
CREATE OR ALTER PROCEDURE ret.usp_GetExportChunk
    @TableLogId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Now DATETIME2(3) = ret.fn_NowUtc7();
    DECLARE @RunId BIGINT, @TableConfigId INT, @ProcessType VARCHAR(20), @Status VARCHAR(10), @N INT,
            @Pending INT, @Bad INT, @WinStart TIME(0), @WinEnd TIME(0), @Continue BIT = 1, @Cleanup BIT = 0,
            @Msg NVARCHAR(4000);

    SELECT @RunId = l.RunId, @TableConfigId = l.TableConfigId, @ProcessType = l.ProcessType, @Status = l.Status,
           @N = ISNULL(c.ExportParallelism, p.ExportParallelism),
           @WinStart = p.IcWindowStart, @WinEnd = p.IcWindowEnd
    FROM ret.RetentionTableLog AS l
    JOIN ret.RetentionConfig AS c ON c.TableConfigId = l.TableConfigId
    CROSS JOIN ret.RetentionParameter AS p
    WHERE l.TableLogId = @TableLogId AND p.ParameterSetId = 1;

    IF @RunId IS NULL
    BEGIN
        ;THROW 50811, N'TableLogId not found.', 1;
    END;
    SET @N = CASE WHEN @N IS NULL OR @N < 1 THEN 1 WHEN @N > 16 THEN 16 ELSE @N END;

    SELECT @Pending = ISNULL(SUM(CASE WHEN ExportStatus = 'PENDING' THEN 1 ELSE 0 END), 0),
           @Bad     = ISNULL(SUM(CASE WHEN ExportStatus IN ('FAILED', 'STOPPED') THEN 1 ELSE 0 END), 0)
    FROM ret.RetentionArchiveDate
    WHERE TableLogId = @TableLogId;

    IF @Status IN ('FAILED', 'STOPPED') OR @Bad > 0
        SELECT @Continue = 0, @Cleanup = 1,
               @Msg = CONCAT(N'Export ended: table log status ', @Status, N', ', @Bad, N' date(s) FAILED or STOPPED.');
    ELSE IF @Pending = 0
        SELECT @Continue = 0, @Cleanup = 0, @Msg = N'All business dates exported.';
    ELSE IF @ProcessType = 'INITIAL_CUTOFF' AND ret.fn_IsWithinWindow(CAST(@Now AS TIME(0)), @WinStart, @WinEnd) = 0
    BEGIN
        SELECT @Continue = 0, @Cleanup = 1,
               @Msg = CONCAT(N'Initial Cut-off window end reached before the export of ', @Pending, N' remaining date(s) (FR-019).');
        EXEC ret.usp_SetTableError @TableLogId = @TableLogId, @ErrorCode = 'ERR-WIN-01', @ErrorStep = 'EXPORT',
             @ErrorMessage = @Msg, @NewStatus = 'STOPPED';
        EXEC ret.usp_WriteStepLog @RunId = @RunId, @StepCode = 'EXPORT', @Status = 'STOPPED', @TableLogId = @TableLogId,
             @TableConfigId = @TableConfigId, @StartTime = @Now, @Message = @Msg, @ErrorCode = 'ERR-WIN-01';
    END;

    IF @Continue = 1
        SELECT TOP (@N)
               CONVERT(CHAR(10), a.BusinessDate, 23) AS BusinessDate, a.FolderPath, a.FileName, a.ExpectedRows,
               CAST(1 AS BIT) AS ContinueExport, CAST(0 AS BIT) AS CleanupRequired,
               @Pending AS RemainingDates, @N AS ChunkSize,
               CASE WHEN @Pending > @N THEN @Pending - @N ELSE 0 END AS RemainingAfterChunk,
               CAST(NULL AS NVARCHAR(4000)) AS Message
        FROM ret.RetentionArchiveDate AS a
        WHERE a.TableLogId = @TableLogId AND a.ExportStatus = 'PENDING'
        ORDER BY a.BusinessDate;
    ELSE
        SELECT CAST(NULL AS CHAR(10)) AS BusinessDate, CAST(NULL AS NVARCHAR(1024)) AS FolderPath,
               CAST(NULL AS NVARCHAR(400)) AS FileName, CAST(NULL AS BIGINT) AS ExpectedRows,
               @Continue AS ContinueExport, @Cleanup AS CleanupRequired,
               @Pending AS RemainingDates, @N AS ChunkSize, 0 AS RemainingAfterChunk, @Msg AS Message;
END;
GO

/* C.4 ret.usp_ValidateDeleteAndCheck - usp_ValidateArchive -> usp_BatchDelete -> usp_PostCheck in one Lookup
       (PL_RET_03C). The BR-08 gate is unchanged: usp_BatchDelete runs only when the validation PASSED, the
       post-check only when the deletion COMPLETED. usp_BatchDelete keeps its own short transactions per batch
       (no outer transaction here). RowsExported is recounted first (parallel usp_LogExportResult calls).
       ADF retry must be 0 (the deletion is never repeated automatically). */
CREATE OR ALTER PROCEDURE ret.usp_ValidateDeleteAndCheck
    @RunId      BIGINT,
    @TableLogId BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Val VARCHAR(12) = 'NOT_RUN', @Del VARCHAR(10) = 'NOT_RUN', @Post VARCHAR(10) = 'NOT_RUN',
            @ValCleanup BIT = 0, @DelCleanup BIT = 0;

    UPDATE ret.RetentionTableLog
       SET RowsExported = (SELECT ISNULL(SUM(a.RowsWritten), 0) FROM ret.RetentionArchiveDate AS a
                           WHERE a.TableLogId = @TableLogId AND a.ExportStatus = 'SUCCEEDED')
     WHERE TableLogId = @TableLogId;

    CREATE TABLE #RetOut_usp_ValidateArchive
    (ValidationResult VARCHAR(12), ValidatedRowCount BIGINT NULL, DeleteMethod VARCHAR(20) NULL, CleanupRequired BIT,
     Message NVARCHAR(MAX) NULL);
    CREATE TABLE #RetOut_usp_BatchDelete
    (DeleteResult VARCHAR(10), RowsDeleted BIGINT NULL, BatchCount INT NULL, IsResume BIT NULL, CleanupRequired BIT NULL,
     ErrorCode VARCHAR(12) NULL, Message NVARCHAR(MAX) NULL);
    CREATE TABLE #RetOut_usp_PostCheck
    (PostCheckResult VARCHAR(10), RowsBelowCutoff BIGINT NULL, RetainedRowsBefore BIGINT NULL, RetainedRowsAfter BIGINT NULL,
     Message NVARCHAR(MAX) NULL);

    EXEC ret.usp_ValidateArchive @TableLogId = @TableLogId;
    SELECT TOP (1) @Val = ValidationResult, @ValCleanup = ISNULL(CleanupRequired, 0) FROM #RetOut_usp_ValidateArchive;

    IF @Val = 'PASSED'
    BEGIN
        EXEC ret.usp_BatchDelete @RunId = @RunId, @TableLogId = @TableLogId;
        SELECT TOP (1) @Del = DeleteResult, @DelCleanup = ISNULL(CleanupRequired, 0) FROM #RetOut_usp_BatchDelete;
    END;

    IF @Del = 'COMPLETED'
    BEGIN
        EXEC ret.usp_PostCheck @TableLogId = @TableLogId;
        SELECT TOP (1) @Post = PostCheckResult FROM #RetOut_usp_PostCheck;
    END;

    SELECT @Val AS ValidationResult, v.ValidatedRowCount, @Del AS DeleteResult, d.RowsDeleted, d.BatchCount,
           @Post AS PostCheckResult, p.RowsBelowCutoff, p.RetainedRowsAfter,
           CAST(CASE WHEN @ValCleanup = 1 OR @DelCleanup = 1 THEN 1 ELSE 0 END AS BIT) AS CleanupRequired,
           d.ErrorCode AS DeleteErrorCode,
           CONCAT_WS(N' | ', v.Message, d.Message, p.Message) AS Message
    FROM (SELECT 1 AS k) AS one
    LEFT JOIN #RetOut_usp_ValidateArchive AS v ON 1 = 1
    LEFT JOIN #RetOut_usp_BatchDelete     AS d ON 1 = 1
    LEFT JOIN #RetOut_usp_PostCheck       AS p ON 1 = 1;
END;
GO

/* C.5 ret.usp_GetCleanupDecision - after an unexpected error of usp_ValidateDeleteAndCheck (PL_RET_03C):
       the files of this run may be removed only while no row was deleted (DeleteStatus NOT_STARTED,
       RowsDeleted 0). Otherwise the files are the only copy of deleted rows and must stay; the resume of the
       next run continues the deletion (FSD 4.17). usp_LogCleanupResult revokes the validation. */
CREATE OR ALTER PROCEDURE ret.usp_GetCleanupDecision
    @TableLogId BIGINT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT CAST(CASE WHEN l.DeleteStatus = 'NOT_STARTED' AND ISNULL(l.RowsDeleted, 0) = 0
                          AND EXISTS (SELECT 1 FROM ret.RetentionArchiveDate AS a
                                      WHERE a.TableLogId = l.TableLogId AND a.ExportStatus IN ('SUCCEEDED', 'FAILED', 'STOPPED'))
                     THEN 1 ELSE 0 END AS BIT) AS CleanupRequired,
           l.DeleteStatus, ISNULL(l.RowsDeleted, 0) AS RowsDeleted, l.IsValidated
    FROM ret.RetentionTableLog AS l
    WHERE l.TableLogId = @TableLogId;
END;
GO

/* C.6 ret.usp_GetExpiredArchiveItems - both levels of the expired archive deletion in one Lookup (PL_RET_04,
       replaces the two calls of usp_GetExpiredArchiveFolders in PL_RET_04A). Decision logic unchanged:
       YEAR on the container root, FILE in <archive cut-off year>/<BlobPath>. Returns DELETE rows only. */
CREATE OR ALTER PROCEDURE ret.usp_GetExpiredArchiveItems
    @TableLogId     BIGINT,
    @RootItemsJson  NVARCHAR(MAX),
    @FileItemsJson  NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Year SMALLINT;
    SELECT @Year = YEAR(ArchiveCutoffDate) FROM ret.RetentionTableLog WHERE TableLogId = @TableLogId;
    IF @Year IS NULL
    BEGIN
        ;THROW 50821, N'TableLogId not found or archive cut-off missing.', 1;
    END;

    CREATE TABLE #RetOut_usp_GetExpiredArchiveFolders
    (ItemName NVARCHAR(400) NULL, FolderPath NVARCHAR(1024) NULL, FileName NVARCHAR(400) NULL, Action VARCHAR(10) NULL);
    CREATE TABLE #ob_Items
    (Level VARCHAR(5), ItemName NVARCHAR(400) NULL, FolderPath NVARCHAR(1024) NULL, FileName NVARCHAR(400) NULL, Action VARCHAR(10) NULL);

    EXEC ret.usp_GetExpiredArchiveFolders @TableLogId = @TableLogId, @ChildItemsJson = @RootItemsJson, @Level = 'YEAR', @Year = @Year;
    INSERT INTO #ob_Items (Level, ItemName, FolderPath, FileName, Action)
    SELECT 'YEAR', ItemName, FolderPath, FileName, Action FROM #RetOut_usp_GetExpiredArchiveFolders;
    DELETE FROM #RetOut_usp_GetExpiredArchiveFolders;

    EXEC ret.usp_GetExpiredArchiveFolders @TableLogId = @TableLogId, @ChildItemsJson = @FileItemsJson, @Level = 'FILE', @Year = @Year;
    INSERT INTO #ob_Items (Level, ItemName, FolderPath, FileName, Action)
    SELECT 'FILE', ItemName, FolderPath, FileName, Action FROM #RetOut_usp_GetExpiredArchiveFolders;

    SELECT Level, ItemName, FolderPath, ISNULL(FileName, N'') AS FileName, Action
    FROM #ob_Items
    WHERE Action = 'DELETE'
    ORDER BY CASE Level WHEN 'YEAR' THEN 0 ELSE 1 END, ItemName;
END;
GO
