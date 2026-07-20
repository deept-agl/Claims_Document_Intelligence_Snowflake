import io
import json
import re
from typing import Any

import pandas as pd
import streamlit as st
from snowflake.snowpark.context import get_active_session


# ============================================================
# CONFIGURATION
# ============================================================

session = get_active_session()

DATABASE = "HEALTHCARE_CLAIMS_AI_DB"
SCHEMA = "CLAIMS"

STAGE = (
    "@HEALTHCARE_CLAIMS_AI_DB."
    "CLAIMS."
    "CLAIM_DOCUMENT_STAGE"
)

PATIENT_CLAIMS_TABLE = (
    "HEALTHCARE_CLAIMS_AI_DB."
    "CLAIMS."
    "PATIENT_CLAIMS"
)

CLAIM_DOCUMENTS_TABLE = (
    "HEALTHCARE_CLAIMS_AI_DB."
    "CLAIMS."
    "CLAIM_DOCUMENTS"
)

VALIDATION_TABLE = (
    "HEALTHCARE_CLAIMS_AI_DB."
    "CLAIMS."
    "CLAIM_VALIDATION_RESULTS"
)


st.set_page_config(
    page_title="Claims Review Workbench",
    page_icon="🏥",
    layout="wide",
)


# ============================================================
# HELPER FUNCTIONS
# ============================================================

def sanitize_name(value: str) -> str:
    """
    Convert user input into a safe stage-folder or file name.
    """

    cleaned = re.sub(
        r"[^A-Za-z0-9._-]+",
        "_",
        value.strip(),
    )

    return cleaned.strip("._-")


def escape_sql(value: Any) -> str:
    """
    Escape apostrophes before placing text inside SQL literals.
    """

    return str(value).replace("'", "''")


def run_query(query: str) -> pd.DataFrame:
    """
    Run a Snowflake query and return a pandas DataFrame.
    """

    return session.sql(query).to_pandas()


def upload_to_stage(
    uploaded_file: Any,
    folder_name: str,
) -> None:
    """
    Upload one document into the claim-specific stage folder.
    """

    safe_file_name = sanitize_name(
        uploaded_file.name
    )

    stage_path = (
        f"{STAGE}/"
        f"{folder_name}/"
        f"{safe_file_name}"
    )

    file_stream = io.BytesIO(
        uploaded_file.getvalue()
    )

    session.file.put_stream(
        input_stream=file_stream,
        stage_location=stage_path,
        auto_compress=False,
        overwrite=True,
    )


def get_claims() -> pd.DataFrame:
    """
    Load all patient claims.
    """

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
    """
    Load claim documents and generate browser-accessible links.
    """

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
            END,
            D.FILE_NAME
        """
    )


def get_claim_validations(
    claim_id: str,
) -> pd.DataFrame:
    """
    Load validation results for one claim.
    """

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


def update_reviewer_decision(
    claim_id: str,
    decision: str,
    comments: str,
) -> None:
    """
    Save reviewer decision and comments.
    """

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


def get_status_icon(status: Any) -> str:
    """
    Return an icon for common workflow statuses.
    """

    status_map = {
        "PASSED": "✅",
        "SUCCESS": "✅",
        "EXTRACTED": "✅",
        "COMPLETED": "✅",
        "EXTRACTION_COMPLETED": "✅",
        "READY_FOR_APPROVAL": "✅",
        "APPROVED": "✅",

        "WARNING": "⚠️",
        "MANUAL_REVIEW_REQUIRED": "🔍",
        "MORE_INFORMATION_REQUIRED": "📄",

        "FAILED": "❌",
        "REJECTED": "❌",
        "EXTRACTION_FAILED": "❌",
        "FINANCIAL_REVIEW_REQUIRED": "💰",
        "MEDICAL_REVIEW_REQUIRED": "🩺",

        "PROCESSING": "⏳",
        "EXTRACTING": "⏳",
        "UPLOADED": "📤",
        "PENDING": "⏳",
    }

    return status_map.get(
        str(status).upper(),
        "ℹ️",
    )


def parse_source_documents(
    value: Any,
) -> list[str]:
    """
    Convert Snowflake ARRAY or JSON text into a Python list.
    """

    if value is None:
        return []

    if isinstance(value, list):
        return [
            str(item)
            for item in value
        ]

    if isinstance(value, tuple):
        return [
            str(item)
            for item in value
        ]

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


def format_actual_value(
    value: Any,
) -> str:
    """
    Pretty-format JSON validation values when possible.
    """

    if value is None:
        return "Not available"

    value_text = str(value)

    try:
        parsed = json.loads(value_text)

        return json.dumps(
            parsed,
            indent=2,
            default=str,
        )

    except Exception:
        return value_text


def go_to_review_page() -> None:
    """
    Move to the review page after document submission.
    """

    st.session_state["active_page"] = "Review Claims"


# ============================================================
# PAGE HEADER
# ============================================================

st.title("🏥 Claims Review Workbench")

st.caption(
    "Submit healthcare claim documents, review automated checks, "
    "inspect supporting evidence, and record the final claim decision."
)


# ============================================================
# PERSISTENT PAGE NAVIGATION
# ============================================================

if "active_page" not in st.session_state:
    st.session_state["active_page"] = "Review Claims"


active_page = st.radio(
    "Navigation",
    options=[
        "Submit Claim Documents",
        "Review Claims",
    ],
    key="active_page",
    horizontal=True,
    label_visibility="collapsed",
)


st.markdown("---")


# ============================================================
# PAGE 1: SUBMIT CLAIM DOCUMENTS
# ============================================================

if active_page == "Submit Claim Documents":

    st.subheader("📤 Submit claim documents")

    st.write(
        "Upload all documents related to one healthcare claim. "
        "The patient name and claim reference will be combined to "
        "create the claim folder."
    )

    input_col1, input_col2 = st.columns(2)

    with input_col1:

        patient_name = st.text_input(
            "Patient name",
            placeholder="Example: Gregorio366 Auer97",
            key="upload_patient_name",
        )

    with input_col2:

        claim_reference = st.text_input(
            "Claim reference",
            placeholder="Example: f5dcd418",
            key="upload_claim_reference",
            help=(
                "Enter a unique policy, patient, or submission reference."
            ),
        )


    # --------------------------------------------------------
    # Folder preview
    # --------------------------------------------------------

    if (
        patient_name.strip()
        and claim_reference.strip()
    ):

        folder_preview = (
            f"{sanitize_name(patient_name)}_"
            f"{sanitize_name(claim_reference)}"
        )

        st.info(
            f"Stage folder: `{folder_preview}`"
        )


    # --------------------------------------------------------
    # File upload
    # --------------------------------------------------------

    uploaded_files = st.file_uploader(
        "Upload supporting documents",
        type=[
            "pdf",
            "png",
            "jpg",
            "jpeg",
        ],
        accept_multiple_files=True,
        key="claim_document_uploader",
        help=(
            "Upload the claim form and supporting documents such as "
            "prescriptions, invoices, discharge summaries, diagnostic "
            "reports, and payment receipts."
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


    # --------------------------------------------------------
    # Submit claim
    # --------------------------------------------------------

    submitted = st.button(
        "Submit Claim",
        type="primary",
        use_container_width=True,
        disabled=not uploaded_files,
        key="submit_claim_button",
    )


    if submitted:

        if not patient_name.strip():

            st.error(
                "Enter the patient name."
            )

        elif not claim_reference.strip():

            st.error(
                "Enter the claim reference."
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

                folder_name = (
                    f"{safe_patient_name}_"
                    f"{safe_reference}"
                )

                progress = st.progress(0)

                upload_message = st.empty()

                try:

                    total_files = len(
                        uploaded_files
                    )

                    for index, file in enumerate(
                        uploaded_files,
                        start=1,
                    ):

                        upload_message.info(
                            f"Uploading {file.name}..."
                        )

                        upload_to_stage(
                            file,
                            folder_name,
                        )

                        progress.progress(
                            int(
                                index
                                / total_files
                                * 100
                            )
                        )

                    upload_message.empty()

                    st.success(
                        "Claim documents submitted successfully."
                    )

                    st.info(
                        "Automated extraction and validation will begin. "
                        "The claim will appear in the review queue after "
                        "processing is complete."
                    )

                    st.markdown(
                        f"**Submission reference:** `{folder_name}`"
                    )

                    st.button(
                        "Go to Claims Review",
                        type="primary",
                        use_container_width=True,
                        key="go_to_review_after_upload",
                        on_click=go_to_review_page,
                    )

                except Exception as exc:

                    st.error(
                        f"Unable to submit documents: {exc}"
                    )


# ============================================================
# PAGE 2: REVIEW CLAIMS
# ============================================================

elif active_page == "Review Claims":

    review_header_col, refresh_col = st.columns(
        [5, 1]
    )

    with review_header_col:

        st.subheader("📋 Claims review queue")

    with refresh_col:

        if st.button(
            "Refresh",
            use_container_width=True,
            key="refresh_claim_review",
        ):
            st.rerun()


    # --------------------------------------------------------
    # Load claims
    # --------------------------------------------------------

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

        # ----------------------------------------------------
        # Filters
        # ----------------------------------------------------

        filter_col1, filter_col2 = st.columns(2)

        with filter_col1:

            status_options = [
                "All"
            ] + sorted(
                claims_df[
                    "CLAIM_STATUS"
                ]
                .dropna()
                .astype(str)
                .unique()
                .tolist()
            )

            selected_status = st.selectbox(
                "Filter by claim status",
                options=status_options,
                key="review_status_filter",
            )

        with filter_col2:

            search_text = st.text_input(
                "Search by claim, patient, or policy",
                placeholder="Enter search text",
                key="review_claim_search",
            )


        filtered_claims = claims_df.copy()


        if selected_status != "All":

            filtered_claims = filtered_claims[
                filtered_claims[
                    "CLAIM_STATUS"
                ].astype(str)
                == selected_status
            ]


        if search_text.strip():

            search_value = (
                search_text
                .strip()
                .lower()
            )

            filtered_claims = filtered_claims[
                filtered_claims
                .astype(str)
                .apply(
                    lambda row: (
                        row
                        .str.lower()
                        .str.contains(
                            search_value,
                            regex=False,
                            na=False,
                        )
                        .any()
                    ),
                    axis=1,
                )
            ]


        if filtered_claims.empty:

            st.info(
                "No claims match the selected filters."
            )

        else:

            # ------------------------------------------------
            # Persistent claim selector
            # ------------------------------------------------

            claim_ids = (
                filtered_claims[
                    "CLAIM_ID"
                ]
                .astype(str)
                .tolist()
            )

            claim_display_map = {
                str(row["CLAIM_ID"]): (
                    f"{get_status_icon(row['CLAIM_STATUS'])} "
                    f"{row['CLAIM_ID']} | "
                    f"{row['PATIENT_NAME']} | "
                    f"{row['CLAIM_STATUS']}"
                )
                for _, row in filtered_claims.iterrows()
            }


            if (
                "selected_review_claim_id"
                not in st.session_state
            ):

                st.session_state[
                    "selected_review_claim_id"
                ] = claim_ids[0]


            if (
                st.session_state[
                    "selected_review_claim_id"
                ]
                not in claim_ids
            ):

                st.session_state[
                    "selected_review_claim_id"
                ] = claim_ids[0]


            selected_claim_id = st.selectbox(
                "Select claim",
                options=claim_ids,
                format_func=lambda claim_id: (
                    claim_display_map.get(
                        claim_id,
                        claim_id,
                    )
                ),
                key="selected_review_claim_id",
            )


            claim_rows = claims_df[
                claims_df[
                    "CLAIM_ID"
                ].astype(str)
                == str(selected_claim_id)
            ]


            if claim_rows.empty:

                st.warning(
                    "The selected claim is no longer available."
                )

            else:

                claim = claim_rows.iloc[0]

                st.markdown("---")


                # --------------------------------------------
                # Claim summary
                # --------------------------------------------

                summary_col1, summary_col2, summary_col3, summary_col4 = st.columns(4)
                
                with summary_col1:
                    st.markdown("**Claim ID**")
                    st.write(claim["CLAIM_ID"])
                
                with summary_col2:
                    st.markdown("**Patient**")
                    st.write(claim["PATIENT_NAME"])
                
                with summary_col3:
                    st.markdown("**Claimed Amount**")
                    amount = claim["CLAIMED_AMOUNT"]
                
                    st.write(
                        f"₹{amount:,.2f}"
                        if pd.notna(amount)
                        else "Not available"
                    )
                
                with summary_col4:
                    st.markdown("**Current Status**")
                    st.write(claim["CLAIM_STATUS"])
                    #     # f"{get_status_icon(claim['CLAIM_STATUS'])} "
                    #     f"{claim['CLAIM_STATUS']}"
                    # )

                details_col1, details_col2 = (
                    st.columns(2)
                )


                with details_col1:

                    st.markdown(
                        f"**Patient ID:** "
                        f"{claim['PATIENT_ID']}"
                    )

                    st.markdown(
                        f"**Patient Name:** "
                        f"{claim['PATIENT_NAME']}"
                    )

                    st.markdown(
                        f"**Policy Number:** "
                        f"{claim['POLICY_NUMBER']}"
                    )


                with details_col2:

                    st.markdown(
                        f"**Claim Type:** "
                        f"{claim['CLAIM_TYPE']}"
                    )

                    st.markdown(
                        f"**Submitted On:** "
                        f"{claim['CREATED_AT']}"
                    )

                    reviewed_at = claim[
                        "REVIEWED_AT"
                    ]

                    st.markdown(
                        f"**Reviewed On:** "
                        f"{reviewed_at if pd.notna(reviewed_at) else 'Pending'}"
                    )


                # --------------------------------------------
                # Load documents and validations
                # --------------------------------------------

                try:

                    documents_df = (
                        get_claim_documents(
                            selected_claim_id
                        )
                    )

                    validations_df = (
                        get_claim_validations(
                            selected_claim_id
                        )
                    )

                except Exception as exc:

                    documents_df = pd.DataFrame()
                    validations_df = pd.DataFrame()

                    st.error(
                        "Unable to load claim review details: "
                        f"{exc}"
                    )


                (
                    review_tab1,
                    review_tab2,
                    review_tab3,
                ) = st.tabs(
                    [
                        "Validation Summary",
                        "Supporting Documents",
                        "Reviewer Decision",
                    ]
                )


                # ============================================
                # VALIDATION SUMMARY
                # ============================================

                with review_tab1:

                    if validations_df.empty:

                        st.info(
                            "Validation results are not yet available."
                        )

                    else:

                        detail_validations = (
                            validations_df[
                                validations_df[
                                    "VALIDATION_CATEGORY"
                                ] != "CLAIM_DECISION"
                            ]
                            .copy()
                        )


                        passed_count = int(
                            (
                                detail_validations[
                                    "VALIDATION_STATUS"
                                ]
                                == "PASSED"
                            ).sum()
                        )


                        warning_count = int(
                            (
                                detail_validations[
                                    "VALIDATION_STATUS"
                                ]
                                == "WARNING"
                            ).sum()
                        )


                        failed_count = int(
                            (
                                detail_validations[
                                    "VALIDATION_STATUS"
                                ]
                                == "FAILED"
                            ).sum()
                        )


                        (
                            metric_col1,
                            metric_col2,
                            metric_col3,
                        ) = st.columns(3)


                        metric_col1.metric(
                            "Passed Checks",
                            passed_count,
                        )

                        metric_col2.metric(
                            "Warnings",
                            warning_count,
                        )

                        metric_col3.metric(
                            "Failed Checks",
                            failed_count,
                        )


                        issue_validations = (
                            detail_validations[
                                detail_validations[
                                    "VALIDATION_STATUS"
                                ].isin(
                                    [
                                        "FAILED",
                                        "WARNING",
                                    ]
                                )
                            ]
                        )


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

                                validation_status = (
                                    validation[
                                        "VALIDATION_STATUS"
                                    ]
                                )


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


                                    issue_col1, issue_col2 = (
                                        st.columns(2)
                                    )


                                    issue_col1.markdown(
                                        f"**Severity:** "
                                        f"{validation['SEVERITY']}"
                                    )


                                    issue_col2.markdown(
                                        f"**Category:** "
                                        f"{validation['VALIDATION_CATEGORY']}"
                                    )


                                    st.markdown(
                                        "**Expected result**"
                                    )

                                    st.write(
                                        validation[
                                            "EXPECTED_VALUE"
                                        ]
                                    )


                                    st.markdown(
                                        "**Actual result**"
                                    )

                                    st.code(
                                        format_actual_value(
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
                                            .copy()
                                        )


                                        if not related_documents.empty:

                                            st.markdown(
                                                "**Documents related "
                                                "to this validation**"
                                            )

                                            st.dataframe(
                                                related_documents,
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

                                                    "DOCUMENT_URL":
                                                        st.column_config.LinkColumn(
                                                            "Open Document",
                                                            display_text=(
                                                                "View document"
                                                            ),
                                                        ),
                                                },
                                            )


                        st.markdown(
                            "#### All validation checks"
                        )


                        validation_display = (
                            detail_validations[
                                [
                                    "VALIDATION_NAME",
                                    "VALIDATION_STATUS",
                                    "SEVERITY",
                                    "VALIDATION_MESSAGE",
                                    "REQUIRES_REVIEW",
                                ]
                            ]
                            .copy()
                        )


                        validation_display[
                            "STATUS"
                        ] = validation_display[
                            "VALIDATION_STATUS"
                        ].apply(
                            lambda value: (
                                f"{get_status_icon(value)} "
                                f"{value}"
                            )
                        )


                        st.dataframe(
                            validation_display[
                                [
                                    "VALIDATION_NAME",
                                    "STATUS",
                                    "SEVERITY",
                                    "VALIDATION_MESSAGE",
                                    "REQUIRES_REVIEW",
                                ]
                            ],
                            use_container_width=True,
                            hide_index=True,
                            column_config={
                                "VALIDATION_NAME":
                                    st.column_config.TextColumn(
                                        "Validation Check"
                                    ),

                                "STATUS":
                                    st.column_config.TextColumn(
                                        "Status"
                                    ),

                                "SEVERITY":
                                    st.column_config.TextColumn(
                                        "Severity"
                                    ),

                                "VALIDATION_MESSAGE":
                                    st.column_config.TextColumn(
                                        "Validation Result"
                                    ),

                                "REQUIRES_REVIEW":
                                    st.column_config.CheckboxColumn(
                                        "Requires Review"
                                    ),
                            },
                        )


                # ============================================
                # SUPPORTING DOCUMENTS
                # ============================================

                with review_tab2:

                    st.markdown(
                        "#### Submitted claim documents"
                    )


                    if documents_df.empty:

                        st.info(
                            "No supporting documents are available."
                        )

                    else:

                        document_display = (
                            documents_df[
                                [
                                    "FILE_NAME",
                                    "DOCUMENT_TYPE",
                                    "PROCESSING_STATUS",
                                    "ERROR_MESSAGE",
                                    "DOCUMENT_URL",
                                ]
                            ]
                            .copy()
                        )


                        document_display[
                            "STATUS"
                        ] = document_display[
                            "PROCESSING_STATUS"
                        ].apply(
                            lambda value: (
                                f"{get_status_icon(value)} "
                                f"{value}"
                            )
                        )


                        st.dataframe(
                            document_display[
                                [
                                    "FILE_NAME",
                                    "DOCUMENT_TYPE",
                                    "STATUS",
                                    "ERROR_MESSAGE",
                                    "DOCUMENT_URL",
                                ]
                            ],
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

                                "STATUS":
                                    st.column_config.TextColumn(
                                        "Processing Status"
                                    ),

                                "ERROR_MESSAGE":
                                    st.column_config.TextColumn(
                                        "Processing Issue"
                                    ),

                                "DOCUMENT_URL":
                                    st.column_config.LinkColumn(
                                        "Document Link",
                                        display_text=(
                                            "Open document"
                                        ),
                                    ),
                            },
                        )


                # ============================================
                # REVIEWER DECISION
                # ============================================

                with review_tab3:

                    st.markdown(
                        "#### Record reviewer decision"
                    )


                    current_decision = (
                        str(
                            claim[
                                "REVIEWER_DECISION"
                            ]
                        )
                        if pd.notna(
                            claim[
                                "REVIEWER_DECISION"
                            ]
                        )
                        else "PENDING"
                    )


                    current_comments = (
                        str(
                            claim[
                                "REVIEWER_COMMENTS"
                            ]
                        )
                        if pd.notna(
                            claim[
                                "REVIEWER_COMMENTS"
                            ]
                        )
                        else ""
                    )


                    st.markdown(
                        f"**Current decision:** "
                        f"{get_status_icon(current_decision)} "
                        f"{current_decision}"
                    )


                    decision_options = [
                        "PENDING",
                        "APPROVED",
                        "REJECTED",
                        "MORE_INFORMATION_REQUIRED",
                        "MEDICAL_REVIEW_REQUIRED",
                        "FINANCIAL_REVIEW_REQUIRED",
                    ]


                    decision_key = (
                        f"decision_"
                        f"{selected_claim_id}"
                    )


                    comments_key = (
                        f"comments_"
                        f"{selected_claim_id}"
                    )


                    if decision_key not in st.session_state:

                        if current_decision in decision_options:

                            st.session_state[
                                decision_key
                            ] = current_decision

                        else:

                            st.session_state[
                                decision_key
                            ] = "PENDING"


                    if comments_key not in st.session_state:

                        st.session_state[
                            comments_key
                        ] = current_comments


                    decision = st.selectbox(
                        "Decision",
                        options=decision_options,
                        key=decision_key,
                    )


                    comments = st.text_area(
                        "Reviewer comments",
                        placeholder=(
                            "Add the reason for the decision, "
                            "documents reviewed, and any required "
                            "follow-up."
                        ),
                        height=160,
                        key=comments_key,
                    )


                    submit_decision = st.button(
                        "Save Reviewer Decision",
                        type="primary",
                        use_container_width=True,
                        key=(
                            f"save_decision_"
                            f"{selected_claim_id}"
                        ),
                    )


                    if submit_decision:

                        if decision == "PENDING":

                            st.error(
                                "Select a final reviewer decision."
                            )

                        elif not comments.strip():

                            st.error(
                                "Add reviewer comments before "
                                "saving the decision."
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
                                    "Unable to save reviewer "
                                    f"decision: {exc}"
                                )