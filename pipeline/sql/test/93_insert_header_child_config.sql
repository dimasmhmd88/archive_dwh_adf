/* =====================================================================================
   DWH Data Retention and Archiving - register a HEADER table and its CHILD (detail) table
   -------------------------------------------------------------------------------------
   Script  : pipeline/sql/test/93_insert_header_child_config.sql   Version 0.1 (DRAFT, not executed)   26 November 2026
   Example : header bos.BOS_SD_FDo (date column dtmDelivery)  <-  child bos.BOS_SD_FDoItem (join key szdoId)
             (values from List Table DWH.xlsx as used in config v0.1; check them with block 1)
   Requires: SQL v0.6 or later.

   How a child table works (FR-023): the child has NO own date column. Its business date is the date of the
   header row found through the join key(s) in ret.RetentionParentKey. Rules:
     DBR-20  one level only; header has its own date column and the SAME retention years as the child
     V-10/11 key columns exist in both tables with compatible types; key unique in the header
     DBR-18  Initial Cut-off: the child must be COMPLETED first, or be listed BEFORE the header in
             TableConfigIdList (e.g. "<child>,<header>")
     DBR-21  child rows without header row (orphans) are never archived or deleted
     MD-05   child tables are out of go-live phase 1 (FSD v1.1): activating them is a scope decision

   Order: block 1 (checks, read-only) -> set @Apply = 1 -> block 2 inserts/aligns header, child and key in
   one transaction. Re-runnable. Rows whose archiving already started are not changed.
   ===================================================================================== */
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @Apply          BIT          = 0;                  -- 0 = checks only, 1 = insert / align
DECLARE @IsActive       BIT          = 1;                  -- MD-05: 0 = registered but not processed

DECLARE @HdrSchema      SYSNAME      = N'bos';
DECLARE @HdrTable       SYSNAME      = N'BOS_SD_FDo';
DECLARE @HdrDateColumn  SYSNAME      = N'dtmDelivery';     -- business date of header AND child rows

DECLARE @ChdSchema      SYSNAME      = N'bos';
DECLARE @ChdTable       SYSNAME      = N'BOS_SD_FDoItem';

DECLARE @Keys TABLE (KeyOrdinal TINYINT PRIMARY KEY, ChildColumn SYSNAME, ParentColumn SYSNAME);
INSERT INTO @Keys VALUES (1, N'szdoId', N'szdoId');        -- add rows for a composite key: (2, N'..', N'..')

DECLARE @DwhYears SMALLINT = 3, @BlobYears SMALLINT = 5, @LogYears SMALLINT = 3;   -- must be equal for header and child
DECLARE @Method VARCHAR(20) = 'BATCH_DELETE';

/* =====================================================================================
   1. CHECKS (read-only)
   ===================================================================================== */
DECLARE @HdrObj INT = OBJECT_ID(QUOTENAME(@HdrSchema) + N'.' + QUOTENAME(@HdrTable), N'U');
DECLARE @ChdObj INT = OBJECT_ID(QUOTENAME(@ChdSchema) + N'.' + QUOTENAME(@ChdTable), N'U');
DECLARE @Check TABLE (Ord INT IDENTITY, CheckName NVARCHAR(200), Result NVARCHAR(20), Detail NVARCHAR(1000));

-- 1a. tables
INSERT INTO @Check SELECT N'Header table exists', CASE WHEN @HdrObj IS NULL THEN 'ERROR' ELSE 'OK' END, @HdrSchema + N'.' + @HdrTable;
INSERT INTO @Check SELECT N'Child table exists',  CASE WHEN @ChdObj IS NULL THEN 'ERROR' ELSE 'OK' END, @ChdSchema + N'.' + @ChdTable;

-- 1b. header date column (V-02 / V-03)
INSERT INTO @Check
SELECT N'Header date column ' + @HdrDateColumn,
       CASE WHEN c.column_id IS NULL THEN 'ERROR' WHEN t.name IN (N'date', N'datetime', N'datetime2', N'smalldatetime') THEN 'OK' ELSE 'ERROR' END,
       CASE WHEN c.column_id IS NULL THEN N'column not found' ELSE CONCAT(N'type ', t.name, N', nullable ', c.is_nullable) END
FROM (SELECT 1 AS x) AS one
LEFT JOIN sys.columns AS c ON c.object_id = @HdrObj AND c.name = @HdrDateColumn
LEFT JOIN sys.types AS t ON t.user_type_id = c.user_type_id;

-- 1c. join keys (V-10). NULL values of the header date column (V-04) are checked by the dry run (usp_BeginTable).
INSERT INTO @Check
SELECT CONCAT(N'Key ', k.KeyOrdinal, N': ', k.ChildColumn, N' = ', k.ParentColumn),
       CASE WHEN cc.column_id IS NULL OR pc.column_id IS NULL THEN 'ERROR'
            WHEN ISNULL(cc.collation_name COLLATE DATABASE_DEFAULT, N'') <> ISNULL(pc.collation_name COLLATE DATABASE_DEFAULT, N'') THEN 'ERROR'
            WHEN TYPE_NAME(cc.system_type_id) <> TYPE_NAME(pc.system_type_id) OR cc.max_length <> pc.max_length THEN 'WARNING'
            ELSE 'OK' END,
       CONCAT(N'child ', ISNULL(TYPE_NAME(cc.system_type_id), N'NOT FOUND'), N'(', cc.max_length, N') / header ',
              ISNULL(TYPE_NAME(pc.system_type_id), N'NOT FOUND'), N'(', pc.max_length, N')',
              CASE WHEN ISNULL(cc.collation_name COLLATE DATABASE_DEFAULT, N'') <> ISNULL(pc.collation_name COLLATE DATABASE_DEFAULT, N'') THEN N' - different collations' ELSE N'' END)
FROM @Keys AS k
LEFT JOIN sys.columns AS cc ON cc.object_id = @ChdObj AND cc.name COLLATE DATABASE_DEFAULT = k.ChildColumn
LEFT JOIN sys.columns AS pc ON pc.object_id = @HdrObj AND pc.name COLLATE DATABASE_DEFAULT = k.ParentColumn;

-- 1d. key unique in the header (V-11): unique index / primary key on exactly the key columns
INSERT INTO @Check
SELECT N'Unique index on the header key (V-11)',
       CASE WHEN x.name IS NULL THEN 'WARNING' ELSE 'OK' END,
       ISNULL(N'index ' + x.name, N'no unique index on exactly the key columns: the pipeline counts duplicates (full scan); check with monitoring/32')
FROM (SELECT 1 AS one) AS o
OUTER APPLY (SELECT TOP (1) i.name FROM sys.indexes AS i
             WHERE i.object_id = @HdrObj AND i.is_unique = 1 AND i.has_filter = 0 AND i.is_disabled = 0
               AND NOT EXISTS (SELECT 1 FROM sys.index_columns AS ic JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                               WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.key_ordinal > 0
                                 AND NOT EXISTS (SELECT 1 FROM @Keys AS k WHERE k.ParentColumn = c.name COLLATE DATABASE_DEFAULT))
               AND (SELECT COUNT(*) FROM sys.index_columns AS ic WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.key_ordinal > 0)
                   = (SELECT COUNT(*) FROM @Keys)) AS x;

-- 1e. foreign key child -> header in the database (information)
INSERT INTO @Check
SELECT N'Foreign key child -> header', CASE WHEN COUNT(*) = 0 THEN 'INFO' ELSE 'OK' END,
       CASE WHEN COUNT(*) = 0 THEN N'none (keys only from ret.RetentionParentKey)'
            ELSE STRING_AGG(CONVERT(NVARCHAR(MAX), fk.name) COLLATE DATABASE_DEFAULT, N', ') END
FROM sys.foreign_keys AS fk WHERE fk.parent_object_id = @ChdObj AND fk.referenced_object_id = @HdrObj;

-- 1f. size category from used space (SMALL <= 500 MB, MEDIUM <= 5 GB, LARGE > 5 GB)
DECLARE @HdrMB DECIMAL(18, 2), @ChdMB DECIMAL(18, 2);
SELECT @HdrMB = SUM(CONVERT(BIGINT, au.used_pages)) * 8 / 1024.0
FROM sys.partitions AS p JOIN sys.allocation_units AS au ON au.container_id = CASE WHEN au.type IN (1, 3) THEN p.hobt_id ELSE p.partition_id END
WHERE p.object_id = @HdrObj;
SELECT @ChdMB = SUM(CONVERT(BIGINT, au.used_pages)) * 8 / 1024.0
FROM sys.partitions AS p JOIN sys.allocation_units AS au ON au.container_id = CASE WHEN au.type IN (1, 3) THEN p.hobt_id ELSE p.partition_id END
WHERE p.object_id = @ChdObj;
DECLARE @HdrSize VARCHAR(10) = CASE WHEN ISNULL(@HdrMB, 0) <= 500 THEN 'SMALL' WHEN @HdrMB <= 5120 THEN 'MEDIUM' ELSE 'LARGE' END;
DECLARE @ChdSize VARCHAR(10) = CASE WHEN ISNULL(@ChdMB, 0) <= 500 THEN 'SMALL' WHEN @ChdMB <= 5120 THEN 'MEDIUM' ELSE 'LARGE' END;
INSERT INTO @Check SELECT N'Size header / child', 'INFO', CONCAT(@HdrMB, N' MB ', @HdrSize, N' / ', @ChdMB, N' MB ', @ChdSize,
       CASE WHEN 'LARGE' IN (@HdrSize, @ChdSize) THEN N' - LARGE: Initial Cut-off needs DowntimeReference and all SMALL/MEDIUM tables COMPLETED' ELSE N'' END);

-- 1g. existing configuration
INSERT INTO @Check
SELECT N'Existing config ' + c.SchemaName + N'.' + c.TableName,
       CASE WHEN s.InitialCutoffStatus IN ('RUNNING', 'COMPLETED')
                 OR EXISTS (SELECT 1 FROM ret.RetentionArchiveDate AS a WHERE a.TableConfigId = c.TableConfigId AND a.ExportStatus <> 'REMOVED')
            THEN 'WARNING' ELSE 'INFO' END,
       CONCAT(N'TableConfigId ', c.TableConfigId, N', ParentTableConfigId ', ISNULL(CONVERT(NVARCHAR(10), c.ParentTableConfigId), N'NULL'),
              N', RetentionColumn ', ISNULL(c.RetentionColumn, N'NULL'), N', IsActive ', c.IsActive, N', IC status ', s.InitialCutoffStatus)
FROM ret.RetentionConfig AS c
JOIN ret.RetentionTableStatus AS s ON s.TableConfigId = c.TableConfigId
WHERE (c.SchemaName = @HdrSchema AND c.TableName = @HdrTable) OR (c.SchemaName = @ChdSchema AND c.TableName = @ChdTable);

-- 1h. other configured tables that already use this header or this child as header (DBR-20: one level)
INSERT INTO @Check
SELECT N'Child table is header of another table', 'ERROR', g.SchemaName + N'.' + g.TableName
FROM ret.RetentionConfig AS g
JOIN ret.RetentionConfig AS p ON p.TableConfigId = g.ParentTableConfigId
WHERE p.SchemaName = @ChdSchema AND p.TableName = @ChdTable;

SELECT Ord, CheckName, Result, Detail FROM @Check ORDER BY Ord;

/* =====================================================================================
   2. INSERT / ALIGN (only with @Apply = 1 and no ERROR in block 1)
   ===================================================================================== */
IF @Apply = 1
BEGIN
    IF EXISTS (SELECT 1 FROM @Check WHERE Result = 'ERROR')
    BEGIN
        ;THROW 50931, N'Block 1 reports ERROR rows; nothing changed.', 1;
    END;

    DECLARE @HdrId INT, @ChdId INT, @HdrBlob NVARCHAR(400) = LOWER(@HdrSchema + N'.' + @HdrTable),
            @ChdBlob NVARCHAR(400) = LOWER(@ChdSchema + N'.' + @ChdTable);

    BEGIN TRANSACTION;

    -- header (own date column)
    SELECT @HdrId = TableConfigId FROM ret.RetentionConfig WHERE SchemaName = @HdrSchema AND TableName = @HdrTable;
    IF @HdrId IS NULL
    BEGIN
        INSERT INTO ret.RetentionConfig (SchemaName, TableName, RetentionColumn, ParentTableConfigId, DwhRetentionYears,
                                         BlobRetentionYears, LogRetentionYears, BlobPath, InitialCutoffMethod, IsActive, SizeCategory)
        VALUES (@HdrSchema, @HdrTable, @HdrDateColumn, NULL, @DwhYears, @BlobYears, @LogYears, @HdrBlob, @Method, @IsActive, @HdrSize);
        SET @HdrId = SCOPE_IDENTITY();
    END
    ELSE
        UPDATE c SET RetentionColumn = @HdrDateColumn, ParentTableConfigId = NULL, DwhRetentionYears = @DwhYears,
                     BlobRetentionYears = @BlobYears, BlobPath = @HdrBlob, SizeCategory = @HdrSize, IsActive = @IsActive
        FROM ret.RetentionConfig AS c JOIN ret.RetentionTableStatus AS s ON s.TableConfigId = c.TableConfigId
        WHERE c.TableConfigId = @HdrId AND s.InitialCutoffStatus = 'PENDING'
          AND NOT EXISTS (SELECT 1 FROM ret.RetentionArchiveDate AS a WHERE a.TableConfigId = c.TableConfigId AND a.ExportStatus <> 'REMOVED');

    -- child (no own date column, ParentTableConfigId = header)
    SELECT @ChdId = TableConfigId FROM ret.RetentionConfig WHERE SchemaName = @ChdSchema AND TableName = @ChdTable;
    IF @ChdId IS NULL
    BEGIN
        INSERT INTO ret.RetentionConfig (SchemaName, TableName, RetentionColumn, ParentTableConfigId, DwhRetentionYears,
                                         BlobRetentionYears, LogRetentionYears, BlobPath, InitialCutoffMethod, IsActive, SizeCategory)
        VALUES (@ChdSchema, @ChdTable, NULL, @HdrId, @DwhYears, @BlobYears, @LogYears, @ChdBlob, @Method, @IsActive, @ChdSize);
        SET @ChdId = SCOPE_IDENTITY();
    END
    ELSE
        UPDATE c SET RetentionColumn = NULL, ParentTableConfigId = @HdrId, DwhRetentionYears = @DwhYears,
                     BlobRetentionYears = @BlobYears, BlobPath = @ChdBlob, SizeCategory = @ChdSize, IsActive = @IsActive
        FROM ret.RetentionConfig AS c JOIN ret.RetentionTableStatus AS s ON s.TableConfigId = c.TableConfigId
        WHERE c.TableConfigId = @ChdId AND s.InitialCutoffStatus = 'PENDING'
          AND NOT EXISTS (SELECT 1 FROM ret.RetentionArchiveDate AS a WHERE a.TableConfigId = c.TableConfigId AND a.ExportStatus <> 'REMOVED');

    -- join keys (replaced only while the child has not started archiving; trigger trg_RetentionParentKey_Protect)
    IF NOT EXISTS (SELECT 1 FROM ret.RetentionParentKey AS k
                   WHERE k.TableConfigId = @ChdId
                     AND NOT EXISTS (SELECT 1 FROM @Keys AS n WHERE n.KeyOrdinal = k.KeyOrdinal AND n.ChildColumn = k.ChildColumn AND n.ParentColumn = k.ParentColumn))
       AND (SELECT COUNT(*) FROM ret.RetentionParentKey WHERE TableConfigId = @ChdId) = (SELECT COUNT(*) FROM @Keys)
        PRINT 'Join keys already registered.';
    ELSE
    BEGIN
        DELETE FROM ret.RetentionParentKey WHERE TableConfigId = @ChdId;
        INSERT INTO ret.RetentionParentKey (TableConfigId, KeyOrdinal, ChildColumn, ParentColumn)
        SELECT @ChdId, KeyOrdinal, ChildColumn, ParentColumn FROM @Keys;
    END;

    COMMIT TRANSACTION;

    -- result
    SELECT c.TableConfigId, c.SchemaName, c.TableName, c.RetentionColumn, c.ParentTableConfigId, c.SizeCategory,
           c.InitialCutoffMethod, c.IsActive, c.BlobPath, s.InitialCutoffStatus,
           CASE WHEN c.ParentTableConfigId IS NULL THEN N'HEADER' ELSE N'CHILD' END AS Role
    FROM ret.RetentionConfig AS c JOIN ret.RetentionTableStatus AS s ON s.TableConfigId = c.TableConfigId
    WHERE c.TableConfigId IN (@HdrId, @ChdId)
    ORDER BY CASE WHEN c.ParentTableConfigId IS NULL THEN 1 ELSE 0 END;
    SELECT * FROM ret.RetentionParentKey WHERE TableConfigId = @ChdId ORDER BY KeyOrdinal;
    SELECT CONCAT(@ChdId, N',', @HdrId) AS TableConfigIdList_ChildFirst;   -- for PL_RET(B)_01 (DBR-18)
END
ELSE
    SELECT N'Checks only (@Apply = 0). Nothing changed.' AS Result;
GO
