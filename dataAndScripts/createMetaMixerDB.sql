BEGIN TRANSACTION;
-- Table that tracks various scripts run
CREATE TABLE IF NOT EXISTS "scriptUse" (
	"runId"	integer primary key,
	"scriptName" text NOT NULL,
	"start" text integer NOT NULL,
	"end" text,
	"status" text,
	"info" text
);
-- Save the arguments with which each script runs
CREATE TABLE IF NOT EXISTS "scriptArguments" (
	"argId"	integer primary key,
	"runId"	integer NOT NULL,
	"scriptName" text NOT NULL,
	"argument" text,
	"value" text,
	FOREIGN KEY("runId") REFERENCES "scriptUse"("runId") ON UPDATE CASCADE ON DELETE CASCADE
);
-- Table that keeps general logs
CREATE TABLE IF NOT EXISTS "logs" (
    "logId"	integer primary key,
	"runId"	integer NOT NULL,
	"tool" text NOT NULL,
	"timeStamp" integer NOT NULL,
	"actionId" integer NOT NULL,
	"actionName" text,
	FOREIGN KEY("runId") REFERENCES "scriptUse"("runId") ON UPDATE CASCADE ON DELETE CASCADE
);
-- Table lising all sequencing data info
CREATE TABLE IF NOT EXISTS "seqData" (
	"seqId"	integer primary key,
	"sampleName" text NOT NULL,
	"readCount" text integer NOT NULL,
	"sampleType" text,
	"description" text,
	"SRR" text,
	"SAMN" text
);
-- Table listing all files used
CREATE TABLE IF NOT EXISTS "seqFiles" (
	"fileId" integer primary key,
	"seqId" integer NOT NULL,
	"fileName" text NOT NULL,
	"folder" text NOT NULL,
	"modDate" text NOT NULL,
	"fileSize" integer NOT NULL,
	FOREIGN KEY("seqId") REFERENCES "seqData"("seqId") ON UPDATE CASCADE ON DELETE CASCADE
);
CREATE TABLE IF NOT EXISTS "mixDetails" (
    "runId" integer NOT NULL,
	"seqId" integer NOT NULL,
	"type" text NOT NULL,
	"relativeAbundance" real NOT NULL,
	"nReadsUsed" integer NOT NULL,
	PRIMARY KEY("runId", "seqId"),
	FOREIGN KEY("runId") REFERENCES "scriptUse"("runId") ON UPDATE CASCADE,
	FOREIGN KEY("seqId") REFERENCES "seqData"("seqId") ON UPDATE CASCADE ON DELETE CASCADE
);
COMMIT;
