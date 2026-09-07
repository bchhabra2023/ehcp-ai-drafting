"""
Microsoft Entra ID authentication helper for the Streamlit frontend.

Uses authorization code flow (browser redirect) via MSAL ConfidentialClientApplication.
User clicks sign-in -> redirected to Microsoft login -> comes back with auth code -> exchanged for tokens.
"""

import os
from functools import lru_cache
import streamlit as st
import msal
from dotenv import load_dotenv
from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient

load_dotenv()

ENTRA_TENANT_ID = os.getenv("ENTRA_TENANT_ID", "").strip()
ENTRA_CLIENT_ID = os.getenv("ENTRA_CLIENT_ID", "").strip()
ENTRA_FRONTEND_CLIENT_ID = os.getenv("ENTRA_FRONTEND_CLIENT_ID", "").strip() or ENTRA_CLIENT_ID
ENTRA_BACKEND_CLIENT_ID = os.getenv("ENTRA_BACKEND_CLIENT_ID", "").strip() or ENTRA_CLIENT_ID
ENTRA_SCOPE = os.getenv("ENTRA_SCOPE", "").strip()
ENTRA_AUTHORITY = f"https://login.microsoftonline.com/{ENTRA_TENANT_ID}"
ENTRA_SCOPES = [
    ENTRA_SCOPE or f"api://{ENTRA_BACKEND_CLIENT_ID}/user_impersonation",
]
# Redirect URI â€” the app's own URL (set via env or auto-detected)
ENTRA_REDIRECT_URI = os.getenv("ENTRA_REDIRECT_URI", "").strip()
AZURE_KEY_VAULT_URL = os.getenv("AZURE_KEY_VAULT_URL", "").strip()
ENTRA_CLIENT_SECRET_SECRET_NAME = os.getenv("ENTRA_CLIENT_SECRET_SECRET_NAME", "").strip()
AZURE_CLIENT_ID = os.getenv("AZURE_CLIENT_ID", "").strip()

AUTH_ENABLED = os.getenv("AUTH_ENABLED", "false").lower() in ("true", "1", "yes")


@lru_cache(maxsize=1)
def _get_key_vault_secret_client() -> SecretClient:
    if not AZURE_KEY_VAULT_URL:
        raise RuntimeError("AZURE_KEY_VAULT_URL is required when authentication is enabled.")

    credential_kwargs = {}
    if AZURE_CLIENT_ID:
        credential_kwargs["managed_identity_client_id"] = AZURE_CLIENT_ID

    return SecretClient(
        vault_url=AZURE_KEY_VAULT_URL,
        credential=DefaultAzureCredential(**credential_kwargs),
    )


@lru_cache(maxsize=1)
def _get_entra_client_secret() -> str:
    if not ENTRA_CLIENT_SECRET_SECRET_NAME:
        raise RuntimeError(
            "ENTRA_CLIENT_SECRET_SECRET_NAME is required when authentication is enabled."
        )

    client = _get_key_vault_secret_client()
    secret = client.get_secret(ENTRA_CLIENT_SECRET_SECRET_NAME)
    if not secret.value:
        raise RuntimeError(
            f"Key Vault secret '{ENTRA_CLIENT_SECRET_SECRET_NAME}' is empty."
        )
    return secret.value


def _get_redirect_uri() -> str:
    """Get the redirect URI for the auth code flow."""
    if ENTRA_REDIRECT_URI:
        return ENTRA_REDIRECT_URI
    return os.getenv("FRONTEND_URL", "http://localhost:8501")


def _get_msal_app() -> msal.ConfidentialClientApplication:
    """Create MSAL ConfidentialClientApplication."""
    return msal.ConfidentialClientApplication(
        client_id=ENTRA_FRONTEND_CLIENT_ID,
        client_credential=_get_entra_client_secret(),
        authority=ENTRA_AUTHORITY,
    )


def _validate_auth_config() -> bool:
    missing = []
    if not ENTRA_TENANT_ID:
        missing.append("ENTRA_TENANT_ID")
    if not ENTRA_FRONTEND_CLIENT_ID:
        missing.append("ENTRA_CLIENT_ID (or ENTRA_FRONTEND_CLIENT_ID)")
    if not AZURE_KEY_VAULT_URL:
        missing.append("AZURE_KEY_VAULT_URL")
    if not ENTRA_CLIENT_SECRET_SECRET_NAME:
        missing.append("ENTRA_CLIENT_SECRET_SECRET_NAME")
    if missing:
        st.error("Authentication is enabled but missing env values: " + ", ".join(missing))
        return False
    return True


def get_auth_headers() -> dict:
    if not AUTH_ENABLED:
        return {}
    if "access_token" not in st.session_state or not st.session_state.access_token:
        return {}
    return {"Authorization": f"Bearer {st.session_state.access_token}"}


def login_ui():
    if not AUTH_ENABLED:
        return True

    if not _validate_auth_config():
        return False

    # Already logged in
    if "access_token" in st.session_state and st.session_state.access_token:
        return True

    # Check if we're returning from Microsoft login with an auth code
    query_params = st.query_params
    auth_code = query_params.get("code")
    auth_error = query_params.get("error")

    if auth_code:
        # Exchange the auth code for tokens
        try:
            app = _get_msal_app()
        except Exception as exc:
            st.error(f"Failed to load frontend auth secret from Key Vault: {exc}")
            st.query_params.clear()
            return False
        redirect_uri = _get_redirect_uri()
        result = app.acquire_token_by_authorization_code(
            code=auth_code,
            scopes=ENTRA_SCOPES,
            redirect_uri=redirect_uri,
        )

        if "access_token" in result:
            st.session_state.access_token = result["access_token"]
            claims = result.get("id_token_claims", {})
            st.session_state.user_name = claims.get("name", "User")
            st.session_state.user_email = claims.get(
                "preferred_username", claims.get("upn", ""))
            # Save email to localStorage so future tabs can skip the account picker
            email = st.session_state.user_email
            if email:
                st.session_state._login_hint = email
            # Clear the code from URL
            st.query_params.clear()
            st.rerun()
        else:
            error = result.get("error_description", result.get("error", "Unknown error"))
            st.error(f"Authentication failed: {error}")
            st.query_params.clear()
            return False

    # Microsoft returned an error â€” mark redirect as failed, show button
    if auth_error:
        st.session_state._auth_redirect_failed = True
        st.query_params.clear()
        st.rerun()

    # Auto-redirect to Microsoft (no prompt param â€” uses existing session if available)
    # Only show button if auto-redirect already failed (prevents infinite loop)
    if not st.session_state.get("_auth_redirect_failed"):
        try:
            app = _get_msal_app()
        except Exception as exc:
            st.error(f"Failed to load frontend auth secret from Key Vault: {exc}")
            return False
        redirect_uri = _get_redirect_uri()
        auth_url = app.get_authorization_request_url(
            scopes=ENTRA_SCOPES,
            redirect_uri=redirect_uri,
        )
        # Use meta refresh to redirect â€” JS doesn't work in Streamlit's sandboxed context
        st.markdown(
            f'<meta http-equiv="refresh" content="0;url={auth_url}">',
            unsafe_allow_html=True,
        )
        st.stop()

    # Show sign-in page (auto-redirect failed â€” fallback)
    st.title("\U0001f510 Sign In")
    st.markdown("You must sign in with your Microsoft account to use this application.")

    try:
        app = _get_msal_app()
    except Exception as exc:
        st.error(f"Failed to load frontend auth secret from Key Vault: {exc}")
        return False
    redirect_uri = _get_redirect_uri()
    auth_url = app.get_authorization_request_url(
        scopes=ENTRA_SCOPES,
        redirect_uri=redirect_uri,
    )

    st.link_button("Sign in with Microsoft", auth_url, type="primary")
    return False


def logout():
    st.session_state.pop("access_token", None)
    st.session_state.pop("user_name", None)
    st.session_state.pop("_auth_redirect_failed", None)
    st.session_state.pop("_login_hint", None)
    st.rerun()
