/* =====================================================================================
   DWH Data Retention and Archiving - register OWN-DATED tables (no header / parent key)
   -------------------------------------------------------------------------------------
   Script   : config/11_insert_table_config.sql   Version 0.1 (DRAFT - not executed against any database)
   Date     : 28 November 2026
   Requires : schema ret v0.6.1 (deploy/01..05 + 08), opsi B objects optional (ExportParallelism)
   Scope    : tables with their OWN retention column (ParentTableConfigId NULL, no ret.RetentionParentKey rows).
              Child tables (date from a header table): test/93_insert_header_child_config.sql.
              The 31 phase-1 tables: config/10_insert_retention_config.sql.

   WHAT IT DOES (re-runnable)
     1. Checks every listed table with the rules of usp_BeginTable, so problems show before a run:
          V-01 table exists                     V-02 retention column exists
          V-03 column type date / datetime / datetime2 / smalldatetime
          V-04 no NULL in the column (counted only when the column is nullable)
          V-05 retention years >= 1             V-06 BlobPath lower case, no slash, unique
          V-08 Parquet: no sql_variant / CLR column, column names unique after renaming (D-6)
          plus: method, size category, ExportParallelism 1..16, the table is not configured as a child,
          header of child tables: retention years must stay equal to the children (DBR-20).
     2. SizeCategory from the used space when NULL: SMALL <= 500 MB, MEDIUM <= 5 GB, LARGE > 5 GB.
     3. New table   -> INSERT (status row PENDING is created by trigger trg_RetentionConfig_AfterInsert).
        Registered  -> UPDATE of column, years, BlobPath, method, size, IsActive, ExportParallelism, only while
                       the Initial Cut-off status is PENDING and no archive file exists; otherwise not changed.
     @Apply = 0 (default): preview only, nothing is changed. @Apply = 1: one transaction, all or nothing
     for the rows without problem.

   NOTES
     - LARGE tables need a DowntimeReference at run time and run only after every active SMALL / MEDIUM table
       is COMPLETED (BR-16).
     - Information column HasDateIndex: without an index whose first column is the retention column every
       batch delete scans the table (recommended for MEDIUM / LARGE).
   ===================================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

/* -------------------------------------------------------------------------------------
   Settings - change here only
   ------------------------------------------------------------------------------------- */
DECLARE @Apply    BIT = 0;          -- 0 = preview, 1 = insert / update
DECLARE @IsActive BIT = 1;          -- IsActive of the listed tables (0 = registered but not processed)

DECLARE @List TABLE
(
    SchemaName          SYSNAME         NOT NULL,
    TableName           SYSNAME         NOT NULL,
    RetentionColumn     SYSNAME         NOT NULL,
    SizeCategory        VARCHAR(10)     NULL,                               -- NULL = from used space
    InitialCutoffMethod VARCHAR(20)     NOT NULL DEFAULT ('BATCH_DELETE'),  -- BATCH_DELETE / TABLE_REBUILD
    DwhRetentionYears   SMALLINT        NOT NULL DEFAULT (3),
    BlobRetentionYears  SMALLINT        NOT NULL DEFAULT (5),
    LogRetentionYears   SMALLINT        NOT NULL DEFAULT (3),
    BlobPath            NVARCHAR(400)   NULL,                               -- NULL = lower-case <schema>.<table> (MD-07)
    ExportParallelism   TINYINT         NULL,                               -- opsi B; NULL = global value
    PRIMARY KEY (SchemaName, TableName)
);

-- <== one row per table (SchemaName, TableName, RetentionColumn, SizeCategory)
INSERT INTO @List (SchemaName, TableName, RetentionColumn, SizeCategory)
VALUES
    (N'schema1', N'Table1', N'DateColumn', NULL);
--  , (N'schema2', N'Table2', N'TransDate', 'MEDIUM')
-- Other values per table: add the columns to the INSERT, e.g.
-- INSERT INTO @List (SchemaName, TableName, RetentionColumn, SizeCategory, DwhRetentionYears, ExportParallelism)
-- VALUES (N'schema3', N'Table3', N'dtmDate', NULL, 3, 8);

/* -------------------------------------------------------------------------------------
   0. Prerequisites
   ------------------------------------------------------------------------------------- */
IF OBJECT_ID(N'ret.RetentionConfig', N'U') IS NULL OR COL_LENGTH(N'ret.RetentionConfig', N'LogRetentionYears') IS NULL
BEGIN
    ;THROW 50971, N'Schema ret v0.6 not found. Deploy deploy/01..05 first.', 1;
END;
IF OBJECT_ID(N'ret.fn_ParquetColumnName', N'FN') IS NULL
BEGIN
    ;THROW 50972, N'ret.fn_ParquetColumnName not found. Deploy deploy/08_patch_v0.6.1_parquet_column_names.sql first.', 1;
END;

DECLARE @HasExportPar BIT = CASE WHEN COL_LENGTH(N'ret.RetentionConfig', N'ExportParallelism') IS NULL THEN 0 ELSE 1 END;

/* -------------------------------------------------------------------------------------
   1. Checks
   ------------------------------------------------------------------------------------- */
IF OBJECT_ID(N'tempdb..#Chk') IS NOT NULL DROP TABLE #Chk;
CREATE TABLE #Chk
(
    SchemaName SYSNAME, TableName SYSNAME, RetentionColumn SYSNAME, InitialCutoffMethod VARCHAR(20),
    DwhRetentionYears SMALLINT, BlobRetentionYears SMALLINT, LogRetentionYears SMALLINT, ExportParallelism TINYINT NULL,
    ObjectId INT NULL, ColumnType SYSNAME NULL, ColumnNullable BIT NULL, HasDateIndex BIT NULL,
    UsedSpaceMB DECIMAL(18, 2) NULL, SizeCategory VARCHAR(10) NULL, BlobPath NVARCHAR(400), NullDates BIGINT NULL,
    BadTypes NVARCHAR(MAX) NULL, DupParquetNames NVARCHAR(MAX) NULL,
    ExistingConfigId INT NULL, ExistingParentId INT NULL, ExistingStatus VARCHAR(10) NULL,
    HasArchiveFiles BIT NOT NULL DEFAULT (0), ChildYearsMismatch NVARCHAR(400) NULL, Problem NVARCHAR(400) NULL
);

INSERT INTO #Chk (SchemaName, TableName, RetentionColumn, InitialCutoffMethod, DwhRetentionYears, BlobRetentionYears,
                  LogRetentionYears, ExportParallelism, ObjectId, ColumnType, ColumnNullable, UsedSpaceMB, SizeCategory, BlobPath)
SELECT l.SchemaName, l.TableName, l.RetentionColumn, l.InitialCutoffMethod, l.DwhRetentionYears, l.BlobRetentionYears,
       l.LogRetentionYears, l.ExportParallelism,
       o.object_id, TYPE_NAME(c.system_type_id), c.is_nullable,
       CAST(sz.UsedPages * 8 / 1024.0 AS DECIMAL(18, 2)),
       ISNULL(l.SizeCategory, CASE WHEN o.object_id IS NULL THEN NULL
                                   WHEN sz.UsedPages * 8 / 1024.0 <= 500  THEN 'SMALL'
                                   WHEN sz.UsedPages * 8 / 1024.0 <= 5120 THEN 'MEDIUM' ELSE 'LARGE' END),
       ISNULL(l.BlobPath, LOWER(l.SchemaName + N'.' + l.TableName))
FROM @List AS l
LEFT JOIN sys.tables AS o ON o.object_id = OBJECT_ID(QUOTENAME(l.SchemaName) + N'.' + QUOTENAME(l.TableName))
LEFT JOIN sys.columns AS c ON c.object_id = o.object_id AND c.name COLLATE DATABASE_DEFAULT = l.RetentionColumn
-- catalog views instead of sys.dm_db_partition_stats: no VIEW DATABASE PERFORMANCE STATE permission needed
OUTER APPLY (SELECT ISNULL(SUM(CONVERT(BIGINT, au.used_pages)), 0) AS UsedPages
             FROM sys.partitions AS p
             JOIN sys.allocation_units AS au
               ON au.container_id = CASE WHEN au.type IN (1, 3) THEN p.hobt_id ELSE p.partition_id END
             WHERE p.object_id = o.object_id) AS sz;

-- index with the retention column as first key column (information)
UPDATE k
   SET HasDateIndex = CASE WHEN EXISTS (SELECT 1 FROM sys.index_columns AS ic
                                        JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                                        WHERE ic.object_id = k.ObjectId AND ic.key_ordinal = 1
                                          AND c.name COLLATE DATABASE_DEFAULT = k.RetentionColumn) THEN 1 ELSE 0 END
  FROM #Chk AS k
 WHERE k.ObjectId IS NOT NULL;

-- V-08 column types Parquet cannot hold
UPDATE k
   SET BadTypes = (SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), CONCAT(QUOTENAME(c.name COLLATE DATABASE_DEFAULT), N' (',
                                     t.name COLLATE DATABASE_DEFAULT, N')')) COLLATE DATABASE_DEFAULT, N', ')
                   FROM sys.columns AS c JOIN sys.types AS t ON t.user_type_id = c.user_type_id
                   WHERE c.object_id = k.ObjectId AND (TYPE_NAME(c.system_type_id) = 'sql_variant' OR t.is_assembly_type = 1)),
       DupParquetNames = (SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), QUOTENAME(d.ParquetColumn)) COLLATE DATABASE_DEFAULT, N', ')
                          FROM (SELECT ISNULL(ret.fn_ParquetColumnName(c.name), CONCAT(N'column_', c.column_id)) COLLATE Latin1_General_CI_AS AS ParquetColumn
                                FROM sys.columns AS c
                                WHERE c.object_id = k.ObjectId
                                GROUP BY ISNULL(ret.fn_ParquetColumnName(c.name), CONCAT(N'column_', c.column_id)) COLLATE Latin1_General_CI_AS
                                HAVING COUNT(*) > 1) AS d)
  FROM #Chk AS k
 WHERE k.ObjectId IS NOT NULL;

-- existing configuration
UPDATE k
   SET ExistingConfigId = rc.TableConfigId,
       ExistingParentId = rc.ParentTableConfigId,
       ExistingStatus   = s.InitialCutoffStatus,
       HasArchiveFiles  = CASE WHEN EXISTS (SELECT 1 FROM ret.RetentionArchiveDate AS a
                                            WHERE a.TableConfigId = rc.TableConfigId AND a.ExportStatus <> 'REMOVED') THEN 1 ELSE 0 END,
       ChildYearsMismatch = (SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), CONCAT(ch.SchemaName, N'.', ch.TableName, N' (', ch.DwhRetentionYears,
                                               N' + ', ch.BlobRetentionYears, N')')), N', ')
                             FROM ret.RetentionConfig AS ch
                             WHERE ch.ParentTableConfigId = rc.TableConfigId
                               AND (ch.DwhRetentionYears <> k.DwhRetentionYears OR ch.BlobRetentionYears <> k.BlobRetentionYears))
  FROM #Chk AS k
  JOIN ret.RetentionConfig AS rc ON rc.SchemaName = k.SchemaName AND rc.TableName = k.TableName
  LEFT JOIN ret.RetentionTableStatus AS s ON s.TableConfigId = rc.TableConfigId;

-- V-04 NULL count, only for valid nullable columns
DECLARE @s SYSNAME, @t SYSNAME, @col SYSNAME, @n BIGINT, @sql NVARCHAR(MAX);
DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT SchemaName, TableName, RetentionColumn FROM #Chk
    WHERE ObjectId IS NOT NULL AND ColumnNullable = 1 AND ColumnType IN (N'date', N'datetime', N'datetime2', N'smalldatetime');
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
        WHEN NOT (k.DwhRetentionYears >= 1 AND k.BlobRetentionYears >= 1 AND k.LogRetentionYears >= 1)
             THEN N'V-05: DWH, archive and log retention must each be >= 1 year'
        WHEN k.BlobPath COLLATE Latin1_General_100_BIN2 <> LOWER(k.BlobPath) COLLATE Latin1_General_100_BIN2
             OR CHARINDEX(N'/', k.BlobPath) > 0 OR CHARINDEX(N'\', k.BlobPath) > 0 OR LEN(k.BlobPath) = 0
             THEN N'V-06: BlobPath must be lower case without slash'
        WHEN EXISTS (SELECT 1 FROM ret.RetentionConfig AS rc
                     WHERE rc.BlobPath = k.BlobPath AND NOT (rc.SchemaName = k.SchemaName AND rc.TableName = k.TableName))
          OR EXISTS (SELECT 1 FROM #Chk AS o
                     WHERE o.BlobPath = k.BlobPath AND NOT (o.SchemaName = k.SchemaName AND o.TableName = k.TableName))
             THEN N'V-06: BlobPath ' + k.BlobPath + N' already used by another table'
        WHEN k.BadTypes IS NOT NULL THEN LEFT(N'V-08: column types not supported for Parquet: ' + k.BadTypes, 400)
        WHEN k.DupParquetNames IS NOT NULL THEN LEFT(N'V-08: Parquet column names not unique after renaming: ' + k.DupParquetNames, 400)
        WHEN k.InitialCutoffMethod NOT IN ('BATCH_DELETE', 'TABLE_REBUILD') THEN N'Invalid InitialCutoffMethod'
        WHEN k.SizeCategory NOT IN ('SMALL', 'MEDIUM', 'LARGE') THEN N'Invalid SizeCategory'
        WHEN k.ExportParallelism IS NOT NULL AND @HasExportPar = 0 THEN N'ExportParallelism given but opsi B column not deployed'
        WHEN k.ExportParallelism IS NOT NULL AND k.ExportParallelism NOT BETWEEN 1 AND 16 THEN N'ExportParallelism must be 1..16'
        WHEN k.ExistingParentId IS NOT NULL
             THEN N'Registered as CHILD table (TableConfigId ' + CONVERT(NVARCHAR(10), k.ExistingConfigId)
                  + N') - not changed; use test/93_insert_header_child_config.sql'
        WHEN k.ChildYearsMismatch IS NOT NULL
             THEN LEFT(N'DBR-20: header of child tables with other retention years: ' + k.ChildYearsMismatch, 400)
        WHEN k.ExistingConfigId IS NOT NULL AND (ISNULL(k.ExistingStatus, 'PENDING') <> 'PENDING' OR k.HasArchiveFiles = 1)
             THEN N'Already registered and archiving started (status ' + ISNULL(k.ExistingStatus, N'?')
                  + N') - not changed; reset with test/91_reset_table_for_retest.sql'
        END
  FROM #Chk AS k;

SELECT k.SchemaName, k.TableName, k.RetentionColumn, k.ColumnType, k.UsedSpaceMB, k.SizeCategory, k.InitialCutoffMethod,
       k.DwhRetentionYears, k.BlobRetentionYears, k.LogRetentionYears, k.BlobPath, k.ExportParallelism,
       k.NullDates, k.HasDateIndex, k.ExistingConfigId, k.ExistingStatus,
       CASE WHEN k.Problem IS NOT NULL THEN N'NOT APPLIED: ' + k.Problem
            WHEN k.ExistingConfigId IS NULL THEN N'INSERT'
            ELSE N'UPDATE (status PENDING, no archive file)' END AS Action,
       CASE WHEN k.SizeCategory = 'LARGE' THEN N'LARGE: needs DowntimeReference; runs after all SMALL / MEDIUM are COMPLETED. ' ELSE N'' END
       + CASE WHEN k.HasDateIndex = 0 AND k.SizeCategory IN ('MEDIUM', 'LARGE') THEN N'No index on the retention column.' ELSE N'' END AS Note
FROM #Chk AS k
ORDER BY k.SchemaName, k.TableName;

/* -------------------------------------------------------------------------------------
   2. Apply
   ------------------------------------------------------------------------------------- */
IF @Apply = 1
BEGIN
    BEGIN TRANSACTION;

    INSERT INTO ret.RetentionConfig
        (SchemaName, TableName, RetentionColumn, ParentTableConfigId, DwhRetentionYears, BlobRetentionYears, LogRetentionYears,
         BlobPath, InitialCutoffMethod, IsActive, SizeCategory)
    SELECT k.SchemaName, k.TableName, k.RetentionColumn, NULL, k.DwhRetentionYears, k.BlobRetentionYears, k.LogRetentionYears,
           k.BlobPath, k.InitialCutoffMethod, @IsActive, k.SizeCategory
    FROM #Chk AS k
    WHERE k.Problem IS NULL AND k.ExistingConfigId IS NULL;

    UPDATE rc
       SET RetentionColumn = k.RetentionColumn, DwhRetentionYears = k.DwhRetentionYears, BlobRetentionYears = k.BlobRetentionYears,
           LogRetentionYears = k.LogRetentionYears, BlobPath = k.BlobPath, InitialCutoffMethod = k.InitialCutoffMethod,
           SizeCategory = k.SizeCategory, IsActive = @IsActive,
           ModifiedBy = ORIGINAL_LOGIN(), ModifiedAt = DATEADD(HOUR, 7, SYSUTCDATETIME())
      FROM ret.RetentionConfig AS rc
      JOIN #Chk AS k ON k.ExistingConfigId = rc.TableConfigId
     WHERE k.Problem IS NULL;

    -- opsi B: per-table export parallelism (NULL = global value)
    IF @HasExportPar = 1
        EXEC sp_executesql N'UPDATE rc SET ExportParallelism = k.ExportParallelism
                             FROM ret.RetentionConfig AS rc
                             JOIN #Chk AS k ON k.SchemaName = rc.SchemaName AND k.TableName = rc.TableName
                             WHERE k.Problem IS NULL;';

    COMMIT TRANSACTION;

    SELECT rc.TableConfigId, rc.SchemaName, rc.TableName, rc.RetentionColumn, rc.SizeCategory, rc.InitialCutoffMethod,
           rc.DwhRetentionYears, rc.BlobRetentionYears, rc.LogRetentionYears, rc.BlobPath, rc.IsActive, s.InitialCutoffStatus
    FROM ret.RetentionConfig AS rc
    JOIN #Chk AS k ON k.SchemaName = rc.SchemaName AND k.TableName = rc.TableName
    LEFT JOIN ret.RetentionTableStatus AS s ON s.TableConfigId = rc.TableConfigId
    WHERE k.Problem IS NULL
    ORDER BY rc.TableConfigId;

    -- TableConfigIdList for the ADF parameter of PL_RETB_01 (Initial Cut-off), e.g. "36,41"
    SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), rc.TableConfigId), N',') WITHIN GROUP (ORDER BY rc.TableConfigId) AS TableConfigIdList
    FROM ret.RetentionConfig AS rc
    JOIN #Chk AS k ON k.SchemaName = rc.SchemaName AND k.TableName = rc.TableName
    WHERE k.Problem IS NULL;
END
ELSE
    SELECT N'Preview only (@Apply = 0). Nothing changed. Check the Action column, then set @Apply = 1.' AS Result;

DROP TABLE #Chk;
GO
