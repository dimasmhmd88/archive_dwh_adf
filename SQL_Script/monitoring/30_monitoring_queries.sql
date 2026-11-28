/* =====================================================================================
   DWH Data Retention and Archiving - monitoring queries (schema ret, SQL v0.6.2 / opsi B)
   -------------------------------------------------------------------------------------
   Script  : SQL_Script/monitoring/30_monitoring_queries.sql   Version 0.3.1 (DRAFT, not executed)   24 November 2026
   Read-only. Run the whole file, or block 0 together with any other block.

   FILTERS (block 0) - used by every block
     @TableConfigId   NULL = all tables, or one TableConfigId
     @RunId           NULL = latest run (MAX RunId); with @TableConfigId: latest run of that table
   Run-related blocks (1-8, 13, 14) show @RunId only. Blocks 9-12, 15, 16 show the current configuration /
   archive state and use @TableConfigId only (they do not belong to one run). Block 11 runs only with @TableConfigId.

   VIEWS (schema ret)
     vw_MQ01_LatestRuns            runs: status and table counters
     vw_MQ02_FailedTables          FAILED / STOPPED / SKIPPED tables of the last 7 days
     vw_MQ03_TableStatus           Initial Cut-off status and flags per table
     vw_MQ04_PendingResume         validated ranges not yet fully deleted
     vw_MQ05_Reconciliation        rows eligible / exported / deleted / retained per table run
     vw_MQ06_LocksAndRebuildTables table locks held, leftover __RBD_ tables
     vw_MQ07_ArchiveFiles          row counts per Parquet file: DWH / read / written, path, status (v0.6.2)
     vw_ParquetColumnMap           source column -> column in the Parquet file (v0.6.1, D-6)

   BLOCKS
      0  Filters                                     9  Configuration and parameters
      1  Run                                        10  Daily Routine readiness
      2  Tables of the run (reconciliation)         11  Eligible data preview
      3  Files of the run (row counts per file)     12  Archive inventory per table and year
      4  Errors and skipped tables of the run       13  Duration and performance of the run
      5  Step log of the run                        14  Expired archive deletion of the run
      6  Flags, pending resume, locks               15  Parquet column renaming (D-6)
      7  Live progress (tables of the run RUNNING)  16  Log volume
      8  Run still RUNNING (stale check)
   ===================================================================================== */
SET NOCOUNT ON;

/* ---- 0. Filters ---- */
DECLARE @TableConfigId INT    = NULL;     -- NULL = all tables
DECLARE @RunId         BIGINT = NULL;     -- NULL = latest run (of @TableConfigId when given)

IF @RunId IS NULL
    SELECT @RunId = CASE WHEN @TableConfigId IS NULL
                         THEN (SELECT MAX(RunId) FROM ret.RetentionRunLog)
                         ELSE (SELECT MAX(RunId) FROM ret.RetentionTableLog WHERE TableConfigId = @TableConfigId) END;

SELECT @RunId AS RunId, @TableConfigId AS TableConfigId,
       (SELECT SchemaName + N'.' + TableName FROM ret.RetentionConfig WHERE TableConfigId = @TableConfigId) AS TableName;

/* ---- 1. Run ---- */
SELECT r.RunId, r.ProcessType, r.RunDate, r.TriggerType, r.TriggeredBy, r.DowntimeReference, r.Status,
       r.TablesSelected, r.TablesSucceeded, r.TablesFailed, r.TablesSkipped,
       r.StartTime, r.EndTime, DATEDIFF(MINUTE, r.StartTime, ISNULL(r.EndTime, ret.fn_NowUtc7())) AS Minutes,
       r.ErrorMessage
FROM ret.RetentionRunLog AS r
WHERE r.RunId = @RunId;

/* ---- 2. Tables of the run: reconciliation (RowsDeleted = EligibleRows when SUCCEEDED) ---- */
SELECT v.*, CASE WHEN v.Status IN ('SUCCEEDED', 'NODATA')
                  AND ISNULL(v.RowsDeleted, 0) = ISNULL(v.EligibleRows, 0) THEN 'OK' ELSE 'CHECK' END AS ReconCheck
FROM ret.vw_MQ05_Reconciliation AS v
JOIN ret.RetentionTableLog AS l ON l.TableLogId = v.TableLogId
WHERE v.RunId = @RunId
  AND (@TableConfigId IS NULL OR l.TableConfigId = @TableConfigId)
ORDER BY v.TableLogId;

/* ---- 3. Files of the run: row counts per Parquet file (view MQ-07, patch v0.6.2) ---- */
IF OBJECT_ID(N'ret.vw_MQ07_ArchiveFiles', N'V') IS NOT NULL
BEGIN
    EXEC sp_executesql N'
        SELECT ProcessDate, ProcessType, SchemaName + N''.'' + TableName AS TableName, DataDate,
               RowCountDwh, RowCountRead, RowCountParquet, RowDifference, RowCountMatch,
               FileCount, ExportStatus, ValidationResult, FilePath, ExportStartTime, ExportEndTime,
               ExportSeconds, ErrorMessage
        FROM ret.vw_MQ07_ArchiveFiles
        WHERE RunId = @RunId AND (@Tc IS NULL OR TableConfigId = @Tc)
        ORDER BY TableName, DataDate;

        -- 3a. Summary per table and status
        SELECT SchemaName + N''.'' + TableName AS TableName, ExportStatus, COUNT(*) AS Dates, SUM(FileCount) AS Files,
               SUM(RowCountDwh) AS RowsDwh, SUM(RowCountParquet) AS RowsParquet,
               SUM(CASE WHEN RowCountMatch = 0 THEN 1 ELSE 0 END) AS DatesWithMismatch
        FROM ret.vw_MQ07_ArchiveFiles
        WHERE RunId = @RunId AND (@Tc IS NULL OR TableConfigId = @Tc)
        GROUP BY SchemaName, TableName, ExportStatus
        ORDER BY TableName, ExportStatus;

        -- 3b. Files with a row-count mismatch or a failed export (should be empty)
        SELECT * FROM ret.vw_MQ07_ArchiveFiles
        WHERE RunId = @RunId AND (@Tc IS NULL OR TableConfigId = @Tc)
          AND ExportStatus IN (''SUCCEEDED'', ''FAILED'') AND RowCountMatch = 0
        ORDER BY SchemaName, TableName, DataDate;',
        N'@RunId BIGINT, @Tc INT', @RunId = @RunId, @Tc = @TableConfigId;
END
ELSE
    SELECT N'ret.vw_MQ07_ArchiveFiles not found: run SQL_Script/deploy/09_patch_v0.6.2_view_archive_files.sql.' AS Warning;

/* ---- 4. Errors and skipped tables of the run, with the meaning of the error code ---- */
SELECT l.TableLogId, c.SchemaName + N'.' + c.TableName AS TableName, l.Status, l.ErrorCode, e.Category,
       e.Description, e.IsWarning, l.ErrorStep, l.ErrorMessage
FROM ret.RetentionTableLog AS l
JOIN ret.RetentionConfig AS c ON c.TableConfigId = l.TableConfigId
LEFT JOIN ret.RetentionErrorCode AS e ON e.ErrorCode = l.ErrorCode
WHERE l.RunId = @RunId
  AND (@TableConfigId IS NULL OR l.TableConfigId = @TableConfigId)
  AND (l.Status IN ('FAILED', 'STOPPED', 'SKIPPED') OR l.ErrorCode IS NOT NULL)
ORDER BY l.TableLogId;

/* ---- 5. Step log of the run (process trail) ---- */
SELECT s.StepLogId, c.SchemaName + N'.' + c.TableName AS TableName, s.StepCode, s.ValidationCheckCode, s.Status,
       s.BusinessDate, s.ExpectedRows, s.RowsRead, s.RowsWritten, s.RowsProcessed, s.BatchCount, s.FileCount,
       s.FilePath, s.Message, s.ErrorCode, s.ErrorMessage, s.StartTime, s.EndTime
FROM ret.RetentionStepLog AS s
LEFT JOIN ret.RetentionConfig AS c ON c.TableConfigId = s.TableConfigId
WHERE s.RunId = @RunId
  AND (@TableConfigId IS NULL OR s.TableConfigId = @TableConfigId OR s.TableConfigId IS NULL)
ORDER BY s.StepLogId;

/* ---- 6. Flags, pending resume, locks (all should be empty) ---- */
SELECT v.* FROM ret.vw_MQ03_TableStatus AS v
WHERE (v.HasOrphanFiles = 1 OR v.HasIntegrityIssue = 1 OR v.HasReconciliationWarning = 1)
  AND (@TableConfigId IS NULL OR v.TableConfigId = @TableConfigId);

SELECT v.* FROM ret.vw_MQ04_PendingResume AS v
JOIN ret.RetentionTableLog AS l ON l.TableLogId = v.TableLogId
WHERE (@TableConfigId IS NULL OR l.TableConfigId = @TableConfigId);

SELECT v.* FROM ret.vw_MQ06_LocksAndRebuildTables AS v
WHERE @TableConfigId IS NULL
   OR EXISTS (SELECT 1 FROM ret.RetentionConfig AS c
              WHERE c.TableConfigId = @TableConfigId AND c.SchemaName = v.SchemaName
                AND (v.TableName = c.TableName OR v.TableName LIKE c.TableName + N'[_][_]RBD[_]%'));

/* ---- 7. Live progress of the tables of the run that are still RUNNING (export + batch delete) ---- */
SELECT l.TableLogId, c.SchemaName + N'.' + c.TableName AS TableName, l.Status, l.ExportDateCount,
       (SELECT COUNT(*) FROM ret.RetentionArchiveDate AS a WHERE a.TableLogId = l.TableLogId AND a.ExportStatus = 'SUCCEEDED') AS DatesExported,
       (SELECT COUNT(*) FROM ret.RetentionArchiveDate AS a WHERE a.TableLogId = l.TableLogId AND a.ExportStatus = 'PENDING')   AS DatesPending,
       l.IsValidated, l.ValidatedRowCount, l.DeleteStatus, l.RowsDeleted, l.DeleteBatchCount,
       CAST(100.0 * ISNULL(l.RowsDeleted, 0) / NULLIF(l.ValidatedRowCount, 0) AS DECIMAL(5, 1)) AS PctDeleted,
       DATEDIFF(MINUTE, l.StartTime, ret.fn_NowUtc7()) AS MinutesRunning
FROM ret.RetentionTableLog AS l
JOIN ret.RetentionConfig AS c ON c.TableConfigId = l.TableConfigId
WHERE l.RunId = @RunId AND l.Status = 'RUNNING'
  AND (@TableConfigId IS NULL OR l.TableConfigId = @TableConfigId)
ORDER BY l.TableLogId;

/* ---- 8. Run still RUNNING after 12 hours (ADF run cancelled or crashed) -> ret.usp_AdminCloseStaleRun ---- */
SELECT RunId, ProcessType, RunDate, TriggeredBy, StartTime, DATEDIFF(HOUR, StartTime, ret.fn_NowUtc7()) AS HoursRunning
FROM ret.RetentionRunLog
WHERE RunId = @RunId AND Status = 'RUNNING' AND StartTime < DATEADD(HOUR, -12, ret.fn_NowUtc7());

/* ---- 9. Configuration and parameters (current state) ---- */
SELECT c.TableConfigId, c.SchemaName, c.TableName, c.RetentionColumn, c.SizeCategory, c.InitialCutoffMethod,
       c.IsActive, c.DwhRetentionYears, c.BlobRetentionYears, c.LogRetentionYears, c.BlobPath,
       s.InitialCutoffStatus, s.InitialCutoffCompletionDate
FROM ret.RetentionConfig AS c
JOIN ret.RetentionTableStatus AS s ON s.TableConfigId = c.TableConfigId
WHERE (@TableConfigId IS NULL OR c.TableConfigId = @TableConfigId)
ORDER BY c.IsActive DESC, c.SizeCategory, c.TableConfigId;

SELECT BatchSize, BatchPauseSeconds, CONVERT(CHAR(5), IcWindowStart, 108) AS IcWindowStart,
       CONVERT(CHAR(5), IcWindowEnd, 108) AS IcWindowEnd, DailyRoutineStartDate, DeleteRetryCount,
       DeleteLockTimeoutMs, DailyNullCheckMode, ArchiveContainer, ModifiedBy, ModifiedAt
FROM ret.RetentionParameter WHERE ParameterSetId = 1;

-- 9b. Opsi B only: export parallelism N (global and per table)
IF COL_LENGTH(N'ret.RetentionParameter', N'ExportParallelism') IS NOT NULL
    EXEC sp_executesql N'
        SELECT p.ExportParallelism AS GlobalN, c.TableConfigId, c.SchemaName, c.TableName,
               c.ExportParallelism AS TableN, ISNULL(c.ExportParallelism, p.ExportParallelism) AS EffectiveN
        FROM ret.RetentionConfig AS c CROSS JOIN ret.RetentionParameter AS p
        WHERE p.ParameterSetId = 1 AND c.IsActive = 1 AND (@Tc IS NULL OR c.TableConfigId = @Tc)
        ORDER BY c.TableConfigId;', N'@Tc INT', @Tc = @TableConfigId;

/* ---- 10. Daily Routine readiness (tables the Daily Routine of today will process) ---- */
SELECT c.TableConfigId, c.SchemaName + N'.' + c.TableName AS TableName, c.IsActive, s.InitialCutoffStatus,
       s.InitialCutoffCompletionDate, p.DailyRoutineStartDate,
       CASE WHEN p.DailyRoutineStartDate IS NULL THEN 'NO - Daily Routine not activated (usp_ActivateDailyRoutine)'
            WHEN p.DailyRoutineStartDate > ret.fn_TodayUtc7() THEN 'NO - starts ' + CONVERT(CHAR(10), p.DailyRoutineStartDate, 23)
            WHEN c.IsActive = 0 THEN 'NO - inactive'
            WHEN s.InitialCutoffStatus <> 'COMPLETED' THEN 'NO - Initial Cut-off ' + s.InitialCutoffStatus
            WHEN s.InitialCutoffCompletionDate >= ret.fn_TodayUtc7() THEN 'NO - completed today, from tomorrow'
            ELSE 'YES' END AS InDailyRoutineToday
FROM ret.RetentionConfig AS c
JOIN ret.RetentionTableStatus AS s ON s.TableConfigId = c.TableConfigId
CROSS JOIN ret.RetentionParameter AS p
WHERE p.ParameterSetId = 1 AND (@TableConfigId IS NULL OR c.TableConfigId = @TableConfigId)
ORDER BY c.IsActive DESC, c.TableConfigId;

/* ---- 11. Eligible data preview (same cut-off rule as the pipeline, run date = today UTC+7; no change) ---- */
--     Reads the whole table: only for one table (@TableConfigId); skipped when @TableConfigId IS NULL,
--     so that running the whole file never scans all LARGE tables.
DECLARE @PreviewTc INT, @PreviewName NVARCHAR(300), @Sch SYSNAME, @Tab SYSNAME, @Col SYSNAME, @Dwh DATE, @Arc DATE, @sql NVARCHAR(MAX);
DECLARE @Preview TABLE (TableConfigId INT, TableName NVARCHAR(300), ArchiveCutoff DATE, DwhCutoff DATE, ExpiredRows BIGINT,
                        ArchivedRows BIGINT, ArchivedFiles INT, FirstArchiveDate DATE, LastArchiveDate DATE,
                        RetainedRows BIGINT, NullDates BIGINT);
DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT c.TableConfigId, c.SchemaName, c.TableName, c.RetentionColumn, co.DwhCutoffDate, co.ArchiveCutoffDate
    FROM ret.RetentionConfig AS c
    CROSS APPLY ret.fn_GetCutoffDates(ret.fn_TodayUtc7(), c.DwhRetentionYears, c.BlobRetentionYears) AS co
    WHERE c.RetentionColumn IS NOT NULL
      AND OBJECT_ID(QUOTENAME(c.SchemaName) + N'.' + QUOTENAME(c.TableName), N'U') IS NOT NULL
      AND c.TableConfigId = @TableConfigId;
OPEN cur;
FETCH NEXT FROM cur INTO @PreviewTc, @Sch, @Tab, @Col, @Dwh, @Arc;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'WITH d AS (SELECT CAST(' + QUOTENAME(@Col) + N' AS DATE) AS BusinessDate, COUNT_BIG(*) AS RowCnt
                            FROM ' + QUOTENAME(@Sch) + N'.' + QUOTENAME(@Tab) + N' GROUP BY CAST(' + QUOTENAME(@Col) + N' AS DATE))
                 SELECT @Tc, @Name, @Arc, @Dwh,
                        ISNULL(SUM(CASE WHEN BusinessDate < @Arc THEN RowCnt END), 0),
                        ISNULL(SUM(CASE WHEN BusinessDate >= @Arc AND BusinessDate < @Dwh THEN RowCnt END), 0),
                        COUNT(CASE WHEN BusinessDate >= @Arc AND BusinessDate < @Dwh THEN 1 END),
                        MIN(CASE WHEN BusinessDate >= @Arc AND BusinessDate < @Dwh THEN BusinessDate END),
                        MAX(CASE WHEN BusinessDate >= @Arc AND BusinessDate < @Dwh THEN BusinessDate END),
                        ISNULL(SUM(CASE WHEN BusinessDate >= @Dwh THEN RowCnt END), 0),
                        ISNULL(SUM(CASE WHEN BusinessDate IS NULL THEN RowCnt END), 0)
                 FROM d;';
    SET @PreviewName = @Sch + N'.' + @Tab;       -- EXEC parameters cannot be expressions
    INSERT INTO @Preview
    EXEC sp_executesql @sql, N'@Tc INT, @Name NVARCHAR(300), @Dwh DATE, @Arc DATE',
         @Tc = @PreviewTc, @Name = @PreviewName, @Dwh = @Dwh, @Arc = @Arc;
    FETCH NEXT FROM cur INTO @PreviewTc, @Sch, @Tab, @Col, @Dwh, @Arc;
END;
CLOSE cur; DEALLOCATE cur;
IF @TableConfigId IS NULL
    SELECT N'Block 11 skipped: set @TableConfigId to preview the eligible data of one table.' AS Info;
ELSE
    SELECT * FROM @Preview ORDER BY TableConfigId;

/* ---- 12. Archive inventory per table and year (files kept in Blob) ---- */
SELECT c.TableConfigId, c.SchemaName + N'.' + c.TableName AS TableName, YEAR(a.BusinessDate) AS ArchiveYear,
       COUNT(*) AS Files, SUM(a.RowsWritten) AS Rows, MIN(a.BusinessDate) AS FirstDate, MAX(a.BusinessDate) AS LastDate
FROM ret.RetentionArchiveDate AS a
JOIN ret.RetentionConfig AS c ON c.TableConfigId = a.TableConfigId
WHERE a.ExportStatus = 'SUCCEEDED'
  AND (@TableConfigId IS NULL OR a.TableConfigId = @TableConfigId)
GROUP BY c.TableConfigId, c.SchemaName, c.TableName, YEAR(a.BusinessDate)
ORDER BY c.TableConfigId, ArchiveYear;

-- 12b. The same business date archived more than once (should be empty; D-1)
SELECT a.TableConfigId, a.BusinessDate, COUNT(*) AS Times, STRING_AGG(CONVERT(NVARCHAR(20), a.RunId), N', ') AS RunIds
FROM ret.RetentionArchiveDate AS a
WHERE a.ExportStatus = 'SUCCEEDED'
  AND (@TableConfigId IS NULL OR a.TableConfigId = @TableConfigId)
GROUP BY a.TableConfigId, a.BusinessDate
HAVING COUNT(*) > 1;

/* ---- 13. Duration and performance of the run per table ---- */
SELECT l.RunId, r.ProcessType, r.TriggeredBy, c.SchemaName + N'.' + c.TableName AS TableName, l.Status,
       l.ExportDateCount, l.RowsExported, l.RowsDeleted, l.DeleteBatchCount,
       DATEDIFF(SECOND, l.StartTime, l.EndTime) AS TableSeconds,
       CAST(DATEDIFF(SECOND, l.StartTime, l.EndTime) * 1.0 / NULLIF(l.ExportDateCount, 0) AS DECIMAL(10, 1)) AS SecondsPerDate,
       (SELECT SUM(DATEDIFF(SECOND, a.ExportStartTime, a.ExportEndTime)) FROM ret.RetentionArchiveDate AS a
         WHERE a.TableLogId = l.TableLogId) AS ExportSecondsSum
FROM ret.RetentionTableLog AS l
JOIN ret.RetentionRunLog AS r ON r.RunId = l.RunId
JOIN ret.RetentionConfig AS c ON c.TableConfigId = l.TableConfigId
WHERE l.RunId = @RunId AND (@TableConfigId IS NULL OR l.TableConfigId = @TableConfigId)
ORDER BY l.TableLogId;

/* ---- 14. Expired archive deletion of the run (Daily Routine, DR-05) ---- */
SELECT l.RunId, l.RunDate, c.SchemaName + N'.' + c.TableName AS TableName, l.ArchiveCutoffDate,
       l.ArchiveFoldersDeleted, l.ArchiveFilesDeleted, s.Status AS ExpireStatus, s.Message, s.ErrorCode, s.ErrorMessage
FROM ret.RetentionTableLog AS l
JOIN ret.RetentionConfig AS c ON c.TableConfigId = l.TableConfigId
LEFT JOIN ret.RetentionStepLog AS s ON s.TableLogId = l.TableLogId AND s.StepCode = 'EXPIRE'
WHERE l.RunId = @RunId AND l.ProcessType = 'DAILY_ROUTINE'
  AND (@TableConfigId IS NULL OR l.TableConfigId = @TableConfigId)
ORDER BY l.TableLogId, s.StepLogId;

/* ---- 15. Parquet column renaming (decision D-6, patch v0.6.1) ---- */
IF OBJECT_ID(N'ret.vw_ParquetColumnMap', N'V') IS NOT NULL
    EXEC sp_executesql N'SELECT * FROM ret.vw_ParquetColumnMap
                         WHERE IsRenamed = 1 AND (@Tc IS NULL OR TableConfigId = @Tc)
                         ORDER BY TableConfigId, ColumnOrdinal;', N'@Tc INT', @Tc = @TableConfigId;
ELSE
    SELECT N'ret.vw_ParquetColumnMap not found: run SQL_Script/deploy/08_patch_v0.6.1_parquet_column_names.sql.' AS Warning;

/* ---- 16. Log volume (log retention, LogRetentionYears) ---- */
SELECT N'RetentionTableLog' AS LogTable, COUNT(*) AS Rows, MIN(StartTime) AS Oldest
FROM ret.RetentionTableLog WHERE (@TableConfigId IS NULL OR TableConfigId = @TableConfigId)
UNION ALL
SELECT N'RetentionStepLog', COUNT(*), MIN(StartTime)
FROM ret.RetentionStepLog WHERE (@TableConfigId IS NULL OR TableConfigId = @TableConfigId)
UNION ALL
SELECT N'RetentionArchiveDate', COUNT(*), MIN(CAST(BusinessDate AS DATETIME2(3)))
FROM ret.RetentionArchiveDate WHERE (@TableConfigId IS NULL OR TableConfigId = @TableConfigId)
UNION ALL
SELECT N'RetentionRunLog (all tables)', COUNT(*), MIN(StartTime) FROM ret.RetentionRunLog;
