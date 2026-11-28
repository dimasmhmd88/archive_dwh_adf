/* =====================================================================================
   DWH Data Retention and Archiving - check of header (parent) / child table configuration
   -------------------------------------------------------------------------------------
   Script  : SQL_Script/monitoring/31_check_parent_child.sql   Version 0.1 (DRAFT, not executed)   24 November 2026
   Read-only (no data or configuration is changed). Requires SQL v0.6.

   Child table = RetentionConfig row with ParentTableConfigId (no own date column): its business date is the
   date of the header row, found through the join keys in ret.RetentionParentKey (FR-023). Rules checked:
     DBR-20  one level only; header has its own retention column, is active, same retention years
     V-10    join key columns exist in both tables, compatible types and collations (ERR-CFG-11)
     V-11    join key unique in the header table (ERR-CFG-12)
     DBR-21  orphan child rows (no header row) are never archived or deleted (warning ERR-PAR-01)
     DBR-18  Initial Cut-off: the child table must be COMPLETED before its header (or listed before it)
     MD-05   child tables are out of go-live phase 1 (normally IsActive = 0)
   Block 3 uses ret.usp_GetTableSqlParts, the same procedure the pipeline uses (usp_BeginTable).

   BLOCKS
     0  Filters
     1  Child / header overview (status, retention years, Initial Cut-off order)
     2  Join keys per child table (columns, types, collations, unique index on the header)
     3  Validation as in the pipeline (V-10 / V-11) + row counts via the header date (orphans, segments)
     4  Foreign keys in the database: possible child tables that are not configured, and
        configured children without a foreign key
   ===================================================================================== */
SET NOCOUNT ON;

/* ---- 0. Filters ---- */
DECLARE @TableConfigId   INT     = NULL;   -- NULL = all child tables; a child or a header TableConfigId
DECLARE @CheckUniqueness TINYINT = 2;      -- V-11: 2 = always count duplicates, 1 = only when no unique index, 0 = skip
DECLARE @CountRows       BIT     = NULL;   -- NULL = only when @TableConfigId is set (block 3 reads the child tables)

SET @CountRows = ISNULL(@CountRows, CASE WHEN @TableConfigId IS NULL THEN 0 ELSE 1 END);

-- children in scope: the child itself, or all children of a header
DECLARE @Child TABLE (ChildId INT PRIMARY KEY);
INSERT INTO @Child (ChildId)
SELECT c.TableConfigId
FROM ret.RetentionConfig AS c
WHERE c.ParentTableConfigId IS NOT NULL
  AND (@TableConfigId IS NULL OR c.TableConfigId = @TableConfigId OR c.ParentTableConfigId = @TableConfigId);

SELECT COUNT(*) AS ChildTablesInScope, @TableConfigId AS TableConfigId, @CheckUniqueness AS CheckUniqueness, @CountRows AS CountRows
FROM @Child;

/* ---- 1. Child / header overview ---- */
SELECT ch.TableConfigId AS ChildId, ch.SchemaName + N'.' + ch.TableName AS ChildTable, ch.IsActive AS ChildActive,
       ch.SizeCategory AS ChildSize, chs.InitialCutoffStatus AS ChildIcStatus, chs.InitialCutoffCompletionDate AS ChildIcDate,
       h.TableConfigId AS HeaderId, h.SchemaName + N'.' + h.TableName AS HeaderTable, h.IsActive AS HeaderActive,
       h.RetentionColumn AS HeaderDateColumn, hs.InitialCutoffStatus AS HeaderIcStatus, hs.InitialCutoffCompletionDate AS HeaderIcDate,
       CONCAT(ch.DwhRetentionYears, N'+', ch.BlobRetentionYears) AS ChildYears,
       CONCAT(h.DwhRetentionYears, N'+', h.BlobRetentionYears) AS HeaderYears,
       (SELECT COUNT(*) FROM ret.RetentionParentKey AS k WHERE k.TableConfigId = ch.TableConfigId) AS JoinKeys,
       CASE WHEN h.TableConfigId IS NULL THEN 'ERROR - header configuration not found'
            WHEN h.ParentTableConfigId IS NOT NULL OR h.RetentionColumn IS NULL THEN 'ERROR - header has no own date column / is a child (DBR-20)'
            WHEN EXISTS (SELECT 1 FROM ret.RetentionConfig AS g WHERE g.ParentTableConfigId = ch.TableConfigId)
                 THEN 'ERROR - child is also a header of another table (DBR-20)'
            WHEN ch.DwhRetentionYears <> h.DwhRetentionYears OR ch.BlobRetentionYears <> h.BlobRetentionYears
                 THEN 'ERROR - retention years differ from the header (DBR-20)'
            WHEN NOT EXISTS (SELECT 1 FROM ret.RetentionParentKey AS k WHERE k.TableConfigId = ch.TableConfigId)
                 THEN 'ERROR - no join keys (ret.RetentionParentKey)'
            WHEN ch.IsActive = 1 AND h.IsActive = 0 THEN 'ERROR - child active, header inactive'
            WHEN ch.IsActive = 1 AND hs.InitialCutoffStatus = 'COMPLETED' AND chs.InitialCutoffStatus <> 'COMPLETED'
                 THEN 'WARNING - header COMPLETED before the child (DBR-18 order not followed)'
            WHEN h.IsActive = 1 AND ch.IsActive = 1 AND chs.InitialCutoffStatus <> 'COMPLETED'
                 THEN 'INFO - Initial Cut-off: process the child first (list child before header, DBR-18)'
            WHEN ch.IsActive = 0 THEN 'INFO - child inactive (MD-05: child tables out of phase 1)'
            ELSE 'OK' END AS ConfigCheck
FROM ret.RetentionConfig AS ch
JOIN @Child AS x ON x.ChildId = ch.TableConfigId
JOIN ret.RetentionTableStatus AS chs ON chs.TableConfigId = ch.TableConfigId
LEFT JOIN ret.RetentionConfig AS h ON h.TableConfigId = ch.ParentTableConfigId
LEFT JOIN ret.RetentionTableStatus AS hs ON hs.TableConfigId = h.TableConfigId
ORDER BY h.TableConfigId, ch.TableConfigId;

-- 1b. Header tables in scope that have more than one child
SELECT h.TableConfigId AS HeaderId, h.SchemaName + N'.' + h.TableName AS HeaderTable, COUNT(*) AS Children,
       STRING_AGG(CONVERT(NVARCHAR(MAX), ch.SchemaName + N'.' + ch.TableName), N', ') AS ChildTables
FROM ret.RetentionConfig AS ch
JOIN @Child AS x ON x.ChildId = ch.TableConfigId
JOIN ret.RetentionConfig AS h ON h.TableConfigId = ch.ParentTableConfigId
GROUP BY h.TableConfigId, h.SchemaName, h.TableName
HAVING COUNT(*) > 1;

/* ---- 2. Join keys per child table ---- */
SELECT k.TableConfigId AS ChildId, ch.SchemaName + N'.' + ch.TableName AS ChildTable, k.KeyOrdinal,
       k.ChildColumn, TYPE_NAME(cc.system_type_id) AS ChildType, cc.max_length AS ChildLength, cc.is_nullable AS ChildNullable,
       k.ParentColumn, TYPE_NAME(pc.system_type_id) AS HeaderType, pc.max_length AS HeaderLength,
       CASE WHEN cc.column_id IS NULL THEN 'ERROR - child column not found'
            WHEN pc.column_id IS NULL THEN 'ERROR - header column not found'
            WHEN TYPE_NAME(cc.system_type_id) <> TYPE_NAME(pc.system_type_id) THEN 'CHECK - different types (compatible family required)'
            WHEN ISNULL(cc.collation_name COLLATE DATABASE_DEFAULT, N'') <> ISNULL(pc.collation_name COLLATE DATABASE_DEFAULT, N'')
                 THEN 'ERROR - different collations'
            ELSE 'OK' END AS KeyCheck
FROM ret.RetentionParentKey AS k
JOIN @Child AS x ON x.ChildId = k.TableConfigId
JOIN ret.RetentionConfig AS ch ON ch.TableConfigId = k.TableConfigId
LEFT JOIN ret.RetentionConfig AS h ON h.TableConfigId = ch.ParentTableConfigId
LEFT JOIN sys.columns AS cc ON cc.object_id = OBJECT_ID(QUOTENAME(ch.SchemaName) + N'.' + QUOTENAME(ch.TableName))
                           AND cc.name COLLATE DATABASE_DEFAULT = k.ChildColumn
LEFT JOIN sys.columns AS pc ON pc.object_id = OBJECT_ID(QUOTENAME(h.SchemaName) + N'.' + QUOTENAME(h.TableName))
                           AND pc.name COLLATE DATABASE_DEFAULT = k.ParentColumn
ORDER BY k.TableConfigId, k.KeyOrdinal;

-- 2b. Unique index on the header that covers exactly the join key columns (V-11 is then guaranteed)
SELECT ch.TableConfigId AS ChildId, h.SchemaName + N'.' + h.TableName AS HeaderTable,
       (SELECT TOP (1) i.name
        FROM sys.indexes AS i
        WHERE i.object_id = OBJECT_ID(QUOTENAME(h.SchemaName) + N'.' + QUOTENAME(h.TableName))
          AND i.is_unique = 1 AND i.has_filter = 0 AND i.is_disabled = 0 AND i.is_hypothetical = 0
          AND NOT EXISTS (SELECT 1 FROM sys.index_columns AS ic
                          JOIN sys.columns AS c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
                          WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.key_ordinal > 0
                            AND NOT EXISTS (SELECT 1 FROM ret.RetentionParentKey AS k
                                            WHERE k.TableConfigId = ch.TableConfigId
                                              AND k.ParentColumn = c.name COLLATE DATABASE_DEFAULT))) AS UniqueIndexOnKey
FROM ret.RetentionConfig AS ch
JOIN @Child AS x ON x.ChildId = ch.TableConfigId
JOIN ret.RetentionConfig AS h ON h.TableConfigId = ch.ParentTableConfigId;

/* ---- 3. Validation as in the pipeline + row counts via the header date ---- */
DECLARE @Result TABLE (ChildId INT, ChildTable NVARCHAR(300), HeaderTable NVARCHAR(300), ErrorCode VARCHAR(12), CheckCode VARCHAR(4),
                       Message NVARCHAR(4000), ChildRows BIGINT, OrphanRows BIGINT, ExpiredRows BIGINT, ArchivedRows BIGINT,
                       ArchivedDates INT, RetainedRows BIGINT, NullHeaderDates BIGINT, ArchiveCutoff DATE, DwhCutoff DATE);
DECLARE @Id INT, @IsChild BIT, @FullName NVARCHAR(300), @ObjectId INT, @DtFull NVARCHAR(300), @DtObj INT, @DtCol SYSNAME,
        @DateExpr NVARCHAR(400), @JoinSql NVARCHAR(MAX), @FromSql NVARCHAR(MAX), @OrphanExpr NVARCHAR(400), @ParentId INT,
        @ErrCode VARCHAR(12), @ChkCode VARCHAR(4), @ErrMsg NVARCHAR(4000), @Dwh DATE, @Arc DATE, @sql NVARCHAR(MAX),
        @Rows BIGINT, @Orph BIGINT, @Exp BIGINT, @ArcRows BIGINT, @ArcDates INT, @Ret BIGINT, @NullD BIGINT;

DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT ChildId FROM @Child ORDER BY ChildId;
OPEN cur;
FETCH NEXT FROM cur INTO @Id;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @Rows = NULL, @Orph = NULL, @Exp = NULL, @ArcRows = NULL, @ArcDates = NULL, @Ret = NULL, @NullD = NULL;

    EXEC ret.usp_GetTableSqlParts @TableConfigId = @Id, @CheckUniqueness = @CheckUniqueness,
         @IsChild = @IsChild OUTPUT, @FullName = @FullName OUTPUT, @ObjectId = @ObjectId OUTPUT,
         @DateTableFullName = @DtFull OUTPUT, @DateTableObjectId = @DtObj OUTPUT, @DateColumn = @DtCol OUTPUT,
         @DateExpr = @DateExpr OUTPUT, @JoinSql = @JoinSql OUTPUT, @FromSql = @FromSql OUTPUT, @OrphanExpr = @OrphanExpr OUTPUT,
         @ParentTableConfigId = @ParentId OUTPUT, @ErrorCode = @ErrCode OUTPUT, @CheckCode = @ChkCode OUTPUT,
         @ErrorMessage = @ErrMsg OUTPUT;

    SELECT @Dwh = co.DwhCutoffDate, @Arc = co.ArchiveCutoffDate
    FROM ret.RetentionConfig AS c
    CROSS APPLY ret.fn_GetCutoffDates(ret.fn_TodayUtc7(), c.DwhRetentionYears, c.BlobRetentionYears) AS co
    WHERE c.TableConfigId = @Id;

    IF @ErrCode IS NULL AND @CountRows = 1
    BEGIN
        -- same expressions as the pipeline: business date = header date, orphans excluded from every segment
        SET @sql = N'SELECT @Rows = COUNT_BIG(*),
                            @Orph = SUM(CASE WHEN ' + @OrphanExpr + N' THEN 1 ELSE 0 END),
                            @Exp  = SUM(CASE WHEN NOT (' + @OrphanExpr + N') AND CAST(' + @DateExpr + N' AS DATE) <  @Arc THEN 1 ELSE 0 END),
                            @ArcRows = SUM(CASE WHEN NOT (' + @OrphanExpr + N') AND CAST(' + @DateExpr + N' AS DATE) >= @Arc
                                                 AND CAST(' + @DateExpr + N' AS DATE) < @Dwh THEN 1 ELSE 0 END),
                            @ArcDates = COUNT(DISTINCT CASE WHEN NOT (' + @OrphanExpr + N') AND CAST(' + @DateExpr + N' AS DATE) >= @Arc
                                                 AND CAST(' + @DateExpr + N' AS DATE) < @Dwh THEN CAST(' + @DateExpr + N' AS DATE) END),
                            @Ret  = SUM(CASE WHEN NOT (' + @OrphanExpr + N') AND CAST(' + @DateExpr + N' AS DATE) >= @Dwh THEN 1 ELSE 0 END),
                            @NullD = SUM(CASE WHEN NOT (' + @OrphanExpr + N') AND ' + @DateExpr + N' IS NULL THEN 1 ELSE 0 END)'
                 + @FromSql + N';';
        EXEC sp_executesql @sql,
             N'@Dwh DATE, @Arc DATE, @Rows BIGINT OUTPUT, @Orph BIGINT OUTPUT, @Exp BIGINT OUTPUT, @ArcRows BIGINT OUTPUT,
               @ArcDates INT OUTPUT, @Ret BIGINT OUTPUT, @NullD BIGINT OUTPUT',
             @Dwh = @Dwh, @Arc = @Arc, @Rows = @Rows OUTPUT, @Orph = @Orph OUTPUT, @Exp = @Exp OUTPUT,
             @ArcRows = @ArcRows OUTPUT, @ArcDates = @ArcDates OUTPUT, @Ret = @Ret OUTPUT, @NullD = @NullD OUTPUT;
    END;

    INSERT INTO @Result
    SELECT @Id, @FullName, @DtFull, @ErrCode, @ChkCode,
           ISNULL(@ErrMsg, CASE WHEN @CountRows = 0 THEN N'Configuration OK (row counts skipped: set @TableConfigId or @CountRows = 1)'
                                WHEN @Orph > 0 THEN CONCAT(N'OK; ', @Orph, N' orphan child rows are kept (ERR-PAR-01 warning, DBR-21)')
                                ELSE N'OK' END),
           @Rows, @Orph, @Exp, @ArcRows, @ArcDates, @Ret, @NullD, @Arc, @Dwh;

    FETCH NEXT FROM cur INTO @Id;
END;
CLOSE cur; DEALLOCATE cur;

SELECT * FROM @Result ORDER BY ChildId;

/* ---- 4. Foreign keys in the database ---- */
-- 4a. Tables with a foreign key to a configured table that are NOT configured themselves (possible child tables)
SELECT OBJECT_SCHEMA_NAME(fk.parent_object_id) + N'.' + OBJECT_NAME(fk.parent_object_id) AS ReferencingTable,
       fk.name AS ForeignKey, c.TableConfigId AS ReferencedTableConfigId, c.SchemaName + N'.' + c.TableName AS ReferencedTable,
       c.IsActive AS ReferencedActive,
       STRING_AGG(CONVERT(NVARCHAR(MAX), CONCAT(COL_NAME(fkc.parent_object_id, fkc.parent_column_id), N' -> ',
                  COL_NAME(fkc.referenced_object_id, fkc.referenced_column_id))) COLLATE DATABASE_DEFAULT, N', ') AS Columns
FROM sys.foreign_keys AS fk
JOIN sys.foreign_key_columns AS fkc ON fkc.constraint_object_id = fk.object_id
JOIN ret.RetentionConfig AS c ON OBJECT_ID(QUOTENAME(c.SchemaName) + N'.' + QUOTENAME(c.TableName)) = fk.referenced_object_id
WHERE NOT EXISTS (SELECT 1 FROM ret.RetentionConfig AS x
                  WHERE OBJECT_ID(QUOTENAME(x.SchemaName) + N'.' + QUOTENAME(x.TableName)) = fk.parent_object_id)
  AND (@TableConfigId IS NULL OR c.TableConfigId = @TableConfigId)
GROUP BY fk.parent_object_id, fk.name, c.TableConfigId, c.SchemaName, c.TableName, c.IsActive
ORDER BY ReferencedTable, ReferencingTable;
-- Deleting header rows while such a table still references them fails (FK) or leaves the child data
-- without its header. Decide per table: configure it as child, or confirm that it is out of scope.

-- 4b. Configured child tables without a foreign key to their header (information: keys only from RetentionParentKey)
SELECT ch.TableConfigId AS ChildId, ch.SchemaName + N'.' + ch.TableName AS ChildTable, h.SchemaName + N'.' + h.TableName AS HeaderTable,
       CASE WHEN EXISTS (SELECT 1 FROM sys.foreign_keys AS fk
                         WHERE fk.parent_object_id = OBJECT_ID(QUOTENAME(ch.SchemaName) + N'.' + QUOTENAME(ch.TableName))
                           AND fk.referenced_object_id = OBJECT_ID(QUOTENAME(h.SchemaName) + N'.' + QUOTENAME(h.TableName)))
            THEN 'FK exists' ELSE 'No FK (join keys from ret.RetentionParentKey only)' END AS ForeignKeyStatus
FROM ret.RetentionConfig AS ch
JOIN @Child AS x ON x.ChildId = ch.TableConfigId
JOIN ret.RetentionConfig AS h ON h.TableConfigId = ch.ParentTableConfigId
ORDER BY ch.TableConfigId;
