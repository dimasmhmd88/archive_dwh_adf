/* =====================================================================================
   DWH Data Retention and Archiving - register TEST tables in ret.RetentionConfig
   -------------------------------------------------------------------------------------
   Script  : test/92_insert_test_table_config.sql   Version 0.2 (DRAFT)      16 November 2026
   Requires: schema ret v0.6 (verify/90_verify_v06_deployment.sql all OK)
   Use     : DEV / TEST databases. For production tables use config/10_insert_retention_config.sql.

   What it does (one transaction, re-runnable)
     1. Checks every listed table (same rules as usp_BeginTable, so problems show before a run):
          table exists (V-01), retention column exists (V-02) and is date / datetime / datetime2 /
          smalldatetime (V-03), no NULL in the column (V-04), BlobPath unique (V-06).
     2. SizeCategory from the used space when not given: SMALL <= 500 MB, MEDIUM <= 5 GB (5,120 MB), LARGE > 5 GB.
     3. Inserts missing tables: BlobPath = lower-case <schema>.<table> (MD-07), DwhRetentionYears 3,
        BlobRetentionYears 5, LogRetentionYears 3, BATCH_DELETE, IsActive 1. The status row (PENDING)
        is created by trigger trg_RetentionConfig_AfterInsert.
     4. Already registered tables: column, size and IsActive are aligned only while the status is
        PENDING and no archive file exists (otherwise left unchanged and reported).
     @Apply = 0 (default): preview only, nothing is changed.

   Note for the test: a LARGE table is skipped by usp_GetTablesToProcess while any other active
   SMALL / MEDIUM table is not COMPLETED, and always needs a DowntimeReference (BR-16).
   ===================================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Apply BIT = 0;                         -- 0 = preview, 1 = insert / update

DECLARE @Test TABLE
(
    SchemaName          SYSNAME     NOT NULL,
    TableName           SYSNAME     NOT NULL,
    RetentionColumn     SYSNAME     NOT NULL,
    SizeCategory        VARCHAR(10) NULL,       -- NULL = from used space
    InitialCutoffMethod VARCHAR(20) NOT NULL DEFAULT ('BATCH_DELETE'),
    PRIMARY KEY (SchemaName, TableName)
);

-- <== list the test tables here
INSERT INTO @Test (SchemaName, TableName, RetentionColumn, SizeCategory)
VALUES
    (N'bos', N'JTI_SCW_Stock_Retention', N'dtmDate', NULL);
--  , (N'BI',  N'Fact_PO_Invoice_Retention', N'Date', NULL)      -- example: one row per test table

IF OBJECT_ID(N'ret.RetentionConfig', N'U') IS NULL OR COL_LENGTH(N'ret.RetentionConfig', N'LogRetentionYears') IS NULL
BEGIN
    ;THROW 50961, N'Schema ret v0.6 not found. Deploy deploy/01..05 first.', 1;
END;

/* ---- 1. Checks ---- */
IF OBJECT_ID(N'tempdb..#Chk') IS NOT NULL DROP TABLE #Chk;
CREATE TABLE #Chk
(
    SchemaName SYSNAME, TableName SYSNAME, RetentionColumn SYSNAME, InitialCutoffMethod VARCHAR(20),
    ObjectId INT NULL, ColumnType SYSNAME NULL, UsedSpaceMB DECIMAL(18, 2) NULL, SizeCategory VARCHAR(10) NULL,
    BlobPath NVARCHAR(400), NullDates BIGINT NULL, ExistingConfigId INT NULL, ExistingStatus VARCHAR(10) NULL,
    HasArchiveFiles BIT NOT NULL DEFAULT (0), Problem NVARCHAR(400) NULL
);

INSERT INTO #Chk (SchemaName, TableName, RetentionColumn, InitialCutoffMethod, ObjectId, ColumnType, UsedSpaceMB, SizeCategory, BlobPath)
SELECT t.SchemaName, t.TableName, t.RetentionColumn, t.InitialCutoffMethod,
       o.object_id, ty.name,
       CAST(sz.UsedPages * 8 / 1024.0 AS DECIMAL(18, 2)),
       ISNULL(t.SizeCategory, CASE WHEN sz.UsedPages * 8 / 1024.0 <= 500 THEN 'SMALL'
                                   WHEN sz.UsedPages * 8 / 1024.0 <= 5120 THEN 'MEDIUM' ELSE 'LARGE' END),
       LOWER(t.SchemaName + N'.' + t.TableName)
FROM @Test AS t
LEFT JOIN sys.tables AS o ON o.object_id = OBJECT_ID(QUOTENAME(t.SchemaName) + N'.' + QUOTENAME(t.TableName))
LEFT JOIN sys.columns AS c ON c.object_id = o.object_id AND c.name = t.RetentionColumn
LEFT JOIN sys.types AS ty ON ty.user_type_id = c.user_type_id
-- Catalog views instead of sys.dm_db_partition_stats: no VIEW DATABASE PERFORMANCE STATE permission needed
OUTER APPLY (SELECT ISNULL(SUM(CONVERT(BIGINT, au.used_pages)), 0) AS UsedPages
             FROM sys.partitions AS p
             JOIN sys.allocation_units AS au
               ON au.container_id = CASE WHEN au.type IN (1, 3) THEN p.hobt_id ELSE p.partition_id END
             WHERE p.object_id = o.object_id) AS sz;

UPDATE k
   SET ExistingConfigId = rc.TableConfigId,
       ExistingStatus   = s.InitialCutoffStatus,
       HasArchiveFiles  = CASE WHEN EXISTS (SELECT 1 FROM ret.RetentionArchiveDate AS a
                                            WHERE a.TableConfigId = rc.TableConfigId AND a.ExportStatus <> 'REMOVED') THEN 1 ELSE 0 END
  FROM #Chk AS k
  JOIN ret.RetentionConfig AS rc ON rc.SchemaName = k.SchemaName AND rc.TableName = k.TableName
  LEFT JOIN ret.RetentionTableStatus AS s ON s.TableConfigId = rc.TableConfigId;

-- NULL count (V-04), only for tables whose column is valid
DECLARE @s SYSNAME, @t SYSNAME, @col SYSNAME, @n BIGINT, @sql NVARCHAR(MAX);
DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT SchemaName, TableName, RetentionColumn FROM #Chk
    WHERE ObjectId IS NOT NULL AND ColumnType IN (N'date', N'datetime', N'datetime2', N'smalldatetime');
OPEN cur;
FETCH NEXT FROM cur INTO @s, @t, @col;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'SELECT @n = COUNT_BIG(*) FROM ' + QUOTENAME(@s) + N'.' + QUOTENAME(@t) + N' WHERE ' + QUOTENAME(@col) + N' IS NULL;';
    EXEC sp_executesql @sql, N'@n BIGINT OUTPUT', @n = @n OUTPUT;
    UPDATE #Chk SET NullDates = @n WHERE SchemaName = @s AND TableName = @t;
    FETCH NEXT FROM cur INTO @s, @t, @col;
END;
CLOSE cur; DEALLOCATE cur;

UPDATE k
   SET Problem = CASE
        WHEN k.ObjectId IS NULL THEN N'V-01: table not found'
        WHEN k.ColumnType IS NULL THEN N'V-02: retention column not found'
        WHEN k.ColumnType NOT IN (N'date', N'datetime', N'datetime2', N'smalldatetime')
             THEN N'V-03: retention column type ' + k.ColumnType + N' (must be date / datetime / datetime2 / smalldatetime)'
        WHEN k.NullDates > 0 THEN N'V-04: ' + CONVERT(NVARCHAR(20), k.NullDates) + N' NULL values in the retention column'
        WHEN k.InitialCutoffMethod NOT IN ('BATCH_DELETE', 'TABLE_REBUILD') THEN N'Invalid InitialCutoffMethod'
        WHEN EXISTS (SELECT 1 FROM ret.RetentionConfig AS rc
                     WHERE rc.BlobPath = k.BlobPath AND NOT (rc.SchemaName = k.SchemaName AND rc.TableName = k.TableName))
             THEN N'V-06: BlobPath ' + k.BlobPath + N' already used by another table'
        WHEN k.ExistingConfigId IS NOT NULL AND (k.ExistingStatus <> 'PENDING' OR k.HasArchiveFiles = 1)
             THEN N'Already registered and archiving started (status ' + ISNULL(k.ExistingStatus, N'?')
                  + N') - not changed; reset with test/91_reset_table_for_retest.sql'
        END
  FROM #Chk AS k;

SELECT SchemaName, TableName, RetentionColumn, ColumnType, UsedSpaceMB, SizeCategory, InitialCutoffMethod, BlobPath,
       NullDates, ExistingConfigId, ExistingStatus,
       CASE WHEN Problem IS NOT NULL THEN N'NOT APPLIED: ' + Problem
            WHEN ExistingConfigId IS NULL THEN N'INSERT'
            ELSE N'UPDATE (align column / size / method, IsActive = 1)' END AS Action
FROM #Chk ORDER BY SchemaName, TableName;

/* ---- 2. Apply ---- */
IF @Apply = 1
BEGIN
    BEGIN TRANSACTION;

    INSERT INTO ret.RetentionConfig
        (SchemaName, TableName, RetentionColumn, ParentTableConfigId, DwhRetentionYears, BlobRetentionYears, LogRetentionYears,
         BlobPath, InitialCutoffMethod, IsActive, SizeCategory)
    SELECT k.SchemaName, k.TableName, k.RetentionColumn, NULL, 3, 5, 3, k.BlobPath, k.InitialCutoffMethod, 1, k.SizeCategory
    FROM #Chk AS k
    WHERE k.Problem IS NULL AND k.ExistingConfigId IS NULL;

    UPDATE rc
       SET RetentionColumn = k.RetentionColumn, ParentTableConfigId = NULL, SizeCategory = k.SizeCategory,
           InitialCutoffMethod = k.InitialCutoffMethod, BlobPath = k.BlobPath, IsActive = 1
      FROM ret.RetentionConfig AS rc
      JOIN #Chk AS k ON k.ExistingConfigId = rc.TableConfigId
     WHERE k.Problem IS NULL;

    COMMIT TRANSACTION;

    SELECT v.TableConfigId, v.SchemaName, v.TableName, v.RetentionColumn, v.SizeCategory, v.InitialCutoffMethod,
           rc.BlobPath, v.IsActive, v.InitialCutoffStatus
    FROM ret.vw_MQ03_TableStatus AS v
    JOIN ret.RetentionConfig AS rc ON rc.TableConfigId = v.TableConfigId
    JOIN #Chk AS k ON k.SchemaName = v.SchemaName AND k.TableName = v.TableName
    ORDER BY v.TableConfigId;
    -- TableConfigId values of this result -> ADF parameter TableConfigIdList, e.g. "36,41"
END
ELSE
    SELECT N'Preview only (@Apply = 0). Nothing changed.' AS Result;

DROP TABLE #Chk;
GO

/* Optional - test with ONLY the test tables active (avoids the LARGE gate and keeps automatic mode
   and the Daily Routine activation to the test tables). Restore afterwards with
   config/10_insert_retention_config.sql (sets the 31 phase-1 tables active again; note that it also
   sets every table outside phase 1, including these test tables, to IsActive = 0).

UPDATE ret.RetentionConfig SET IsActive = 0
 WHERE IsActive = 1 AND TableName NOT LIKE N'%[_]Retention';   -- adjust to the naming of your test tables
*/
