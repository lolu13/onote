//! Wire format: one JSON object per line on stdin, one per line on stdout.
//! Request:  {"id": <any json>, "op": "<name>", ...op-specific fields}
//! Response: {"id": <echoed>, "ok": true, "result": ...} or {"id": <echoed>, "ok": false, "error": "..."}
//! The helper never writes unsolicited lines to stdout. Diagnostics go to stderr.
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Deserialize)]
pub struct Request {
    #[serde(default)]
    pub id: Value,
    pub op: String,
    #[serde(flatten)]
    pub args: serde_json::Map<String, Value>,
}

#[derive(Serialize)]
pub struct Response {
    pub id: Value,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl Response {
    pub fn ok(id: Value, result: Value) -> Self {
        Response { id, ok: true, result: Some(result), error: None }
    }
    pub fn err(id: Value, error: impl Into<String>) -> Self {
        Response { id, ok: false, result: None, error: Some(error.into()) }
    }
}
