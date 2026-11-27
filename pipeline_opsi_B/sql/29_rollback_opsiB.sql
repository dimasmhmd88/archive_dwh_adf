/* =====================================================================================
   DWH Data Retention and Archiving - remove the OPSI B objects (back to SQL v0.6)
   -------------------------------------------------------------------------------------
   Script  : pipeline_opsi_B/sql/29_rollback_opsiB.sql   Version 0.2 (DRAFT)   27 November 2026
   Use only when the opsi B ADF package (PL_RETB_*) is no longer used and no PL_RETB run is RUNNING.
   1. Drops the 6 new procedures and the ExportParallelism and ChildDeleteMode columns
      (usp_BatchDelete reads ChildDeleteMode dynamically: without the column it deletes child rows with JOIN).
   2. The 9 v0.6 procedures with the #RetOut_ option behave exactly like v0.6 without the temp table;
      to restore the original text as well, run pipeline/sql/deploy/04_procedures.sql (v0.6) again.
   ===================================================================================== */
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF EXISTS (SELECT 1 FROM ret.RetentionRunLog WHERE Status = 'RUNNING')
BEGIN
    ;THROW 50891, N'A retention run is RUNNING. Roll back after it has ended.', 1;
END;

DROP PROCEDURE IF EXISTS ret.usp_StartRunAndGetTables;
DROP PROCEDURE IF EXISTS ret.usp_BeginTableAndIdentify;
DROP PROCEDURE IF EXISTS ret.usp_GetExportChunk;
DROP PROCEDURE IF EXISTS ret.usp_ValidateDeleteAndCheck;
DROP PROCEDURE IF EXISTS ret.usp_GetCleanupDecision;
DROP PROCEDURE IF EXISTS ret.usp_GetExpiredArchiveItems;
GO
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_RetentionConfig_ExportParallelism')
    ALTER TABLE ret.RetentionConfig DROP CONSTRAINT CK_RetentionConfig_ExportParallelism;
IF COL_LENGTH(N'ret.RetentionConfig', N'ExportParallelism') IS NOT NULL
    ALTER TABLE ret.RetentionConfig DROP COLUMN ExportParallelism;
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_RetentionParameter_ExportParallelism')
    ALTER TABLE ret.RetentionParameter DROP CONSTRAINT CK_RetentionParameter_ExportParallelism;
IF EXISTS (SELECT 1 FROM sys.default_constraints WHERE name = N'DF_RetentionParameter_ExportParallelism')
    ALTER TABLE ret.RetentionParameter DROP CONSTRAINT DF_RetentionParameter_ExportParallelism;
IF COL_LENGTH(N'ret.RetentionParameter', N'ExportParallelism') IS NOT NULL
    ALTER TABLE ret.RetentionParameter DROP COLUMN ExportParallelism;
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_RetentionParameter_ChildDeleteMode')
    ALTER TABLE ret.RetentionParameter DROP CONSTRAINT CK_RetentionParameter_ChildDeleteMode;
IF EXISTS (SELECT 1 FROM sys.default_constraints WHERE name = N'DF_RetentionParameter_ChildDeleteMode')
    ALTER TABLE ret.RetentionParameter DROP CONSTRAINT DF_RetentionParameter_ChildDeleteMode;
IF COL_LENGTH(N'ret.RetentionParameter', N'ChildDeleteMode') IS NOT NULL
    ALTER TABLE ret.RetentionParameter DROP COLUMN ChildDeleteMode;
GO
SELECT N'Opsi B objects removed. Optional: run pipeline/sql/deploy/04_procedures.sql (v0.6) to restore the original procedure text.' AS Result;
GO
