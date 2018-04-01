USE DBA
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF (OBJECT_ID('dbo.FileFileGroup_Builder') IS NULL)
BEGIN
    EXEC ('CREATE PROCEDURE dbo.FileFileGroup_Builder AS SELECT 1 AS Stub;');
END
GO
----------------------------------------------------------------------------------
-- Procedure Name: dbo.FileFileGroup_Builder
--
-- Desc: This procedure is to create files and filegroups.
--
-- Parameters: 
--	INPUT
--			@Directory NVARCHAR(250),
--			@TableName NVARCHAR(128) = NULL,
--			@SchemaName NVARCHAR(128) = NULL,
--			@Size INT = 0,
--			@SizeBasedOnTable BIT = 0,
--			@DatabaseName NVARCHAR(128),
--			@ConcatDatabaseName BIT = 0,
--			@ByDate BIT = 0,
--			@ByPartitionNumber BIT = 0,
--			@ByFilegroupName BIT = 0,
--			@NumPartitions TINYINT = 0,
--			@FileGroupName NVARCHAR(128), 
--			@StartDate CHAR(6) = NULL,
--			@EndDate CHAR(6) = NULL,
--			@FileGrowthMB INT = 2048,
--			@MaxSizeMB INT = 51200,
--			@Debug BIT = 0
--
--	OUTPUT
--
-- Auth: Tracy Boggiano
-- Date: 08/05/2015
--
-- Change History 
-- --------------------------------
-- Date - Auth: 09/14/2015 - Tracy Boggiano
-- Description: Add max size allowing for multiple files per filegroup.
----------------------------------------------------------------------------------
ALTER PROCEDURE [dbo].[FileFileGroup_Builder]
(
@Directory NVARCHAR(250),
@TableName NVARCHAR(128) = NULL,
@SchemaName NVARCHAR(128) = NULL,
@Size INT = 0,
@SizeBasedOnTable BIT = 0,
@DatabaseName NVARCHAR(128),
@ConcatDatabaseName BIT = 0,
@ByDate BIT = 0,
@ByPartitionNumber BIT = 0,
@ByFilegroupName BIT = 0,
@NumPartitions TINYINT = 0,
@FileGroupName NVARCHAR(128), 
@StartDate CHAR(6) = NULL,
@EndDate CHAR(6) = NULL,
@FileGrowthMB INT = 2048,
@MaxSizeMB INT = 51200,
@Debug BIT = 0
)
AS
SET NOCOUNT ON;

--Figure out size of each file
DECLARE @TableMB INT;
DECLARE @FilegroupSizeMB INT;
DECLARE @FGName NVARCHAR(128);
DECLARE @SQL NVARCHAR(MAX);
DECLARE @ParmDefinition nvarchar(500);
DECLARE @NumMonths SMALLINT;
DECLARE @StartMonth TINYINT = RIGHT(@StartDate, 2);
DECLARE @StartYear SMALLINT = LEFT(@StartDate, 4);
DECLARE @EndMonth TINYINT = RIGHT(@EndDate, 2);
DECLARE @EndYear SMALLINT = LEFT(@EndDate, 4);
DECLARE @CurrentMonth TINYINT;
DECLARE @CurrentYear SMALLINT;
DECLARE @NumFiles TINYINT;
DECLARE @Stuff BIT;
DECLARE @OrgNumFiles TINYINT;
DECLARE @LogicalFilename NVARCHAR(128);
DECLARE @BeginLogicalFileName NVARCHAR(128);

IF @ByDate = 0 AND @ByPartitionNumber = 0 and @ByFilegroupName = 0
	RAISERROR('Must specify one of the BY options', 11, -1)

IF @SizeBasedOnTable = 0 AND @Size = 0
	RAISERROR('Must specify one of the size options', 11, -1)

IF @Debug = 1
 EXEC master.sys.xp_create_subdir @Directory;

--Get months for start and end year
SET @NumMonths = 12 - @StartMonth + 1
SET @NumMonths = @NumMonths + @EndMonth
		
--Get months for years in between
SET @NumMonths = @NumMonths + (@EndYear - @StartYear - 1) * 12 

IF @SizeBasedOnTable = 1
BEGIN
	SET @SQL = REPLACE(REPLACE(REPLACE(REPLACE('SELECT @TableMB = (SUM(a.total_pages) / 128) * 1.2
		FROM {{@DatabaseName}}.sys.tables t
		INNER JOIN {{@DatabaseName}}.sys.schemas s ON s.schema_id = t.schema_id
		INNER JOIN {{@DatabaseName}}.sys.indexes i ON t.OBJECT_ID = i.object_id
		INNER JOIN {{@DatabaseName}}.sys.partitions p ON i.object_id = p.OBJECT_ID AND i.index_id = p.index_id
		INNER JOIN {{@DatabaseName}}.sys.allocation_units a ON p.partition_id = a.container_id
		WHERE 
			t.NAME = "{{@TableName}}"
			AND s.name = "{{@SchemaName}}"
			AND i.index_id in (0,1)
		GROUP BY 
			t.Name, 
			s.Name
		ORDER BY 
			s.Name, 
			t.Name'
		,'"','''')
		,'{{@DatabaseName}}', @DatabaseName)
		,'{{@TableName}}', @TableName)
		,'{{@SchemaName}}', @SchemaName)

		SET @ParmDefinition = N'@TableName NVARCHAR(257), @TableMB INT OUTPUT';

		EXECUTE sp_executesql @SQL, @ParmDefinition, @TableName = @TableName, @TableMB = @TableMB OUTPUT;
END
ELSE
	SET @TableMB = @Size

IF @ByPartitionNumber = 1 AND @SizeBasedOnTable = 1
	SET @FilegroupSizeMB = ROUND(@TableMB / @NumPartitions, 0);
ELSE
IF @ByDate = 1 AND @SizeBasedOnTable = 1
	SET @FilegroupSizeMB = ROUND(@TableMB / @NumMonths, 0);
ELSE
	SET @FilegroupSizeMB = @TableMB

SET @OrgNumFiles = CEILING(@FilegroupSizeMB * 1.0 / @MaxSizeMB)

IF @OrgNumFiles = 1
	SET @Stuff = 0
ELSE
	SET @Stuff = 1 

IF @ByPartitionNumber = 1 AND @NumPartitions > 0
BEGIN
	SET @SQL = ''

	WHILE (@NumPartitions > 0)
	BEGIN
		SET @FGName = CONCAT(@FileGroupName, RIGHT('00' + CONVERT(VARCHAR(2),@NumPartitions), 2));

		SET @BeginLogicalFileName = CASE @ConcatDatabaseName 
							WHEN 1 THEN CONCAT(@DatabaseName, '_', @FGName)
							ELSE @FGName
						END

		SET @SQL = @SQL + REPLACE(REPLACE(REPLACE(
			N'
			IF NOT EXISTS (
				SELECT 1
				FROM {{@DatabaseName}}.sys.filegroups
				WHERE name = "{{@FGName}}"
			)
			BEGIN
				ALTER DATABASE {{@DatabaseName}} ADD FILEGROUP {{@FGName}};
			END
			'
			,'{{@FGName}}', @FGName)
			,'{{@DatabaseName}}', @DatabaseName)
			,'"', '''');

		SET @NumFiles = @OrgNumFiles

		WHILE @NumFiles > 0
		BEGIN
			SET @LogicalFilename = CONCAT(@BeginLogicalFileName, CASE @Stuff 
										WHEN 1 THEN 
										CASE LEN(@NumFiles) 
										WHEN 1 THEN '_0' + CAST(@NumFiles AS VARCHAR(1))
										ELSE '_' + CAST(@NumFiles AS VARCHAR(2))
										END
										ELSE ''
										END)

			SET @SQL = @SQL + REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
				N'
				IF NOT EXISTS (
					SELECT 1
					FROM {{@DatabaseName}}.sys.database_files
					WHERE
						name = "{{@LogicalFileName}}"
				)
				BEGIN
					ALTER DATABASE {{@DatabaseName}} ADD FILE (
						NAME = "{{@LogicalFileName}}",
						FILENAME = "{{@PhysicalFilePath}}\{{@LogicalFileName}}.ndf",
						SIZE = {{@FilegroupSizeMB}}MB,
						FILEGROWTH = {{@FileGrowthMB}}MB
					)
					TO FILEGROUP {{@FGName}};
				END
				'
				, '{{@LogicalFileName}}', @LogicalFilename)
				, '{{@PhysicalFilePath}}', @Directory)
				, '{{@FilegroupSizeMB}}', CONVERT(NVARCHAR(8), CASE @Stuff
											WHEN 0 THEN @FilegroupSizeMB
											ELSE @MaxSizeMB	
											END))
				, '{{@FGName}}', @FGName)
				, '{{@FileGrowthMB}}', CONVERT(NVARCHAR(5), @FilegrowthMB))
				, '{{@DatabaseName}}', @DatabaseName)
				, '"', '''');

			SET @NumFiles = @NumFiles - 1
		END

		SET @NumPartitions = @NumPartitions - 1;
	END
END
	
IF @ByDate = 1 
BEGIN
	SET @SQL = ''
	SET @CurrentMonth = @StartMonth
	SET @CurrentYear = @StartYear

	WHILE (@NumMonths > 0)
	BEGIN
		IF @CurrentMonth = 13
		BEGIN
			SET @CurrentYear = @CurrentYear + 1
			SET @CurrentMonth = 1
		END

		SET @BeginLogicalFileName = CASE @ConcatDatabaseName 
							WHEN 1 THEN CONCAT(@DatabaseName, '_', @FGName)
							ELSE @FGName
						END

		SET @FGName = CONCAT(@FileGroupName, @CurrentYear, RIGHT('00' + CONVERT(VARCHAR(2),@CurrentMonth), 2));
	
		SET @SQL = @SQL + REPLACE(REPLACE(REPLACE(
			N'
			IF NOT EXISTS (
				SELECT 1
				FROM {{@DatabaseName}}.sys.filegroups
				WHERE name = "{{@FGName}}"
			)
			BEGIN
				ALTER DATABASE {{@DatabaseName}} ADD FILEGROUP {{@FGName}};
			END
			'
			,'{{@FGName}}', @FGName)
			,'{{@DatabaseName}}', @DatabaseName)
			,'"', '''');

		SET @NumFiles = @OrgNumFiles

		WHILE @NumFiles > 0
		BEGIN
			SET @LogicalFilename = CONCAT(@BeginLogicalFileName, CASE @Stuff 
										WHEN 1 THEN 
											CASE LEN(@NumFiles) 
											WHEN 1 THEN '_0' + CAST(@NumFiles AS VARCHAR(1))
											ELSE '_' + CAST(@NumFiles AS VARCHAR(2))
										END
										ELSE ''
										END)

			SET @SQL = @SQL + REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
				N'
				IF NOT EXISTS (
					SELECT 1
					FROM {{@DatabaseName}}.sys.database_files
					WHERE
						name = "{{@LogicalFileName}}"
				)
				BEGIN
					ALTER DATABASE {{@DatabaseName}} ADD FILE (
						NAME = "{{@LogicalFileName}}",
						FILENAME = "{{@PhysicalFilePath}}\{{@LogicalFileName}}.ndf",
						SIZE = {{@FilegroupSizeMB}}MB,
						FILEGROWTH = {{@FileGrowthMB}}MB
					)
					TO FILEGROUP {{@FGName}};
				END
				'
				, '{{@LogicalFileName}}', @LogicalFilename)
				, '{{@PhysicalFilePath}}', @Directory)
				, '{{@FilegroupSizeMB}}', CONVERT(NVARCHAR(8), CASE @Stuff
										WHEN 0 THEN @FilegroupSizeMB
										ELSE @MaxSizeMB	
										END))
				, '{{@FGName}}', @FGName)
				, '{{@FileGrowthMB}}', CONVERT(NVARCHAR(5), @FilegrowthMB))
				, '{{@DatabaseName}}', @DatabaseName)
				, '"', '''');
				
			SET @NumFiles = @NumFiles - 1
		END

		SET @NumMonths = @NumMonths - 1;
		SET @CurrentMonth = @CurrentMonth + 1
	END
END

IF @ByFilegroupName = 1 
BEGIN
	SET @FGName = @FileGroupName

	SET @BeginLogicalFileName = CASE @ConcatDatabaseName 
					WHEN 1 THEN CONCAT(@DatabaseName, '_', @FGName)
					ELSE @FGName
				END

	SET @SQL = REPLACE(REPLACE(REPLACE(
		N'
		IF NOT EXISTS (
			SELECT 1
			FROM {{@DatabaseName}}.sys.filegroups
			WHERE name = "{{@FGName}}"
		)
		BEGIN
			ALTER DATABASE {{@DatabaseName}} ADD FILEGROUP {{@FGName}};
		END
		'
		,'{{@FGName}}', @FGName)
		,'{{@DatabaseName}}', @DatabaseName)
		,'"', '''');

	SET @NumFiles = @OrgNumFiles

	WHILE @NumFiles > 0
	BEGIN
		SET @LogicalFilename = CONCAT(@BeginLogicalFileName, CASE @Stuff 
									WHEN 1 THEN 
										CASE LEN(@NumFiles) 
										WHEN 1 THEN '_0' + CAST(@NumFiles AS VARCHAR(1))
										ELSE '_' + CAST(@NumFiles AS VARCHAR(2))
									END
									ELSE ''
									END)

		SET @SQL = @SQL + REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
			N'
			IF NOT EXISTS (
				SELECT 1
				FROM {{@DatabaseName}}.sys.database_files
				WHERE
					name = "{{@LogicalFileName}}"
			)
			BEGIN
				ALTER DATABASE {{@DatabaseName}} ADD FILE (
					NAME = "{{@LogicalFileName}}",
					FILENAME = "{{@PhysicalFilePath}}\{{@LogicalFileName}}.ndf",
					SIZE = {{@FilegroupSizeMB}}MB,
					FILEGROWTH = {{@FileGrowthMB}}MB
				)
				TO FILEGROUP {{@FGName}};
			END
			'
			, '{{@LogicalFileName}}', @LogicalFilename)
			, '{{@PhysicalFilePath}}', @Directory)
			, '{{@FilegroupSizeMB}}', CONVERT(NVARCHAR(8), CASE @Stuff
									WHEN 0 THEN @FilegroupSizeMB
									ELSE @MaxSizeMB	
									END))
			, '{{@FGName}}', @FGName)
			, '{{@FileGrowthMB}}', CONVERT(NVARCHAR(5), @FilegrowthMB))
			, '{{@DatabaseName}}', @DatabaseName)
			, '"', '''');
				
		SET @NumFiles = @NumFiles - 1
	END
END

IF @Debug = 1
BEGIN
    SELECT 'EXEC master.sys.xp_create_subdir @Directory;'
	SELECT @SQL FOR XML PATH('');
END	
ELSE
	EXEC(@SQL);
GO