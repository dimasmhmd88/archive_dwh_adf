/* opsi B source of ret.usp_BatchDelete (used by tools/make_sql_opsiB.py instead of pipeline/sql/deploy/04_procedures.sql).
   Do not deploy this file on its own: deploy pipeline_opsi_B/sql/20_OpsiB_DB_Objects.sql. */
/* 6.11 ret.usp_BatchDelete - batch delete of a validated range (BRQ-08, BR-08, FR-017).
        @TableLogId = log owning the validated range (current run, or an earlier run for a resume).
        Each batch: at most BatchSize rows plus the progress update in one short transaction, then
        a pause of BatchPauseSeconds. IC: stops at the window end and is resumed by the next run.
        Child table: rows are selected through the header date (FR-023); orphan rows never match.
        OPSI B v0.7.1 (D-8, 27 Nov 2026) - RetentionParameter.ChildDeleteMode, child tables only:
          JOIN      (default) every batch joins the header table and filters on the header date (as v0.6).
          KEY_TABLE the join keys of the header rows in the validated range are read once into the temp table
                    #RetBdParentKey (KeySeq + key columns k1..kn, types and collations of the header columns);
                    the pre-delete recount and every batch join the child table to that temp table only.
                    Batches stay BatchSize CHILD rows; keys are processed in windows of BatchSize keys
                    (KeySeq BETWEEN @SeqFrom AND @SeqTo); a batch below BatchSize moves to the next window.
                    The final recount still uses the header join (independent check, ERR-DEL-02).
          Missing column (opsi B rolled back) or a key column type that cannot be copied -> JOIN.
        Source of this procedure for opsi B: pipeline_opsi_B/sql/src/usp_BatchDelete_opsiB.sql
        (pipeline/sql/deploy/04_procedures.sql keeps the v0.6 text for the old packages). */
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
    -- opsi B v0.7.1: child delete through a key table (D-8)
    DECLARE @IsChild BIT, @FullName NVARCHAR(300), @DateTableFullName NVARCHAR(300), @ChildMode VARCHAR(10) = 'JOIN',
            @UseKeyTable BIT = 0, @KeyDefs NVARCHAR(MAX), @KeyCols NVARCHAR(MAX), @KeySel NVARCHAR(MAX), @KeyNotNull NVARCHAR(MAX),
            @KeyOn NVARCHAR(MAX), @KeyBad INT, @KeyCount INT = 0, @SeqFrom INT = 1, @SeqTo INT, @KeyWindow INT,
            @sqlKey NVARCHAR(MAX), @sqlDel NVARCHAR(MAX), @sqlRecount NVARCHAR(MAX), @KeyNote NVARCHAR(400) = N'';

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
         @IsChild = @IsChild OUTPUT, @FullName = @FullName OUTPUT, @DateTableFullName = @DateTableFullName OUTPUT,
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

    -- ChildDeleteMode is read dynamically: the procedure also compiles when the column is missing (-> JOIN)
    IF @IsChild = 1 AND COL_LENGTH(N'ret.RetentionParameter', N'ChildDeleteMode') IS NOT NULL
        EXEC sp_executesql N'SELECT @m = ChildDeleteMode FROM ret.RetentionParameter WHERE ParameterSetId = 1;',
             N'@m VARCHAR(10) OUTPUT', @m = @ChildMode OUTPUT;
    SET @ChildMode = ISNULL(@ChildMode, 'JOIN');

    SET @Delay    = ret.fn_DelayString(@Pause);
    SET @Pred     = @DateExpr + N' < @Upper' + CASE WHEN @RangeFrom IS NOT NULL THEN N' AND ' + @DateExpr + N' >= @Lower' ELSE N'' END;
    SET @sqlCount = N'SELECT @n = COUNT_BIG(*)' + @FromSql + N' WHERE ' + @Pred + N';';
    SET @sql      = N'SET LOCK_TIMEOUT ' + CONVERT(NVARCHAR(12), @LockTimeoutMs) + N';
DELETE TOP (@BatchSize) t' + @FromSql + N' WHERE ' + @Pred + N';
SET @rc = @@ROWCOUNT;';
    SET @sqlDel     = @sql;
    SET @sqlRecount = @sqlCount;

    /* ---- Child table, ChildDeleteMode KEY_TABLE: key column definitions from the header columns ---- */
    IF @IsChild = 1 AND @ChildMode = 'KEY_TABLE'
    BEGIN
        SELECT @KeyDefs    = STRING_AGG(CONVERT(NVARCHAR(MAX), N'k' + CONVERT(NVARCHAR(10), k.KeyOrdinal) + N' ' + ty.TypeDef + N' NULL')
                                        COLLATE DATABASE_DEFAULT, N', ') WITHIN GROUP (ORDER BY k.KeyOrdinal),
               @KeyCols    = STRING_AGG(CONVERT(NVARCHAR(MAX), N'k' + CONVERT(NVARCHAR(10), k.KeyOrdinal))
                                        COLLATE DATABASE_DEFAULT, N', ') WITHIN GROUP (ORDER BY k.KeyOrdinal),
               @KeySel     = STRING_AGG(CONVERT(NVARCHAR(MAX), N'p.' + QUOTENAME(k.ParentColumn))
                                        COLLATE DATABASE_DEFAULT, N', ') WITHIN GROUP (ORDER BY k.KeyOrdinal),
               @KeyNotNull = STRING_AGG(CONVERT(NVARCHAR(MAX), N'p.' + QUOTENAME(k.ParentColumn) + N' IS NOT NULL')
                                        COLLATE DATABASE_DEFAULT, N' AND ') WITHIN GROUP (ORDER BY k.KeyOrdinal),
               @KeyOn      = STRING_AGG(CONVERT(NVARCHAR(MAX), N'k.k' + CONVERT(NVARCHAR(10), k.KeyOrdinal) + N' = t.' + QUOTENAME(k.ChildColumn))
                                        COLLATE DATABASE_DEFAULT, N' AND ') WITHIN GROUP (ORDER BY k.KeyOrdinal),
               @KeyBad     = SUM(CASE WHEN pc.column_id IS NULL OR ty.TypeDef IS NULL THEN 1 ELSE 0 END)
        FROM ret.RetentionParentKey AS k
        LEFT JOIN sys.columns AS pc
               ON pc.object_id = OBJECT_ID(@DateTableFullName, N'U') AND pc.name COLLATE DATABASE_DEFAULT = k.ParentColumn
        CROSS APPLY (SELECT TYPE_NAME(pc.system_type_id) COLLATE DATABASE_DEFAULT AS TypeName) AS tn
        CROSS APPLY (SELECT CASE
                WHEN tn.TypeName IN (N'text', N'ntext', N'image', N'xml', N'sql_variant', N'geography', N'geometry',
                                     N'hierarchyid', N'timestamp') THEN NULL
                WHEN tn.TypeName IN (N'varchar', N'char', N'varbinary', N'binary')
                    THEN tn.TypeName + N'(' + CASE WHEN pc.max_length = -1 THEN N'max' ELSE CONVERT(NVARCHAR(10), pc.max_length) END + N')'
                WHEN tn.TypeName IN (N'nvarchar', N'nchar')
                    THEN tn.TypeName + N'(' + CASE WHEN pc.max_length = -1 THEN N'max' ELSE CONVERT(NVARCHAR(10), pc.max_length / 2) END + N')'
                WHEN tn.TypeName IN (N'decimal', N'numeric')
                    THEN tn.TypeName + N'(' + CONVERT(NVARCHAR(10), pc.[precision]) + N', ' + CONVERT(NVARCHAR(10), pc.[scale]) + N')'
                WHEN tn.TypeName IN (N'datetime2', N'time', N'datetimeoffset')
                    THEN tn.TypeName + N'(' + CONVERT(NVARCHAR(10), pc.[scale]) + N')'
                ELSE tn.TypeName END
              + CASE WHEN pc.collation_name IS NOT NULL THEN N' COLLATE ' + pc.collation_name COLLATE DATABASE_DEFAULT ELSE N'' END AS TypeDef) AS ty
        WHERE k.TableConfigId = @TableConfigId;

        IF @KeyDefs IS NULL OR @KeyBad > 0
            SET @KeyNote = N' ChildDeleteMode KEY_TABLE not possible for these join key types: JOIN used.';
        ELSE
        BEGIN
            SET @UseKeyTable = 1;
            SET @KeyWindow   = @BatchSize;
            SET @SeqTo       = @KeyWindow;
            SET @sqlDel      = N'SET LOCK_TIMEOUT ' + CONVERT(NVARCHAR(12), @LockTimeoutMs) + N';
DELETE TOP (@BatchSize) t FROM ' + @FullName + N' AS t
JOIN #RetBdParentKey AS k ON ' + @KeyOn + N'
WHERE k.KeySeq BETWEEN @SeqFrom AND @SeqTo;
SET @rc = @@ROWCOUNT;';
            SET @sqlRecount  = N'SELECT @n = COUNT_BIG(*) FROM ' + @FullName + N' AS t JOIN #RetBdParentKey AS k ON ' + @KeyOn + N';';
        END;
    END;

    BEGIN TRY
        /* ---- KEY_TABLE: header keys of the validated range, read once (before the recount, so that the
                recount counts exactly the rows the batches can delete) ---- */
        IF @UseKeyTable = 1
        BEGIN
            CREATE TABLE #RetBdParentKey (KeySeq INT IDENTITY(1, 1) NOT NULL PRIMARY KEY CLUSTERED);
            SET @sqlKey = N'ALTER TABLE #RetBdParentKey ADD ' + @KeyDefs + N';';
            EXEC sp_executesql @sqlKey;
            SET @sqlKey = N'INSERT INTO #RetBdParentKey (' + @KeyCols + N')
SELECT DISTINCT ' + @KeySel + N' FROM ' + @DateTableFullName + N' AS p WHERE ' + @Pred + N' AND ' + @KeyNotNull + N'
ORDER BY ' + @KeySel + N';
SET @k = @@ROWCOUNT;';
            EXEC sp_executesql @sqlKey, N'@Upper DATE, @Lower DATE, @k INT OUTPUT',
                 @Upper = @RangeTo, @Lower = @RangeFrom, @k = @KeyCount OUTPUT;
            SET @KeyNote = CONCAT(N' ChildDeleteMode KEY_TABLE: ', @KeyCount, N' header keys.');
        END;

        /* ---- Recount (DBR-06) / resume integrity check (FR-017) ---- */
        EXEC sp_executesql @sqlRecount, N'@Upper DATE, @Lower DATE, @n BIGINT OUTPUT',
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
            IF @UseKeyTable = 1 AND @SeqFrom > @KeyCount
                BREAK;      -- KEY_TABLE: all key windows processed

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
                        EXEC sp_executesql @sqlDel, N'@BatchSize INT, @Upper DATE, @Lower DATE, @SeqFrom INT, @SeqTo INT, @rc INT OUTPUT',
                             @BatchSize = @BatchSize, @Upper = @RangeTo, @Lower = @RangeFrom,
                             @SeqFrom = @SeqFrom, @SeqTo = @SeqTo, @rc = @rc OUTPUT;

                        UPDATE ret.RetentionTableLog
                           SET RowsDeleted      = ISNULL(RowsDeleted, 0) + @rc,
                               DeleteBatchCount = ISNULL(DeleteBatchCount, 0) + CASE WHEN @UseKeyTable = 1 AND @rc = 0 THEN 0 ELSE 1 END
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

            SELECT @Batches += CASE WHEN @UseKeyTable = 1 AND @rc = 0 THEN 0 ELSE 1 END, @DeletedThisCall += @rc;

            IF @UseKeyTable = 0
            BEGIN
                IF @rc < @BatchSize
                    BREAK;
            END
            ELSE IF @rc < @BatchSize
            BEGIN
                -- current key window has no rows left: next window; no pause after an empty window
                SELECT @SeqFrom = @SeqTo + 1, @SeqTo = @SeqTo + @KeyWindow;
                IF @rc = 0
                    CONTINUE;
            END;

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
                    SET @Msg = CONCAT(N'Deleted ', @DeletedThisCall, N' rows in ', @Batches, N' batches.', @KeyNote);

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
