/* =====================================================================================
   DWH Data Retention and Archiving - Database Objects (schema ret) - PATCH v0.5
   -------------------------------------------------------------------------------------
   Script        : DWH_Retention_DB_Objects_v0.5_patch.sql
   Script ver.   : 0.5 (DRAFT - not reviewed, not executed against any database)
   Date          : 31 October 2026
   Applies to    : a database where DWH_Retention_DB_Objects_v0.4.sql has been deployed.
                   v0.5 = v0.4 + this patch. Re-runnable (CREATE OR ALTER).
   Sources       : FSD-DWH-RET-001 v0.2 (Draft for Review - NOT approved), FR-004
                   ADF Pipeline Design ADF-DD-DWH-RET-001 v0.2, option A (31 October 2026)

   CHANGE FROM v0.4
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
   ===================================================================================== */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

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

        SELECT @Unknown = STRING_AGG(CONVERT(NVARCHAR(20), TableConfigId), N', ')
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

/* Example (commented out)
-- Automatic mode: run again until every active table is COMPLETED
EXEC ret.usp_StartRun @ProcessType = 'INITIAL_CUTOFF', @TriggerType = 'MANUAL', @TriggeredBy = N'<operator>', @DowntimeReference = NULL;
EXEC ret.usp_GetTablesToProcess @RunId = <RunId>, @TableConfigIdList = NULL;     -- or N''
*/
