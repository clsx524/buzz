use nostr::Event;
use serde_json::Value;
use tauri::State;

use crate::{
    app_state::AppState,
    relay::{
        assert_expected_relay_scope, assert_expected_signer, query_relay_at_with_keys,
        relay_api_base_url_with_override,
    },
};

/// Read the active relay's signed events, preserving explicit NIP-AR filters.
///
/// The renderer never receives a private key. Pin both destination and signer
/// before awaiting I/O, and refuse a result whose workspace has been retired.
#[tauri::command]
pub async fn query_relay_events(
    filters: Vec<Value>,
    expected_relay_url: String,
    expected_signer_pubkey: String,
    state: State<'_, AppState>,
) -> Result<Vec<Event>, String> {
    if filters.is_empty() || filters.len() > 10 || filters.iter().any(|f| !f.is_object()) {
        return Err("a relay query requires one to ten filter objects".into());
    }
    let base = relay_api_base_url_with_override(&state);
    assert_expected_relay_scope(Some(&expected_relay_url), &base)?;
    let keys = state.signing_keys()?;
    assert_expected_signer(Some(&expected_signer_pubkey), &keys.public_key().to_hex())?;
    let events = query_relay_at_with_keys(&state, &base, &filters, &keys, None).await?;
    assert_expected_relay_scope(Some(&base), &relay_api_base_url_with_override(&state))?;
    assert_expected_signer(
        Some(&expected_signer_pubkey),
        &state.signing_keys()?.public_key().to_hex(),
    )?;
    Ok(events)
}
