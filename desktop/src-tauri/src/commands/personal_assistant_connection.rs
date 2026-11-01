use serde::{Deserialize, Serialize};

const CONNECTION_KEY: &str = "personal-assistant-client-connection";

/// One atomic profile connection snapshot, held only in the existing OS secret store.
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct PersonalAssistantConnection {
    origin: String,
    profile: String,
    token: String,
}

impl PersonalAssistantConnection {
    fn validate(&self) -> Result<(), String> {
        let url = url::Url::parse(&self.origin).map_err(|_| "Invalid assistant server origin")?;
        let loopback = matches!(url.host_str(), Some("localhost" | "127.0.0.1" | "[::1]"));
        if (url.scheme() != "https" && !(url.scheme() == "http" && loopback))
            || !url.username().is_empty()
            || url.password().is_some()
            || url.query().is_some()
            || url.fragment().is_some()
            || url.path() != "/"
        {
            return Err("Assistant origin requires HTTPS and no credentials, path, query, or fragment (localhost HTTP is allowed)".into());
        }
        if self.profile.is_empty()
            || self.profile.len() > 128
            || !self
                .profile
                .starts_with(|ch: char| ch.is_ascii_alphanumeric())
            || !self
                .profile
                .chars()
                .all(|ch| ch.is_ascii_alphanumeric() || "_.-".contains(ch))
        {
            return Err("Invalid assistant profile".into());
        }
        if self.token.trim().is_empty() || self.token.contains(['\r', '\n']) {
            return Err("An assistant client API token is required".into());
        }
        Ok(())
    }
}

fn connection_store() -> &'static crate::secret_store::SecretStore {
    crate::secret_store::SecretStore::shared(crate::app_state::keyring_service())
}

/// Read the assistant API connection from the OS secret store; never fall back to a file.
#[tauri::command]
pub async fn load_personal_assistant_connection(
) -> Result<Option<PersonalAssistantConnection>, String> {
    tauri::async_runtime::spawn_blocking(|| {
        let Some(raw) = connection_store().load(CONNECTION_KEY)? else {
            return Ok(None);
        };
        let connection: PersonalAssistantConnection = serde_json::from_str(&raw)
            .map_err(|_| "Stored assistant connection is invalid; replace or disconnect it")?;
        connection.validate()?;
        Ok(Some(connection))
    })
    .await
    .map_err(|error| format!("Assistant secure storage task failed: {error}"))?
}

/// Persist the connection as one secret-store mutation, including its profile and origin.
#[tauri::command]
pub async fn save_personal_assistant_connection(
    connection: PersonalAssistantConnection,
) -> Result<(), String> {
    connection.validate()?;
    tauri::async_runtime::spawn_blocking(move || {
        let raw = serde_json::to_string(&connection)
            .map_err(|_| "Unable to encode assistant connection")?;
        connection_store().store(CONNECTION_KEY, &raw)
    })
    .await
    .map_err(|error| format!("Assistant secure storage task failed: {error}"))?
}

/// Remove the assistant connection and its token from the OS secret store.
#[tauri::command]
pub async fn clear_personal_assistant_connection() -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(|| connection_store().delete(CONNECTION_KEY))
        .await
        .map_err(|error| format!("Assistant secure storage task failed: {error}"))?
}

#[cfg(test)]
mod tests {
    use super::PersonalAssistantConnection;

    #[test]
    fn connection_rejects_credential_leak_destinations_and_accepts_local_development() {
        for origin in [
            "https://user:secret@example.com",
            "https://example.com/path",
            "https://example.com?token=x",
            "http://example.com",
            "file:///tmp",
        ] {
            assert!(PersonalAssistantConnection {
                origin: origin.into(),
                profile: "home".into(),
                token: "client-token".into()
            }
            .validate()
            .is_err());
        }
        for origin in [
            "https://assistant.example.com",
            "http://localhost:8080",
            "http://127.0.0.1:8080",
            "http://[::1]:8080",
        ] {
            assert!(PersonalAssistantConnection {
                origin: origin.into(),
                profile: "home".into(),
                token: "client-token".into()
            }
            .validate()
            .is_ok());
        }
    }
}
