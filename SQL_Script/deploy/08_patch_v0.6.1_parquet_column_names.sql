/* =====================================================================================
   DWH Data Retention and Archiving - schema ret - PATCH v0.6.1 (decision D-6)
   -------------------------------------------------------------------------------------
   Script   : SQL_Script/deploy/08_patch_v0.6.1_parquet_column_names.sql
   Version  : 0.6.1 (DRAFT - not reviewed, not executed against any database)
   Date     : 21 November 2026
   Decision : D-6 (user, 21 Nov 2026): column names that Parquet rejects (white space and , ; { } ( ) =)
              are renamed in the archive file only; DWH tables and values are unchanged; the mapping is
              shown by ret.vw_ParquetColumnMap. Changes FSD FR-006/FR-007 ("all columns, no
              transformation") for column NAMES - FSD update required.
   Content  : ret.fn_ParquetColumnName (new), ret.vw_ParquetColumnMap (new),
              ret.usp_ExportSourceRows (aliases), ret.usp_BeginTable (V-08: types + unique renamed names)
   Apply to : databases with SQL v0.6 (deploy/01..05 already run). New deployments: deploy/03..05 already
              contain the change; this patch is not needed.
   OPSI B   : if SQL_Script/deploy/20_OpsiB_DB_Objects.sql was deployed, run it AGAIN after this patch
              (it contains usp_BeginTable with the #RetOut_ option); check with 21_verify_opsiB.sql.
   ===================================================================================== */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO



-- v0.6.1, decision D-6 (21 Nov 2026): column name written to the Parquet file. Parquet (ADF Copy) rejects
-- white space and , ; { } ( ) = tab line-feed carriage-return in column names (ParquetInvalidColumnName).
-- Such names get '_' for every rejected character, repeated '_' collapsed, leading/trailing '_' removed.
-- Every other name is returned unchanged. NULL when nothing is left (caller uses column_<column_id>).
-- Mapping source column -> archive column: view ret.vw_ParquetColumnMap.
CREATE OR ALTER FUNCTION ret.fn_ParquetColumnName (@ColumnName NVARCHAR(128))
RETURNS NVARCHAR(128)
AS
BEGIN
    DECLARE @n NVARCHAR(128) = @ColumnName;
    IF @n IS NULL RETURN NULL;
    IF @n NOT LIKE N'%[ ,;{}()=]%' AND CHARINDEX(NCHAR(9), @n) = 0 AND CHARINDEX(NCHAR(10), @n) = 0
       AND CHARINDEX(NCHAR(13), @n) = 0
        RETURN @n;
    SET @n = TRANSLATE(@n, N' ,;{}()=' + NCHAR(9) + NCHAR(10) + NCHAR(13), N'___________');
    WHILE CHARINDEX(N'__', @n) > 0 SET @n = REPLACE(@n, N'__', N'_');
    WHILE LEFT(@n, 1) = N'_' SET @n = STUFF(@n, 1, 1, N'');
    WHILE RIGHT(@n, 1) = N'_' SET @n = LEFT(@n, LEN(@n) - 1);
    RETURN NULLIF(@n, N'');
END;
GO

-- Parquet column names of the configured tables (v0.6.1, decision D-6): source column -> column in the archive
-- files. IsRenamed = 1 for names that Parquet does not accept (see ret.fn_ParquetColumnName).
CREATE OR ALTER VIEW ret.vw_ParquetColumnMap
AS
SELECT c.TableConfigId, c.SchemaName, c.TableName, col.column_id AS ColumnOrdinal,
       CONVERT(NVARCHAR(128), col.name) COLLATE DATABASE_DEFAULT AS SourceColumn,
       ISNULL(ret.fn_ParquetColumnName(col.name), CONCAT(N'column_', col.column_id)) COLLATE DATABASE_DEFAULT AS ParquetColumn,
       CAST(CASE WHEN ret.fn_ParquetColumnName(col.name) COLLATE Latin1_General_100_BIN2
                      = CONVERT(NVARCHAR(128), col.name) COLLATE Latin1_General_100_BIN2 THEN 0 ELSE 1 END AS BIT) AS IsRenamed
FROM ret.RetentionConfig AS c
JOIN sys.columns AS col ON col.object_id = OBJECT_ID(QUOTENAME(c.SchemaName) + N'.' + QUOTENAME(c.TableName));
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

    -- v0.6.1, decision D-6: names that Parquet rejects get an alias (ret.fn_ParquetColumnName); values unchanged
    SELECT @ColList = STRING_AGG(CONVERT(NVARCHAR(MAX),
               N't.' + QUOTENAME(c.name COLLATE DATABASE_DEFAULT)
               + CASE WHEN p.ParquetColumn COLLATE Latin1_General_100_BIN2 = CONVERT(NVARCHAR(128), c.name) COLLATE Latin1_General_100_BIN2
                      THEN N'' ELSE N' AS ' + QUOTENAME(p.ParquetColumn) END), N', ') WITHIN GROUP (ORDER BY c.column_id)
    FROM sys.columns AS c
    CROSS APPLY (SELECT ISNULL(ret.fn_ParquetColumnName(c.name), CONCAT(N'column_', c.column_id)) COLLATE DATABASE_DEFAULT AS ParquetColumn) AS p
    WHERE c.object_id = @ObjectId;

    SET @sql = N'SELECT ' + @ColList + @FromSql
             + N' WHERE ' + @DateExpr + N' >= @d AND ' + @DateExpr + N' < DATEADD(DAY, 1, @d);';

    EXEC sp_executesql @sql, N'@d DATE', @d = @BusinessDate;
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
            -- column types that Parquet cannot hold
            SELECT @BadList = STRING_AGG(CONVERT(NVARCHAR(MAX), CONCAT(QUOTENAME(c.name COLLATE DATABASE_DEFAULT), N' (', t.name COLLATE DATABASE_DEFAULT, N')')) COLLATE DATABASE_DEFAULT, N', ')
            FROM sys.columns AS c
            JOIN sys.types AS t ON t.user_type_id = c.user_type_id
            WHERE c.object_id = @ObjectId
              AND (   TYPE_NAME(c.system_type_id) = 'sql_variant'
                   OR t.is_assembly_type = 1);

            IF @BadList IS NOT NULL
                SELECT @ErrCode = 'ERR-CFG-08', @CheckCode = 'V-08',
                       @ErrMsg = LEFT(CONCAT(N'Column types not supported for Parquet export: ', @BadList), 4000);
            ELSE
            BEGIN
                -- v0.6.1, decision D-6: names with white space or , ; { } ( ) = are renamed in the Parquet file
                -- (ret.fn_ParquetColumnName); the renamed names must stay unique (case-insensitive)
                SELECT @BadList = STRING_AGG(CONVERT(NVARCHAR(MAX), CONCAT(QUOTENAME(d.ParquetColumn), N' (', d.Cnt, N' columns)')) COLLATE DATABASE_DEFAULT, N', ')
                FROM (SELECT ISNULL(ret.fn_ParquetColumnName(c.name), CONCAT(N'column_', c.column_id)) COLLATE Latin1_General_CI_AS AS ParquetColumn,
                             COUNT(*) AS Cnt
                      FROM sys.columns AS c
                      WHERE c.object_id = @ObjectId
                      GROUP BY ISNULL(ret.fn_ParquetColumnName(c.name), CONCAT(N'column_', c.column_id)) COLLATE Latin1_General_CI_AS
                      HAVING COUNT(*) > 1) AS d;

                IF @BadList IS NOT NULL
                    SELECT @ErrCode = 'ERR-CFG-08', @CheckCode = 'V-08',
                           @ErrMsg = LEFT(CONCAT(N'Parquet column names not unique after renaming (D-6, ret.vw_ParquetColumnMap): ', @BadList), 4000);
            END;
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


-- Check: mapping of the configured tables that have renamed columns
SELECT TableConfigId, SchemaName, TableName, ColumnOrdinal, SourceColumn, ParquetColumn
FROM ret.vw_ParquetColumnMap
WHERE IsRenamed = 1
ORDER BY TableConfigId, ColumnOrdinal;
GO
