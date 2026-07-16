USE ROLE HEALTHCARE_CLAIMS_AI_ROLE;
USE WAREHOUSE HEALTHCARE_CLAIMS_AI_WH;
USE DATABASE HEALTHCARE_CLAIMS_AI_DB;
USE SCHEMA CLAIMS;

--First test if you are getting all files metadata
SELECT
    D.RELATIVE_PATH,
    SPLIT_PART(D.RELATIVE_PATH, '/', -1) AS FILE_NAME
FROM DIRECTORY(
    '@HEALTHCARE_CLAIMS_AI_DB.CLAIMS.CLAIM_DOCUMENT_STAGE'
) AS D
WHERE D.RELATIVE_PATH LIKE
      'Gregorio366_Auer97_f5dcd418/%'
ORDER BY D.RELATIVE_PATH;

/* ============================================================
   PATIENT CLAIM LOADING PROCEDURE
   ============================================================ */

CREATE OR REPLACE PROCEDURE
HEALTHCARE_CLAIMS_AI_DB.CLAIMS.LOAD_PATIENT_CLAIM_FOLDER
(
    P_FOLDER_PATH VARCHAR
)
RETURNS OBJECT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
V_STAGE_NAME VARCHAR DEFAULT '@HEALTHCARE_CLAIMS_AI_DB.CLAIMS.CLAIM_DOCUMENT_STAGE';

/* Folder details */
V_FOLDER_PATH       VARCHAR;
V_FOLDER_NAME       VARCHAR;

/* Claim form */
V_CLAIM_FORM_PATH   VARCHAR;
V_CLAIM_FORM_RESULT OBJECT;
V_CLAIM_RESPONSE    VARIANT;
V_CLAIM_FORM_ERROR  VARIANT;

/* Claim data */
V_CLAIM_ID       VARCHAR;
V_PATIENT_ID     VARCHAR;
V_PATIENT_NAME   VARCHAR;
V_POLICY_NUMBER  VARCHAR;
V_CLAIM_TYPE     VARCHAR;
V_CLAIMED_AMOUNT NUMBER(18,2);

/* Document data */
V_DOCUMENT_ID       VARCHAR;
V_DOCUMENT_TYPE     VARCHAR;
V_TEMPLATE_ID       VARCHAR;
V_FILE_NAME         VARCHAR;
V_RELATIVE_PATH     VARCHAR;

V_EXTRACTION_RESULT OBJECT;
V_EXTRACTION_ERROR  VARIANT;
V_EXTRACTION_STATUS VARCHAR;

V_RESPONSE_OBJECT OBJECT;
V_SCORING_OBJECT  OBJECT;
V_ERROR_OBJECT    OBJECT;

/* Error capture */
V_ERROR_MESSAGE VARCHAR;
V_ERROR_CODE    NUMBER;
V_ERROR_STATE   VARCHAR;

/* Counters */
V_DOCUMENT_COUNT  NUMBER DEFAULT 0;
V_EXTRACTED_COUNT NUMBER DEFAULT 0;
V_FAILED_COUNT    NUMBER DEFAULT 0;
V_SKIPPED_COUNT   NUMBER DEFAULT 0;

V_FILES RESULTSET;


BEGIN
    /*==========================================================
      1. Normalize folder path
      ==========================================================*/

    /* Assign the input parameter */
    V_FOLDER_PATH := RTRIM(TRIM(P_FOLDER_PATH),'/');

    /*==========================================================
      2. Find claim form
      ==========================================================*/
     SELECT
        D.RELATIVE_PATH
    INTO
        :V_CLAIM_FORM_PATH
    FROM DIRECTORY(
        '@HEALTHCARE_CLAIMS_AI_DB.CLAIMS.CLAIM_DOCUMENT_STAGE'
    ) AS D
    WHERE D.RELATIVE_PATH LIKE (:V_FOLDER_PATH || '/%')
      AND LOWER(SPLIT_PART(D.RELATIVE_PATH, '/', -1)) ILIKE '%claim%'
    AND LOWER(SPLIT_PART(D.RELATIVE_PATH, '/', -1)) ILIKE '%form%'
    ORDER BY D.RELATIVE_PATH
    LIMIT 1;

    IF (V_CLAIM_FORM_PATH IS NULL) THEN
        RETURN OBJECT_CONSTRUCT(
            'status', 'FAILED',
            'folder_path', V_FOLDER_PATH,
            'message', 'claim_form.pdf was not found.'
        );
    END IF;


    /*==========================================================
      3. Extract claim form
      ==========================================================*/
      SELECT
        HEALTHCARE_CLAIMS_AI_DB.CLAIMS.EXTRACT_DOCUMENT_DATA(
            :V_STAGE_NAME,
            :V_CLAIM_FORM_PATH,
            'CLAIM_FORM_V1'
        )
    INTO
        :V_CLAIM_FORM_RESULT;

        V_CLAIM_FORM_ERROR :=
        STRIP_NULL_VALUE(GET(V_CLAIM_FORM_RESULT,'error'));


    IF (V_CLAIM_FORM_ERROR IS NOT NULL) THEN
        RETURN OBJECT_CONSTRUCT(
            'status', 'FAILED',
            'folder_path', V_FOLDER_PATH,
            'claim_form_path', V_CLAIM_FORM_PATH,
            'message', 'Claim-form extraction failed.',
            'error', V_CLAIM_FORM_ERROR
        );
    END IF;


    V_CLAIM_RESPONSE :=
        STRIP_NULL_VALUE(GET(V_CLAIM_FORM_RESULT,'response'));

    IF (V_CLAIM_RESPONSE IS NULL) THEN
        RETURN OBJECT_CONSTRUCT(
            'status', 'FAILED',
            'folder_path', V_FOLDER_PATH,
            'claim_form_path', V_CLAIM_FORM_PATH,
            'message', 'Claim-form extraction returned no response.'
        );
    END IF;

     /*==========================================================
      4. Read claim details
      ==========================================================*/

    V_CLAIM_ID := COALESCE(NULLIF(TRIM(GET(V_CLAIM_RESPONSE,'claim_id')::VARCHAR),''),NULLIF(TRIM(GET(V_CLAIM_RESPONSE,'claim_number')::VARCHAR), ''));
    V_PATIENT_ID := COALESCE(NULLIF(TRIM(GET(V_CLAIM_RESPONSE,'patient_id')::VARCHAR), ''),NULLIF(TRIM(GET(V_CLAIM_RESPONSE,'member_id')::VARCHAR),''));
    V_PATIENT_NAME := COALESCE(NULLIF(TRIM(GET(V_CLAIM_RESPONSE,'patient_name')::VARCHAR), ''),NULLIF(TRIM(GET(V_CLAIM_RESPONSE,'insured_name')::VARCHAR),''));
    V_POLICY_NUMBER := COALESCE(NULLIF(TRIM(GET(V_CLAIM_RESPONSE,'policy_number')::VARCHAR), ''),NULLIF(TRIM(GET(V_CLAIM_RESPONSE,'policy_id')::VARCHAR),''));
    V_CLAIM_TYPE := COALESCE(NULLIF(TRIM(GET(V_CLAIM_RESPONSE,'claim_type')::VARCHAR), ''),NULLIF(TRIM(GET(V_CLAIM_RESPONSE,'treatment_type')::VARCHAR),''),'UNKNOWN');
    V_CLAIMED_AMOUNT := COALESCE(TRY_TO_DECIMAL(REGEXP_REPLACE(GET(V_CLAIM_RESPONSE,'claimed_amount')::VARCHAR,'[^0-9.-]', ''),18, 2),
                        TRY_TO_DECIMAL(REGEXP_REPLACE(GET(V_CLAIM_RESPONSE,'total_claim_amount')::VARCHAR,'[^0-9.-]',''),18,2),
                        TRY_TO_DECIMAL(REGEXP_REPLACE(GET(V_CLAIM_RESPONSE,'claim_amount')::VARCHAR,'[^0-9.-]',''),18,2));

    IF (V_CLAIM_ID IS NULL) THEN
        RETURN OBJECT_CONSTRUCT(
            'status', 'FAILED',
            'folder_path', V_FOLDER_PATH,
            'message',
            'Claim ID could not be extracted.',
            'claim_form_response',
            V_CLAIM_RESPONSE
        );
    END IF;


     /*==========================================================
      5. Load PATIENT_CLAIMS
      ==========================================================*/

    MERGE INTO
        HEALTHCARE_CLAIMS_AI_DB.CLAIMS.PATIENT_CLAIMS AS T
    USING
    (
        SELECT
            :V_CLAIM_ID       AS SRC_CLAIM_ID,
            :V_PATIENT_ID     AS SRC_PATIENT_ID,
            :V_PATIENT_NAME   AS SRC_PATIENT_NAME,
            :V_POLICY_NUMBER  AS SRC_POLICY_NUMBER,
            :V_CLAIM_TYPE     AS SRC_CLAIM_TYPE,
            :V_CLAIMED_AMOUNT AS SRC_CLAIMED_AMOUNT
    ) AS S
        ON T.CLAIM_ID = S.SRC_CLAIM_ID

    WHEN MATCHED THEN
        UPDATE SET
            T.PATIENT_ID = S.SRC_PATIENT_ID,
            T.PATIENT_NAME = S.SRC_PATIENT_NAME,
            T.POLICY_NUMBER = S.SRC_POLICY_NUMBER,
            T.CLAIM_TYPE = S.SRC_CLAIM_TYPE,
            T.CLAIMED_AMOUNT = S.SRC_CLAIMED_AMOUNT,
            T.CLAIM_STATUS = 'PROCESSING',
            T.REVIEWER_DECISION = NULL,
            T.REVIEWER_COMMENTS = NULL,
            T.REVIEWED_AT = NULL

    WHEN NOT MATCHED THEN
        INSERT
        (
            CLAIM_ID,
            PATIENT_ID,
            PATIENT_NAME,
            POLICY_NUMBER,
            CLAIM_TYPE,
            CLAIMED_AMOUNT,
            CLAIM_STATUS
        )
        VALUES
        (
            S.SRC_CLAIM_ID,
            S.SRC_PATIENT_ID,
            S.SRC_PATIENT_NAME,
            S.SRC_POLICY_NUMBER,
            S.SRC_CLAIM_TYPE,
            S.SRC_CLAIMED_AMOUNT,
            'PROCESSING'
        );

    /*==========================================================
      6. Fetch documents

      ==========================================================*/

    V_FILES := (
        SELECT
            D.RELATIVE_PATH AS STAGE_FILE_PATH,
            SPLIT_PART(
                D.RELATIVE_PATH,
                '/',
                -1
            ) AS STAGE_FILE_NAME
        FROM DIRECTORY(
            '@HEALTHCARE_CLAIMS_AI_DB.CLAIMS.CLAIM_DOCUMENT_STAGE'
        ) AS D
        WHERE D.RELATIVE_PATH LIKE (:V_FOLDER_PATH || '/%')
          AND REGEXP_LIKE(
              LOWER(D.RELATIVE_PATH),
              '.*[.](pdf|png|jpg|jpeg)$'
          )
        ORDER BY D.RELATIVE_PATH
    );
 /*==========================================================
      7. Process documents
      ==========================================================*/

    FOR FILE_RECORD IN V_FILES DO

        V_RELATIVE_PATH :=
            FILE_RECORD.STAGE_FILE_PATH;

        V_FILE_NAME :=
            FILE_RECORD.STAGE_FILE_NAME;


      V_DOCUMENT_TYPE :=
    CASE

        /* Claim form */
        WHEN LOWER(V_FILE_NAME) ILIKE '%claim%'
         AND LOWER(V_FILE_NAME) ILIKE '%form%'
            THEN 'CLAIM_FORM'

        /* Prescription */
        WHEN LOWER(V_FILE_NAME) ILIKE '%prescription%'
            THEN 'PRESCRIPTION'

        /* Discharge summary */
        WHEN LOWER(V_FILE_NAME) ILIKE '%discharge%'
         AND LOWER(V_FILE_NAME) ILIKE '%summary%'
            THEN 'DISCHARGE_SUMMARY'

        /* Hospital invoice or bill */
        WHEN LOWER(V_FILE_NAME) ILIKE '%hospital%'
         AND (
                LOWER(V_FILE_NAME) ILIKE '%invoice%'
             OR LOWER(V_FILE_NAME) ILIKE '%bill%'
         )
            THEN 'HOSPITAL_INVOICE'

        /* Pharmacy invoice, bill, or receipt */
        WHEN LOWER(V_FILE_NAME) LIKE '%pharmacy%'
         AND (
                LOWER(V_FILE_NAME) ILIKE '%invoice%'
             OR LOWER(V_FILE_NAME) ILIKE '%bill%'
             OR LOWER(V_FILE_NAME) ILIKE '%receipt%'
         )
            THEN 'PHARMACY_INVOICE'

        /* Diagnostic or lab report */
        WHEN (
                LOWER(V_FILE_NAME) ILIKE '%diagnostic%'
             OR LOWER(V_FILE_NAME) ILIKE '%laboratory%'
             OR LOWER(V_FILE_NAME) ILIKE '%lab%'
             OR LOWER(V_FILE_NAME) ILIKE '%test%'
        )
         AND (
                LOWER(V_FILE_NAME) ILIKE '%report%'
             OR LOWER(V_FILE_NAME) ILIKE '%result%'
         )
            THEN 'DIAGNOSTIC_REPORT'

        /* Payment receipt */
        WHEN LOWER(V_FILE_NAME) ILIKE '%payment%'
         AND (
         LOWER(V_FILE_NAME) ILIKE '%receipt%'
         OR LOWER(V_FILE_NAME) ILIKE '%bill%'
         OR LOWER(V_FILE_NAME) ILIKE '%invoice%')
            THEN 'PAYMENT_RECEIPT'

        WHEN LOWER(V_FILE_NAME) ILIKE '%receipt%'
         AND LOWER(V_FILE_NAME) NOT ILIKE '%pharmacy%'
            THEN 'PAYMENT_RECEIPT'

        ELSE 'OTHER'

    END;

        V_TEMPLATE_ID :=
            CASE V_DOCUMENT_TYPE
                WHEN 'CLAIM_FORM'
                    THEN 'CLAIM_FORM_V1'
                WHEN 'PRESCRIPTION'
                    THEN 'PRESCRIPTION_V1'
                WHEN 'DISCHARGE_SUMMARY'
                    THEN 'DISCHARGE_SUMMARY_V1'
                WHEN 'HOSPITAL_INVOICE'
                    THEN 'HOSPITAL_INVOICE_V1'
                WHEN 'PHARMACY_INVOICE'
                    THEN 'PHARMACY_INVOICE_V1'
                WHEN 'DIAGNOSTIC_REPORT'
                    THEN 'DIAGNOSTIC_REPORT_V1'
                WHEN 'PAYMENT_RECEIPT'
                    THEN 'PAYMENT_RECEIPT_V1'
                ELSE NULL
            END;


        IF (V_TEMPLATE_ID IS NULL) THEN
            V_SKIPPED_COUNT :=
                V_SKIPPED_COUNT + 1;

            CONTINUE;
        END IF;


        V_DOCUMENT_COUNT :=
            V_DOCUMENT_COUNT + 1;


        BEGIN

            /*==================================================
              8. Register document
              ==================================================*/

            MERGE INTO
                HEALTHCARE_CLAIMS_AI_DB.CLAIMS.CLAIM_DOCUMENTS AS T
            USING
            (
                SELECT
                    :V_CLAIM_ID       AS SRC_CLAIM_ID,
                    :V_FILE_NAME      AS SRC_FILE_NAME,
                    :V_RELATIVE_PATH  AS SRC_FILE_PATH,
                    :V_DOCUMENT_TYPE  AS SRC_DOCUMENT_TYPE,
                    :V_TEMPLATE_ID    AS SRC_TEMPLATE_ID
            ) AS S
                ON T.RELATIVE_PATH = S.SRC_FILE_PATH

            WHEN MATCHED THEN
                UPDATE SET
                    T.CLAIM_ID = S.SRC_CLAIM_ID,
                    T.FILE_NAME = S.SRC_FILE_NAME,
                    T.DOCUMENT_TYPE = S.SRC_DOCUMENT_TYPE,
                    T.TEMPLATE_ID = S.SRC_TEMPLATE_ID,
                    T.PROCESSING_STATUS = 'EXTRACTING',
                    T.ERROR_MESSAGE = NULL,
                    T.PROCESSED_AT = NULL

            WHEN NOT MATCHED THEN
                INSERT
                (
                    DOCUMENT_ID,
                    CLAIM_ID,
                    FILE_NAME,
                    RELATIVE_PATH,
                    DOCUMENT_TYPE,
                    TEMPLATE_ID,
                    PROCESSING_STATUS
                )
                VALUES
                (
                    UUID_STRING(),
                    S.SRC_CLAIM_ID,
                    S.SRC_FILE_NAME,
                    S.SRC_FILE_PATH,
                    S.SRC_DOCUMENT_TYPE,
                    S.SRC_TEMPLATE_ID,
                    'EXTRACTING'
                );


            SELECT
                D.DOCUMENT_ID
            INTO
                :V_DOCUMENT_ID
            FROM
                HEALTHCARE_CLAIMS_AI_DB.CLAIMS.CLAIM_DOCUMENTS AS D
            WHERE
                D.RELATIVE_PATH = :V_RELATIVE_PATH
            ORDER BY
                D.UPLOADED_AT DESC
            LIMIT 1;


            /*==================================================
              9. Extract document
              ==================================================*/

            IF (V_DOCUMENT_TYPE = 'CLAIM_FORM') THEN
                V_EXTRACTION_RESULT :=
                    V_CLAIM_FORM_RESULT;
            ELSE
                SELECT
                    HEALTHCARE_CLAIMS_AI_DB.CLAIMS.EXTRACT_DOCUMENT_DATA(
                        :V_STAGE_NAME,
                        :V_RELATIVE_PATH,
                        :V_TEMPLATE_ID
                    )
                INTO
                    :V_EXTRACTION_RESULT;
            END IF;


            V_EXTRACTION_ERROR :=
                STRIP_NULL_VALUE(
                    GET(
                        V_EXTRACTION_RESULT,
                        'error'
                    )
                );


            V_EXTRACTION_STATUS :=
                CASE
                    WHEN V_EXTRACTION_ERROR IS NULL
                        THEN 'EXTRACTED'
                    ELSE 'FAILED'
                END;


            V_RESPONSE_OBJECT :=
                CASE
                    WHEN STRIP_NULL_VALUE(
                        GET(
                            V_EXTRACTION_RESULT,
                            'response'
                        )
                    ) IS NULL
                        THEN NULL

                    WHEN TYPEOF(
                        GET(
                            V_EXTRACTION_RESULT,
                            'response'
                        )
                    ) = 'OBJECT'
                        THEN GET(
                            V_EXTRACTION_RESULT,
                            'response'
                        )::OBJECT

                    ELSE OBJECT_CONSTRUCT(
                        'value',
                        GET(
                            V_EXTRACTION_RESULT,
                            'response'
                        )
                    )
                END;


            V_SCORING_OBJECT :=
                CASE
                    WHEN STRIP_NULL_VALUE(
                        GET(
                            V_EXTRACTION_RESULT,
                            'scoring'
                        )
                    ) IS NULL
                        THEN NULL

                    WHEN TYPEOF(
                        GET(
                            V_EXTRACTION_RESULT,
                            'scoring'
                        )
                    ) = 'OBJECT'
                        THEN GET(
                            V_EXTRACTION_RESULT,
                            'scoring'
                        )::OBJECT

                    ELSE OBJECT_CONSTRUCT(
                        'value',
                        GET(
                            V_EXTRACTION_RESULT,
                            'scoring'
                        )
                    )
                END;


            V_ERROR_OBJECT :=
                CASE
                    WHEN V_EXTRACTION_ERROR IS NULL
                        THEN NULL

                    WHEN TYPEOF(V_EXTRACTION_ERROR) = 'OBJECT'
                        THEN V_EXTRACTION_ERROR::OBJECT

                    ELSE OBJECT_CONSTRUCT(
                        'message',
                        V_EXTRACTION_ERROR::VARCHAR
                    )
                END;


            /*==================================================
              10. Store extraction
              ==================================================*/

            DELETE FROM
                HEALTHCARE_CLAIMS_AI_DB.CLAIMS.DOCUMENT_EXTRACTIONS AS E
            WHERE
                E.DOCUMENT_ID = :V_DOCUMENT_ID;


            INSERT INTO
                HEALTHCARE_CLAIMS_AI_DB.CLAIMS.DOCUMENT_EXTRACTIONS
            (
                EXTRACTION_ID,
                DOCUMENT_ID,
                CLAIM_ID,
                DOCUMENT_TYPE,
                TEMPLATE_ID,
                RELATIVE_PATH,
                EXTRACTION_RESULT,
                EXTRACTED_RESPONSE,
                EXTRACTION_SCORING,
                EXTRACTION_ERROR,
                EXTRACTION_STATUS
            )
            SELECT
                UUID_STRING(),
                :V_DOCUMENT_ID,
                :V_CLAIM_ID,
                :V_DOCUMENT_TYPE,
                :V_TEMPLATE_ID,
                :V_RELATIVE_PATH,
                :V_EXTRACTION_RESULT,
                :V_RESPONSE_OBJECT,
                :V_SCORING_OBJECT,
                :V_ERROR_OBJECT,
                :V_EXTRACTION_STATUS;


            UPDATE
                HEALTHCARE_CLAIMS_AI_DB.CLAIMS.CLAIM_DOCUMENTS AS D
            SET
                D.PROCESSING_STATUS =
                    :V_EXTRACTION_STATUS,

                D.ERROR_MESSAGE =
                    CASE
                        WHEN :V_EXTRACTION_ERROR IS NULL
                            THEN NULL
                        ELSE :V_EXTRACTION_ERROR::VARCHAR
                    END,

                D.PROCESSED_AT =
                    CURRENT_TIMESTAMP()

            WHERE
                D.DOCUMENT_ID = :V_DOCUMENT_ID;


            IF (V_EXTRACTION_STATUS = 'EXTRACTED') THEN
                V_EXTRACTED_COUNT :=
                    V_EXTRACTED_COUNT + 1;
            ELSE
                V_FAILED_COUNT :=
                    V_FAILED_COUNT + 1;
            END IF;


        EXCEPTION
            WHEN OTHER THEN

                /*
                  Save the original error before running additional
                  SQL in the exception handler.
                */
                V_ERROR_MESSAGE := SQLERRM;
                V_ERROR_CODE := SQLCODE;
                V_ERROR_STATE := SQLSTATE;

                V_FAILED_COUNT :=
                    V_FAILED_COUNT + 1;


                UPDATE
                    HEALTHCARE_CLAIMS_AI_DB.CLAIMS.CLAIM_DOCUMENTS AS D
                SET
                    D.PROCESSING_STATUS = 'FAILED',
                    D.ERROR_MESSAGE = :V_ERROR_MESSAGE,
                    D.PROCESSED_AT = CURRENT_TIMESTAMP()
                WHERE
                    D.DOCUMENT_ID = :V_DOCUMENT_ID;


                DELETE FROM
                    HEALTHCARE_CLAIMS_AI_DB.CLAIMS.DOCUMENT_EXTRACTIONS AS E
                WHERE
                    E.DOCUMENT_ID = :V_DOCUMENT_ID;


                INSERT INTO
                    HEALTHCARE_CLAIMS_AI_DB.CLAIMS.DOCUMENT_EXTRACTIONS
                (
                    EXTRACTION_ID,
                    DOCUMENT_ID,
                    CLAIM_ID,
                    DOCUMENT_TYPE,
                    TEMPLATE_ID,
                    RELATIVE_PATH,
                    EXTRACTION_ERROR,
                    EXTRACTION_STATUS
                )
                SELECT
                    UUID_STRING(),
                    :V_DOCUMENT_ID,
                    :V_CLAIM_ID,
                    :V_DOCUMENT_TYPE,
                    :V_TEMPLATE_ID,
                    :V_RELATIVE_PATH,
                    OBJECT_CONSTRUCT(
                        'message', :V_ERROR_MESSAGE,
                        'sqlcode', :V_ERROR_CODE,
                        'sqlstate', :V_ERROR_STATE
                    ),
                    'FAILED';

        END;

    END FOR;


    /*==========================================================
      11. Update claim status
      ==========================================================*/

    UPDATE
        HEALTHCARE_CLAIMS_AI_DB.CLAIMS.PATIENT_CLAIMS AS C
    SET
        C.CLAIM_STATUS =
            CASE
                WHEN :V_DOCUMENT_COUNT = 0
                    THEN 'NO_SUPPORTED_DOCUMENTS'

                WHEN :V_FAILED_COUNT > 0
                 AND :V_EXTRACTED_COUNT > 0
                    THEN 'EXTRACTION_COMPLETED_WITH_ERRORS'

                WHEN :V_FAILED_COUNT > 0
                 AND :V_EXTRACTED_COUNT = 0
                    THEN 'EXTRACTION_FAILED'

                WHEN :V_EXTRACTED_COUNT = :V_DOCUMENT_COUNT
                    THEN 'EXTRACTION_COMPLETED'

                ELSE 'PROCESSING'
            END
    WHERE
        C.CLAIM_ID = :V_CLAIM_ID;


    RETURN OBJECT_CONSTRUCT(
        'status',
        IFF(
            V_FAILED_COUNT = 0,
            'SUCCESS',
            'COMPLETED_WITH_ERRORS'
        ),
        'folder_path', V_FOLDER_PATH,
        'claim_id', V_CLAIM_ID,
        'patient_id', V_PATIENT_ID,
        'patient_name', V_PATIENT_NAME,
        'policy_number', V_POLICY_NUMBER,
        'claim_type', V_CLAIM_TYPE,
        'claimed_amount', V_CLAIMED_AMOUNT,
        'documents_found', V_DOCUMENT_COUNT,
        'documents_extracted', V_EXTRACTED_COUNT,
        'documents_failed', V_FAILED_COUNT,
        'documents_skipped', V_SKIPPED_COUNT
    );


EXCEPTION
    WHEN OTHER THEN

        V_ERROR_MESSAGE := SQLERRM;
        V_ERROR_CODE := SQLCODE;
        V_ERROR_STATE := SQLSTATE;


        IF (V_CLAIM_ID IS NOT NULL) THEN
            UPDATE
                HEALTHCARE_CLAIMS_AI_DB.CLAIMS.PATIENT_CLAIMS AS C
            SET
                C.CLAIM_STATUS =
                    'EXTRACTION_FAILED',

                C.REVIEWER_COMMENTS =
                    'Folder processing error: '
                    || :V_ERROR_MESSAGE
            WHERE
                C.CLAIM_ID = :V_CLAIM_ID;
        END IF;


        RETURN OBJECT_CONSTRUCT(
            'status', 'FAILED',
            'folder_path', V_FOLDER_PATH,
            'claim_id', V_CLAIM_ID,
            'message', V_ERROR_MESSAGE,
            'sqlcode', V_ERROR_CODE,
            'sqlstate', V_ERROR_STATE
        );

END;
$$;

--Test if it processes your files.
CALL HEALTHCARE_CLAIMS_AI_DB.CLAIMS.LOAD_PATIENT_CLAIM_FOLDER(
    'Gregorio366_Auer97_f5dcd418'
);