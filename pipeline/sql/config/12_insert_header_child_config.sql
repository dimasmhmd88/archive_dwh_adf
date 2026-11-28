/* =====================================================================================
   DWH Data Retention and Archiving - register HEADER + CHILD (detail) tables
   -------------------------------------------------------------------------------------
   Script   : config/12_insert_header_child_config.sql   Version 0.1 (DRAFT - not executed against any database)
   Date     : 28 November 2026
   Requires : schema ret v0.6.1 (deploy/01..05 + 08)
   Scope    : one or more header tables, each with one or more child tables. A child table has NO own date
              column: its business date is the date of the header row found through the join keys
              (ret.RetentionParentKey, FR-023). Own-dated tables only: config/11_insert_table_config.sql.

   RULES APPLIED
     DBR-20  one level only (a child is never a header, a header is never a child); header and child have the
             SAME retention years (@DwhYears / @BlobYears / @LogYears below)
     V-01..V-04  tables exist; header date column date / datetime / datetime2 / smalldatetime without NULL
     V-06    BlobPath lower-case <schema>.<table>, unique
     V-08    Parquet: no sql_variant / CLR column, column names unique after renaming (D-6)
     V-10    join key columns exist in both tables, compatible types (string / integer / decimal / same type),
             same collation
     V-11    join key unique in the header (unique index on the key columns, otherwise duplicate count = full scan)
     Method  InitialCutoffMethod NULL = by size: SMALL / MEDIUM -> BATCH_DELETE, LARGE -> TABLE_REBUILD;
             RebuildBlockers lists what makes usp_TableRebuildPrepare refuse a rebuild (RB-01, ERR-RBD-04), e.g. a
             foreign key from the child to a LARGE header
     DBR-18  Initial Cut-off: list the child BEFORE its header in TableConfigIdList (the script returns the list)
     DBR-21  child rows without header row (orphans) are never archived or deleted (count shown as information)
     MD-05   child tables are out of go-live phase 1 (FSD v1.1): activating them is a scope decision

   BEHAVIOUR
     @Apply = 0 (default): checks and preview only, nothing changed.
     @Apply = 1          : one transaction. A header and all its children are applied together; when ONE of
                           them has an ERROR the whole group is skipped. Rows whose archiving already started
                           (status not PENDING or archive files exist) are not changed; join keys of such a child
                           cannot be changed (trigger trg_RetentionParentKey_Protect).
   ===================================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

/* -------------------------------------------------------------------------------------
   Settings - change here only
   ------------------------------------------------------------------------------------- */
DECLARE @Apply     BIT      = 0;        -- 0 = preview, 1 = insert / align
DECLARE @IsActive  BIT      = 1;        -- MD-05: 0 = registered but not processed
DECLARE @DwhYears  SMALLINT = 3;        -- same for header and child (DBR-20)
DECLARE @BlobYears SMALLINT = 5;
DECLARE @LogYears  SMALLINT = 3;

-- one row per CHILD table (repeat the header for a second child of the same header)
DECLARE @Pair TABLE
(
    HdrSchema       SYSNAME     NOT NULL,
    HdrTable        SYSNAME     NOT NULL,
    HdrDateColumn   SYSNAME     NOT NULL,       -- business date of header AND child rows
    ChdSchema       SYSNAME     NOT NULL,
    ChdTable        SYSNAME     NOT NULL,
    HdrSize         VARCHAR(10) NULL,           -- NULL = from used space (SMALL <= 500 MB, MEDIUM <= 5 GB, LARGE)
    ChdSize         VARCHAR(10) NULL,
    HdrMethod       VARCHAR(20) NULL,           -- NULL = by size (LARGE -> TABLE_REBUILD, else BATCH_DELETE)
    ChdMethod       VARCHAR(20) NULL,
    PRIMARY KEY (ChdSchema, ChdTable)
);

-- join keys per child: KeyOrdinal 1..n (composite key = several rows)
DECLARE @Keys TABLE
(
    ChdSchema       SYSNAME     NOT NULL,
    ChdTable        SYSNAME     NOT NULL,
    KeyOrdinal      TINYINT     NOT NULL,
    ChildColumn     SYSNAME     NOT NULL,
    ParentColumn    SYSNAME     NOT NULL,
    PRIMARY KEY (ChdSchema, ChdTable, KeyOrdinal)
);

-- <== header / child pairs
INSERT INTO @Pair (HdrSchema, HdrTable, HdrDateColumn, ChdSchema, ChdTable)
VALUES
    (N'schema1', N'HeaderTable1', N'HeaderDate', N'schema1', N'DetailTable1');
--  , (N'schema1', N'HeaderTable1', N'HeaderDate', N'schema1', N'DetailTable1b')    -- second child of the same header
--  , (N'schema2', N'HeaderTable2', N'TransDate',  N'schema2', N'DetailTable2')

-- <== join keys (child column = header column)
INSERT INTO @Keys (ChdSchema, ChdTable, KeyOrdinal, ChildColumn, ParentColumn)
VALUES
    (N'schema1', N'DetailTable1', 1, N'HeaderId', N'HeaderId');
--  , (N'schema2', N'DetailTable2', 1, N'DocNo',  N'DocNo')
--  , (N'schema2', N'DetailTable2', 2, N'Branch', N'Branch')                        -- composite key

/* -------------------------------------------------------------------------------------
   0. Prerequisites
   ------------------------------------------------------------------------------------- */
IF OBJECT_ID(N'ret.RetentionParentKey', N'U') IS NULL OR COL_LENGTH(N'ret.RetentionConfig', N'LogRetentionYears') IS NULL
BEGIN
    ;THROW 50981, N'Schema ret v0.6 not found. Deploy deploy/01..05 first.', 1;
END;
IF OBJECT_ID(N'ret.fn_ParquetColumnName', N'FN') IS NULL
BEGIN
    ;THROW 50982, N'ret.fn_ParquetColumnName not found. Deploy deploy/08_patch_v0.6.1_parquet_column_names.sql first.', 1;
END;

/* -------------------------------------------------------------------------------------
   1. Tables to register (one row per table and role)
   ------------------------------------------------------------------------------------- */
IF OBJECT_ID(N'tempdb..#T') IS NOT NULL DROP TABLE #T;
IF OBJECT_ID(N'tempdb..#Issue') IS NOT NULL DROP TABLE #Issue;

CREATE TABLE #T
(
    Role VARCHAR(6) NOT NULL,                      -- HEADER / CHILD
    SchemaName SYSNAME NOT NULL, TableName SYSNAME NOT NULL,
    GroupSchema SYSNAME NOT NULL, GroupTable SYSNAME NOT NULL,   -- the header of the group
    DateColumn SYSNAME NULL,                       -- header only
    ObjectId INT NULL, UsedSpaceMB DECIMAL(18, 2) NULL, SizeCategory VARCHAR(10) NULL,
    GivenMethod VARCHAR(20) NULL, InitialCutoffMethod VARCHAR(20) NULL, MethodSource VARCHAR(10) NULL,
    BlobPath NVARCHAR(400) NOT NULL,
    ExistingConfigId INT NULL, ExistingParentId INT NULL, ExistingColumn SYSNAME NULL,
    ExistingDwh SMALLINT NULL, ExistingBlob SMALLINT NULL, ExistingStatus VARCHAR(10) NULL,
    HasArchiveFiles BIT NOT NULL DEFAULT (0), Started BIT NOT NULL DEFAULT (0),
    RebuildBlockers NVARCHAR(MAX) NULL,
    PRIMARY KEY (SchemaName, TableName)
);
CREATE TABLE #Issue
(
    Ord INT IDENTITY(1, 1), SchemaName SYSNAME, TableName SYSNAME, Severity VARCHAR(7), CheckCode VARCHAR(10), Detail NVARCHAR(1000)
);

-- a table listed as header and as child at the same time (DBR-20)
INSERT INTO #Issue (SchemaName, TableName, Severity, CheckCode, Detail)
SELECT c.ChdSchema, c.ChdTable, 'ERROR', 'DBR-20', N'Listed as child and as header in @Pair (one level only)'
FROM @Pair AS c
WHERE EXISTS (SELECT 1 FROM @Pair AS h WHERE h.HdrSchema = c.ChdSchema AND h.HdrTable = c.ChdTable);

INSERT INTO #Issue (SchemaName, TableName, Severity, CheckCode, Detail)
SELECT p.ChdSchema, p.ChdTable, 'ERROR', 'V-10', N'Child table and header table are the same table'
FROM @Pair AS p WHERE p.ChdSchema = p.HdrSchema AND p.ChdTable = p.HdrTable;

-- header listed with different settings
INSERT INTO #Issue (SchemaName, TableName, Severity, CheckCode, Detail)
SELECT HdrSchema, HdrTable, 'ERROR', 'INPUT', N'Header listed with different HdrDateColumn / HdrSize / HdrMethod values'
FROM @Pair
GROUP BY HdrSchema, HdrTable
HAVING COUNT(DISTINCT HdrDateColumn) > 1 OR COUNT(DISTINCT ISNULL(HdrSize, '-')) > 1 OR COUNT(DISTINCT ISNULL(HdrMethod, '-')) > 1;

INSERT INTO #T (Role, SchemaName, TableName, GroupSchema, GroupTable, DateColumn, GivenMethod, SizeCategory, BlobPath)
SELECT 'HEADER', HdrSchema, HdrTable, HdrSchema, HdrTable, MIN(HdrDateColumn), MIN(HdrMethod), MIN(HdrSize),
       LOWER(HdrSchema + N'.' + HdrTable)
FROM @Pair
GROUP BY HdrSchema, HdrTable;

INSERT INTO #T (Role, SchemaName, TableName, GroupSchema, GroupTable, DateColumn, GivenMethod, SizeCategory, BlobPath)
SELECT 'CHILD', p.ChdSchema, p.ChdTable, p.HdrSchema, p.HdrTable, NULL, p.ChdMethod, p.ChdSize, LOWER(p.ChdSchema + N'.' + p.ChdTable)
FROM @Pair AS p
WHERE NOT EXISTS (SELECT 1 FROM #T AS t WHERE t.SchemaName = p.ChdSchema AND t.TableName = p.ChdTable);

-- object, used space, size category, method
UPDATE t
   SET ObjectId     = o.object_id,
       UsedSpaceMB  = CAST(sz.UsedPages * 8 / 1024.0 AS DECIMAL(18, 2)),
       SizeCategory = ISNULL(t.SizeCategory, CASE WHEN o.object_id IS NULL THEN NULL
                                                  WHEN sz.UsedPages * 8 / 1024.0 <= 500  THEN 'SMALL'
                                                  WHEN sz.UsedPages * 8 / 1024.0 <= 5120 THEN 'MEDIUM' ELSE 'LARGE' END)
  FROM #T AS t
  LEFT JOIN sys.tables AS o ON o.object_id = OBJECT_ID(QUOTENAME(t.SchemaName) + N'.' + QUOTENAME(t.TableName))
  OUTER APPLY (SELECT ISNULL(SUM(CONVERT(BIGINT, au.used_pages)), 0) AS UsedPages
               FROM sys.partitions AS p
               JOIN sys.allocation_units AS au
                 ON au.container_id = CASE WHEN au.type IN (1, 3) THEN p.hobt_id ELSE p.partition_id END
               WHERE p.object_id = o.object_id) AS sz;

UPDATE #T
   SET InitialCutoffMethod = ISNULL(GivenMethod, CASE SizeCategory WHEN 'LARGE' THEN 'TABLE_REBUILD'
                                                                   WHEN 'SMALL' THEN 'BATCH_DELETE' WHEN 'MEDIUM' THEN 'BATCH_DELETE' END),
       MethodSource = CASE WHEN GivenMethod IS NULL THEN 'BY_SIZE' ELSE 'MANUAL' END;

-- existing configuration
UPDATE t
   SET ExistingConfigId = rc.TableConfigId, ExistingParentId = rc.ParentTableConfigId, ExistingColumn = rc.RetentionColumn,
       ExistingDwh = rc.DwhRetentionYears, ExistingBlob = rc.BlobRetentionYears, ExistingStatus = s.InitialCutoffStatus,
       HasArchiveFiles = CASE WHEN EXISTS (SELECT 1 FROM ret.RetentionArchiveDate AS a
                                           WHERE a.TableConfigId = rc.TableConfigId AND a.ExportStatus <> 'REMOVED') THEN 1 ELSE 0 END
  FROM #T AS t
  JOIN ret.RetentionConfig AS rc ON rc.SchemaName = t.SchemaName AND rc.TableName = t.TableName
  LEFT JOIN ret.RetentionTableStatus AS s ON s.TableConfigId = rc.TableConfigId;

UPDATE #T SET Started = 1
 WHERE ExistingConfigId IS NOT NULL AND (ISNULL(ExistingStatus, 'PENDING') <> 'PENDING' OR HasArchiveFiles = 1);

/* -------------------------------------------------------------------------------------
   2. Checks
   ------------------------------------------------------------------------------------- */
-- V-01 tables
INSERT INTO #Issue (SchemaName, TableName, Severity, CheckCode, Detail)
SELECT SchemaName, TableName, 'ERROR', 'V-01', Role + N' table not found'
FROM #T WHERE ObjectId IS NULL;

-- V-02 / V-03 header date column
INSERT INTO #Issue (SchemaName, TableName, Severity, CheckCode, Detail)
SELECT t.SchemaName, t.TableName, 'ERROR', CASE WHEN c.column_id IS NULL THEN 'V-02' ELSE 'V-03' END,
       CASE WHEN c.column_id IS NULL THEN N'Date column ' + QUOTENAME(t.DateColumn) + N' not found'
            ELSE N'Date column ' + QUOTENAME(t.DateColumn) + N' has type ' + TYPE_NAME(c.system_type_id)
                 + N' (must be date / datetime / datetime2 / smalldatetime)' END
FROM #T AS t
LEFT JOIN sys.columns AS c ON c.object_id = t.ObjectId AND c.name COLLATE DATABASE_DEFAULT = t.DateColumn
WHERE t.Role = 'HEADER' AND t.ObjectId IS NOT NULL
  AND (c.column_id IS NULL OR TYPE_NAME(c.system_type_id) NOT IN ('date', 'datetime', 'datetime2', 'smalldatetime'));

-- V-04 NULL values in the header date column (only nullable columns are counted)
DECLARE @s SYSNAME, @t SYSNAME, @col SYSNAME, @n BIGINT, @sql NVARCHAR(MAX);
DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT t.SchemaName, t.TableName, t.DateColumn
    FROM #T AS t JOIN sys.columns AS c ON c.object_id = t.ObjectId AND c.name COLLATE DATABASE_DEFAULT = t.DateColumn
    WHERE t.Role = 'HEADER' AND c.is_nullable = 1 AND TYPE_NAME(c.system_type_id) IN ('date', 'datetime', 'datetime2', 'smalldatetime');
OPEN cur;
FETCH NEXT FROM cur INTO @s, @t, @col;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'SELECT @n = COUNT_BIG(*) FROM ' + QUOTENAME(@s) + N'.' + QUOTENAME(@t) + N' WHERE ' + QUOTENAME(@col) + N' IS NULL;';
    EXEC sp_executesql @sql, N'@n BIGINT OUTPUT', @n = @n OUTPUT;
    IF @n > 0
        INSERT INTO #Issue (SchemaName, TableName, Severity, CheckCode, Detail)
        VALUES (@s, @t, 'ERROR', 'V-04', CONCAT(@n, N' NULL values in date column ', QUOTENAME(@col)));
    FETCH NEXT FROM cur INTO @s, @t, @col;
END;
CLOSE cur; DEALLOCATE cur;

-- V-05 retention years
IF NOT (@DwhYears >= 1 AND @BlobYears >= 1 AND @LogYears >= 1)
    INSERT INTO #Issue (SchemaName, TableName, Severity, CheckCode, Detail)
    SELECT SchemaName, TableName, 'ERROR', 'V-05', N'DWH, archive and log retention must each be >= 1 year' FROM #T;

-- V-06 BlobPath unique
INSERT INTO #Issue (SchemaName, TableName, Severity, CheckCode, Detail)
SELECT t.SchemaName, t.TableName, 'ERROR', 'V-06', N'BlobPath ' + t.BlobPath + N' already used by ' + rc.SchemaName + N'.' + rc.TableName
FROM #T AS t
JOIN ret.RetentionConfig AS rc ON rc.BlobPath = t.BlobPath AND NOT (rc.SchemaName = t.SchemaName AND rc.TableName = t.TableName);

-- V-08 Parquet types and renamed column names
INSERT INTO #Issue (SchemaName, TableName, Severity, CheckCode, Detail)
SELECT t.SchemaName, t.TableName, 'ERROR', 'V-08', LEFT(N'Column types not supported for Parquet: ' + x.Bad, 1000)
FROM #T AS t
CROSS APPLY (SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), CONCAT(QUOTENAME(c.name COLLATE DATABASE_DEFAULT), N' (',
                               ty.name COLLATE DATABASE_DEFAULT, N')')) COLLATE DATABASE_DEFAULT, N', ') AS Bad
             FROM sys.columns AS c JOIN sys.types AS ty ON ty.user_type_id = c.user_type_id
             WHERE c.object_id = t.ObjectId AND (TYPE_NAME(c.system_type_id) = 'sql_variant' OR ty.is_assembly_type = 1)) AS x
WHERE t.ObjectId IS NOT NULL AND x.Bad IS NOT NULL;

INSERT INTO #Issue (SchemaName, TableName, Severity, CheckCode, Detail)
SELECT t.SchemaName, t.TableName, 'ERROR', 'V-08', LEFT(N'Parquet column names not unique after renaming (D-6): ' + x.Dup, 1000)
FROM #T AS t
CROSS APPLY (SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), QUOTENAME(d.ParquetColumn)) COLLATE DATABASE_DEFAULT, N', ') AS Dup
             FROM (SELECT ISNULL(ret.fn_ParquetColumnName(c.name), CONCAT(N'column_', c.column_id)) COLLATE Latin1_General_CI_AS AS ParquetColumn
                   FROM sys.columns AS c WHERE c.object_id = t.ObjectId
                   GROUP BY ISNULL(ret.fn_ParquetColumnName(c.name), CONCAT(N'column_', c.column_id)) COLLATE Latin1_General_CI_AS
                   HAVING COUNT(*) > 1) AS d) AS x
WHERE t.ObjectId IS NOT NULL AND x.Dup IS NOT NULL;

-- method and size
INSERT INTO #Issue (SchemaName, TableName, Severity, CheckCode, Detail)
SELECT SchemaName, TableName, 'ERROR', 'INPUT', N'Invalid SizeCategory or InitialCutoffMethod'
FROM #T
WHERE ObjectId IS NOT NULL
  AND (ISNULL(SizeCategory, '') NOT IN ('SMALL', 'MEDIUM', 'LARGE') OR ISNULL(InitialCutoffMethod, '') NOT IN ('BATCH_DELETE', 'TABLE_REBUILD'));

-- V-10 join keys
INSERT INTO #Issue (SchemaName, TableName, Severity, CheckCode, Detail)
SELECT t.SchemaName, t.TableName, 'ERROR', 'V-10', N'No join keys in @Keys'
FROM #T AS t
WHERE t.Role = 'CHILD' AND NOT EXISTS (SELECT 1 FROM @Keys AS k WHERE k.ChdSchema = t.SchemaName AND k.ChdTable = t.TableName);

INSERT INTO #Issue (SchemaName, TableName, Severity, CheckCode, Detail)
SELECT k.ChdSchema, k.ChdTable, 'ERROR', 'INPUT', N'Keys given for a table that is not a child in @Pair'
FROM @Keys AS k
WHERE NOT EXISTS (SELECT 1 FROM @Pair AS p WHERE p.ChdSchema = k.ChdSchema AND p.ChdTable = k.ChdTable)
GROUP BY k.ChdSchema, k.ChdTable;

INSERT INTO #Issue (SchemaName, TableName, Severity, CheckCode, Detail)
SELECT k.ChdSchema, k.ChdTable, 'ERROR', 'INPUT', N'KeyOrdinal must be 1..n without gaps'
FROM @Keys AS k
GROUP BY k.ChdSchema, k.ChdTable
HAVING MIN(k.KeyOrdinal) <> 1 OR MAX(k.KeyOrdinal) <> COUNT(*);

INSERT INTO #Issue (SchemaName, TableName, Severity, CheckCode, Detail)
SELECT ch.SchemaName, ch.TableName, x.Severity, 'V-10',
       CONCAT(N'Key ', k.KeyOrdinal, N' ', k.ChildColumn, N' = ', k.ParentColumn, N': ', x.Problem)
FROM #T AS ch
JOIN #T AS hd ON hd.Role = 'HEADER' AND hd.SchemaName = ch.GroupSchema AND hd.TableName = ch.GroupTable
JOIN @Keys AS k ON k.ChdSchema = ch.SchemaName AND k.ChdTable = ch.TableName
LEFT JOIN sys.columns AS cc ON cc.object_id = ch.ObjectId AND cc.name COLLATE DATABASE_DEFAULT = k.ChildColumn
LEFT JOIN sys.columns AS pc ON pc.object_id = hd.ObjectId AND pc.name COLLATE DATABASE_DEFAULT = k.ParentColumn
CROSS APPLY (SELECT
        CASE WHEN TYPE_NAME(cc.system_type_id) IN ('char', 'varchar', 'nchar', 'nvarchar') THEN 'STRING'
             WHEN TYPE_NAME(cc.system_type_id) IN ('tinyint', 'smallint', 'int', 'bigint') THEN 'INTEGER'
             WHEN TYPE_NAME(cc.system_type_id) IN ('decimal', 'numeric') THEN 'DECIMAL'
             ELSE TYPE_NAME(cc.system_type_id) END COLLATE DATABASE_DEFAULT AS CF,
        CASE WHEN TYPE_NAME(pc.system_type_id) IN ('char', 'varchar', 'nchar', 'nvarchar') THEN 'STRING'
             WHEN TYPE_NAME(pc.system_type_id) IN ('tinyint', 'smallint', 'int', 'bigint') THEN 'INTEGER'
             WHEN TYPE_NAME(pc.system_type_id) IN ('decimal', 'numeric') THEN 'DECIMAL'
             ELSE TYPE_NAME(pc.system_type_id) END COLLATE DATABASE_DEFAULT AS PF) AS f
CROSS APPLY (SELECT
        CASE WHEN cc.column_id IS NULL THEN 'ERROR' WHEN pc.column_id IS NULL THEN 'ERROR'
             WHEN f.CF <> f.PF THEN 'ERROR'
             WHEN ISNULL(cc.collation_name COLLATE DATABASE_DEFAULT, N'') <> ISNULL(pc.collation_name COLLATE DATABASE_DEFAULT, N'') THEN 'ERROR'
             WHEN TYPE_NAME(cc.system_type_id) <> TYPE_NAME(pc.system_type_id) OR cc.max_length <> pc.max_length THEN 'WARNING'
        END AS Severity,
        CASE WHEN cc.column_id IS NULL THEN N'child column not found'
             WHEN pc.column_id IS NULL THEN N'header column not found'
             WHEN f.CF <> f.PF THEN CONCAT(N'incompatible types ', TYPE_NAME(cc.system_type_id), N' / ', TYPE_NAME(pc.system_type_id))
             WHEN ISNULL(cc.collation_name COLLATE DATABASE_DEFAULT, N'') <> ISNULL(pc.collation_name COLLATE DATABASE_DEFAULT, N'')
                  THEN CONCAT(N'different collations ', cc.collation_name COLLATE DATABASE_DEFAULT, N' / ', pc.collation_name COLLATE DATABASE_DEFAULT)
             ELSE CONCAT(N'different type or length ', TYPE_NAME(cc.system_type_id), N'(', cc.max_length, N') / ',
                         TYPE_NAME(pc.system_type_id), N'(', pc.max_length, N') - allowed, check the values')
        END AS Problem) AS x
WHERE ch.Role = 'CHILD' AND ch.ObjectId IS NOT NULL AND hd.ObjectId IS NOT NULL AND x.Severity IS NOT NULL;

-- V-11 join key unique in the header: unique index whose key columns are all join key columns, else duplicate count
DECLARE @cs SYSNAME, @ct SYSNAME, @hs SYSNAME, @ht SYSNAME, @hObj INT, @KeyList NVARCHAR(MAX), @Dup BIGINT;
DECLARE curk CURSOR LOCAL FAST_FORWARD FOR
    SELECT ch.SchemaName, ch.TableName, hd.SchemaName, hd.TableName, hd.ObjectId
    FROM #T AS ch JOIN #T AS hd ON hd.Role = 'HEADER' AND hd.SchemaName = ch.GroupSchema AND hd.TableName = ch.GroupTable
    WHERE ch.Role = 'CHILD' AND ch.ObjectId IS NOT NULL AND hd.ObjectId IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM #Issue AS i WHERE i.SchemaName = ch.SchemaName AND i.TableName = ch.TableName
                                                 AND i.CheckCode = 'V-10' AND i.Severity = 'ERROR');
OPEN curk;
FETCH NEXT FROM curk INTO @cs, @ct, @hs, @ht, @hObj;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.indexes AS i
                   WHERE i.object_id = @hObj AND i.is_unique = 1 AND i.has_filter = 0 AND i.is_disabled = 0 AND i.is_hypothetical = 0
                     AND NOT EXISTS (SELECT 1 FROM sys.index_columns AS ic
                                     JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                                     WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.key_ordinal > 0
                                       AND NOT EXISTS (SELECT 1 FROM @Keys AS k
                                                       WHERE k.ChdSchema = @cs AND k.ChdTable = @ct
                                                         AND k.ParentColumn = c.name COLLATE DATABASE_DEFAULT)))
    BEGIN
        SELECT @KeyList = STRING_AGG(CONVERT(NVARCHAR(MAX), QUOTENAME(ParentColumn)), N', ') WITHIN GROUP (ORDER BY KeyOrdinal)
        FROM @Keys WHERE ChdSchema = @cs AND ChdTable = @ct;
        SET @sql = N'SELECT @d = COUNT_BIG(*) FROM (SELECT ' + @KeyList + N' FROM ' + QUOTENAME(@hs) + N'.' + QUOTENAME(@ht)
                 + N' GROUP BY ' + @KeyList + N' HAVING COUNT_BIG(*) > 1) AS q;';
        EXEC sp_executesql @sql, N'@d BIGINT OUTPUT', @d = @Dup OUTPUT;
        INSERT INTO #Issue (SchemaName, TableName, Severity, CheckCode, Detail)
        VALUES (@cs, @ct, CASE WHEN @Dup > 0 THEN 'ERROR' ELSE 'WARNING' END, 'V-11',
                CASE WHEN @Dup > 0 THEN CONCAT(@Dup, N' duplicate join key values in header ', @hs, N'.', @ht, N' (', @KeyList, N')')
                     ELSE CONCAT(N'No unique index on the join key of ', @hs, N'.', @ht,
                                 N': no duplicates now, but every Initial Cut-off counts them (full scan). Recommended: unique index on (', @KeyList, N')') END);
    END;
    FETCH NEXT FROM curk INTO @cs, @ct, @hs, @ht, @hObj;
END;
CLOSE curk; DEALLOCATE curk;

-- DBR-20 with the existing configuration
INSERT INTO #Issue (SchemaName, TableName, Severity, CheckCode, Detail)
SELECT t.SchemaName, t.TableName, 'ERROR', 'DBR-20', N'Header table is already configured as a CHILD of TableConfigId '
       + CONVERT(NVARCHAR(10), t.ExistingParentId)
FROM #T AS t WHERE t.Role = 'HEADER' AND t.ExistingParentId IS NOT NULL;

INSERT INTO #Issue (SchemaName, TableName, Severity, CheckCode, Detail)
SELECT t.SchemaName, t.TableName, 'ERROR', 'DBR-20', N'Child table is the header of configured table ' + g.SchemaName + N'.' + g.TableName
FROM #T AS t
JOIN ret.RetentionConfig AS g ON g.ParentTableConfigId = t.ExistingConfigId
WHERE t.Role = 'CHILD';

INSERT INTO #Issue (SchemaName, TableName, Severity, CheckCode, Detail)
SELECT t.SchemaName, t.TableName, 'ERROR', 'DBR-20',
       CONCAT(N'Header archiving started with retention ', t.ExistingDwh, N' + ', t.ExistingBlob, N' years; @DwhYears / @BlobYears must be equal')
FROM #T AS t
WHERE t.Role = 'HEADER' AND t.Started = 1 AND (t.ExistingDwh <> @DwhYears OR t.ExistingBlob <> @BlobYears);

INSERT INTO #Issue (SchemaName, TableName, Severity, CheckCode, Detail)
SELECT t.SchemaName, t.TableName, 'ERROR', 'DBR-20',
       CONCAT(N'Other child ', ch.SchemaName, N'.', ch.TableName, N' of this header has retention ', ch.DwhRetentionYears, N' + ', ch.BlobRetentionYears, N' years')
FROM #T AS t
JOIN ret.RetentionConfig AS ch ON ch.ParentTableConfigId = t.ExistingConfigId
WHERE t.Role = 'HEADER' AND (ch.DwhRetentionYears <> @DwhYears OR ch.BlobRetentionYears <> @BlobYears)
  AND NOT EXISTS (SELECT 1 FROM #T AS x WHERE x.SchemaName = ch.SchemaName AND x.TableName = ch.TableName);

-- existing rows whose archiving started
INSERT INTO #Issue (SchemaName, TableName, Severity, CheckCode, Detail)
SELECT t.SchemaName, t.TableName,
       CASE WHEN t.Role = 'HEADER' AND t.ExistingColumn = t.DateColumn THEN 'WARNING'
            WHEN t.Role = 'CHILD' AND t.ExistingParentId = hd.ExistingConfigId AND hd.ExistingConfigId IS NOT NULL THEN 'WARNING'
            ELSE 'ERROR' END,
       'PRC-06',
       CONCAT(N'Archiving started (status ', ISNULL(t.ExistingStatus, N'?'), N', archive files ', t.HasArchiveFiles,
              N'): configuration not changed',
              CASE WHEN t.Role = 'HEADER' AND t.ExistingColumn <> t.DateColumn THEN N'; registered date column ' + ISNULL(t.ExistingColumn, N'NULL') + N' differs'
                   WHEN t.Role = 'CHILD' AND (hd.ExistingConfigId IS NULL OR ISNULL(t.ExistingParentId, -1) <> hd.ExistingConfigId)
                        THEN N'; registered with another header or as own-dated table' ELSE N'' END,
              N'. Reset with test/91_reset_table_for_retest.sql when this is a test.')
FROM #T AS t
LEFT JOIN #T AS hd ON hd.Role = 'HEADER' AND hd.SchemaName = t.GroupSchema AND hd.TableName = t.GroupTable
WHERE t.Started = 1;

INSERT INTO #Issue (SchemaName, TableName, Severity, CheckCode, Detail)
SELECT t.SchemaName, t.TableName, 'ERROR', 'PRC-06', N'Archiving of the child started and the registered join keys differ from @Keys'
FROM #T AS t
WHERE t.Role = 'CHILD' AND t.Started = 1
  AND (   EXISTS (SELECT 1 FROM ret.RetentionParentKey AS r
                  WHERE r.TableConfigId = t.ExistingConfigId
                    AND NOT EXISTS (SELECT 1 FROM @Keys AS k WHERE k.ChdSchema = t.SchemaName AND k.ChdTable = t.TableName
                                      AND k.KeyOrdinal = r.KeyOrdinal AND k.ChildColumn = r.ChildColumn AND k.ParentColumn = r.ParentColumn))
       OR (SELECT COUNT(*) FROM ret.RetentionParentKey AS r WHERE r.TableConfigId = t.ExistingConfigId)
          <> (SELECT COUNT(*) FROM @Keys AS k WHERE k.ChdSchema = t.SchemaName AND k.ChdTable = t.TableName));

INSERT INTO #Issue (SchemaName, TableName, Severity, CheckCode, Detail)
SELECT t.SchemaName, t.TableName, 'WARNING', 'CONFIG', N'Registered as own-dated table (RetentionColumn ' + t.ExistingColumn
       + N'); will be changed to a child table (RetentionColumn NULL)'
FROM #T AS t WHERE t.Role = 'CHILD' AND t.Started = 0 AND t.ExistingColumn IS NOT NULL;

-- RB-01 preview for TABLE_REBUILD (same list as ret.usp_TableRebuildPrepare)
UPDATE k
   SET RebuildBlockers = (
        SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), x.Reason) COLLATE DATABASE_DEFAULT, N'; ')
        FROM (
            SELECT CONCAT(N'referenced by foreign key ', QUOTENAME(fk.name COLLATE DATABASE_DEFAULT), N' of ',
                          QUOTENAME(OBJECT_SCHEMA_NAME(fk.parent_object_id)), N'.', QUOTENAME(OBJECT_NAME(fk.parent_object_id))) AS Reason
            FROM sys.foreign_keys AS fk WHERE fk.referenced_object_id = k.ObjectId
            UNION ALL
            SELECT CONCAT(N'referenced by schema-bound module ', QUOTENAME(OBJECT_SCHEMA_NAME(m.object_id)), N'.', QUOTENAME(OBJECT_NAME(m.object_id)))
            FROM sys.sql_expression_dependencies AS d JOIN sys.sql_modules AS m ON m.object_id = d.referencing_id
            WHERE d.referenced_id = k.ObjectId AND m.is_schema_bound = 1
            UNION ALL
            SELECT N'system-versioned temporal or history table' FROM sys.tables AS t WHERE t.object_id = k.ObjectId AND t.temporal_type <> 0
            UNION ALL
            SELECT N'memory-optimized table' FROM sys.tables AS t WHERE t.object_id = k.ObjectId AND t.is_memory_optimized = 1
            UNION ALL
            SELECT N'graph table' FROM sys.tables AS t WHERE t.object_id = k.ObjectId AND (t.is_node = 1 OR t.is_edge = 1)
            UNION ALL
            SELECT N'ledger table' FROM sys.tables AS t WHERE t.object_id = k.ObjectId AND t.ledger_type <> 0
            UNION ALL
            SELECT N'tracked by change data capture' FROM sys.tables AS t WHERE t.object_id = k.ObjectId AND t.is_tracked_by_cdc = 1
            UNION ALL
            SELECT N'change tracking enabled' FROM sys.change_tracking_tables AS ct WHERE ct.object_id = k.ObjectId
            UNION ALL
            SELECT N'replicated table' FROM sys.tables AS t WHERE t.object_id = k.ObjectId AND (t.is_replicated = 1 OR t.is_merge_published = 1)
            UNION ALL
            SELECT DISTINCT N'partitioned table' FROM sys.indexes AS i JOIN sys.data_spaces AS ds ON ds.data_space_id = i.data_space_id
            WHERE i.object_id = k.ObjectId AND ds.type = 'PS'
            UNION ALL
            SELECT CONCAT(N'rowversion column ', QUOTENAME(c.name COLLATE DATABASE_DEFAULT)) FROM sys.columns AS c
            WHERE c.object_id = k.ObjectId AND TYPE_NAME(c.system_type_id) = 'timestamp'
            UNION ALL
            SELECT CONCAT(N'GENERATED ALWAYS column ', QUOTENAME(c.name COLLATE DATABASE_DEFAULT)) FROM sys.columns AS c
            WHERE c.object_id = k.ObjectId AND c.generated_always_type <> 0
            UNION ALL
            SELECT CONCAT(N'sparse column or column set ', QUOTENAME(c.name COLLATE DATABASE_DEFAULT)) FROM sys.columns AS c
            WHERE c.object_id = k.ObjectId AND (c.is_sparse = 1 OR c.is_column_set = 1)
            UNION ALL
            SELECT CONCAT(N'masked column ', QUOTENAME(c.name COLLATE DATABASE_DEFAULT)) FROM sys.columns AS c
            WHERE c.object_id = k.ObjectId AND c.is_masked = 1
            UNION ALL
            SELECT CONCAT(N'encrypted column ', QUOTENAME(c.name COLLATE DATABASE_DEFAULT)) FROM sys.columns AS c
            WHERE c.object_id = k.ObjectId AND c.encryption_type IS NOT NULL
            UNION ALL
            SELECT CONCAT(N'typed xml column ', QUOTENAME(c.name COLLATE DATABASE_DEFAULT)) FROM sys.columns AS c
            WHERE c.object_id = k.ObjectId AND c.xml_collection_id <> 0
            UNION ALL
            SELECT CONCAT(N'index type ', i.type_desc COLLATE DATABASE_DEFAULT, N' ', QUOTENAME(i.name COLLATE DATABASE_DEFAULT)) FROM sys.indexes AS i
            WHERE i.object_id = k.ObjectId AND i.type NOT IN (0, 1, 2)
            UNION ALL
            SELECT N'full-text index' FROM sys.fulltext_indexes AS f WHERE f.object_id = k.ObjectId
            UNION ALL
            SELECT CONCAT(N'trigger without readable definition ', QUOTENAME(tr.name COLLATE DATABASE_DEFAULT))
            FROM sys.triggers AS tr LEFT JOIN sys.sql_modules AS m ON m.object_id = tr.object_id
            WHERE tr.parent_id = k.ObjectId AND m.definition COLLATE DATABASE_DEFAULT IS NULL
            UNION ALL
            SELECT CONCAT(N'NOT FOR REPLICATION constraint ', QUOTENAME(ck.name COLLATE DATABASE_DEFAULT)) FROM sys.check_constraints AS ck
            WHERE ck.parent_object_id = k.ObjectId AND ck.is_not_for_replication = 1
            UNION ALL
            SELECT CONCAT(N'NOT FOR REPLICATION constraint ', QUOTENAME(fk.name COLLATE DATABASE_DEFAULT)) FROM sys.foreign_keys AS fk
            WHERE fk.parent_object_id = k.ObjectId AND fk.is_not_for_replication = 1
        ) AS x)
  FROM #T AS k
 WHERE k.ObjectId IS NOT NULL AND k.InitialCutoffMethod = 'TABLE_REBUILD';

INSERT INTO #Issue (SchemaName, TableName, Severity, CheckCode, Detail)
SELECT SchemaName, TableName, 'WARNING', 'RB-01',
       LEFT(N'TABLE_REBUILD will be refused (ERR-RBD-04): ' + RebuildBlockers
            + N'. Set the method to BATCH_DELETE for this table (HdrMethod / ChdMethod) or remove the blocker.', 1000)
FROM #T WHERE RebuildBlockers IS NOT NULL;

INSERT INTO #Issue (SchemaName, TableName, Severity, CheckCode, Detail)
SELECT SchemaName, TableName, 'WARNING', 'METHOD', N'Method set manually (' + InitialCutoffMethod + N'), differs from the size rule'
FROM #T
WHERE MethodSource = 'MANUAL' AND InitialCutoffMethod <> CASE SizeCategory WHEN 'LARGE' THEN 'TABLE_REBUILD' ELSE 'BATCH_DELETE' END;

INSERT INTO #Issue (SchemaName, TableName, Severity, CheckCode, Detail)
SELECT SchemaName, TableName, 'INFO', 'BR-16', N'LARGE: Initial Cut-off needs a DowntimeReference and runs after every active SMALL / MEDIUM table is COMPLETED'
FROM #T WHERE SizeCategory = 'LARGE';

-- information: index on the child join key, foreign key child -> header, orphan child rows (DBR-21)
INSERT INTO #Issue (SchemaName, TableName, Severity, CheckCode, Detail)
SELECT ch.SchemaName, ch.TableName, 'INFO', 'INDEX',
       N'No index with the first join key column ' + QUOTENAME(k.ChildColumn) + N' as first column: every batch delete scans the child'
FROM #T AS ch
JOIN @Keys AS k ON k.ChdSchema = ch.SchemaName AND k.ChdTable = ch.TableName AND k.KeyOrdinal = 1
WHERE ch.Role = 'CHILD' AND ch.ObjectId IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM sys.index_columns AS ic JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                  WHERE ic.object_id = ch.ObjectId AND ic.key_ordinal = 1 AND c.name COLLATE DATABASE_DEFAULT = k.ChildColumn);

INSERT INTO #Issue (SchemaName, TableName, Severity, CheckCode, Detail)
SELECT ch.SchemaName, ch.TableName, 'INFO', 'FK',
       ISNULL(N'Foreign key child -> header: ' + x.Names, N'No foreign key child -> header (keys only from ret.RetentionParentKey)')
FROM #T AS ch
JOIN #T AS hd ON hd.Role = 'HEADER' AND hd.SchemaName = ch.GroupSchema AND hd.TableName = ch.GroupTable
CROSS APPLY (SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), fk.name COLLATE DATABASE_DEFAULT), N', ') AS Names
             FROM sys.foreign_keys AS fk WHERE fk.parent_object_id = ch.ObjectId AND fk.referenced_object_id = hd.ObjectId) AS x
WHERE ch.Role = 'CHILD' AND ch.ObjectId IS NOT NULL AND hd.ObjectId IS NOT NULL;

DECLARE @On NVARCHAR(MAX), @First SYSNAME;
DECLARE curo CURSOR LOCAL FAST_FORWARD FOR
    SELECT ch.SchemaName, ch.TableName, hd.SchemaName, hd.TableName
    FROM #T AS ch JOIN #T AS hd ON hd.Role = 'HEADER' AND hd.SchemaName = ch.GroupSchema AND hd.TableName = ch.GroupTable
    WHERE ch.Role = 'CHILD' AND ch.ObjectId IS NOT NULL AND hd.ObjectId IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM #Issue AS i WHERE i.SchemaName = ch.SchemaName AND i.TableName = ch.TableName
                                                 AND i.CheckCode IN ('V-10', 'INPUT') AND i.Severity = 'ERROR');
OPEN curo;
FETCH NEXT FROM curo INTO @cs, @ct, @hs, @ht;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @On = STRING_AGG(CONVERT(NVARCHAR(MAX), N'p.' + QUOTENAME(ParentColumn) + N' = t.' + QUOTENAME(ChildColumn)), N' AND ')
                 WITHIN GROUP (ORDER BY KeyOrdinal)
    FROM @Keys WHERE ChdSchema = @cs AND ChdTable = @ct;
    SELECT @First = ParentColumn FROM @Keys WHERE ChdSchema = @cs AND ChdTable = @ct AND KeyOrdinal = 1;
    SET @sql = N'SELECT @n = COUNT_BIG(*) FROM ' + QUOTENAME(@cs) + N'.' + QUOTENAME(@ct) + N' AS t LEFT JOIN '
             + QUOTENAME(@hs) + N'.' + QUOTENAME(@ht) + N' AS p ON ' + @On + N' WHERE p.' + QUOTENAME(@First) + N' IS NULL;';
    EXEC sp_executesql @sql, N'@n BIGINT OUTPUT', @n = @n OUTPUT;
    INSERT INTO #Issue (SchemaName, TableName, Severity, CheckCode, Detail)
    VALUES (@cs, @ct, 'INFO', 'DBR-21', CONCAT(@n, N' child rows without header row (orphans): never archived or deleted'));
    FETCH NEXT FROM curo INTO @cs, @ct, @hs, @ht;
END;
CLOSE curo; DEALLOCATE curo;

/* -------------------------------------------------------------------------------------
   3. Preview
   ------------------------------------------------------------------------------------- */
IF OBJECT_ID(N'tempdb..#Grp') IS NOT NULL DROP TABLE #Grp;
SELECT t.GroupSchema, t.GroupTable,
       CAST(MAX(CASE WHEN i.Severity = 'ERROR' THEN 1 ELSE 0 END) AS BIT) AS HasError
INTO #Grp
FROM #T AS t
LEFT JOIN #Issue AS i ON i.SchemaName = t.SchemaName AND i.TableName = t.TableName
GROUP BY t.GroupSchema, t.GroupTable;

SELECT t.GroupSchema + N'.' + t.GroupTable AS HeaderOfGroup, t.Role, t.SchemaName, t.TableName, t.DateColumn,
       t.UsedSpaceMB, t.SizeCategory, t.InitialCutoffMethod, t.MethodSource, t.BlobPath,
       t.ExistingConfigId, t.ExistingStatus,
       CASE WHEN g.HasError = 1 THEN N'NOT APPLIED (ERROR in this header / child group)'
            WHEN t.Started = 1 THEN N'UNCHANGED (archiving started)'
            WHEN t.ExistingConfigId IS NULL THEN N'INSERT'
            ELSE N'UPDATE (status PENDING, no archive file)' END AS Action
FROM #T AS t
JOIN #Grp AS g ON g.GroupSchema = t.GroupSchema AND g.GroupTable = t.GroupTable
ORDER BY t.GroupSchema, t.GroupTable, CASE t.Role WHEN 'CHILD' THEN 0 ELSE 1 END, t.SchemaName, t.TableName;

SELECT i.Ord, i.SchemaName + N'.' + i.TableName AS TableName, i.Severity, i.CheckCode, i.Detail
FROM #Issue AS i
ORDER BY CASE i.Severity WHEN 'ERROR' THEN 1 WHEN 'WARNING' THEN 2 ELSE 3 END, i.Ord;

/* -------------------------------------------------------------------------------------
   4. Apply
   ------------------------------------------------------------------------------------- */
IF @Apply = 1
BEGIN
    DECLARE @Now DATETIME2(3) = DATEADD(HOUR, 7, SYSUTCDATETIME());

    BEGIN TRANSACTION;

    -- 4a. headers (own date column)
    INSERT INTO ret.RetentionConfig
        (SchemaName, TableName, RetentionColumn, ParentTableConfigId, DwhRetentionYears, BlobRetentionYears, LogRetentionYears,
         BlobPath, InitialCutoffMethod, IsActive, SizeCategory)
    SELECT t.SchemaName, t.TableName, t.DateColumn, NULL, @DwhYears, @BlobYears, @LogYears,
           t.BlobPath, t.InitialCutoffMethod, @IsActive, t.SizeCategory
    FROM #T AS t JOIN #Grp AS g ON g.GroupSchema = t.GroupSchema AND g.GroupTable = t.GroupTable
    WHERE t.Role = 'HEADER' AND g.HasError = 0 AND t.ExistingConfigId IS NULL;

    UPDATE rc
       SET RetentionColumn = t.DateColumn, ParentTableConfigId = NULL, DwhRetentionYears = @DwhYears,
           BlobRetentionYears = @BlobYears, LogRetentionYears = @LogYears, BlobPath = t.BlobPath,
           InitialCutoffMethod = t.InitialCutoffMethod, SizeCategory = t.SizeCategory, IsActive = @IsActive,
           ModifiedBy = ORIGINAL_LOGIN(), ModifiedAt = @Now
      FROM ret.RetentionConfig AS rc
      JOIN #T AS t ON t.ExistingConfigId = rc.TableConfigId
      JOIN #Grp AS g ON g.GroupSchema = t.GroupSchema AND g.GroupTable = t.GroupTable
     WHERE t.Role = 'HEADER' AND g.HasError = 0 AND t.Started = 0;

    -- 4b. children (no own date column, ParentTableConfigId = header)
    INSERT INTO ret.RetentionConfig
        (SchemaName, TableName, RetentionColumn, ParentTableConfigId, DwhRetentionYears, BlobRetentionYears, LogRetentionYears,
         BlobPath, InitialCutoffMethod, IsActive, SizeCategory)
    SELECT t.SchemaName, t.TableName, NULL, h.TableConfigId, @DwhYears, @BlobYears, @LogYears,
           t.BlobPath, t.InitialCutoffMethod, @IsActive, t.SizeCategory
    FROM #T AS t
    JOIN #Grp AS g ON g.GroupSchema = t.GroupSchema AND g.GroupTable = t.GroupTable
    JOIN ret.RetentionConfig AS h ON h.SchemaName = t.GroupSchema AND h.TableName = t.GroupTable
    WHERE t.Role = 'CHILD' AND g.HasError = 0 AND t.ExistingConfigId IS NULL;

    UPDATE rc
       SET RetentionColumn = NULL, ParentTableConfigId = h.TableConfigId, DwhRetentionYears = @DwhYears,
           BlobRetentionYears = @BlobYears, LogRetentionYears = @LogYears, BlobPath = t.BlobPath,
           InitialCutoffMethod = t.InitialCutoffMethod, SizeCategory = t.SizeCategory, IsActive = @IsActive,
           ModifiedBy = ORIGINAL_LOGIN(), ModifiedAt = @Now
      FROM ret.RetentionConfig AS rc
      JOIN #T AS t ON t.ExistingConfigId = rc.TableConfigId
      JOIN #Grp AS g ON g.GroupSchema = t.GroupSchema AND g.GroupTable = t.GroupTable
      JOIN ret.RetentionConfig AS h ON h.SchemaName = t.GroupSchema AND h.TableName = t.GroupTable
     WHERE t.Role = 'CHILD' AND g.HasError = 0 AND t.Started = 0;

    -- 4c. join keys of children not started (replaced as a whole)
    DELETE r
      FROM ret.RetentionParentKey AS r
      JOIN ret.RetentionConfig AS rc ON rc.TableConfigId = r.TableConfigId
      JOIN #T AS t ON t.SchemaName = rc.SchemaName AND t.TableName = rc.TableName
      JOIN #Grp AS g ON g.GroupSchema = t.GroupSchema AND g.GroupTable = t.GroupTable
     WHERE t.Role = 'CHILD' AND g.HasError = 0 AND t.Started = 0;

    INSERT INTO ret.RetentionParentKey (TableConfigId, KeyOrdinal, ChildColumn, ParentColumn)
    SELECT rc.TableConfigId, k.KeyOrdinal, k.ChildColumn, k.ParentColumn
    FROM @Keys AS k
    JOIN #T AS t ON t.Role = 'CHILD' AND t.SchemaName = k.ChdSchema AND t.TableName = k.ChdTable
    JOIN #Grp AS g ON g.GroupSchema = t.GroupSchema AND g.GroupTable = t.GroupTable
    JOIN ret.RetentionConfig AS rc ON rc.SchemaName = t.SchemaName AND rc.TableName = t.TableName
    WHERE g.HasError = 0 AND t.Started = 0;

    COMMIT TRANSACTION;

    -- result
    SELECT rc.TableConfigId, CASE WHEN rc.ParentTableConfigId IS NULL THEN 'HEADER' ELSE 'CHILD' END AS Role,
           rc.SchemaName, rc.TableName, rc.RetentionColumn, rc.ParentTableConfigId, rc.SizeCategory, rc.InitialCutoffMethod,
           rc.DwhRetentionYears, rc.BlobRetentionYears, rc.LogRetentionYears, rc.BlobPath, rc.IsActive, s.InitialCutoffStatus
    FROM ret.RetentionConfig AS rc
    JOIN #T AS t ON t.SchemaName = rc.SchemaName AND t.TableName = rc.TableName
    LEFT JOIN ret.RetentionTableStatus AS s ON s.TableConfigId = rc.TableConfigId
    ORDER BY t.GroupSchema, t.GroupTable, CASE WHEN rc.ParentTableConfigId IS NULL THEN 1 ELSE 0 END, rc.TableConfigId;

    SELECT rc.SchemaName + N'.' + rc.TableName AS ChildTable, r.KeyOrdinal, r.ChildColumn, r.ParentColumn
    FROM ret.RetentionParentKey AS r
    JOIN ret.RetentionConfig AS rc ON rc.TableConfigId = r.TableConfigId
    JOIN #T AS t ON t.Role = 'CHILD' AND t.SchemaName = rc.SchemaName AND t.TableName = rc.TableName
    ORDER BY ChildTable, r.KeyOrdinal;

    -- TableConfigIdList for PL_RETB_01: children BEFORE their header (DBR-18)
    SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), x.TableConfigId), N',') WITHIN GROUP (ORDER BY x.GroupOrd, x.RoleOrd, x.TableConfigId)
           AS TableConfigIdList_ChildFirst
    FROM (SELECT rc.TableConfigId, DENSE_RANK() OVER (ORDER BY t.GroupSchema, t.GroupTable) AS GroupOrd,
                 CASE t.Role WHEN 'CHILD' THEN 0 ELSE 1 END AS RoleOrd
          FROM ret.RetentionConfig AS rc
          JOIN #T AS t ON t.SchemaName = rc.SchemaName AND t.TableName = rc.TableName
          JOIN #Grp AS g ON g.GroupSchema = t.GroupSchema AND g.GroupTable = t.GroupTable
          WHERE g.HasError = 0) AS x;
END
ELSE
    SELECT N'Preview only (@Apply = 0). Nothing changed. No ERROR rows -> set @Apply = 1.' AS Result;

DROP TABLE #T;
DROP TABLE #Issue;
DROP TABLE #Grp;
GO
