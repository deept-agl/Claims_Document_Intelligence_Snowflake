import io
import json
import re
import uuid
from datetime import datetime
from typing import Optional

import pandas as pd
import streamlit as st
from snowflake.snowpark.context import get_active_session

# ============================================================
# CONFIGURATION
# ============================================================

session = get_active_session()

DATABASE = "HEALTHCARE_CLAIMS_AI_DB"
SCHEMA = "CLAIMS"

STAGE = ("@HEALTHCARE_CLAIMS_AI_DB.CLAIMS.CLAIM_DOCUMENT_STAGE")

PATIENT_CLAIMS_TABLE = ("HEALTHCARE_CLAIMS_AI_DB.CLAIMS.PATIENT_CLAIMS")
CLAIM_DOCUMENTS_TABLE = ("HEALTHCARE_CLAIMS_AI_DB.CLAIMS.CLAIM_DOCUMENTS")
VALIDATION_TABLE = ("HEALTHCARE_CLAIMS_AI_DB.CLAIMS.CLAIM_VALIDATION_RESULTS")

st.set_page_config(
    page_title="Claims Review Workbench",
    page_icon="🏥",
    layout="wide",
)

# ============================================================
# HELPERS
# ============================================================

def sanitize_name(value: str) -> str:
    cleaned = re.sub(
        r"[^A-Za-z0-9._-]+",
        "_",
        value.strip(),
    )
    return cleaned.strip("._-")


def escape_sql(value: str) -> str:
    return value.replace("'", "''")


def run_query(query: str) -> pd.DataFrame:
    return session.sql(query).to_pandas()


def upload_to_stage(
    uploaded_file,
    folder_name: str,
) -> None:

    safe_file_name = sanitize_name(uploaded_file.name)

    stage_path = (
        f"{STAGE}/"
        f"{folder_name}/"
        f"{safe_file_name}"
    )

    file_stream = io.BytesIO(uploaded_file.getvalue())

    session.file.put_stream(
        input_stream=file_stream,
        stage_location=stage_path,
        auto_compress=False,
        overwrite=True,
    )


def get_claims() -> pd.DataFrame:

    return run_query(
        f"""
        SELECT
            CLAIM_ID,
            PATIENT_ID,
            PATIENT_NAME,
            POLICY_NUMBER,
            CLAIM_TYPE,
            CLAIMED_AMOUNT,
            CLAIM_STATUS,
            REVIEWER_DECISION,
            REVIEWER_COMMENTS,
            CREATED_AT,
            REVIEWED_AT
        FROM {PATIENT_CLAIMS_TABLE}
        ORDER BY CREATED_AT DESC
        """
    )

def get_claim_documents(
    claim_id: str,
) -> pd.DataFrame:

    safe_claim_id = escape_sql(claim_id)

    return run_query(
        f"""
        SELECT
            D.FILE_NAME,
            D.RELATIVE_PATH,
            D.DOCUMENT_TYPE,
            D.PROCESSING_STATUS,
            D.ERROR_MESSAGE,
            D.UPLOADED_AT,
            D.PROCESSED_AT,

            GET_PRESIGNED_URL(
                {STAGE},
                D.RELATIVE_PATH,
                3600
            ) AS DOCUMENT_URL

        FROM {CLAIM_DOCUMENTS_TABLE} AS D

        WHERE D.CLAIM_ID = '{safe_claim_id}'

        ORDER BY
            CASE D.DOCUMENT_TYPE
                WHEN 'CLAIM_FORM' THEN 1
                WHEN 'PRESCRIPTION' THEN 2
                WHEN 'DISCHARGE_SUMMARY' THEN 3
                WHEN 'HOSPITAL_INVOICE' THEN 4
                WHEN 'PHARMACY_INVOICE' THEN 5
                WHEN 'DIAGNOSTIC_REPORT' THEN 6
                WHEN 'PAYMENT_RECEIPT' THEN 7
                ELSE 8
            END
        """
    )


def get_claim_validations(
    claim_id: str,
) -> pd.DataFrame:

    safe_claim_id = escape_sql(claim_id)

    return run_query(
        f"""
        SELECT
            VALIDATION_CATEGORY,
            VALIDATION_NAME,
            VALIDATION_STATUS,
            EXPECTED_VALUE,
            ACTUAL_VALUE,
            VALIDATION_MESSAGE,
            SEVERITY,
            REQUIRES_REVIEW,
            SOURCE_DOCUMENTS,
            VALIDATED_AT
        FROM {VALIDATION_TABLE}
        WHERE CLAIM_ID = '{safe_claim_id}'
        ORDER BY
            CASE VALIDATION_STATUS
                WHEN 'FAILED' THEN 1
                WHEN 'WARNING' THEN 2
                WHEN 'PASSED' THEN 3
                ELSE 4
            END,
            VALIDATED_AT
        """
    )


def get_status_icon(status: str) -> str:

    status_map = {
        "PASSED": "✅",
        "WARNING": "⚠️",
        "FAILED": "❌",
        "READY_FOR_APPROVAL": "✅",
        "FINANCIAL_REVIEW_REQUIRED": "💰",
        "MEDICAL_REVIEW_REQUIRED": "🩺",
        "MANUAL_REVIEW_REQUIRED": "🔍",
        "MORE_INFORMATION_REQUIRED": "📄",
        "APPROVED": "✅",
        "REJECTED": "❌",
        "PROCESSING": "⏳",
    }

    return status_map.get(
        str(status).upper(),
        "ℹ️",
    )


def parse_source_documents(
    value,
) -> list[str]:

    if value is None:
        return []

    if isinstance(value, list):
        return [str(item) for item in value]

    if isinstance(value, tuple):
        return [str(item) for item in value]

    value_text = str(value)

    try:
        parsed = json.loads(value_text)

        if isinstance(parsed, list):
            return [
                str(item)
                for item in parsed
            ]

    except Exception:
        pass

    return [
        item.strip().strip('"[]')
        for item in value_text.split(",")
        if item.strip()
    ]


def update_reviewer_decision(
    claim_id: str,
    decision: str,
    comments: str,
) -> None:

    safe_claim_id = escape_sql(claim_id)
    safe_decision = escape_sql(decision)
    safe_comments = escape_sql(comments)

    session.sql(
        f"""
        UPDATE {PATIENT_CLAIMS_TABLE}
        SET
            REVIEWER_DECISION = '{safe_decision}',
            REVIEWER_COMMENTS = '{safe_comments}',
            CLAIM_STATUS = '{safe_decision}',
            REVIEWED_AT = CURRENT_TIMESTAMP()
        WHERE CLAIM_ID = '{safe_claim_id}'
        """
    ).collect()


# ============================================================
# HEADER
# ============================================================

st.title("🏥 Claims Review Workbench")

st.caption(
    "Submit healthcare claim documents, review automated checks, "
    "inspect supporting documents, and record the final claim decision."
)


tab_upload, tab_review = st.tabs(
    [
        "📤 Submit Claim Documents",
        "📋 Review Claims",
    ]
)


# ============================================================
# TAB 1: CLAIM DOCUMENT UPLOAD
# ============================================================

with tab_upload:

    st.subheader("Submit claim documents")

    st.write(
        "Upload all documents related to one healthcare claim. "
        "The documents will be processed automatically after submission."
    )

    col1, col2 = st.columns(2)

    with col1:

        patient_name = st.text_input(
            "Patient name",
            placeholder="Example: Gregorio366 Auer97",
        )

    with col2:

        claim_reference = st.text_input(
            "Claim reference",
            placeholder="Example: f5dcd418",
            help=(
                "Use a unique patient, policy, or submission reference. "
                "A reference will be generated when left blank."
            ),
        )

    uploaded_files = st.file_uploader(
        "Upload supporting documents",
        type=[
            "pdf",
            "png",
            "jpg",
            "jpeg",
        ],
        accept_multiple_files=True,
        help=(
            "Upload the claim form and all available supporting documents, "
            "such as prescriptions, invoices, discharge summaries, "
            "diagnostic reports, and payment receipts."
        ),
    )

    if uploaded_files:

        file_preview = pd.DataFrame(
            [
                {
                    "Document": file.name,
                    "Size (KB)": round(
                        file.size / 1024,
                        2,
                    ),
                }
                for file in uploaded_files
            ]
        )

        st.dataframe(
            file_preview,
            use_container_width=True,
            hide_index=True,
        )

        file_names = [
            file.name.lower()
            for file in uploaded_files
        ]

        claim_form_present = any(
            "claim" in file_name
            and "form" in file_name
            for file_name in file_names
        )

        if claim_form_present:

            st.success(
                "Claim form identified."
            )

        else:

            st.warning(
                "A claim form could not be identified. "
                "Ensure one filename contains both 'claim' and 'form'."
            )

    submitted = st.button(
        "Submit Claim",
        type="primary",
        use_container_width=True,
        disabled=not uploaded_files,
    )

    if submitted:

        if not patient_name.strip():

            st.error(
                "Enter the patient name."
            )

        elif not uploaded_files:

            st.error(
                "Upload at least one document."
            )

        else:

            file_names = [
                file.name.lower()
                for file in uploaded_files
            ]

            claim_form_present = any(
                "claim" in file_name
                and "form" in file_name
                for file_name in file_names
            )

            if not claim_form_present:

                st.error(
                    "A claim form is required before submission."
                )

            else:

                safe_patient_name = sanitize_name(
                    patient_name
                )

                safe_reference = sanitize_name(
                    claim_reference
                )

                if not safe_reference:

                    safe_reference = uuid.uuid4().hex[:8]

                folder_name = (f"{safe_patient_name}_"f"{safe_reference}"
                )

                progress = st.progress(0)
                message = st.empty()

                try:

                    for index, file in enumerate(
                        uploaded_files,
                        start=1,
                    ):

                        message.info(
                            f"Uploading {file.name}"
                        )

                        upload_to_stage(
                            file,
                            folder_name,
                        )

                        progress.progress(
                            int(
                                index
                                / len(uploaded_files)
                                * 100
                            )
                        )

                    message.empty()

                    st.success(
                        "Claim documents submitted successfully."
                    )

                    st.info(
                        "The claim will appear in the review queue "
                        "after automated extraction and validation complete."
                    )

                    st.markdown(
                        f"**Submission reference:** `{folder_name}`"
                    )

                except Exception as exc:

                    st.error(
                        f"Unable to submit documents: {exc}"
                    )


# ============================================================
# TAB 2: CLAIM REVIEW
# ============================================================

with tab_review:

    top_col1, top_col2 = st.columns(
        [5, 1]
    )

    with top_col1:

        st.subheader("Claims review queue")

    with top_col2:

        if st.button(
            "Refresh",
            use_container_width=True,
        ):
            st.rerun()

    try:

        claims_df = get_claims()

    except Exception as exc:

        claims_df = pd.DataFrame()

        st.error(
            f"Unable to load claims: {exc}"
        )

    if claims_df.empty:

        st.info(
            "No claims are currently available for review."
        )

    else:

        filter_col1, filter_col2 = st.columns(2)

        with filter_col1:

            status_options = [
                "All"
            ] + sorted(
                claims_df[
                    "CLAIM_STATUS"
                ].dropna().unique().tolist()
            )

            selected_status = st.selectbox(
                "Filter by claim status",
                status_options,
            )

        with filter_col2:

            search_text = st.text_input(
                "Search by claim, patient, or policy",
                placeholder="Enter search text",
            )

        filtered_claims = claims_df.copy()

        if selected_status != "All":

            filtered_claims = filtered_claims[
                filtered_claims["CLAIM_STATUS"]
                == selected_status
            ]

        if search_text.strip():

            search_value = search_text.lower()

            filtered_claims = filtered_claims[
                filtered_claims.astype(str)
                .apply(
                    lambda row: row.str.lower()
                    .str.contains(
                        search_value,
                        na=False,
                    )
                    .any(),
                    axis=1,
                )
            ]

        claim_labels = {
            (
                f"{get_status_icon(row['CLAIM_STATUS'])} "
                f"{row['CLAIM_ID']} | "
                f"{row['PATIENT_NAME']} | "
                f"{row['CLAIM_STATUS']}"
            ): row["CLAIM_ID"]
            for _, row in filtered_claims.iterrows()
        }

        if not claim_labels:

            st.info(
                "No claims match the selected filters."
            )

        else:

            selected_label = st.selectbox(
                "Select claim",
                list(claim_labels.keys()),
            )

            selected_claim_id = claim_labels[
                selected_label
            ]

            claim = claims_df[
                claims_df["CLAIM_ID"]
                == selected_claim_id
            ].iloc[0]

            st.markdown("---")

            summary_col1, summary_col2, summary_col3, summary_col4 = (
                st.columns(4)
            )

            summary_col1.metric(
                "Claim ID",
                claim["CLAIM_ID"],
            )

            summary_col2.metric(
                "Patient",
                claim["PATIENT_NAME"],
            )

            amount = claim["CLAIMED_AMOUNT"]

            summary_col3.metric(
                "Claimed Amount",
                (
                    f"₹{amount:,.2f}"
                    if pd.notna(amount)
                    else "Not available"
                ),
            )

            summary_col4.metric(
                "Current Status",
                (
                    f"{get_status_icon(claim['CLAIM_STATUS'])} "
                    f"{claim['CLAIM_STATUS']}"
                ),
            )

            details_col1, details_col2 = st.columns(2)

            with details_col1:

                st.markdown(
                    f"**Patient ID:** {claim['PATIENT_ID']}"
                )

                st.markdown(
                    f"**Policy Number:** {claim['POLICY_NUMBER']}"
                )

            with details_col2:

                st.markdown(
                    f"**Claim Type:** {claim['CLAIM_TYPE']}"
                )

                st.markdown(
                    f"**Submitted On:** {claim['CREATED_AT']}"
                )

            try:

                documents_df = get_claim_documents(
                    selected_claim_id
                )

                validations_df = get_claim_validations(
                    selected_claim_id
                )

            except Exception as exc:

                documents_df = pd.DataFrame()
                validations_df = pd.DataFrame()

                st.error(
                    f"Unable to load claim review details: {exc}"
                )

            review_tab1, review_tab2, review_tab3 = st.tabs(
                [
                    "Validation Summary",
                    "Supporting Documents",
                    "Reviewer Decision",
                ]
            )


            # ==================================================
            # VALIDATION SUMMARY
            # ==================================================

            with review_tab1:

                if validations_df.empty:

                    st.info(
                        "Validation results are not yet available."
                    )

                else:

                    detail_validations = validations_df[
                        validations_df[
                            "VALIDATION_CATEGORY"
                        ] != "CLAIM_DECISION"
                    ].copy()

                    passed = int(
                        (
                            detail_validations[
                                "VALIDATION_STATUS"
                            ] == "PASSED"
                        ).sum()
                    )

                    warnings = int(
                        (
                            detail_validations[
                                "VALIDATION_STATUS"
                            ] == "WARNING"
                        ).sum()
                    )

                    failed = int(
                        (
                            detail_validations[
                                "VALIDATION_STATUS"
                            ] == "FAILED"
                        ).sum()
                    )

                    col1, col2, col3 = st.columns(3)

                    col1.metric(
                        "Passed Checks",
                        passed,
                    )

                    col2.metric(
                        "Warnings",
                        warnings,
                    )

                    col3.metric(
                        "Failed Checks",
                        failed,
                    )

                    issue_validations = detail_validations[
                        detail_validations[
                            "VALIDATION_STATUS"
                        ].isin(
                            [
                                "FAILED",
                                "WARNING",
                            ]
                        )
                    ]

                    if issue_validations.empty:

                        st.success(
                            "No validation issues were identified."
                        )

                    else:

                        st.markdown(
                            "#### Items requiring attention"
                        )

                        for _, validation in (
                            issue_validations.iterrows()
                        ):

                            validation_status = validation[
                                "VALIDATION_STATUS"
                            ]

                            with st.expander(
                                (
                                    f"{get_status_icon(validation_status)} "
                                    f"{validation['VALIDATION_NAME']} — "
                                    f"{validation_status}"
                                ),
                                expanded=True,
                            ):

                                st.write(
                                    validation[
                                        "VALIDATION_MESSAGE"
                                    ]
                                )

                                info_col1, info_col2 = (
                                    st.columns(2)
                                )

                                info_col1.markdown(
                                    f"**Severity:** "
                                    f"{validation['SEVERITY']}"
                                )

                                info_col2.markdown(
                                    f"**Category:** "
                                    f"{validation['VALIDATION_CATEGORY']}"
                                )

                                st.markdown(
                                    "**Expected**"
                                )

                                st.write(
                                    validation[
                                        "EXPECTED_VALUE"
                                    ]
                                )

                                st.markdown(
                                    "**Actual**"
                                )

                                st.code(
                                    str(
                                        validation[
                                            "ACTUAL_VALUE"
                                        ]
                                    ),
                                    language="json",
                                )

                                source_document_types = (
                                    parse_source_documents(
                                        validation[
                                            "SOURCE_DOCUMENTS"
                                        ]
                                    )
                                )

                                if (
                                    source_document_types
                                    and not documents_df.empty
                                ):

                                    related_documents = (
                                        documents_df[
                                            documents_df[
                                                "DOCUMENT_TYPE"
                                            ].isin(
                                                source_document_types
                                            )
                                        ][
                                            [
                                                "FILE_NAME",
                                                "DOCUMENT_TYPE",
                                                "DOCUMENT_URL",
                                            ]
                                        ]
                                    )

                                    if not related_documents.empty:

                                        st.markdown(
                                            "**Documents related to this check**"
                                        )

                                        st.dataframe(
                                            related_documents,
                                            use_container_width=True,
                                            hide_index=True,
                                            column_config={
                                                "DOCUMENT_URL":
                                                    st.column_config.LinkColumn(
                                                        "Open Document",
                                                        display_text="View document",
                                                    )
                                            },
                                        )


            # ==================================================
            # SUPPORTING DOCUMENTS
            # ==================================================

            with review_tab2:

                st.markdown(
                    "#### Submitted claim documents"
                )

                if documents_df.empty:

                    st.info(
                        "No supporting documents are available."
                    )

                else:

                    document_display = documents_df[
                        [
                            "FILE_NAME",
                            "DOCUMENT_TYPE",
                            "PROCESSING_STATUS",
                            "DOCUMENT_URL",
                        ]
                    ].copy()

                    st.dataframe(
                        document_display,
                        use_container_width=True,
                        hide_index=True,
                        column_config={
                            "FILE_NAME":
                                st.column_config.TextColumn(
                                    "Document"
                                ),

                            "DOCUMENT_TYPE":
                                st.column_config.TextColumn(
                                    "Document Type"
                                ),

                            "PROCESSING_STATUS":
                                st.column_config.TextColumn(
                                    "Processing Status"
                                ),

                            "DOCUMENT_URL":
                                st.column_config.LinkColumn(
                                    "Document Link",
                                    display_text="Open document",
                                ),
                        },
                    )


            # ==================================================
            # REVIEWER DECISION
            # ==================================================

            with review_tab3:

                st.markdown(
                    "#### Record reviewer decision"
                )

                current_decision = (
                    claim["REVIEWER_DECISION"]
                    if pd.notna(
                        claim["REVIEWER_DECISION"]
                    )
                    else "PENDING"
                )

                current_comments = (
                    claim["REVIEWER_COMMENTS"]
                    if pd.notna(
                        claim["REVIEWER_COMMENTS"]
                    )
                    else ""
                )

                st.markdown(
                    f"**Current decision:** {current_decision}"
                )

                decision = st.selectbox(
                    "Decision",
                    [
                        "APPROVED",
                        "REJECTED",
                        "MORE_INFORMATION_REQUIRED",
                        "MEDICAL_REVIEW_REQUIRED",
                        "FINANCIAL_REVIEW_REQUIRED",
                    ],
                    index=0,
                )

                comments = st.text_area(
                    "Reviewer comments",
                    value=current_comments,
                    placeholder=(
                        "Add the reason for the decision, "
                        "documents reviewed, and any follow-up required."
                    ),
                    height=150,
                )

                submit_decision = st.button(
                    "Save Reviewer Decision",
                    type="primary",
                    use_container_width=True,
                )

                if submit_decision:

                    if not comments.strip():

                        st.error(
                            "Add reviewer comments before saving the decision."
                        )

                    else:

                        try:

                            update_reviewer_decision(
                                claim_id=selected_claim_id,
                                decision=decision,
                                comments=comments,
                            )

                            st.success(
                                "Reviewer decision saved successfully."
                            )

                            st.rerun()

                        except Exception as exc:

                            st.error(
                                f"Unable to save decision: {exc}"
                            )