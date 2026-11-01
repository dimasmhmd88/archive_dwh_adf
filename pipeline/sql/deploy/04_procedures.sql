/* =====================================================================================
   DWH Data Retention and Archiving - schema ret - 04_procedures.sql
   Part of DWH_Retention_DB_Objects_v0.5.sql, v0.5.1 collation fix (DRAFT - not reviewed, not executed against any database).
   Stored procedures: helpers, main, table rebuild, post-check/expiry/admin, analysis (sections 5-9)
   Deploy order: see pipeline/sql/README.md. Run connected to the DWH database.
   ===================================================================================== */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
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
       VALIDATION    : listed tables, any status (list required). */
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
            IF @ProcessType = 'VALIDATION'
            BEGIN
                ;THROW 50113, N'@TableConfigIdList is required for VALIDATION runs.', 1;
            END;

            /* ---- CR-01 automatic mode (INITIAL_CUTOFF): all active tables not yet COMPLETED ---- */
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
            @ResumeLogId BIGINT, @ResumeRunId BIGINT, @ResumeCount INT = 0, @Uniq TINYINT;

    SELECT @ProcessType = ProcessType, @RunDate = RunDate, @RunStatus = Status
    FROM ret.RetentionRunLog WHERE RunId = @RunId;

    IF @ProcessType IS NULL OR @RunStatus <> 'RUNNING'
    BEGIN
        ;THROW 50121, N'RunId not found or run is not in status RUNNING.', 1;
    END;

    SELECT @SchemaName = SchemaName, @TableName = TableName, @ParentId = ParentTableConfigId,
           @DwhYears = DwhRetentionYears, @BlobYears = BlobRetentionYears, @BlobPath = BlobPath
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
        IF NOT (@DwhYears >= 1 AND @BlobYears >= 1)
            SELECT @ErrCode = 'ERR-CFG-05', @CheckCode = 'V-05',
                   @ErrMsg = N'DWH retention and Blob retention must each be >= 1 year (DBR-01).';

        /* ---- V-06 blob path and archive container (MD-07) ---- */
        IF @ErrCode IS NULL
           AND (   NULLIF(@BlobPath, N'') IS NULL
                OR LEFT(@BlobPath, 1) = N'/' OR RIGHT(@BlobPath, 1) = N'/'
                OR CHARINDEX(N'//', @BlobPath) > 0 OR CHARINDEX(N'\', @BlobPath) > 0
                OR @BlobPath COLLATE Latin1_General_100_BIN2 <> LOWER(@BlobPath) COLLATE Latin1_General_100_BIN2
                OR EXISTS (SELECT 1 FROM ret.RetentionConfig WHERE BlobPath = @BlobPath AND TableConfigId <> @TableConfigId))
            SELECT @ErrCode = 'ERR-CFG-06', @CheckCode = 'V-06',
                   @ErrMsg = N'Blob path missing, not lower case, malformed or not unique (MD-07).';

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
                validation; the files of that run remain and are flagged as orphan files ---- */
        IF @ErrCode IS NULL
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
       NextAction: EXPORT, VALIDATE (IC: expired rows only, DBR-03) or NONE. */
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
            @DateCount INT = 0, @MinDate DATE, @MaxDate DATE, @NextAction VARCHAR(10), @Msg NVARCHAR(4000), @ErrNo INT;

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
       ret.fn_ArchiveFileName(@SchemaName, @TableName, d.BusinessDate, @RunId)
FROM (SELECT CAST(' + @DateExpr + N' AS DATE) AS BusinessDate, COUNT_BIG(*) AS RowCnt' + @FromSql + N'
      WHERE ' + @DateExpr + N' < @DwhCutoff'
            + CASE WHEN @ProcessType = 'INITIAL_CUTOFF' THEN N' AND ' + @DateExpr + N' >= @ArchiveCutoff' ELSE N'' END + N'
      GROUP BY CAST(' + @DateExpr + N' AS DATE)) AS d;';

        EXEC sp_executesql @sql,
             N'@TableLogId BIGINT, @RunId BIGINT, @TableConfigId INT, @BlobPath NVARCHAR(400), @SchemaName SYSNAME, @TableName SYSNAME, @DwhCutoff DATE, @ArchiveCutoff DATE',
             @TableLogId = @TableLogId, @RunId = @RunId, @TableConfigId = @TableConfigId, @BlobPath = @BlobPath,
             @SchemaName = @SchemaName, @TableName = @TableName, @DwhCutoff = @DwhCutoff, @ArchiveCutoff = @ArchiveCutoff;

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
                       FlagComment = CONCAT(N'Unfinished table rebuild of RunId ', @LogRunId, N': remove files *_', @LogRunId, N'.parquet of this table')
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

/* 8.2 ret.usp_GetExpiredArchiveFolders - DR-05 / BRQ-11 / BR-14, layout MD-07.
       Called per folder level with the ADF Get Metadata childItems of that folder:
         @Level = 'YEAR'  : folder <BlobPath>                     items year=YYYY
         @Level = 'MONTH' : folder <BlobPath>/year=@Year          items month=MM
         @Level = 'DAY'   : folder <BlobPath>/year=@Year/month=@Month  items day=DD
       Action DELETE  = whole folder older than the archive cut-off (recursive Delete activity);
       Action DESCEND = folder that contains the cut-off; list it and call again one level lower
                        with NextYear / NextMonth. Items not matching the pattern are never deleted
                        and are logged as a warning (DBR-12). */
CREATE OR ALTER PROCEDURE ret.usp_GetExpiredArchiveFolders
    @TableLogId     BIGINT,
    @ChildItemsJson NVARCHAR(MAX),
    @Level          VARCHAR(5)  = 'YEAR',
    @Year           SMALLINT    = NULL,
    @Month          TINYINT     = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Now DATETIME2(3) = ret.fn_NowUtc7();
    DECLARE @RunId BIGINT, @TableConfigId INT, @ProcessType VARCHAR(20), @ArchiveCutoff DATE, @BlobPath NVARCHAR(400),
            @ParentPath NVARCHAR(1024), @CutYear INT, @CutMonth INT, @Ignored NVARCHAR(MAX), @ToDelete INT, @ToDescend INT,
            @Msg NVARCHAR(4000), @StepStatus VARCHAR(10);

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
    IF @Level IS NULL OR @Level NOT IN ('YEAR', 'MONTH', 'DAY')
       OR (@Level IN ('MONTH', 'DAY') AND @Year IS NULL) OR (@Level = 'DAY' AND (@Month IS NULL OR @Month NOT BETWEEN 1 AND 12))
    BEGIN
        ;THROW 50233, N'Invalid @Level / @Year / @Month combination (YEAR; MONTH with @Year; DAY with @Year and @Month).', 1;
    END;

    SELECT @CutYear = YEAR(@ArchiveCutoff), @CutMonth = MONTH(@ArchiveCutoff);
    SET @ParentPath = @BlobPath
                    + CASE WHEN @Level IN ('MONTH', 'DAY') THEN CONCAT(N'/year=', RIGHT(CONCAT(N'000', @Year), 4)) ELSE N'' END
                    + CASE WHEN @Level = 'DAY' THEN CONCAT(N'/month=', RIGHT(CONCAT(N'0', @Month), 2)) ELSE N'' END;

    CREATE TABLE #Item (ItemName NVARCHAR(400) NULL, ItemType NVARCHAR(20) NULL, Val INT NULL, ItemDate DATE NULL, Action VARCHAR(10) NULL);

    IF NULLIF(LTRIM(RTRIM(@ChildItemsJson)), N'') IS NOT NULL
    BEGIN
        IF ISJSON(@ChildItemsJson) = 0
        BEGIN
            SET @Msg = N'Get Metadata output is not valid JSON; no folder deleted.';
            EXEC ret.usp_SetTableError @TableLogId = @TableLogId, @ErrorCode = 'ERR-ARC-01', @ErrorStep = 'EXPIRE', @ErrorMessage = @Msg;
            EXEC ret.usp_WriteStepLog @RunId = @RunId, @StepCode = 'EXPIRE', @Status = 'FAILED', @TableLogId = @TableLogId,
                 @TableConfigId = @TableConfigId, @StartTime = @Now, @ErrorCode = 'ERR-ARC-01', @ErrorMessage = @Msg;
            SELECT CAST(NULL AS NVARCHAR(400)) AS FolderName, CAST(NULL AS NVARCHAR(1024)) AS FolderPath, CAST(NULL AS VARCHAR(10)) AS Action,
                   CAST(NULL AS SMALLINT) AS NextYear, CAST(NULL AS TINYINT) AS NextMonth
            WHERE 1 = 0;
            RETURN;
        END;

        INSERT INTO #Item (ItemName, ItemType, Val)
        SELECT j.ItemName, j.ItemType,
               CASE WHEN j.ItemType <> N'Folder' THEN NULL
                    WHEN @Level = 'YEAR'  AND LEN(j.ItemName) = 9 AND j.ItemName LIKE N'year=[12][0-9][0-9][0-9]'
                        THEN TRY_CONVERT(INT, SUBSTRING(j.ItemName, 6, 4))
                    WHEN @Level = 'MONTH' AND LEN(j.ItemName) = 8 AND j.ItemName LIKE N'month=[01][0-9]'
                         AND TRY_CONVERT(INT, SUBSTRING(j.ItemName, 7, 2)) BETWEEN 1 AND 12
                        THEN TRY_CONVERT(INT, SUBSTRING(j.ItemName, 7, 2))
                    WHEN @Level = 'DAY'   AND LEN(j.ItemName) = 6 AND j.ItemName LIKE N'day=[0-3][0-9]'
                         AND TRY_CONVERT(DATE, CONCAT(RIGHT(CONCAT(N'000', @Year), 4), N'-', RIGHT(CONCAT(N'0', @Month), 2), N'-',
                                                      SUBSTRING(j.ItemName, 5, 2)), 23) IS NOT NULL
                        THEN TRY_CONVERT(INT, SUBSTRING(j.ItemName, 5, 2))
               END
        FROM OPENJSON(@ChildItemsJson) WITH (ItemName NVARCHAR(400) '$.name', ItemType NVARCHAR(20) '$.type') AS j;

        UPDATE #Item
           SET Action = CASE
                   WHEN Val IS NULL THEN NULL
                   WHEN @Level = 'YEAR'  AND Val <  @CutYear THEN 'DELETE'
                   WHEN @Level = 'YEAR'  AND Val =  @CutYear THEN 'DESCEND'
                   WHEN @Level = 'MONTH' AND @Year < @CutYear THEN 'DELETE'
                   WHEN @Level = 'MONTH' AND @Year = @CutYear AND Val <  @CutMonth THEN 'DELETE'
                   WHEN @Level = 'MONTH' AND @Year = @CutYear AND Val =  @CutMonth THEN 'DESCEND'
                   WHEN @Level = 'DAY'   AND DATEFROMPARTS(@Year, @Month, Val) < @ArchiveCutoff THEN 'DELETE'
               END;
    END;

    SELECT @Ignored   = STRING_AGG(CONVERT(NVARCHAR(MAX), ItemName) COLLATE DATABASE_DEFAULT, N', ') FROM #Item WHERE Val IS NULL;
    SELECT @ToDelete  = COUNT(*) FROM #Item WHERE Action = 'DELETE';
    SELECT @ToDescend = COUNT(*) FROM #Item WHERE Action = 'DESCEND';

    SET @Msg = LEFT(CONCAT(N'Level ', @Level, N' of ', @ParentPath, N' (archive cut-off ', CONVERT(CHAR(10), @ArchiveCutoff, 23), N'): ',
                           @ToDelete, N' folders to delete, ', @ToDescend, N' to descend',
                           CASE WHEN @Ignored IS NOT NULL THEN CONCAT(N'. Items not matching the folder pattern, not deleted: ', @Ignored) ELSE N'' END,
                           N'.'), 4000);
    SET @StepStatus = CASE WHEN @Ignored IS NULL THEN 'SUCCEEDED' ELSE 'WARNING' END;
    EXEC ret.usp_WriteStepLog @RunId = @RunId, @StepCode = 'EXPIRE', @Status = @StepStatus,
         @TableLogId = @TableLogId, @TableConfigId = @TableConfigId, @StartTime = @Now, @Message = @Msg;

    SELECT i.ItemName AS FolderName,
           @ParentPath + N'/' + i.ItemName AS FolderPath,
           i.Action,
           CAST(CASE WHEN @Level = 'YEAR' THEN i.Val ELSE @Year END AS SMALLINT) AS NextYear,
           CAST(CASE WHEN @Level = 'MONTH' THEN i.Val END AS TINYINT) AS NextMonth
    FROM #Item AS i
    WHERE i.Action IN ('DELETE', 'DESCEND')
    ORDER BY i.Action DESC, i.Val;
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

/* 8.6 ret.usp_EndTable - close the table log, final status, Initial Cut-off status on failure/stop,
       release the lock. Always called, also from ADF failure paths. Idempotent. An unfinished rebuild
       still open here is undone and its files are flagged as orphan files. */
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
            @StepStatus VARCHAR(10);

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

        SELECT @StepStatus = CASE WHEN @Final IN ('SUCCEEDED', 'NODATA') THEN 'SUCCEEDED' WHEN @Final = 'STOPPED' THEN 'STOPPED'
                                  WHEN @Final = 'SKIPPED' THEN 'SKIPPED' ELSE 'FAILED' END,
               @Msg = CONCAT(N'Final status: ', @Final, N'.');
        EXEC ret.usp_WriteStepLog @RunId = @RunId, @StepCode = 'END_TABLE', @Status = @StepStatus,
             @TableLogId = @TableLogId, @TableConfigId = @TableConfigId, @StartTime = @Now, @Message = @Msg;
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
            @StepStatus VARCHAR(10), @StepMsg NVARCHAR(4000);

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
