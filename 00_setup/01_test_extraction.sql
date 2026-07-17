

--Test Extraction with AI_EXTRACT

SELECT AI_EXTRACT(
        file => TO_FILE(
            '@HEALTHCARE_CLAIMS_AI_DB.CLAIMS.CLAIM_DOCUMENT_STAGE',
            'Gregorio366_Auer97_f5dcd418/claim_form.pdf'
        ),
        responseFormat =>  [['insurance_provider', 'Who is the insurance provider?'], ['primary_diagnosis', 'What is the primary diagnosis of the patient?']]
);

--Test Extraction with AI_PARSE_DOCUMENT
SELECT AI_PARSE_DOCUMENT(
        TO_FILE(
            '@HEALTHCARE_CLAIMS_AI_DB.CLAIMS.CLAIM_DOCUMENT_STAGE',
            'Gregorio366_Auer97_f5dcd418/claim_form.pdf'
        ),
        {'mode':'LAYOUT'}) AS claim_form;

