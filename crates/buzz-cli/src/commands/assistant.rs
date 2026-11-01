//! Personal-assistant findings, updates and reports stored as NIP-AR artifacts.

use std::io::Read;

use clap::{Subcommand, ValueEnum};
use nostr::{EventBuilder, Kind, Tag};
use serde::{Deserialize, Serialize};

use crate::{
    client::BuzzClient,
    commands::event_output::format_events,
    error::CliError,
    validate::{validate_content_size, MAX_CONTENT_BYTES},
    OutputFormat,
};

/// Personal-assistant artifact operations, usable from a server-side Hermes tool.
#[derive(Subcommand)]
pub enum AssistantCmd {
    /// Publish a finding, update or report; --input is a JSON file or '-' for stdin
    Publish {
        /// Stable artifact UUID; reuse it with --prev for a later revision
        #[arg(long)]
        id: String,
        /// Private conversation channel UUID
        #[arg(long)]
        channel: String,
        #[arg(long, value_enum)]
        kind: AssistantItemKind,
        #[arg(long)]
        title: String,
        /// JSON object with version, summary, body, priority, requiresInput and sources
        #[arg(long)]
        input: String,
        /// Exact current revision event ID; omitted only for creation
        #[arg(long)]
        prev: Option<String>,
        /// Existing conversation message to open for a contextual follow-up
        #[arg(long)]
        root: Option<String>,
    },
    /// List current, accessible findings, updates and reports (not obsolete revisions)
    List {
        #[arg(long, value_enum)]
        kind: Option<AssistantItemKind>,
        #[arg(long)]
        channel: Option<String>,
        #[arg(long, default_value_t = 100)]
        limit: u16,
        #[arg(long, default_value_t = 0)]
        offset: u16,
    },
    /// Read an artifact's authoritative current revision, including a deletion
    Get {
        #[arg(long)]
        id: String,
    },
}

/// User-visible assistant item types; attention state is authored separately.
#[derive(Clone, Copy, ValueEnum)]
pub enum AssistantItemKind {
    /// A potentially actionable finding with supporting evidence.
    Finding,
    /// An informational change that can wait for the user's next check-in.
    Update,
    /// A durable, dated report.
    Report,
}

impl AssistantItemKind {
    fn artifact_type(self) -> &'static str {
        match self {
            Self::Finding => "assistant.finding",
            Self::Update => "assistant.update",
            Self::Report => "assistant.report",
        }
    }
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct AssistantContent {
    version: u8,
    summary: String,
    body: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    topic: Option<String>,
    priority: Priority,
    requires_input: bool,
    sources: Vec<Source>,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
enum Priority {
    Normal,
    Important,
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Source {
    label: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    url: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    checked_at: Option<u64>,
}

fn parse_content(raw: &str) -> Result<String, CliError> {
    validate_content_size(raw)?;
    let content: AssistantContent = serde_json::from_str(raw)
        .map_err(|e| CliError::Usage(format!("invalid assistant content: {e}")))?;
    if content.version != 1 {
        return Err(CliError::Usage(
            "assistant content version must be 1".into(),
        ));
    }
    for source in &content.sources {
        if source.label.trim().is_empty() {
            return Err(CliError::Usage(
                "a source must have a nonblank label".into(),
            ));
        }
        if let Some(raw_url) = &source.url {
            let url = url::Url::parse(raw_url)
                .map_err(|e| CliError::Usage(format!("invalid source URL: {e}")))?;
            if !matches!(url.scheme(), "http" | "https") || url.host().is_none() {
                return Err(CliError::Usage("source URLs must use HTTP or HTTPS".into()));
            }
        }
    }
    let normalized = serde_json::to_string(&content)
        .map_err(|e| CliError::Other(format!("content serialization failed: {e}")))?;
    validate_content_size(&normalized)?;
    Ok(normalized)
}

fn read_input(path: &str) -> Result<String, CliError> {
    if path == "-" {
        read_bounded(std::io::stdin().lock())
    } else {
        let file = std::fs::File::open(path).map_err(|e| {
            CliError::Usage(format!("failed to open assistant input {path:?}: {e}"))
        })?;
        read_bounded(file)
    }
}

fn read_bounded(mut reader: impl Read) -> Result<String, CliError> {
    let mut content = String::new();
    reader
        .by_ref()
        .take(MAX_CONTENT_BYTES as u64 + 1)
        .read_to_string(&mut content)
        .map_err(|e| CliError::Usage(format!("failed to read assistant input: {e}")))?;
    validate_content_size(&content)?;
    Ok(content)
}

fn canonical_uuid(value: &str) -> Result<(), CliError> {
    buzz_core::artifact::canonical_uuid(value)
        .map(|_| ())
        .map_err(|e| CliError::Usage(e.into()))
}

fn artifact_tags(
    id: &str,
    channel: &str,
    kind: AssistantItemKind,
    title: &str,
    prev: Option<&str>,
    root: Option<&str>,
) -> Result<Vec<Tag>, CliError> {
    canonical_uuid(id)?;
    canonical_uuid(channel)?;
    if title.trim().is_empty() || title.len() > 512 {
        return Err(CliError::Usage(
            "title must be nonblank and at most 512 bytes".into(),
        ));
    }
    let mut tags = vec![
        vec!["ar", "1"],
        vec!["d", id],
        vec!["h", channel],
        vec!["type", kind.artifact_type()],
        vec!["title", title],
        vec!["op", if prev.is_some() { "update" } else { "create" }],
    ];
    for (name, value) in [("prev", prev), ("root", root)] {
        if let Some(value) = value {
            buzz_core::artifact::event_id(value).map_err(|e| CliError::Usage(e.into()))?;
            tags.push(vec![name, value]);
        }
    }
    tags.into_iter()
        .map(|parts| Tag::parse(parts).map_err(|e| CliError::Usage(e.to_string())))
        .collect()
}

async fn require_private_channel(client: &BuzzClient, channel: &str) -> Result<(), CliError> {
    let raw = client
        .query(&serde_json::json!({"kinds":[39000], "#d":[channel], "limit":1}))
        .await?;
    let metadata: Vec<nostr::Event> = serde_json::from_str(&raw)
        .map_err(|e| CliError::Other(format!("invalid channel metadata: {e}")))?;
    let private = metadata.first().is_some_and(|event| {
        let mut private = false;
        let mut public = false;
        for tag in event.tags.iter() {
            match tag.as_slice() {
                [name] if name == "private" => private = true,
                [name] if name == "public" => public = true,
                _ => {}
            }
        }
        private && !public
    });
    if !private {
        return Err(CliError::Usage(
            "assistant records require an accessible private conversation channel".into(),
        ));
    }
    Ok(())
}

/// Dispatch personal-assistant operations through the existing signed relay bridge.
pub async fn dispatch(
    cmd: AssistantCmd,
    client: &BuzzClient,
    format: &OutputFormat,
) -> Result<(), CliError> {
    match cmd {
        AssistantCmd::Publish {
            id,
            channel,
            kind,
            title,
            input,
            prev,
            root,
        } => {
            let tags = artifact_tags(
                &id,
                &channel,
                kind,
                &title,
                prev.as_deref(),
                root.as_deref(),
            )?;
            let content = parse_content(&read_input(&input)?)?;
            require_private_channel(client, &channel).await?;
            let event =
                client.sign_event(EventBuilder::new(Kind::Custom(45010), content).tags(tags))?;
            let event_id = event.id.to_hex();
            let raw = client.submit_event(event).await.map_err(|error| match error {
                CliError::DeliveryUnknown(detail) => CliError::DeliveryUnknown(format!(
                    "{detail}; artifact {id}, signed event {event_id}; read its head with buzz assistant get before submitting another revision"
                )),
                CliError::Relay { status: 409, body } => CliError::Conflict(format!(
                    "artifact {id}: {body}; read its current head before choosing a new revision"
                )),
                error => error,
            })?;
            let response: serde_json::Value = serde_json::from_str(&raw)
                .map_err(|e| CliError::Other(format!("invalid relay publication response: {e}")))?;
            if response
                .get("accepted")
                .and_then(serde_json::Value::as_bool)
                != Some(true)
            {
                return Err(CliError::Other(format!(
                    "artifact publication was not accepted: {raw}"
                )));
            }
            println!(
                "{}",
                serde_json::json!({
                    "accepted": true, "artifact_id": id, "event_id": event_id,
                    "channel_id": channel, "type": kind.artifact_type()
                })
            );
            Ok(())
        }
        AssistantCmd::List {
            kind,
            channel,
            limit,
            offset,
        } => {
            if limit == 0 || limit > 1000 || offset > 10000 {
                return Err(CliError::Usage(
                    "limit must be 1–1000; offset must be at most 10000".into(),
                ));
            }
            let types: Vec<&str> = match kind {
                Some(kind) => vec![kind.artifact_type()],
                None => vec!["assistant.finding", "assistant.update", "assistant.report"],
            };
            let mut filter = serde_json::json!({
                "artifact": "current", "#type": types, "limit": limit, "offset": offset
            });
            if let Some(channel) = channel {
                canonical_uuid(&channel)?;
                filter["#h"] = serde_json::json!([channel]);
            }
            let raw = client.query(&filter).await?;
            println!("{}", format_events(&raw, format));
            Ok(())
        }
        AssistantCmd::Get { id } => {
            canonical_uuid(&id)?;
            let raw = client
                .query(&serde_json::json!({"artifact":"head", "#d":[id]}))
                .await?;
            println!("{}", format_events(&raw, format));
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn producer_accepts_shared_evidence_contract_and_rejects_unsafe_sources() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../../test-fixtures/assistant-contract.json"
        ))
        .unwrap();
        let input = &fixture["item"];
        let parsed: serde_json::Value =
            serde_json::from_str(&parse_content(&input.to_string()).unwrap()).unwrap();
        assert_eq!(parsed["requiresInput"], true);
        assert_eq!(parsed["sources"][0]["checkedAt"], 1793404800_u64);
        let mut invalid = input.clone();
        invalid["sources"][0]["url"] = "javascript:alert(1)".into();
        assert!(parse_content(&invalid.to_string()).is_err());
        let mut unsupported = input.clone();
        unsupported["version"] = 2.into();
        assert!(parse_content(&unsupported.to_string()).is_err());
    }

    #[test]
    fn revisions_keep_identity_and_require_canonical_references() {
        let id = "22222222-2222-4222-8222-222222222222";
        let channel = "33333333-3333-4333-8333-333333333333";
        let previous = "a".repeat(64);
        let tags = artifact_tags(
            id,
            channel,
            AssistantItemKind::Finding,
            "Review charges",
            Some(&previous),
            None,
        )
        .unwrap();
        let event = EventBuilder::new(Kind::Custom(45010), "{}")
            .tags(tags)
            .sign_with_keys(&nostr::Keys::generate())
            .unwrap();
        let envelope = buzz_core::artifact::validate(&event).unwrap();
        assert_eq!(envelope.id.to_string(), id);
        assert_eq!(envelope.op, buzz_core::artifact::ArtifactOp::Update);
        assert_eq!(envelope.prev, Some(vec![0xaa; 32]));
        assert!(artifact_tags(
            id,
            channel,
            AssistantItemKind::Finding,
            "Review",
            Some("not-an-event"),
            None
        )
        .is_err());
        assert!(artifact_tags(
            "00000000-0000-0000-0000-000000000000",
            channel,
            AssistantItemKind::Finding,
            "Review",
            None,
            None
        )
        .is_err());
    }
}
